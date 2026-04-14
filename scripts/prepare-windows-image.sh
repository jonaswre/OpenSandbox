#!/bin/bash
# Copyright 2025 Alibaba Group Holding Ltd.
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
#
# Comprehensive pipeline for building OpenSandbox Windows base images using
# QEMU on a Linux host. Produces a qcow2 image suitable for Cloud-Hypervisor.
#
# Usage: chmod +x scripts/prepare-windows-image.sh && ./scripts/prepare-windows-image.sh --help

set -euo pipefail

# ---------------------------------------------------------------------------
# ANSI color helpers
# ---------------------------------------------------------------------------
COLOR_RESET="\033[0m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_RED="\033[0;31m"
COLOR_BLUE="\033[0;34m"
COLOR_BOLD="\033[1m"

log_info()    { printf "${COLOR_BLUE}[INFO]${COLOR_RESET}  %s\n"    "$*"; }
log_success() { printf "${COLOR_GREEN}[OK]${COLOR_RESET}    %s\n"   "$*"; }
log_warn()    { printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  %s\n"  "$*" >&2; }
log_error()   { printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n"     "$*" >&2; }
log_step()    { printf "\n${COLOR_BOLD}==> %s${COLOR_RESET}\n"      "$*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
WINDOWS_ISO=""
VIRTIO_ISO=""
OUTPUT_IMAGE=""
EXECD_BINARY=""
DISK_SIZE="64G"
MEMORY="4G"
CPUS="2"
VNC_DISPLAY="10"
SKIP_INSTALL="false"

# Resolved at runtime
OVMF_CODE=""
OVMF_VARS=""
OVMF_VARS_IMG=""
AUTOUNATTEND_ISO=""
TMPDIR_WORK=""
ISO_TOOL=""

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup() {
    if [[ -n "${TMPDIR_WORK:-}" && -d "${TMPDIR_WORK}" ]]; then
        rm -rf "${TMPDIR_WORK}"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${COLOR_BOLD}Usage:${COLOR_RESET} $(basename "$0") [OPTIONS]

Complete pipeline for building OpenSandbox Windows base images using QEMU on a
Linux host. The resulting qcow2 image can be consumed by Cloud-Hypervisor.

${COLOR_BOLD}Required options:${COLOR_RESET}
  --windows-iso PATH    Path to Windows Server 2022 ISO
  --virtio-iso PATH     Path to VirtIO drivers ISO
                        (https://github.com/virtio-win/virtio-win-pkg-scripts)
  --output PATH         Output path for the qcow2 disk image

${COLOR_BOLD}Optional options:${COLOR_RESET}
  --execd-binary PATH   Path to execd.exe to inject into the image post-install
  --disk-size SIZE      Disk image size (default: ${DISK_SIZE})
  --memory SIZE         RAM allocated during installation (default: ${MEMORY})
  --cpus N              vCPU count during installation (default: ${CPUS})
  --vnc-display N       VNC display number (default: ${VNC_DISPLAY}, port $((5900 + VNC_DISPLAY)))
  --skip-install        Skip QEMU install step (image already exists)
  -h, --help            Show this help message

${COLOR_BOLD}Pipeline steps:${COLOR_RESET}
  1. Generate autounattend ISO from scripts/windows/autounattend.xml
  2. Create qcow2 disk image
  3. Copy OVMF VARS for per-image UEFI variable storage
  4. Print QEMU install command (operator runs and monitors via VNC)
  5. Print post-install checklist (operator completes inside VM)
  6. Print Cloud-Hypervisor verification command

${COLOR_BOLD}Example:${COLOR_RESET}
  $(basename "$0") \\
    --windows-iso /tmp/WinServer2022.iso \\
    --virtio-iso  /tmp/virtio-win-0.1.262.iso \\
    --output      /var/lib/opensandbox/images/windows-server-2022.qcow2 \\
    --execd-binary ./bin/execd.exe

EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --windows-iso)   WINDOWS_ISO="$2";   shift 2 ;;
        --virtio-iso)    VIRTIO_ISO="$2";    shift 2 ;;
        --output)        OUTPUT_IMAGE="$2";  shift 2 ;;
        --execd-binary)  EXECD_BINARY="$2";  shift 2 ;;
        --disk-size)     DISK_SIZE="$2";     shift 2 ;;
        --memory)        MEMORY="$2";        shift 2 ;;
        --cpus)          CPUS="$2";          shift 2 ;;
        --vnc-display)   VNC_DISPLAY="$2";   shift 2 ;;
        --skip-install)  SKIP_INSTALL="true"; shift ;;
        -h|--help)       usage ;;
        *)
            log_error "Unknown option: $1"
            echo "" >&2
            usage
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate required arguments
# ---------------------------------------------------------------------------
MISSING=0
if [[ -z "$WINDOWS_ISO" ]];  then log_error "--windows-iso is required"; MISSING=1; fi
if [[ -z "$VIRTIO_ISO" ]];   then log_error "--virtio-iso is required";  MISSING=1; fi
if [[ -z "$OUTPUT_IMAGE" ]]; then log_error "--output is required";      MISSING=1; fi
if [[ "$MISSING" -eq 1 ]]; then echo "" >&2; usage; fi

if [[ "$SKIP_INSTALL" == "false" ]]; then
    if [[ ! -f "$WINDOWS_ISO" ]]; then
        log_error "Windows ISO not found: $WINDOWS_ISO"
        exit 1
    fi
    if [[ ! -f "$VIRTIO_ISO" ]]; then
        log_error "VirtIO ISO not found: $VIRTIO_ISO"
        exit 1
    fi
fi

if [[ -n "$EXECD_BINARY" && ! -f "$EXECD_BINARY" ]]; then
    log_error "execd binary not found: $EXECD_BINARY"
    exit 1
fi

VNC_PORT=$((5900 + VNC_DISPLAY))

# ---------------------------------------------------------------------------
# Step 0: Validate required tools
# ---------------------------------------------------------------------------
step_validate_tools() {
    log_step "Validating required tools"

    local missing=0

    check_tool() {
        local tool="$1"
        if command -v "$tool" >/dev/null 2>&1; then
            log_success "Found: $tool -> $(command -v "$tool")"
        else
            log_error "Required tool not found in PATH: $tool"
            missing=1
        fi
    }

    check_tool qemu-system-x86_64
    check_tool qemu-img

    # genisoimage or mkisofs
    if command -v genisoimage >/dev/null 2>&1; then
        log_success "Found: genisoimage -> $(command -v genisoimage)"
        ISO_TOOL="genisoimage"
    elif command -v mkisofs >/dev/null 2>&1; then
        log_success "Found: mkisofs -> $(command -v mkisofs)"
        ISO_TOOL="mkisofs"
    else
        log_error "Required tool not found in PATH: genisoimage or mkisofs"
        log_warn  "Install with: apt-get install genisoimage  OR  dnf install genisoimage"
        missing=1
    fi

    # Locate OVMF firmware
    local ovmf_code_candidates=(
        /usr/share/OVMF/OVMF_CODE_4M.fd
        /usr/share/OVMF/OVMF_CODE.fd
        /usr/share/edk2/ovmf/OVMF_CODE.fd
        /usr/share/qemu/OVMF_CODE.fd
    )
    local ovmf_vars_candidates=(
        /usr/share/OVMF/OVMF_VARS_4M.fd
        /usr/share/OVMF/OVMF_VARS.fd
        /usr/share/edk2/ovmf/OVMF_VARS.fd
        /usr/share/qemu/OVMF_VARS.fd
    )

    for candidate in "${ovmf_code_candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            OVMF_CODE="$candidate"
            break
        fi
    done

    for candidate in "${ovmf_vars_candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            OVMF_VARS="$candidate"
            break
        fi
    done

    if [[ -z "$OVMF_CODE" || -z "$OVMF_VARS" ]]; then
        log_error "OVMF UEFI firmware not found. Install with:"
        log_error "  Debian/Ubuntu: apt-get install ovmf"
        log_error "  RHEL/Fedora:   dnf install edk2-ovmf"
        missing=1
    else
        log_success "Found: OVMF_CODE -> $OVMF_CODE"
        log_success "Found: OVMF_VARS -> $OVMF_VARS"
    fi

    if [[ "$missing" -ne 0 ]]; then
        log_error "One or more required tools are missing. Aborting."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Generate autounattend ISO
# ---------------------------------------------------------------------------
step_generate_autounattend_iso() {
    log_step "Step 1: Generating autounattend ISO"

    # Locate autounattend.xml relative to this script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local xml_dir="${script_dir}/windows"
    local xml_file="${xml_dir}/autounattend.xml"

    if [[ ! -f "$xml_file" ]]; then
        log_error "autounattend.xml not found at: $xml_file"
        log_error "Expected path: scripts/windows/autounattend.xml"
        exit 1
    fi

    TMPDIR_WORK="$(mktemp -d)"
    AUTOUNATTEND_ISO="${TMPDIR_WORK}/autounattend.iso"

    log_info "Source XML: $xml_file"
    log_info "Output ISO: $AUTOUNATTEND_ISO"

    "$ISO_TOOL" \
        -o "$AUTOUNATTEND_ISO" \
        -J -r \
        "$xml_dir/" \
        2>/dev/null

    log_success "autounattend ISO generated: $AUTOUNATTEND_ISO"
}

# ---------------------------------------------------------------------------
# Step 2: Create disk image
# ---------------------------------------------------------------------------
step_create_disk_image() {
    log_step "Step 2: Creating qcow2 disk image"

    local image_dir
    image_dir="$(dirname "$OUTPUT_IMAGE")"
    mkdir -p "$image_dir"

    if [[ -f "$OUTPUT_IMAGE" ]]; then
        log_warn "Output image already exists: $OUTPUT_IMAGE"
        log_warn "It will be overwritten."
    fi

    log_info "Creating: $OUTPUT_IMAGE (size: $DISK_SIZE)"
    qemu-img create -f qcow2 "$OUTPUT_IMAGE" "$DISK_SIZE"
    log_success "Disk image created: $OUTPUT_IMAGE"
}

# ---------------------------------------------------------------------------
# Step 3: Copy OVMF VARS
# ---------------------------------------------------------------------------
step_copy_ovmf_vars() {
    log_step "Step 3: Copying OVMF VARS for per-image UEFI variable storage"

    local vars_dest="${OUTPUT_IMAGE}.vars.fd"
    cp "$OVMF_VARS" "$vars_dest"
    log_success "OVMF VARS copied: $vars_dest"
    # Export so later steps can reference it
    OVMF_VARS_IMG="$vars_dest"
}

# ---------------------------------------------------------------------------
# Step 4: Print QEMU install command
# ---------------------------------------------------------------------------
step_print_qemu_command() {
    log_step "Step 4: QEMU installation command"

    log_info "DO NOT auto-run this command — it requires VNC interaction."
    log_info "Connect a VNC viewer to localhost:${VNC_PORT} once the VM starts."
    log_info "The autounattend.xml will drive the unattended install automatically."
    log_info "Wait for the VM to shut down cleanly before proceeding to Step 5."

    printf "\n${COLOR_BOLD}--- QEMU INSTALL COMMAND ---${COLOR_RESET}\n"
    cat <<QEMUCMD
qemu-system-x86_64 \\
  -machine q35,accel=kvm \\
  -cpu host,kvm=on,kvm_hyperv=on \\
  -m ${MEMORY} \\
  -smp ${CPUS} \\
  -drive if=pflash,format=raw,readonly=on,file=${OVMF_CODE} \\
  -drive if=pflash,format=raw,file=${OVMF_VARS_IMG} \\
  -drive file=${OUTPUT_IMAGE},if=none,id=disk0,format=qcow2 \\
  -device virtio-scsi-pci,id=scsi0 \\
  -device scsi-hd,drive=disk0,bus=scsi0.0 \\
  -drive file=${WINDOWS_ISO},media=cdrom,index=0 \\
  -drive file=${AUTOUNATTEND_ISO},media=cdrom,index=1 \\
  -drive file=${VIRTIO_ISO},media=cdrom,index=2 \\
  -device virtio-net-pci,netdev=net0 \\
  -netdev user,id=net0 \\
  -vnc :${VNC_DISPLAY} \\
  -serial stdio
QEMUCMD
    printf "${COLOR_BOLD}----------------------------${COLOR_RESET}\n\n"
}

# ---------------------------------------------------------------------------
# Step 5: Print post-install instructions
# ---------------------------------------------------------------------------
step_print_post_install() {
    log_step "Step 5: Post-install checklist (complete inside the running VM)"

    local execd_note=""
    if [[ -n "$EXECD_BINARY" ]]; then
        execd_note="
      # Option A — inject via qemu-nbd (offline, VM must be shut down):
      sudo modprobe nbd max_part=8
      sudo qemu-nbd --connect=/dev/nbd0 ${OUTPUT_IMAGE}
      sudo mount /dev/nbd0p3 /mnt   # adjust partition as needed
      sudo mkdir -p /mnt/opensandbox
      sudo cp ${EXECD_BINARY} /mnt/opensandbox/execd.exe
      sudo umount /mnt
      sudo qemu-nbd --disconnect /dev/nbd0

      # Option B — copy while VM is running (QEMU user-net SMB or WinRM):
      # scp -P 2222 ${EXECD_BINARY} Administrator@localhost:C:/opensandbox/execd.exe"
    else
        execd_note="
      (--execd-binary was not specified; copy execd.exe manually into C:\\opensandbox\\)"
    fi

    cat <<INSTRUCTIONS
  1.  Connect via VNC at localhost:${VNC_PORT}

  2.  Windows installs automatically — autounattend handles partitioning,
      language, product key, and initial driver setup via the VirtIO ISO.

  3.  After the first reboot the VM will auto-logon and run FirstLogonCommands.
      Wait for those to finish (the desktop will appear when done).

  4.  Verify QEMU Guest Agent service is running:
        sc.exe query QEMU-GA

  5.  Copy execd.exe to C:\\opensandbox\\:${execd_note}

  6.  Run the execd installation script via WinRM or RDP:
        powershell.exe -ExecutionPolicy Bypass -File scripts\\windows\\install-execd.ps1

  7.  Run the cleanup script to reduce image size:
        powershell.exe -ExecutionPolicy Bypass -File scripts\\windows\\cleanup.ps1

  8.  Shut down the VM cleanly to flush the disk image:
        shutdown /s /t 0

INSTRUCTIONS
}

# ---------------------------------------------------------------------------
# Step 6: Print CLH verification command
# ---------------------------------------------------------------------------
step_print_clh_command() {
    log_step "Step 6: Cloud-Hypervisor verification command"

    log_info "After the VM shuts down, test that the image boots correctly under CLH:"

    # Convert MEMORY (e.g. "4G") to MiB string for CLH (e.g. "4096M")
    local mem_mib
    if [[ "$MEMORY" =~ ^([0-9]+)G$ ]]; then
        mem_mib="$(( ${BASH_REMATCH[1]} * 1024 ))M"
    elif [[ "$MEMORY" =~ ^([0-9]+)M$ ]]; then
        mem_mib="${MEMORY}"
    else
        mem_mib="${MEMORY}"
    fi

    printf "\n${COLOR_BOLD}--- CLH TEST COMMAND ---${COLOR_RESET}\n"
    cat <<CLHCMD
cloud-hypervisor \\
  --kernel /usr/share/cloud-hypervisor/CLOUDHV.fd \\
  --disk path=${OUTPUT_IMAGE} \\
  --cpus boot=${CPUS} \\
  --memory size=${mem_mib} \\
  --net tap=,mac=52:54:00:12:34:56,ip=10.44.0.1,mask=255.255.255.0 \\
  --serial tty \\
  --console off
CLHCMD
    printf "${COLOR_BOLD}------------------------${COLOR_RESET}\n\n"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    log_step "Summary"

    printf "${COLOR_BOLD}Generated artifacts:${COLOR_RESET}\n"
    printf "  %-30s %s\n" "Disk image:"       "${OUTPUT_IMAGE}"
    printf "  %-30s %s\n" "OVMF VARS:"        "${OVMF_VARS_IMG}"
    printf "  %-30s %s\n" "autounattend ISO:"  "${AUTOUNATTEND_ISO:-<skipped>}"
    if [[ -n "$EXECD_BINARY" ]]; then
        printf "  %-30s %s\n" "execd binary (to inject):" "${EXECD_BINARY}"
    fi
    printf "\n"
    log_success "Pipeline complete. Follow the checklist above to finish image preparation."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    printf "\n${COLOR_BOLD}OpenSandbox Windows Image Builder${COLOR_RESET}\n"
    printf "%-20s %s\n" "Windows ISO:"   "${WINDOWS_ISO}"
    printf "%-20s %s\n" "VirtIO ISO:"    "${VIRTIO_ISO}"
    printf "%-20s %s\n" "Output image:"  "${OUTPUT_IMAGE}"
    printf "%-20s %s\n" "Disk size:"     "${DISK_SIZE}"
    printf "%-20s %s\n" "Memory:"        "${MEMORY}"
    printf "%-20s %s\n" "CPUs:"          "${CPUS}"
    printf "%-20s %s (port %d)\n" "VNC display:" ":${VNC_DISPLAY}" "${VNC_PORT}"
    if [[ -n "$EXECD_BINARY" ]]; then
        printf "%-20s %s\n" "execd binary:" "${EXECD_BINARY}"
    fi
    printf "\n"

    step_validate_tools

    if [[ "$SKIP_INSTALL" == "false" ]]; then
        step_generate_autounattend_iso
        step_create_disk_image
        step_copy_ovmf_vars
        step_print_qemu_command
    else
        log_warn "--skip-install set: skipping ISO generation, disk creation, and QEMU command."
        # Still need OVMF_VARS_IMG for the summary
        OVMF_VARS_IMG="${OUTPUT_IMAGE}.vars.fd"
    fi

    step_print_post_install
    step_print_clh_command
    print_summary
}

main "$@"
