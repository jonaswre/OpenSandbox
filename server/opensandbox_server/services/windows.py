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
Windows sandbox service using Cloud Hypervisor VMs.

Implements the SandboxService interface for Windows guests. Each sandbox is a
full Cloud Hypervisor VM booted from a pre-built Windows disk image with execd
pre-installed as a Windows service.
"""

import json
import logging
import threading
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException

from opensandbox_server.api.schema import (
    CreateSandboxRequest,
    CreateSandboxResponse,
    Endpoint,
    ListSandboxesRequest,
    ListSandboxesResponse,
    PaginationInfo,
    PlatformSpec,
    RenewSandboxExpirationRequest,
    RenewSandboxExpirationResponse,
    Sandbox,
    SandboxStatus,
)
from opensandbox_server.config import AppConfig, get_config
from opensandbox_server.services.clh_vm_manager import CLHVMManager
from opensandbox_server.services.sandbox_service import SandboxService

logger = logging.getLogger(__name__)


class WindowsErrorCodes:
    """Error codes for Windows sandbox service."""

    VM_NOT_FOUND = "WINDOWS::VM_NOT_FOUND"
    VM_CREATE_FAILED = "WINDOWS::VM_CREATE_FAILED"
    VM_DELETE_FAILED = "WINDOWS::VM_DELETE_FAILED"
    VM_PAUSE_FAILED = "WINDOWS::VM_PAUSE_FAILED"
    VM_RESUME_FAILED = "WINDOWS::VM_RESUME_FAILED"
    VM_NOT_RUNNING = "WINDOWS::VM_NOT_RUNNING"
    VM_NOT_PAUSED = "WINDOWS::VM_NOT_PAUSED"
    INVALID_GUEST_OS = "WINDOWS::INVALID_GUEST_OS"
    BOOT_TIMEOUT = "WINDOWS::BOOT_TIMEOUT"
    INVALID_PORT = "WINDOWS::INVALID_PORT"


# Sandbox metadata stored alongside CLHVMInstance
class _SandboxMeta:
    """Metadata tracked per sandbox that CLHVMInstance doesn't store."""

    __slots__ = (
        "sandbox_id", "image_uri", "entrypoint", "metadata",
        "platform", "status", "created_at", "expires_at",
        "expiration_timer",
    )

    def __init__(
        self,
        sandbox_id: str,
        image_uri: str,
        entrypoint: list[str],
        metadata: Optional[dict[str, str]],
        platform: Optional[PlatformSpec],
        created_at: datetime,
        expires_at: Optional[datetime],
    ):
        self.sandbox_id = sandbox_id
        self.image_uri = image_uri
        self.entrypoint = entrypoint
        self.metadata = metadata
        self.platform = platform
        self.status = "Running"
        self.created_at = created_at
        self.expires_at = expires_at
        self.expiration_timer: Optional[threading.Timer] = None


class WindowsSandboxService(SandboxService):
    """SandboxService implementation for Windows guests via Cloud Hypervisor."""

    def __init__(self, config: Optional[AppConfig] = None):
        self.app_config = config or get_config()
        win_config = self.app_config.windows_runtime
        if win_config is None:
            raise RuntimeError(
                "windows_runtime config block is required when runtime.type = 'windows'"
            )
        self.vm_manager = CLHVMManager(win_config)
        self._meta: dict[str, _SandboxMeta] = {}
        self._lock = threading.Lock()
        self._max_timeout = self.app_config.server.max_sandbox_timeout_seconds

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _get_meta(self, sandbox_id: str) -> _SandboxMeta:
        with self._lock:
            meta = self._meta.get(sandbox_id)
        if meta is None:
            raise HTTPException(
                status_code=404,
                detail={"code": WindowsErrorCodes.VM_NOT_FOUND, "message": f"Sandbox {sandbox_id} not found"},
            )
        return meta

    def _build_sandbox_status(self, meta: _SandboxMeta) -> SandboxStatus:
        return SandboxStatus(state=meta.status)

    def _build_sandbox(self, meta: _SandboxMeta) -> Sandbox:
        from opensandbox_server.api.schema import ImageSpec

        return Sandbox(
            id=meta.sandbox_id,
            image=ImageSpec(uri=meta.image_uri),
            platform=meta.platform,
            status=self._build_sandbox_status(meta),
            metadata=meta.metadata,
            entrypoint=meta.entrypoint,
            expires_at=meta.expires_at,
            created_at=meta.created_at,
        )

    def _schedule_expiration(self, meta: _SandboxMeta):
        if meta.expires_at is None:
            return
        delay = (meta.expires_at - datetime.now(timezone.utc)).total_seconds()
        if delay <= 0:
            delay = 0.1

        def _expire():
            logger.info("Sandbox %s expired, destroying VM", meta.sandbox_id)
            try:
                self.delete_sandbox(meta.sandbox_id)
            except Exception:
                logger.exception("Failed to auto-delete expired sandbox %s", meta.sandbox_id)

        timer = threading.Timer(delay, _expire)
        timer.daemon = True
        timer.start()
        meta.expiration_timer = timer

    def _cancel_expiration(self, meta: _SandboxMeta):
        if meta.expiration_timer is not None:
            meta.expiration_timer.cancel()
            meta.expiration_timer = None

    # ------------------------------------------------------------------
    # SandboxService implementation
    # ------------------------------------------------------------------

    async def create_sandbox(self, request: CreateSandboxRequest) -> CreateSandboxResponse:
        sandbox_id = self.generate_sandbox_id()
        now = datetime.now(timezone.utc)

        # Compute expiration
        expires_at = None
        if request.timeout is not None:
            capped = min(request.timeout, self._max_timeout) if self._max_timeout else request.timeout
            expires_at = datetime.fromtimestamp(now.timestamp() + capped, tz=timezone.utc)

        # Parse resource limits for CPU/memory overrides
        cpus = None
        memory_mb = None
        if request.resource_limits and request.resource_limits.root:
            rl = request.resource_limits.root
            if "cpu" in rl:
                try:
                    cpus = int(rl["cpu"].rstrip("m")) if rl["cpu"].endswith("m") else int(rl["cpu"])
                except ValueError:
                    pass
            if "memory" in rl:
                raw = rl["memory"]
                try:
                    if raw.endswith("Mi"):
                        memory_mb = int(raw[:-2])
                    elif raw.endswith("Gi"):
                        memory_mb = int(raw[:-2]) * 1024
                    else:
                        memory_mb = int(raw)
                except ValueError:
                    pass

        platform = request.platform or PlatformSpec(os="windows", arch="amd64")

        meta = _SandboxMeta(
            sandbox_id=sandbox_id,
            image_uri=request.image.uri,
            entrypoint=request.entrypoint,
            metadata=request.metadata,
            platform=platform,
            created_at=now,
            expires_at=expires_at,
        )

        try:
            await self.vm_manager.create_vm(
                sandbox_id=sandbox_id,
                image_name=request.image.uri,
                cpus=cpus,
                memory_mb=memory_mb,
            )
        except FileNotFoundError as e:
            raise HTTPException(
                status_code=400,
                detail={"code": WindowsErrorCodes.VM_CREATE_FAILED, "message": str(e)},
            ) from e
        except TimeoutError as e:
            raise HTTPException(
                status_code=504,
                detail={"code": WindowsErrorCodes.BOOT_TIMEOUT, "message": str(e)},
            ) from e
        except Exception as e:
            logger.exception("Failed to create Windows sandbox %s", sandbox_id)
            raise HTTPException(
                status_code=500,
                detail={"code": WindowsErrorCodes.VM_CREATE_FAILED, "message": str(e)},
            ) from e

        with self._lock:
            self._meta[sandbox_id] = meta

        self._schedule_expiration(meta)

        return CreateSandboxResponse(
            id=sandbox_id,
            status=SandboxStatus(state="Running"),
            metadata=request.metadata,
            platform=platform,
            expires_at=expires_at,
            created_at=now,
            entrypoint=request.entrypoint,
        )

    def list_sandboxes(self, request: ListSandboxesRequest) -> ListSandboxesResponse:
        with self._lock:
            all_meta = list(self._meta.values())

        # Apply filters
        filtered = all_meta
        if request.filter.state:
            states = set(request.filter.state)
            filtered = [m for m in filtered if m.status in states]
        if request.filter.metadata:
            for key, value in request.filter.metadata.items():
                filtered = [
                    m for m in filtered
                    if m.metadata and m.metadata.get(key) == value
                ]

        total = len(filtered)

        # Pagination
        page = 1
        page_size = 20
        if request.pagination:
            page = request.pagination.page
            page_size = request.pagination.page_size
        start = (page - 1) * page_size
        end = start + page_size
        page_items = filtered[start:end]

        sandboxes = [self._build_sandbox(m) for m in page_items]

        total_pages = (total + page_size - 1) // page_size if page_size else 1
        return ListSandboxesResponse(
            items=sandboxes,
            pagination=PaginationInfo(
                page=page,
                page_size=page_size,
                total_items=total,
                total_pages=total_pages,
                has_next_page=page < total_pages,
            ),
        )

    def get_sandbox(self, sandbox_id: str) -> Sandbox:
        meta = self._get_meta(sandbox_id)
        return self._build_sandbox(meta)

    def delete_sandbox(self, sandbox_id: str) -> None:
        meta = self._get_meta(sandbox_id)
        self._cancel_expiration(meta)

        import asyncio
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        if loop and loop.is_running():
            # Schedule destruction in the running loop
            asyncio.ensure_future(self.vm_manager.destroy_vm(sandbox_id))
        else:
            asyncio.run(self.vm_manager.destroy_vm(sandbox_id))

        with self._lock:
            self._meta.pop(sandbox_id, None)

        meta.status = "Terminated"

    def pause_sandbox(self, sandbox_id: str) -> None:
        meta = self._get_meta(sandbox_id)
        if meta.status != "Running":
            raise HTTPException(
                status_code=409,
                detail={"code": WindowsErrorCodes.VM_NOT_RUNNING, "message": "Sandbox is not running"},
            )

        import asyncio
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        if loop and loop.is_running():
            asyncio.ensure_future(self.vm_manager.pause_vm(sandbox_id))
        else:
            asyncio.run(self.vm_manager.pause_vm(sandbox_id))

        meta.status = "Paused"

    def resume_sandbox(self, sandbox_id: str) -> None:
        meta = self._get_meta(sandbox_id)
        if meta.status != "Paused":
            raise HTTPException(
                status_code=409,
                detail={"code": WindowsErrorCodes.VM_NOT_PAUSED, "message": "Sandbox is not paused"},
            )

        import asyncio
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        if loop and loop.is_running():
            asyncio.ensure_future(self.vm_manager.resume_vm(sandbox_id))
        else:
            asyncio.run(self.vm_manager.resume_vm(sandbox_id))

        meta.status = "Running"

    def renew_expiration(
        self, sandbox_id: str, request: RenewSandboxExpirationRequest,
    ) -> RenewSandboxExpirationResponse:
        meta = self._get_meta(sandbox_id)
        self._cancel_expiration(meta)

        new_expires = request.expires_at
        if new_expires.tzinfo is None:
            new_expires = new_expires.replace(tzinfo=timezone.utc)

        meta.expires_at = new_expires
        self._schedule_expiration(meta)

        return RenewSandboxExpirationResponse(expires_at=new_expires)

    # ------------------------------------------------------------------
    # Diagnostics
    # ------------------------------------------------------------------

    def get_sandbox_logs(self, sandbox_id: str, tail: int = 100, since: str | None = None) -> str:
        meta = self._get_meta(sandbox_id)
        vm = self.vm_manager.get_vm(sandbox_id)
        if vm is None:
            return "(VM not found)"

        lines = [
            f"Windows VM {sandbox_id}",
            f"  PID: {vm.pid}",
            f"  IP: {vm.guest_ip}",
            f"  Status: {meta.status}",
            f"  Created: {meta.created_at.isoformat()}",
            f"  CPUs: {vm.cpus}, Memory: {vm.memory_mb}MB",
            f"  execd URL: {vm.execd_url}",
        ]
        return "\n".join(lines)

    def get_sandbox_inspect(self, sandbox_id: str) -> str:
        meta = self._get_meta(sandbox_id)
        vm = self.vm_manager.get_vm(sandbox_id)
        info = {
            "sandbox_id": sandbox_id,
            "status": meta.status,
            "image": meta.image_uri,
            "entrypoint": meta.entrypoint,
            "platform": {"os": "windows", "arch": "amd64"},
            "created_at": meta.created_at.isoformat(),
            "expires_at": meta.expires_at.isoformat() if meta.expires_at else None,
        }
        if vm:
            info.update({
                "vm": {
                    "pid": vm.pid,
                    "guest_ip": vm.guest_ip,
                    "mac_address": vm.mac_address,
                    "cpus": vm.cpus,
                    "memory_mb": vm.memory_mb,
                    "tap_device": vm.tap_device,
                    "overlay_path": str(vm.overlay_path),
                    "api_socket": str(vm.api_socket),
                    "execd_url": vm.execd_url,
                    "is_running": vm.is_running,
                },
            })
        return json.dumps(info, indent=2)

    def get_sandbox_events(self, sandbox_id: str, limit: int = 50) -> str:
        self._get_meta(sandbox_id)
        # Windows VMs don't have container-level events; return a stub
        return f"Events for Windows VM {sandbox_id}: (event log not available for CLH VMs)"

    def get_endpoint(self, sandbox_id: str, port: int, resolve_internal: bool = False) -> Endpoint:
        self.validate_port(port)
        meta = self._get_meta(sandbox_id)
        vm = self.vm_manager.get_vm(sandbox_id)

        if vm is None or not vm.is_running:
            raise HTTPException(
                status_code=409,
                detail={
                    "code": WindowsErrorCodes.VM_NOT_RUNNING,
                    "message": f"VM {sandbox_id} is not running",
                },
            )

        # Windows VM exposes ports directly on its guest IP
        endpoint_str = f"{vm.guest_ip}:{port}"

        return Endpoint(endpoint=endpoint_str)
