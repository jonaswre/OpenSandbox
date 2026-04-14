---
title: Windows Guest Support via Cloud Hypervisor
authors:
  - "@jonaswre"
creation-date: 2026-04-14
last-updated: 2026-04-14
status: draft
---

# OSEP-0011: Windows Guest Support via Cloud Hypervisor

<!-- toc -->
- [Summary](#summary)
- [Motivation](#motivation)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Requirements](#requirements)
- [Proposal](#proposal)
  - [Notes/Constraints/Caveats](#notesconstraintscaveats)
  - [Risks and Mitigations](#risks-and-mitigations)
- [Design Details](#design-details)
  - [API and SDK Impact](#api-and-sdk-impact)
  - [Server Configuration](#server-configuration)
  - [Image Preparation](#image-preparation)
  - [VM Lifecycle Manager](#vm-lifecycle-manager)
  - [execd for Windows](#execd-for-windows)
  - [Bootstrap: PowerShell Entrypoint](#bootstrap-powershell-entrypoint)
  - [Filesystem Adaptations](#filesystem-adaptations)
  - [Network Configuration](#network-configuration)
  - [Security Model Differences](#security-model-differences)
  - [Kubernetes Integration](#kubernetes-integration)
- [Implementation Phases](#implementation-phases)
- [Test Plan](#test-plan)
- [Drawbacks](#drawbacks)
- [Alternatives](#alternatives)
- [Infrastructure Needed](#infrastructure-needed)
- [Upgrade & Migration Strategy](#upgrade--migration-strategy)
<!-- /toc -->

## Summary

This proposal adds Windows guest support to OpenSandbox using Cloud Hypervisor (CLH) as the hypervisor backend. Windows sandboxes run as UEFI-booted VMs managed directly by CLH, bypassing Kata Containers (which lacks Windows guest support). The execd daemon receives a Windows-native implementation covering command execution, interactive sessions, and filesystem operations.

This enables use cases that require a Windows environment: .NET Framework applications, PowerShell-based agents, Windows-specific toolchains, and GUI agent evaluation against Windows desktop software.

## Motivation

OpenSandbox currently supports Linux containers exclusively. All runtime paths — secure and standard — assume a Linux guest: POSIX shells, Unix signals, Linux namespaces, seccomp filters. This blocks several real-world use cases:

1. **Windows-native AI agents**: Agents that must interact with Windows APIs, COM automation, or Win32 desktop applications
2. **.NET Framework workloads**: Legacy .NET Framework code (not .NET Core) requires a Windows runtime
3. **GUI agent evaluation**: Testing agents against Windows desktop software (Office, proprietary enterprise tools)
4. **PowerShell automation**: Security tooling and infrastructure automation that targets Windows environments
5. **Cross-platform testing**: Running the same agent logic against both Linux and Windows to verify platform-agnostic behavior

Cloud Hypervisor already supports Windows guests since v0.10.0, making it the most viable path for lightweight Windows VM isolation.

### Goals

1. **Windows sandboxes via CLH**: Run Windows Server and Windows 11 guests as first-class OpenSandbox sandboxes using Cloud Hypervisor directly
2. **SDK compatibility**: Existing SDKs work with Windows sandboxes — same `Sandbox.create()` flow with a `guest_os` parameter
3. **execd parity**: Windows sandboxes support command execution, file operations, and interactive sessions via the same execd API
4. **Headless operation**: Windows guests operate headless (no VGA); access is through execd APIs, RDP, or SAC
5. **Image preparation tooling**: Provide scripts and documentation to produce Windows base images with pre-installed VirtIO drivers and execd

### Non-Goals

1. **GUI rendering in the sandbox API**: CLH has no VGA; graphical access (if needed) is via RDP, which is outside the sandbox protocol
2. **Windows container support (Docker Windows containers)**: This proposal targets full Windows VMs via CLH, not Windows Server containers
3. **Kata Containers integration**: Kata lacks Windows guest support upstream; we bypass it entirely
4. **Windows host support**: The OpenSandbox server itself continues to run on Linux; only the guest VM is Windows
5. **Automatic Windows image creation**: Image preparation requires a one-time QEMU-based install; full automation is out of scope
6. **TPM 2.0 support**: CLH's TPM passthrough is currently broken; consumer Windows 11 (which enforces TPM) requires a registry bypass

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| R1 | Server configuration supports `guest_os = "windows"` to select Windows VM mode | Must Have |
| R2 | CLH VM lifecycle (create, start, stop, destroy) managed by OpenSandbox server | Must Have |
| R3 | Pre-built Windows image with VirtIO drivers and execd binary | Must Have |
| R4 | execd Windows binary supports command execution via `cmd.exe` and PowerShell | Must Have |
| R5 | execd Windows binary supports filesystem operations (CRUD, search, permissions) | Must Have |
| R6 | UEFI boot via CLOUDHV.fd firmware | Must Have |
| R7 | Network connectivity between host and Windows guest | Must Have |
| R8 | SDK `guest_os` parameter for creating Windows sandboxes | Must Have |
| R9 | Interactive terminal sessions (ConPTY) for Windows guests | Should Have |
| R10 | Jupyter kernel support inside Windows guests (PowerShell kernel) | Could Have |
| R11 | Hot-add CPU/RAM to running Windows VMs | Could Have |

## Proposal

Windows sandboxes run as full VMs managed by Cloud Hypervisor, not as OCI containers. The architecture introduces a new `CLHVMManager` component that handles VM lifecycle alongside the existing Docker and Kubernetes backends.

```
SDK Request (guest_os=windows)
        │
        ▼
┌─────────────────────────┐
│  OpenSandbox Server     │
│  ┌───────────────────┐  │
│  │ Runtime Router     │  │  guest_os=linux  → Docker/K8s (existing path)
│  │                   │──┼──────────────────────────────────────────────
│  │                   │  │  guest_os=windows → CLHVMManager (new)
│  └───────────────────┘  │
│  ┌───────────────────┐  │
│  │ CLHVMManager      │  │
│  │  • CLOUDHV.fd     │  │
│  │  • VirtIO net/blk │  │
│  │  • UEFI boot      │  │
│  │  • API socket      │  │
│  └───────────────────┘  │
└─────────────────────────┘
        │
        ▼
┌─────────────────────────┐
│  Cloud Hypervisor VM    │
│  ┌───────────────────┐  │
│  │ Windows Guest     │  │
│  │  • execd.exe      │  │
│  │  • PowerShell     │  │
│  │  • VirtIO drivers │  │
│  └───────────────────┘  │
└─────────────────────────┘
```

### Notes/Constraints/Caveats

1. **CLH has no VGA adapter**: All interaction is through execd APIs (HTTP), RDP over the virtual network, or SAC (Special Administration Console) via serial. No graphical console output from the hypervisor.

2. **Initial Windows installation requires QEMU**: CLH cannot boot a Windows installer ISO. The base image must be created once using QEMU, then runs under CLH. This is a one-time image preparation step.

3. **UEFI only**: CLH does not support BIOS boot. Windows guests boot via CLOUDHV.fd, the CLH-specific OVMF firmware build.

4. **Hyper-V enlightenments required**: The CLH CPU configuration must include `kvm_hyperv=on` for acceptable Windows performance. Without it, Windows runs significantly slower.

5. **Disk sizing**: CLH Windows guests need at least 64 GB disk images. A 30 GB image leaves only ~7 GB usable after Windows installation.

6. **VirtIO driver requirement**: The `viostor` (storage) and `NetKVM` (network) drivers from Fedora's virtio-win package must be present in the Windows image. Without them, Windows cannot see the virtual disk or network.

7. **TPM 2.0 is broken in CLH**: The `--tpm` flag causes a panic in current CLH releases. Consumer Windows 11 (which enforces TPM at install) needs a registry bypass. Windows Server editions and Windows 11 IoT Enterprise LTSC do not require TPM.

8. **No Kata integration path**: Kata Containers has an open issue ([kata-containers#7045](https://github.com/kata-containers/kata-containers/issues/7045)) for Windows guest support since June 2023 with no implementation progress. This proposal intentionally bypasses Kata.

### Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| CLH Windows support regressions | Guest boot failures after CLH upgrade | Pin CLH version; test matrix across CLH releases |
| Windows licensing complexity | Legal/compliance burden for image distribution | Document BYOL (Bring Your Own License); do not distribute Windows images |
| Large image sizes (64+ GB) | Slow sandbox creation, high storage cost | Support copy-on-write (qcow2) backing files; pool pre-booted VMs |
| No VGA means harder debugging | Cannot see Windows boot screen during troubleshooting | Serial console (SAC) for boot diagnostics; RDP once network is up |
| Windows update breaks execd | execd service stops after OS update | Install execd as a Windows service with auto-restart; pin Windows version in images |
| Performance overhead vs Linux containers | Windows VMs are heavier than Linux containers | Document expected overhead; recommend pooling for warm starts |

## Design Details

### API and SDK Impact

A new optional `guest_os` field is added to `CreateSandboxRequest`:

```python
# Python SDK
sandbox = await Sandbox.create(
    image="windows-server-2022-base",  # Pre-built Windows image name
    guest_os="windows",                # New field; default "linux"
)

# Command execution works the same way
result = await sandbox.commands.run("powershell -Command Get-Process")
```

The `guest_os` field defaults to `"linux"`, preserving backward compatibility. When set to `"windows"`, the server routes the request to the CLHVMManager instead of the Docker/Kubernetes backend.

**Protocol-level change**: The sandbox protocol's `CreateSandboxRequest` gains one optional field:

```json
{
  "image": { "uri": "windows-server-2022-base" },
  "guest_os": "windows",
  "entrypoint": ["powershell", "-File", "C:\\scripts\\init.ps1"]
}
```

### Server Configuration

Extension to `~/.sandbox.toml`:

```toml
[runtime]
type = "docker"  # Existing Linux runtime (unchanged)

# Windows guest support via Cloud Hypervisor
[windows_runtime]
enabled = false

# Path to cloud-hypervisor binary
clh_binary = "/usr/local/bin/cloud-hypervisor"

# Path to CLOUDHV.fd UEFI firmware (CLH-specific OVMF build)
firmware = "/usr/share/cloud-hypervisor/CLOUDHV.fd"

# Directory containing Windows base images (.qcow2 or .raw)
image_dir = "/var/lib/opensandbox/windows-images"

# Default VM resources
default_cpus = 2
default_memory_mb = 4096
default_disk_gb = 64

# Network bridge for Windows VMs
network_bridge = "opensandbox-win-br0"

# API socket directory (one socket per VM)
api_socket_dir = "/run/opensandbox/clh"

# Enable Hyper-V enlightenments (strongly recommended for performance)
hyperv_enlightenments = true
```

**Pydantic model**:

```python
class WindowsRuntimeConfig(BaseModel):
    enabled: bool = False
    clh_binary: str = "/usr/local/bin/cloud-hypervisor"
    firmware: str = "/usr/share/cloud-hypervisor/CLOUDHV.fd"
    image_dir: str = "/var/lib/opensandbox/windows-images"
    default_cpus: int = 2
    default_memory_mb: int = 4096
    default_disk_gb: int = 64
    network_bridge: str = "opensandbox-win-br0"
    api_socket_dir: str = "/run/opensandbox/clh"
    hyperv_enlightenments: bool = True

    @model_validator(mode="after")
    def validate_windows_runtime(self) -> "WindowsRuntimeConfig":
        if not self.enabled:
            return self
        if not Path(self.clh_binary).exists():
            raise ValueError(f"CLH binary not found: {self.clh_binary}")
        if not Path(self.firmware).exists():
            raise ValueError(f"CLOUDHV.fd firmware not found: {self.firmware}")
        if not Path(self.image_dir).is_dir():
            raise ValueError(f"Image directory not found: {self.image_dir}")
        return self
```

### Image Preparation

Windows image preparation is a one-time, operator-managed process using QEMU.

**Requirements for a base image:**
1. Windows Server 2022 or Windows 11 IoT Enterprise LTSC installed
2. VirtIO drivers (`viostor`, `NetKVM`) from Fedora virtio-win ISO
3. `execd.exe` installed as a Windows service (auto-start)
4. SAC (Special Administration Console) enabled for serial console access
5. RDP enabled (optional, for graphical access)
6. Windows Firewall configured to allow execd port (default 8080)

**Image preparation script** (`scripts/prepare-windows-image.sh`):

```bash
#!/bin/bash
# Step 1: Create disk image
qemu-img create -f qcow2 windows-base.qcow2 64G

# Step 2: Install Windows using QEMU (interactive, one-time)
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host,kvm=on,kvm_hyperv=on \
    -m 4G -smp 2 \
    -bios /usr/share/OVMF/OVMF_CODE.fd \
    -drive file=windows-base.qcow2,if=none,id=disk0 \
    -device virtio-blk-pci,drive=disk0 \
    -drive file=windows.iso,media=cdrom \
    -drive file=virtio-win.iso,media=cdrom \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    -vnc :0

# Step 3: After install, inject execd and configure services
# (Done inside the running VM via RDP or VNC)

# Step 4: Verify the image boots under CLH
cloud-hypervisor \
    --kernel /usr/share/cloud-hypervisor/CLOUDHV.fd \
    --disk path=windows-base.qcow2 \
    --cpus boot=2 \
    --memory size=4096M \
    --net tap=,mac=,ip=,mask= \
    --serial tty \
    --console off \
    --api-socket /tmp/clh-test.sock
```

**Copy-on-write for sandbox instances**: Each sandbox gets a COW overlay on top of the base image, so the base image is never modified:

```bash
qemu-img create -f qcow2 -b windows-base.qcow2 -F qcow2 sandbox-instance.qcow2
```

### VM Lifecycle Manager

New component: `server/opensandbox_server/services/clh_vm_manager.py`

```python
class CLHVMManager:
    """Manages Cloud Hypervisor VM lifecycle for Windows sandboxes."""

    def __init__(self, config: WindowsRuntimeConfig):
        self.config = config
        self.vms: dict[str, CLHVMInstance] = {}

    async def create_vm(self, sandbox_id: str, request: CreateSandboxRequest) -> CLHVMInstance:
        """Create and boot a Windows VM."""
        # 1. Create COW overlay from base image
        overlay_path = self._create_overlay(sandbox_id, request.image.uri)

        # 2. Allocate TAP device on the bridge
        tap_device = self._create_tap(sandbox_id)

        # 3. Build CLH command line
        api_socket = Path(self.config.api_socket_dir) / f"{sandbox_id}.sock"
        cmd = [
            self.config.clh_binary,
            "--kernel", self.config.firmware,
            "--disk", f"path={overlay_path}",
            "--cpus", f"boot={request.cpus or self.config.default_cpus}",
            "--memory", f"size={request.memory_mb or self.config.default_memory_mb}M",
            "--net", f"tap={tap_device},mac={self._generate_mac()}",
            "--serial", "tty",
            "--console", "off",
            "--api-socket", str(api_socket),
        ]

        if self.config.hyperv_enlightenments:
            cmd.extend(["--cpus", "kvm_hyperv=on"])

        # 4. Start CLH process
        process = await asyncio.create_subprocess_exec(*cmd)

        # 5. Wait for execd to become reachable
        vm = CLHVMInstance(
            sandbox_id=sandbox_id,
            process=process,
            api_socket=api_socket,
            overlay_path=overlay_path,
            tap_device=tap_device,
        )
        await self._wait_for_execd(vm)

        self.vms[sandbox_id] = vm
        return vm

    async def destroy_vm(self, sandbox_id: str):
        """Stop VM and clean up resources."""
        vm = self.vms.pop(sandbox_id, None)
        if vm is None:
            return
        # Send shutdown via CLH API socket
        await self._clh_api(vm.api_socket, "PUT", "/api/v1/vm.shutdown")
        await vm.process.wait()
        # Clean up overlay and TAP
        os.unlink(vm.overlay_path)
        self._destroy_tap(vm.tap_device)
```

### execd for Windows

The existing execd Windows stubs (`components/execd/pkg/runtime/*_windows.go`) are upgraded to functional implementations.

**Command execution** (`command_windows.go`) — already partially implemented:
- Uses `cmd /C` for basic commands (working)
- Needs: PowerShell execution path (`powershell.exe -Command` or `pwsh.exe -Command`)
- Needs: environment variable handling via Windows conventions

**Bash sessions** → **Shell sessions** (`shell_session_windows.go`, replacing `bash_session_windows.go`):

```go
// CreateShellSession starts a persistent PowerShell session on Windows.
func (c *Controller) CreateBashSession(req *CreateContextRequest) (string, error) {
    session := c.newContextID()

    // Start a persistent PowerShell process
    cmd := exec.Command("powershell.exe", "-NoExit", "-Command", "-")
    cmd.Dir = req.Cwd
    cmd.Env = mergeEnvs(os.Environ(), req.Envs)

    stdin, _ := cmd.StdinPipe()
    stdout, _ := cmd.StdoutPipe()
    stderr, _ := cmd.StderrPipe()

    if err := cmd.Start(); err != nil {
        return "", fmt.Errorf("failed to start PowerShell session: %w", err)
    }

    c.storePowerShellSession(session, &psSession{
        cmd:    cmd,
        stdin:  stdin,
        stdout: stdout,
        stderr: stderr,
    })

    return session, nil
}
```

**PTY sessions** → **ConPTY sessions** (`pty_session_windows.go`):

Windows 10 1809+ and Windows Server 2019+ support ConPTY (Console Pseudo Terminal). The implementation uses the `conpty` Go package or direct Win32 API calls:

```go
func (c *Controller) CreatePTYSession(id, cwd string) (PTYSession, error) {
    sess := &ptySession{
        id:   id,
        cwd:  cwd,
        done: make(chan struct{}),
    }

    // Create ConPTY pseudo console
    // Uses CreatePseudoConsole Win32 API
    hPC, err := windows.CreatePseudoConsole(
        windows.Coord{X: 120, Y: 40},
        hInput, hOutput, 0,
    )
    if err != nil {
        return nil, fmt.Errorf("CreatePseudoConsole: %w", err)
    }

    sess.hPC = hPC
    return sess, nil
}
```

**Signal handling** (`ctrl_windows.go`):

Windows has no POSIX signals. Process termination uses different mechanisms:

| Linux Signal | Windows Equivalent |
|-------------|-------------------|
| `SIGTERM` | `GenerateConsoleCtrlEvent(CTRL_C_EVENT)` |
| `SIGKILL` | `TerminateProcess()` |
| `SIGINT` | `GenerateConsoleCtrlEvent(CTRL_C_EVENT)` |
| `SIGHUP` | `GenerateConsoleCtrlEvent(CTRL_CLOSE_EVENT)` |

**clone3 compatibility**: Skipped entirely on Windows. The existing `compat_linux.go` build tag already excludes it. No Windows file needed beyond the existing no-op:

```go
//go:build !linux

package clone3compat

func MaybeApply() bool { return false }
```

### Bootstrap: PowerShell Entrypoint

New file: `components/execd/bootstrap.ps1` — the Windows equivalent of `bootstrap.sh`.

```powershell
# bootstrap.ps1 — OpenSandbox Windows guest bootstrap
$ErrorActionPreference = "Stop"

$ExecdPath = if ($env:EXECD) { $env:EXECD } else { "C:\opensandbox\execd.exe" }
$ExecdEnvs = if ($env:EXECD_ENVS) { $env:EXECD_ENVS } else { "C:\opensandbox\.env" }

# Ensure env file exists
$envDir = Split-Path $ExecdEnvs -Parent
if (-not (Test-Path $envDir)) { New-Item -ItemType Directory -Path $envDir -Force | Out-Null }
if (-not (Test-Path $ExecdEnvs)) { New-Item -ItemType File -Path $ExecdEnvs -Force | Out-Null }
$env:EXECD_ENVS = $ExecdEnvs

# Start execd as a background process
Write-Host "Starting OpenSandbox Execd daemon at $ExecdPath"
Start-Process -FilePath $ExecdPath -NoNewWindow

# Execute entrypoint command if provided
if ($env:BOOTSTRAP_CMD) {
    & powershell.exe -Command $env:BOOTSTRAP_CMD
} elseif ($args.Count -gt 0) {
    & $args[0] $args[1..($args.Count-1)]
} else {
    # Keep the bootstrap process alive (execd runs in background)
    Wait-Process -Name "execd" -ErrorAction SilentlyContinue
}
```

In production, `execd.exe` is registered as a Windows service so it starts automatically on boot without needing the bootstrap script:

```powershell
New-Service -Name "OpenSandboxExecd" `
    -BinaryPathName "C:\opensandbox\execd.exe" `
    -DisplayName "OpenSandbox Execd" `
    -StartupType Automatic `
    -Description "OpenSandbox execution daemon for sandbox operations"
```

### Filesystem Adaptations

The existing Windows filesystem controller (`filesystem_windows.go`, `utils_windows.go`) is mostly functional. Key gaps to address:

| Feature | Linux (current) | Windows (needed) |
|---------|----------------|-----------------|
| Ownership (chown) | `os.Chown(uid, gid)` | `SetFileOwnership` is a no-op stub → implement via Windows ACLs or leave as no-op with documentation |
| Permissions | POSIX mode bits (0755) | `os.Chmod` works but only controls read-only flag; full ACL support optional |
| Symlinks | Full support | Requires SeCreateSymbolicLinkPrivilege (admin or developer mode) |
| Path separators | `/` | `\` (Go's `filepath` handles this automatically) |
| Case sensitivity | Case-sensitive | Case-insensitive by default (NTFS) |
| File locking | `flock()` | `LockFileEx()` (different semantics) |

**Decision**: The filesystem controller's POSIX permission model (owner/group/mode) maps imperfectly to Windows. For the initial implementation:
- `chmod` sets the read-only attribute when mode has no write bits; otherwise no-op
- `chown` is a no-op (documented limitation)
- File CRUD operations work as-is through Go's `os` package
- Path handling uses `filepath` throughout (already the case)

### Network Configuration

Windows VMs connect to the host via a TAP device on a Linux bridge:

```
┌────────────────────┐     ┌──────────────────────┐
│  Windows Guest     │     │  Linux Host           │
│  ┌──────────────┐  │     │  ┌────────────────┐   │
│  │ NetKVM driver│──┼─────┼──│ TAP device     │   │
│  │ (VirtIO net) │  │     │  │ (tap-sandbox1) │   │
│  │              │  │     │  └───────┬────────┘   │
│  │ IP: DHCP or  │  │     │  ┌───────┴────────┐   │
│  │   static     │  │     │  │ Bridge         │   │
│  └──────────────┘  │     │  │ (opensandbox-  │   │
└────────────────────┘     │  │  win-br0)      │   │
                           │  └───────┬────────┘   │
                           │          │ NAT/route   │
                           └──────────┴────────────┘
```

**IP assignment options**:
1. **Static IP** (recommended): Server assigns IP from a configured range; injects into Windows via `Unattend.xml` or execd API call at first boot
2. **DHCP**: Run a lightweight DHCP server (dnsmasq) on the bridge; Windows guest uses DHCP (default Windows behavior)

**execd reachability**: The server connects to execd via the guest's IP on the bridge network. Health checks poll `http://<guest-ip>:8080/health` until the VM has booted and execd is running.

### Security Model Differences

| Aspect | Linux Sandbox | Windows Sandbox |
|--------|--------------|----------------|
| Isolation | Container (runc) or VM (Kata) | Full VM (CLH) — always VM-level isolation |
| Syscall filtering | seccomp BPF | N/A (guest kernel is Windows) |
| Capabilities | Linux capabilities drop | N/A |
| AppArmor/SELinux | Host-level MAC | N/A |
| User namespaces | Available | N/A |
| Network isolation | Linux netns | Separate VM with TAP bridge |
| Filesystem isolation | Mount namespaces, overlayfs | Separate disk image (COW overlay) |

Windows sandboxes get **stronger isolation by default** since they always run as full VMs. The attack surface is limited to the CLH VMM and KVM, comparable to Kata Containers with CLH backend.

### Kubernetes Integration

For Kubernetes deployments, Windows sandboxes can be managed via `KubeVirt` or a custom CRD:

**Option A — KubeVirt (recommended for Kubernetes)**:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: sandbox-<id>
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 2
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          interfaces:
          - name: default
            bridge: {}
        features:
          hyperv:
            relaxed: {}
            vapic: {}
            spinlocks:
              spinlocks: 8191
        machine:
          type: q35
        resources:
          requests:
            memory: 4Gi
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: windows-sandbox-<id>
```

**Option B — Direct CLH management from the server** (recommended for Docker mode):

The `CLHVMManager` described above manages VMs directly. This avoids the KubeVirt dependency for simpler deployments.

## Implementation Phases

### Phase 1: Image Preparation and CLH Integration (Foundation)

- [ ] Image preparation documentation and helper scripts
- [ ] `WindowsRuntimeConfig` in server config
- [ ] `CLHVMManager` — create, start, stop, destroy VMs
- [ ] Health check polling for execd reachability
- [ ] TAP/bridge network setup and teardown
- [ ] Startup validation (CLH binary, firmware, image directory)

### Phase 2: execd Windows Implementation (Core Functionality)

- [ ] Command execution via PowerShell and cmd.exe (upgrade existing `command_windows.go`)
- [ ] Shell sessions (persistent PowerShell, replacing bash session stub)
- [ ] Windows signal handling (Ctrl+C, TerminateProcess)
- [ ] Filesystem operations (existing code + gaps documented above)
- [ ] `bootstrap.ps1` and Windows service registration
- [ ] Cross-compile execd for Windows (`GOOS=windows GOARCH=amd64`)

### Phase 3: SDK and API Integration

- [ ] `guest_os` field in `CreateSandboxRequest` (protocol + server)
- [ ] Runtime router: Linux → Docker/K8s, Windows → CLHVMManager
- [ ] Python SDK support for `guest_os` parameter
- [ ] JavaScript/TypeScript SDK support
- [ ] Java/Kotlin SDK support

### Phase 4: Interactive Sessions and Polish

- [ ] ConPTY-based interactive terminal sessions
- [ ] COW image pooling for warm starts
- [ ] VM resource hot-add (CPU/RAM)
- [ ] Kubernetes integration (KubeVirt or custom CRD)
- [ ] PowerShell Jupyter kernel support (optional)
- [ ] Documentation and examples

## Test Plan

### Unit Tests

| Test Case | Description |
|-----------|-------------|
| Config parsing | `WindowsRuntimeConfig` validates paths and defaults |
| Config validation | Server rejects config when CLH binary or firmware is missing |
| Runtime routing | `guest_os=windows` routes to CLHVMManager, `linux` to Docker |
| COW overlay creation | Overlay image is created from base with correct backing file |
| TAP allocation | TAP device naming and bridge attachment |
| Signal mapping | Linux signal names map to correct Windows equivalents |

### Integration Tests

| Test Case | Description |
|-----------|-------------|
| VM lifecycle | Create, boot, health check, stop, destroy a Windows VM |
| Command execution | Run `powershell -Command Get-Process` and verify output |
| File operations | Upload, read, write, delete files in Windows guest |
| Network connectivity | Host can reach execd on guest IP |
| Overlay cleanup | Overlay image and TAP device removed after VM destroy |
| Startup validation | Server fails if CLH binary missing, firmware missing, or image dir empty |

### E2E Tests

| Test Case | Description |
|-----------|-------------|
| SDK create Windows sandbox | `Sandbox.create(guest_os="windows")` succeeds end-to-end |
| PowerShell execution | Execute multi-line PowerShell script, verify output |
| File round-trip | Upload file via SDK, read back, verify contents match |
| Sandbox isolation | Two Windows sandboxes cannot access each other's filesystems |
| Mixed workloads | Create Linux and Windows sandboxes concurrently on same server |
| Warm start from pool | Pre-booted Windows VM claimed from pool in <5s |

## Drawbacks

1. **Operational complexity**: Windows images require QEMU for initial preparation, CLH binary and firmware must be installed, and Windows licensing must be managed by operators
2. **Resource overhead**: Windows VMs require significantly more memory (4+ GB) and disk (64+ GB) than Linux containers (~5 MB)
3. **Startup latency**: Cold boot of a Windows VM takes 30-60 seconds vs <1 second for a Linux container; warm start from a pool mitigates this
4. **Maintenance burden**: execd must be maintained for two platforms; Windows-specific bugs and OS updates add ongoing work
5. **Limited Kubernetes integration**: KubeVirt is a heavy dependency; direct CLH management doesn't integrate with Kubernetes scheduling
6. **No graphics**: CLH lacks VGA, so use cases requiring graphical interaction must use RDP (adds network dependency and complexity)

## Alternatives

### Alternative 1: Wait for Kata Containers Windows Support

**Approach**: Contribute to or wait for [kata-containers#7045](https://github.com/kata-containers/kata-containers/issues/7045) to land, then use Kata's existing integration.

**Pros**:
- Reuses existing Kata integration (OSEP-0004)
- No new VM lifecycle management code
- Kubernetes RuntimeClass works out of the box

**Cons**:
- No active development upstream since June 2023
- Would require implementing a Windows kata-agent and runtime-rs changes
- Timeline is completely uncertain
- We would depend on upstream for a critical feature

**Decision**: Rejected. Upstream progress is stalled, and this blocks Windows support indefinitely.

### Alternative 2: QEMU Instead of Cloud Hypervisor

**Approach**: Use QEMU directly to run Windows VMs.

**Pros**:
- Mature Windows guest support
- VGA output available
- TPM 2.0 works
- Extensive device emulation

**Cons**:
- Significantly higher resource overhead than CLH
- Slower startup times
- Larger attack surface (more emulated devices)
- OpenSandbox already aligns with CLH via Kata integration

**Decision**: Rejected as the primary path, but QEMU remains necessary for image preparation. Could be offered as an alternative VMM backend in a future OSEP if VGA or TPM support is critical.

### Alternative 3: Windows Containers (Docker)

**Approach**: Use Docker Windows containers (Windows Server containers or Hyper-V containers).

**Pros**:
- Fits existing Docker integration
- Lighter weight than full VMs
- Familiar container workflow

**Cons**:
- Requires a Windows host (Docker Windows containers need Windows kernel)
- Limited to Windows Server Core or Nano Server (no full desktop)
- Hyper-V containers on Linux are not supported
- OpenSandbox server would need to run on Windows

**Decision**: Rejected. OpenSandbox server runs on Linux; Windows containers require a Windows host.

## Infrastructure Needed

- **Hardware**: KVM-capable Linux host with sufficient RAM (8+ GB per Windows VM) and disk (64+ GB per image)
- **Software**:
  - Cloud Hypervisor binary (v38.0+ recommended)
  - CLOUDHV.fd firmware (from CLH releases or built from edk2)
  - QEMU (for one-time image preparation only)
  - VirtIO drivers ISO (from Fedora virtio-win)
  - Windows installation media (operator-provided, BYOL)
- **CI/CD**:
  - KVM-enabled CI runners for integration tests
  - Pre-built Windows base image for E2E tests (not redistributable; must be built per-environment)
  - Test matrix: CLH versions x Windows versions
- **Documentation**:
  - Image preparation guide
  - Server configuration reference for `[windows_runtime]`
  - SDK usage examples
  - Troubleshooting guide (SAC, network debugging, execd logs)

## Upgrade & Migration Strategy

### Backward Compatibility

- **No breaking changes**: The `guest_os` field is optional and defaults to `"linux"`
- **Existing SDKs work unchanged**: Linux sandboxes are unaffected
- **New config section is optional**: `[windows_runtime]` defaults to `enabled = false`
- **Protocol extension only**: `guest_os` is additive to `CreateSandboxRequest`

### Migration Path

1. **Phase 0**: Operator installs CLH, firmware, prepares Windows base image using QEMU
2. **Phase 1**: Operator enables `[windows_runtime]` in server config, restarts server
3. **Phase 2**: SDK users can create Windows sandboxes via `guest_os="windows"`
4. No changes needed for existing Linux sandbox workflows
