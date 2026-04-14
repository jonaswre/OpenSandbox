# Copyright 2026 Alibaba Group Holding Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Cloud Hypervisor VM lifecycle manager for Windows sandboxes.

Manages the full lifecycle of Windows VMs running under Cloud Hypervisor (CLH):
create COW overlay images, allocate TAP networking, boot UEFI VMs, health-check
execd readiness, and tear down resources on sandbox deletion.
"""

import asyncio
import json
import logging
import os
import random
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import httpx

from opensandbox_server.config import WindowsRuntimeConfig

logger = logging.getLogger(__name__)


@dataclass
class CLHVMInstance:
    """Tracks a running Cloud Hypervisor VM and its associated resources."""

    sandbox_id: str
    process: asyncio.subprocess.Process
    api_socket: Path
    overlay_path: Path
    tap_device: str
    guest_ip: str
    mac_address: str
    cpus: int
    memory_mb: int
    created_at: float = field(default_factory=time.time)
    execd_port: int = 8080
    _pid: Optional[int] = field(default=None, init=False)

    def __post_init__(self):
        self._pid = self.process.pid

    @property
    def pid(self) -> Optional[int]:
        return self._pid

    @property
    def execd_url(self) -> str:
        return f"http://{self.guest_ip}:{self.execd_port}"

    @property
    def is_running(self) -> bool:
        return self.process.returncode is None


class CLHVMManager:
    """Manages Cloud Hypervisor VM lifecycle for Windows sandboxes."""

    def __init__(self, config: WindowsRuntimeConfig):
        self.config = config
        self.vms: dict[str, CLHVMInstance] = {}
        self._ip_counter = 2  # Start at .2 (bridge is .1)
        self._ensure_directories()

    def _ensure_directories(self):
        Path(self.config.api_socket_dir).mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Image management
    # ------------------------------------------------------------------

    def _resolve_base_image(self, image_name: str) -> Path:
        """Resolve image name to a base image path in the image directory."""
        image_dir = Path(self.config.image_dir)

        # Try exact name first, then common extensions
        for suffix in ("", ".qcow2", ".raw", ".img"):
            candidate = image_dir / f"{image_name}{suffix}"
            if candidate.exists():
                return candidate

        raise FileNotFoundError(
            f"Windows base image '{image_name}' not found in {image_dir}. "
            f"Available images: {[f.name for f in image_dir.iterdir() if f.is_file()]}"
        )

    def _create_overlay(self, sandbox_id: str, image_name: str) -> Path:
        """Create a copy-on-write overlay image from the base image."""
        base_image = self._resolve_base_image(image_name)
        overlay_dir = Path(self.config.image_dir) / "overlays"
        overlay_dir.mkdir(parents=True, exist_ok=True)
        overlay_path = overlay_dir / f"{sandbox_id}.qcow2"

        # Determine backing format from extension
        backing_fmt = "raw" if base_image.suffix == ".raw" else "qcow2"

        result = subprocess.run(
            [
                "qemu-img", "create",
                "-f", "qcow2",
                "-b", str(base_image),
                "-F", backing_fmt,
                str(overlay_path),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Failed to create overlay image: {result.stderr}")

        logger.info("Created COW overlay %s (backing: %s)", overlay_path, base_image)
        return overlay_path

    # ------------------------------------------------------------------
    # Networking
    # ------------------------------------------------------------------

    @staticmethod
    def _generate_mac() -> str:
        """Generate a locally-administered unicast MAC address."""
        octets = [0x52, 0x54, 0x00]  # QEMU/KVM OUI prefix
        octets.extend(random.randint(0, 255) for _ in range(3))
        return ":".join(f"{b:02x}" for b in octets)

    def _allocate_ip(self) -> str:
        """Allocate the next guest IP on the bridge subnet (10.44.0.0/24)."""
        ip = f"10.44.0.{self._ip_counter}"
        self._ip_counter += 1
        if self._ip_counter > 254:
            self._ip_counter = 2
        return ip

    def _create_tap(self, sandbox_id: str) -> str:
        """Create a TAP device and attach it to the bridge."""
        tap_name = f"tap-{sandbox_id[:8]}"

        try:
            subprocess.run(
                ["ip", "tuntap", "add", "dev", tap_name, "mode", "tap"],
                check=True, capture_output=True, text=True, timeout=10,
            )
            subprocess.run(
                ["ip", "link", "set", tap_name, "master", self.config.network_bridge],
                check=True, capture_output=True, text=True, timeout=10,
            )
            subprocess.run(
                ["ip", "link", "set", tap_name, "up"],
                check=True, capture_output=True, text=True, timeout=10,
            )
        except subprocess.CalledProcessError as e:
            logger.error("Failed to create TAP device %s: %s", tap_name, e.stderr)
            raise RuntimeError(f"TAP creation failed: {e.stderr}") from e

        logger.info("Created TAP device %s on bridge %s", tap_name, self.config.network_bridge)
        return tap_name

    def _destroy_tap(self, tap_name: str):
        """Remove a TAP device."""
        try:
            subprocess.run(
                ["ip", "link", "delete", tap_name],
                capture_output=True, text=True, timeout=10,
            )
        except Exception:
            logger.warning("Failed to delete TAP device %s (may already be gone)", tap_name)

    # ------------------------------------------------------------------
    # VM lifecycle
    # ------------------------------------------------------------------

    async def create_vm(
        self,
        sandbox_id: str,
        image_name: str,
        cpus: Optional[int] = None,
        memory_mb: Optional[int] = None,
    ) -> CLHVMInstance:
        """Create and boot a Windows VM via Cloud Hypervisor."""
        if sandbox_id in self.vms:
            raise ValueError(f"VM {sandbox_id} already exists")

        effective_cpus = cpus or self.config.default_cpus
        effective_memory = memory_mb or self.config.default_memory_mb

        # Create COW overlay
        overlay_path = self._create_overlay(sandbox_id, image_name)

        # Set up networking
        tap_device = self._create_tap(sandbox_id)
        mac_address = self._generate_mac()
        guest_ip = self._allocate_ip()

        # Build CLH command
        api_socket = Path(self.config.api_socket_dir) / f"{sandbox_id}.sock"

        cmd = [
            self.config.clh_binary,
            "--kernel", self.config.firmware,
            "--disk", f"path={overlay_path}",
            "--cpus", f"boot={effective_cpus}",
            "--memory", f"size={effective_memory}M",
            "--net", f"tap={tap_device},mac={mac_address}",
            "--serial", "tty",
            "--console", "off",
            "--api-socket", str(api_socket),
        ]

        logger.info(
            "Starting CLH VM %s: cpus=%d, memory=%dMB, image=%s",
            sandbox_id, effective_cpus, effective_memory, image_name,
        )

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        vm = CLHVMInstance(
            sandbox_id=sandbox_id,
            process=process,
            api_socket=api_socket,
            overlay_path=overlay_path,
            tap_device=tap_device,
            guest_ip=guest_ip,
            mac_address=mac_address,
            cpus=effective_cpus,
            memory_mb=effective_memory,
            execd_port=self.config.execd_port,
        )

        # Wait for execd to become reachable
        try:
            await self._wait_for_execd(vm)
        except TimeoutError:
            logger.error("VM %s boot timed out, destroying", sandbox_id)
            await self._force_destroy(vm)
            raise

        self.vms[sandbox_id] = vm
        logger.info("VM %s is ready (pid=%s, ip=%s)", sandbox_id, vm.pid, guest_ip)
        return vm

    async def destroy_vm(self, sandbox_id: str):
        """Stop a VM and clean up all associated resources."""
        vm = self.vms.pop(sandbox_id, None)
        if vm is None:
            raise KeyError(f"VM {sandbox_id} not found")

        await self._force_destroy(vm)
        logger.info("VM %s destroyed", sandbox_id)

    async def _force_destroy(self, vm: CLHVMInstance):
        """Force-stop a VM and clean up resources."""
        # Try graceful shutdown via CLH API socket
        if vm.api_socket.exists():
            try:
                await self._clh_api_request(vm.api_socket, "PUT", "/api/v1/vm.shutdown")
                try:
                    await asyncio.wait_for(vm.process.wait(), timeout=10)
                except asyncio.TimeoutError:
                    pass
            except Exception:
                logger.debug("Graceful shutdown failed for %s, killing", vm.sandbox_id)

        # Force kill if still running
        if vm.is_running:
            try:
                vm.process.kill()
                await asyncio.wait_for(vm.process.wait(), timeout=5)
            except Exception:
                logger.warning("Could not kill CLH process for %s", vm.sandbox_id)

        # Clean up resources
        if vm.overlay_path.exists():
            try:
                os.unlink(vm.overlay_path)
            except OSError:
                logger.warning("Failed to remove overlay %s", vm.overlay_path)

        if vm.api_socket.exists():
            try:
                os.unlink(vm.api_socket)
            except OSError:
                pass

        self._destroy_tap(vm.tap_device)

    async def pause_vm(self, sandbox_id: str):
        """Pause a running VM via CLH API."""
        vm = self._get_vm(sandbox_id)
        await self._clh_api_request(vm.api_socket, "PUT", "/api/v1/vm.pause")
        logger.info("VM %s paused", sandbox_id)

    async def resume_vm(self, sandbox_id: str):
        """Resume a paused VM via CLH API."""
        vm = self._get_vm(sandbox_id)
        await self._clh_api_request(vm.api_socket, "PUT", "/api/v1/vm.resume")
        logger.info("VM %s resumed", sandbox_id)

    def get_vm(self, sandbox_id: str) -> Optional[CLHVMInstance]:
        """Get a VM instance by sandbox ID, or None."""
        return self.vms.get(sandbox_id)

    def list_vms(self) -> list[CLHVMInstance]:
        """List all managed VM instances."""
        return list(self.vms.values())

    def _get_vm(self, sandbox_id: str) -> CLHVMInstance:
        """Get a VM instance, raising KeyError if not found."""
        vm = self.vms.get(sandbox_id)
        if vm is None:
            raise KeyError(f"VM {sandbox_id} not found")
        return vm

    # ------------------------------------------------------------------
    # Health checking
    # ------------------------------------------------------------------

    async def _wait_for_execd(self, vm: CLHVMInstance):
        """Poll execd health endpoint until it responds or timeout."""
        deadline = time.time() + self.config.boot_timeout_seconds
        url = f"{vm.execd_url}/ping"

        async with httpx.AsyncClient(timeout=3.0) as client:
            while time.time() < deadline:
                if not vm.is_running:
                    stderr = ""
                    if vm.process.stderr:
                        stderr = (await vm.process.stderr.read()).decode(errors="replace")
                    raise RuntimeError(
                        f"CLH process exited with code {vm.process.returncode} "
                        f"before execd became ready. stderr: {stderr[:500]}"
                    )
                try:
                    resp = await client.get(url)
                    if resp.status_code == 200:
                        logger.info("execd ready at %s", vm.execd_url)
                        return
                except (httpx.ConnectError, httpx.ReadTimeout, httpx.ConnectTimeout, OSError):
                    pass

                await asyncio.sleep(2)

        raise TimeoutError(
            f"execd at {vm.execd_url} did not become ready within "
            f"{self.config.boot_timeout_seconds}s"
        )

    async def check_vm_health(self, sandbox_id: str) -> bool:
        """Check if a VM's execd is responding."""
        vm = self.vms.get(sandbox_id)
        if vm is None or not vm.is_running:
            return False

        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                resp = await client.get(f"{vm.execd_url}/ping")
                return resp.status_code == 200
        except Exception:
            return False

    # ------------------------------------------------------------------
    # CLH API socket communication
    # ------------------------------------------------------------------

    @staticmethod
    async def _clh_api_request(
        socket_path: Path, method: str, path: str, body: Optional[dict] = None,
    ) -> dict:
        """Send a request to the CLH HTTP API via Unix domain socket."""
        transport = httpx.AsyncHTTPTransport(uds=str(socket_path))
        async with httpx.AsyncClient(transport=transport, timeout=10.0) as client:
            url = f"http://localhost{path}"
            if method.upper() == "GET":
                resp = await client.get(url)
            elif method.upper() == "PUT":
                resp = await client.put(url, json=body)
            else:
                resp = await client.request(method.upper(), url, json=body)

            if resp.status_code >= 400:
                raise RuntimeError(
                    f"CLH API {method} {path} returned {resp.status_code}: {resp.text}"
                )
            if resp.content:
                return resp.json()
            return {}

    # ------------------------------------------------------------------
    # Startup validation
    # ------------------------------------------------------------------

    @classmethod
    def validate_on_startup(cls, config: WindowsRuntimeConfig):
        """Validate Windows runtime prerequisites at server startup."""
        clh = Path(config.clh_binary)
        if not clh.exists():
            raise ValueError(
                f"Cloud Hypervisor binary not found at {config.clh_binary}. "
                f"Install CLH: https://github.com/cloud-hypervisor/cloud-hypervisor/releases"
            )
        if not os.access(str(clh), os.X_OK):
            raise ValueError(f"Cloud Hypervisor binary at {config.clh_binary} is not executable.")

        firmware = Path(config.firmware)
        if not firmware.exists():
            raise ValueError(
                f"CLOUDHV.fd firmware not found at {config.firmware}. "
                f"Build from edk2 or download from CLH releases."
            )

        image_dir = Path(config.image_dir)
        if not image_dir.is_dir():
            raise ValueError(
                f"Windows image directory {config.image_dir} does not exist. "
                f"Create it and place prepared Windows .qcow2 images inside."
            )

        # Check qemu-img is available (needed for COW overlays)
        if not shutil.which("qemu-img"):
            raise ValueError(
                "qemu-img not found in PATH. Install qemu-utils for COW overlay support."
            )

        logger.info(
            "Windows runtime validated: clh=%s, firmware=%s, image_dir=%s",
            config.clh_binary, config.firmware, config.image_dir,
        )
