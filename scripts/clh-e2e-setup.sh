#!/usr/bin/env bash
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

# ===========================================================================
# Cloud Hypervisor E2E Setup & Test
#
# Idempotent script that provisions a local environment for testing the
# WindowsSandboxService via Cloud Hypervisor.  Uses a minimal Alpine Linux
# guest (not Windows) to validate the full CLH pipeline quickly.
#
# Usage:
#   ./scripts/clh-e2e-setup.sh              # setup + run test
#   ./scripts/clh-e2e-setup.sh --setup      # setup only
#   ./scripts/clh-e2e-setup.sh --test       # run test only (setup must exist)
#   ./scripts/clh-e2e-setup.sh --cleanup    # tear down everything
# ===========================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLH_VERSION="${CLH_VERSION:-v44.0}"
ALPINE_VERSION="${ALPINE_VERSION:-3.21}"
ALPINE_MINOR="${ALPINE_MINOR:-3}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/opensandbox-clh-e2e}"
IMAGE_DIR="${WORK_DIR}/images"
SOCKET_DIR="${WORK_DIR}/sockets"
CONFIG_FILE="${WORK_DIR}/sandbox.toml"
SERVER_LOG="${WORK_DIR}/server.log"
SERVER_PID_FILE="${WORK_DIR}/server.pid"

BRIDGE_NAME="osbr0"
BRIDGE_IP="10.44.0.1"
BRIDGE_SUBNET="10.44.0.0/24"
DHCP_RANGE_START="10.44.0.2"
DHCP_RANGE_END="10.44.0.10"

CLH_BINARY="/usr/local/bin/cloud-hypervisor"
CLH_FIRMWARE="/usr/share/cloud-hypervisor/CLOUDHV.fd"

EXECD_PORT=44772
SERVER_PORT=18080  # avoid conflict with other services

# Go resolution
GO_BIN=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[CLH-E2E]${NC} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${NC} $*"; }
fail() { echo -e "${RED}[ FAIL ]${NC} $*"; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not found. Install it first."
}

need_sudo() {
    sudo -n true 2>/dev/null || {
        log "Some operations need sudo. You may be prompted for your password."
        sudo true || fail "sudo is required"
    }
}

# ---------------------------------------------------------------------------
# Phase 0: Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    log "Checking prerequisites..."

    [[ -c /dev/kvm ]] || fail "/dev/kvm not found. KVM required."
    [[ -r /dev/kvm ]] || fail "/dev/kvm not readable. Add user to kvm group."

    need_cmd qemu-img
    need_cmd curl
    need_cmd ip
    need_cmd iptables
    need_cmd dnsmasq
    need_cmd mkfs.ext4

    # Resolve Go
    for candidate in \
        "$(command -v go 2>/dev/null || true)" \
        "$HOME/.local/share/mise/installs/go/1.24.2/bin/go" \
        "$HOME/.local/share/mise/installs/go/latest/bin/go" \
        "/usr/local/go/bin/go"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            GO_BIN="$candidate"
            break
        fi
    done
    [[ -n "$GO_BIN" ]] || fail "Go not found. Install Go 1.22+ first."
    ok "Go found at $GO_BIN ($($GO_BIN version 2>&1 | head -1))"

    # Check disk space (need ~2GB)
    local avail_mb
    avail_mb=$(df -m "$WORK_DIR" 2>/dev/null | awk 'NR==2{print $4}' || df -m /tmp | awk 'NR==2{print $4}')
    (( avail_mb > 2000 )) || fail "Need ≥2GB free disk in ${WORK_DIR}. Available: ${avail_mb}MB"

    ok "Prerequisites OK"
}

# ---------------------------------------------------------------------------
# Phase 1: Install Cloud Hypervisor
# ---------------------------------------------------------------------------
install_cloud_hypervisor() {
    log "Installing Cloud Hypervisor ${CLH_VERSION}..."

    if [[ -x "$CLH_BINARY" ]]; then
        local installed_ver
        installed_ver=$("$CLH_BINARY" --version 2>&1 | head -1 || true)
        ok "Cloud Hypervisor already installed: $installed_ver"
    else
        need_sudo
        local url="https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/${CLH_VERSION}/cloud-hypervisor-static"
        log "Downloading CLH binary..."
        curl -fsSL "$url" -o /tmp/cloud-hypervisor-static
        sudo install -m 0755 /tmp/cloud-hypervisor-static "$CLH_BINARY"
        rm -f /tmp/cloud-hypervisor-static
        ok "Installed $CLH_BINARY"
    fi

    if [[ -f "$CLH_FIRMWARE" ]]; then
        ok "CLOUDHV.fd firmware already present"
    else
        need_sudo
        sudo mkdir -p "$(dirname "$CLH_FIRMWARE")"
        local fw_url="https://github.com/cloud-hypervisor/rust-hypervisor-firmware/releases/download/0.4.2/hypervisor-fw"
        log "Downloading hypervisor firmware..."
        curl -fsSL "$fw_url" -o /tmp/hypervisor-fw
        sudo install -m 0644 /tmp/hypervisor-fw "$CLH_FIRMWARE"
        rm -f /tmp/hypervisor-fw
        ok "Installed $CLH_FIRMWARE"
    fi
}

# ---------------------------------------------------------------------------
# Phase 2: Bridge Network
# ---------------------------------------------------------------------------
setup_bridge_network() {
    log "Setting up bridge network ${BRIDGE_NAME}..."

    need_sudo

    if ip link show "$BRIDGE_NAME" &>/dev/null; then
        ok "Bridge $BRIDGE_NAME already exists"
    else
        sudo ip link add "$BRIDGE_NAME" type bridge
        sudo ip addr add "${BRIDGE_IP}/24" dev "$BRIDGE_NAME"
        sudo ip link set "$BRIDGE_NAME" up
        ok "Created bridge $BRIDGE_NAME at $BRIDGE_IP"
    fi

    # Enable IP forwarding
    sudo sysctl -qw net.ipv4.ip_forward=1

    # NAT (idempotent — check before adding)
    if ! sudo iptables -t nat -C POSTROUTING -s "$BRIDGE_SUBNET" ! -d "$BRIDGE_SUBNET" -j MASQUERADE 2>/dev/null; then
        sudo iptables -t nat -A POSTROUTING -s "$BRIDGE_SUBNET" ! -d "$BRIDGE_SUBNET" -j MASQUERADE
        ok "Added NAT masquerade rule"
    else
        ok "NAT rule already present"
    fi

    # dnsmasq for DHCP (check if already running for this bridge)
    if pgrep -f "dnsmasq.*${BRIDGE_NAME}" &>/dev/null; then
        ok "dnsmasq already running for $BRIDGE_NAME"
    else
        sudo dnsmasq \
            --interface="$BRIDGE_NAME" \
            --bind-interfaces \
            --dhcp-range="${DHCP_RANGE_START},${DHCP_RANGE_END},12h" \
            --dhcp-option=3,"$BRIDGE_IP" \
            --dhcp-option=6,8.8.8.8,8.8.4.4 \
            --pid-file="${WORK_DIR}/dnsmasq.pid" \
            --log-facility="${WORK_DIR}/dnsmasq.log" \
            --no-daemon &
        disown
        sleep 1
        ok "Started dnsmasq DHCP on $BRIDGE_NAME"
    fi
}

# ---------------------------------------------------------------------------
# Phase 3: Build execd for Linux
# ---------------------------------------------------------------------------
build_execd() {
    log "Building execd for linux/amd64..."

    local execd_bin="${WORK_DIR}/execd"
    if [[ -f "$execd_bin" ]]; then
        ok "execd binary already exists at $execd_bin"
        return
    fi

    local goroot
    goroot="$(dirname "$(dirname "$GO_BIN")")"
    export GOROOT="$goroot"
    export PATH="${goroot}/bin:${PATH}"

    (
        cd "${REPO_ROOT}/components/execd"
        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
            "$GO_BIN" build -ldflags "-s -w" -o "$execd_bin" main.go
    )
    chmod +x "$execd_bin"
    ok "Built execd at $execd_bin"
}

# ---------------------------------------------------------------------------
# Phase 4: Build Alpine Test VM Image
# ---------------------------------------------------------------------------
build_test_image() {
    local image_name="alpine-test"
    local image_path="${IMAGE_DIR}/${image_name}.raw"
    local qcow2_path="${IMAGE_DIR}/${image_name}.qcow2"

    if [[ -f "$qcow2_path" ]]; then
        ok "Test image already exists at $qcow2_path"
        return
    fi

    log "Building Alpine test image (unpartitioned root)..."
    need_sudo

    local execd_bin="${WORK_DIR}/execd"
    [[ -f "$execd_bin" ]] || fail "execd binary not found at $execd_bin. Run build_execd first."

    mkdir -p "$IMAGE_DIR"

    # Use unpartitioned raw image — whole disk is ext4 root.
    # Direct kernel boot (--kernel + --initramfs) means no GRUB/UEFI needed.
    local img_size="1G"
    local alpine_rootfs_url="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/x86_64/alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-x86_64.tar.gz"
    local alpine_rootfs="${WORK_DIR}/alpine-minirootfs.tar.gz"
    local mnt="${WORK_DIR}/mnt"

    # Download Alpine minirootfs
    if [[ ! -f "$alpine_rootfs" ]]; then
        log "Downloading Alpine ${ALPINE_VERSION}.${ALPINE_MINOR} minirootfs..."
        curl -fsSL "$alpine_rootfs_url" -o "$alpine_rootfs"
    fi

    # Create raw image — no partitions, entire disk = ext4
    qemu-img create -f raw "$image_path" "$img_size"
    mkfs.ext4 -q "$image_path"

    # Mount
    sudo mkdir -p "$mnt"
    sudo mount -o loop "$image_path" "$mnt"

    # Extract Alpine rootfs
    log "Extracting Alpine rootfs..."
    sudo tar xzf "$alpine_rootfs" -C "$mnt"

    # Setup DNS + repos in chroot
    sudo cp /etc/resolv.conf "$mnt/etc/resolv.conf"
    sudo tee "$mnt/etc/apk/repositories" > /dev/null <<REPOS
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
REPOS

    # Install minimal packages (no GRUB — direct kernel boot)
    sudo chroot "$mnt" /bin/sh -c '
        apk add --no-cache linux-lts mkinitfs e2fsprogs dhcpcd openrc
        rm -rf /lib/firmware
        rc-update add devfs sysinit
        rc-update add dmesg sysinit
        rc-update add hwdrivers sysinit
        rc-update add modules boot
        rc-update add sysctl boot
        rc-update add hostname boot
        rc-update add bootmisc boot
        rc-update add networking boot
        rc-update add dhcpcd default
        rc-update add local default
    '

    # Configure networking
    sudo tee "$mnt/etc/network/interfaces" > /dev/null <<NET
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NET

    echo "opensandbox-test" | sudo tee "$mnt/etc/hostname" > /dev/null

    # fstab: whole disk is /dev/vda (no partitions)
    sudo tee "$mnt/etc/fstab" > /dev/null <<FSTAB
/dev/vda    /    ext4    defaults,noatime    0 1
FSTAB

    # Serial console
    sudo tee "$mnt/etc/inittab" > /dev/null <<INITTAB
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100
::shutdown:/sbin/openrc shutdown
INITTAB

    # Install execd
    sudo install -m 0755 "$execd_bin" "$mnt/usr/local/bin/execd"

    # Create execd OpenRC init script
    sudo tee "$mnt/etc/init.d/execd" > /dev/null <<'EXECD_INIT'
#!/sbin/openrc-run

name="execd"
description="OpenSandbox execd agent"
command="/usr/local/bin/execd"
command_args="-port 44772"
command_background="yes"
pidfile="/run/execd.pid"
output_log="/var/log/execd.log"
error_log="/var/log/execd.log"

depend() {
    need net
    after networking
}
EXECD_INIT
    sudo chmod +x "$mnt/etc/init.d/execd"
    sudo chroot "$mnt" rc-update add execd default

    # Generate minimal initramfs (virtio + ext4 only)
    log "Generating initramfs..."
    sudo chroot "$mnt" /bin/sh -c '
        KVER=$(ls /lib/modules/ | head -1)
        [ -n "$KVER" ] || exit 1
        echo "features=\"base ext4 virtio\"" > /etc/mkinitfs/mkinitfs.conf
        mkinitfs -o /boot/initramfs-lts "$KVER"
    '

    # Copy kernel + initrd out for direct boot
    log "Extracting kernel and initrd..."
    sudo cp "$mnt/boot/vmlinuz-lts" "${IMAGE_DIR}/vmlinuz-lts"
    sudo cp "$mnt/boot/initramfs-lts" "${IMAGE_DIR}/initramfs-lts"
    sudo chmod 644 "${IMAGE_DIR}/vmlinuz-lts" "${IMAGE_DIR}/initramfs-lts"

    # Cleanup
    sudo rm -f "$mnt/etc/resolv.conf"
    sync
    sudo umount "$mnt"

    # Convert to qcow2
    log "Converting to qcow2..."
    qemu-img convert -f raw -O qcow2 "$image_path" "$qcow2_path"
    rm -f "$image_path"

    ok "Test image ready at $qcow2_path"
    ok "Kernel: ${IMAGE_DIR}/vmlinuz-lts"
    ok "Initrd: ${IMAGE_DIR}/initramfs-lts"
}

# ---------------------------------------------------------------------------
# Phase 5: Python Server Setup
# ---------------------------------------------------------------------------
setup_server() {
    log "Setting up Python server..."

    # Install uv if needed
    if ! command -v uv &>/dev/null; then
        log "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi
    ok "uv available: $(uv --version)"

    # Sync server dependencies
    (cd "${REPO_ROOT}/server" && uv sync --quiet)
    ok "Server dependencies synced"

    # Generate config
    mkdir -p "$SOCKET_DIR" "$IMAGE_DIR"

    cat > "$CONFIG_FILE" <<TOML
[server]
host = "0.0.0.0"
port = ${SERVER_PORT}

[runtime]
type = "windows"

[windows_runtime]
clh_binary = "${CLH_BINARY}"
firmware = "${CLH_FIRMWARE}"
kernel = "${IMAGE_DIR}/vmlinuz-lts"
initrd = "${IMAGE_DIR}/initramfs-lts"
cmdline = "console=ttyS0 root=/dev/vda rootfstype=ext4 modules=virtio_pci,virtio_blk,virtio_net,ext4 net.ifnames=0 rw quiet"
image_dir = "${IMAGE_DIR}"
default_cpus = 1
default_memory_mb = 1024
network_bridge = "${BRIDGE_NAME}"
api_socket_dir = "${SOCKET_DIR}"
hyperv_enlightenments = false
execd_port = ${EXECD_PORT}
boot_timeout_seconds = 90
TOML

    ok "Config written to $CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Phase 6: Run E2E Test
# ---------------------------------------------------------------------------
start_server() {
    log "Starting server on port ${SERVER_PORT}..."

    # Ensure no old server is running
    stop_server

    need_sudo
    (
        cd "${REPO_ROOT}/server"
        sudo -E SANDBOX_CONFIG_PATH="$CONFIG_FILE" \
            "$(which uv)" run python -m opensandbox_server.main \
            > "$SERVER_LOG" 2>&1 &
        echo $! > "$SERVER_PID_FILE"
    )

    # Wait for health
    local retries=30
    while (( retries > 0 )); do
        if curl -sf "http://localhost:${SERVER_PORT}/health" >/dev/null 2>&1; then
            ok "Server is healthy"
            return 0
        fi
        sleep 1
        (( retries-- ))
    done

    warn "Server may not be healthy. Last log lines:"
    tail -20 "$SERVER_LOG" || true
    fail "Server did not become healthy within 30s"
}

stop_server() {
    # Kill by PID file
    if [[ -f "$SERVER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$SERVER_PID_FILE")
        sudo kill "$pid" 2>/dev/null || true
        sleep 1
        sudo kill -9 "$pid" 2>/dev/null || true
        rm -f "$SERVER_PID_FILE"
    fi
    # Kill any leftover processes on our port and by name
    sudo pkill -9 -f "opensandbox_server" 2>/dev/null || true
    sudo pkill -9 -f "uvicorn" 2>/dev/null || true
    # Wait for port to free
    local retries=10
    while (( retries > 0 )); do
        if ! sudo lsof -ti:"$SERVER_PORT" &>/dev/null; then
            break
        fi
        sudo kill -9 "$(sudo lsof -ti:"$SERVER_PORT")" 2>/dev/null || true
        sleep 1
        (( retries-- ))
    done
    log "Server stopped"
}

run_e2e_test() {
    log "=========================================="
    log "  Running Cloud Hypervisor E2E Test"
    log "=========================================="

    local api="http://localhost:${SERVER_PORT}"
    local sandbox_id=""

    # Create sandbox
    log "Creating sandbox..."
    local create_resp
    create_resp=$(curl -s --max-time 120 -X POST "${api}/v1/sandboxes" \
        -H "Content-Type: application/json" \
        -d '{
            "image": {"uri": "alpine-test"},
            "entrypoint": ["/bin/sh"],
            "timeout": 300,
            "guestOs": "windows",
            "resourceLimits": {}
        }')
    log "Create response: $create_resp"

    # Check if response contains an ID (success) or error code (failure)
    if echo "$create_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'id' in d" 2>/dev/null; then
        ok "Sandbox created successfully"
    else
        fail "Failed to create sandbox: $create_resp"
    fi

    sandbox_id=$(echo "$create_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    ok "Sandbox created: $sandbox_id"

    # Verify sandbox exists
    log "Verifying sandbox..."
    local get_resp
    get_resp=$(curl -sf "${api}/v1/sandboxes/${sandbox_id}")
    local state
    state=$(echo "$get_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['status']['state'])")
    [[ "$state" == "Running" ]] || fail "Expected state=Running, got: $state"
    ok "Sandbox state: $state"

    # Check execd health via inspect
    log "Checking execd connectivity..."
    local inspect_resp
    inspect_resp=$(curl -sf "${api}/v1/sandboxes/${sandbox_id}/diagnostics/inspect" || echo "{}")
    log "Inspect: $(echo "$inspect_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"IP={d.get('vm',{}).get('guest_ip','?')}, PID={d.get('vm',{}).get('pid','?')}\")" 2>/dev/null || echo "(parse failed)")"

    # Get endpoint
    local endpoint_resp
    endpoint_resp=$(curl -sf "${api}/v1/sandboxes/${sandbox_id}/endpoint/${EXECD_PORT}" || echo "{}")
    local endpoint
    endpoint=$(echo "$endpoint_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('endpoint',''))" 2>/dev/null || echo "")
    if [[ -n "$endpoint" ]]; then
        ok "Execd endpoint: $endpoint"

        # Try pinging execd directly
        if curl -sf "http://${endpoint}/ping" >/dev/null 2>&1; then
            ok "Execd /ping responded OK!"
        else
            warn "Execd /ping not reachable at http://${endpoint}/ping (may need routing)"
        fi
    else
        warn "Could not get endpoint for port $EXECD_PORT"
    fi

    # List sandboxes
    log "Listing sandboxes..."
    local list_resp
    list_resp=$(curl -sf "${api}/v1/sandboxes")
    local count
    count=$(echo "$list_resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))")
    ok "Listed $count sandbox(es)"

    # Delete sandbox
    log "Deleting sandbox..."
    curl -sf -X DELETE "${api}/v1/sandboxes/${sandbox_id}" || warn "Delete may have failed"
    sleep 2

    # Verify deletion
    local del_check
    del_check=$(curl -s -o /dev/null -w "%{http_code}" "${api}/v1/sandboxes/${sandbox_id}")
    [[ "$del_check" == "404" ]] && ok "Sandbox deleted (404 on get)" || warn "Sandbox may still exist (HTTP $del_check)"

    log "=========================================="
    echo -e "${GREEN}  E2E TEST COMPLETE${NC}"
    log "=========================================="
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    log "Cleaning up..."

    stop_server

    # Kill dnsmasq
    if [[ -f "${WORK_DIR}/dnsmasq.pid" ]]; then
        sudo kill "$(cat "${WORK_DIR}/dnsmasq.pid")" 2>/dev/null || true
        rm -f "${WORK_DIR}/dnsmasq.pid"
    fi
    sudo pkill -f "dnsmasq.*${BRIDGE_NAME}" 2>/dev/null || true

    # Remove NAT rule
    sudo iptables -t nat -D POSTROUTING -s "$BRIDGE_SUBNET" ! -d "$BRIDGE_SUBNET" -j MASQUERADE 2>/dev/null || true

    # Remove bridge
    if ip link show "$BRIDGE_NAME" &>/dev/null; then
        sudo ip link set "$BRIDGE_NAME" down 2>/dev/null || true
        sudo ip link delete "$BRIDGE_NAME" 2>/dev/null || true
    fi

    # Remove work dir
    if [[ -d "$WORK_DIR" ]]; then
        # Cleanup any leftover loop devices
        for loop in $(losetup -j "${IMAGE_DIR}/" 2>/dev/null | cut -d: -f1); do
            sudo losetup -d "$loop" 2>/dev/null || true
        done
        # Unmount any leftover mounts
        sudo umount "${WORK_DIR}/mnt/boot/efi" 2>/dev/null || true
        sudo umount "${WORK_DIR}/mnt" 2>/dev/null || true
        rm -rf "$WORK_DIR"
    fi

    ok "Cleanup done"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="${1:---all}"

    mkdir -p "$WORK_DIR"

    case "$mode" in
        --setup)
            check_prerequisites
            install_cloud_hypervisor
            setup_bridge_network
            build_execd
            build_test_image
            setup_server
            ok "Setup complete. Run with --test to execute E2E test."
            ;;
        --test)
            setup_server
            start_server
            run_e2e_test
            stop_server
            ;;
        --cleanup)
            cleanup
            ;;
        --all|"")
            check_prerequisites
            install_cloud_hypervisor
            setup_bridge_network
            build_execd
            build_test_image
            setup_server
            start_server
            run_e2e_test
            stop_server
            ok "All done. Run --cleanup to tear down."
            ;;
        *)
            echo "Usage: $0 [--setup|--test|--cleanup|--all]"
            exit 1
            ;;
    esac
}

main "$@"
