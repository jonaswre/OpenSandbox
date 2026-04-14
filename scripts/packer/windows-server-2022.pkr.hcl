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

# OpenSandbox Windows Server 2022 Base Image Builder
#
# Builds a Windows Server 2022 qcow2 image pre-configured for Cloud Hypervisor:
# - UEFI boot via OVMF
# - VirtIO SCSI + VirtIO Net drivers
# - QEMU Guest Agent
# - OpenSandbox execd daemon registered as a Windows service
# - Firewall rule for execd (port 8080)
# - SAC (Special Administration Console) enabled
# - Cleaned up for minimal image size
#
# Usage:
#   cd scripts/packer
#   packer init .
#   packer build -var-file=variables.auto.pkrvars.hcl .
#
# Prerequisites:
#   - QEMU/KVM installed on build host
#   - Windows Server 2022 ISO
#   - VirtIO drivers ISO (from Fedora)
#   - execd.exe cross-compiled for Windows (GOOS=windows GOARCH=amd64)

packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# --------------------------------------------------------------------------
# Variables
# --------------------------------------------------------------------------

variable "windows_iso_path" {
  type        = string
  description = "Path to the Windows Server 2022 ISO file"
}

variable "virtio_iso_path" {
  type        = string
  description = "Path to the VirtIO drivers ISO (e.g., virtio-win-0.1.240.iso)"
}

variable "execd_binary_path" {
  type        = string
  description = "Path to the execd.exe binary (cross-compiled for Windows amd64)"
  default     = ""
}

variable "output_directory" {
  type        = string
  description = "Directory for the output qcow2 image"
  default     = "output"
}

variable "disk_size" {
  type        = string
  description = "VM disk size"
  default     = "65536M"
}

variable "memory" {
  type        = string
  description = "VM memory in MB"
  default     = "4096"
}

variable "cpus" {
  type        = number
  description = "Number of vCPUs"
  default     = 2
}

variable "winrm_username" {
  type        = string
  description = "WinRM username for provisioning"
  default     = "Administrator"
}

variable "winrm_password" {
  type        = string
  description = "WinRM password for provisioning"
  default     = "OpenSandbox!"
  sensitive   = true
}

variable "headless" {
  type        = bool
  description = "Run build without VNC display"
  default     = false
}

variable "vnc_port_min" {
  type        = number
  description = "Minimum VNC port"
  default     = 5900
}

variable "vnc_port_max" {
  type        = number
  description = "Maximum VNC port"
  default     = 5999
}

# --------------------------------------------------------------------------
# Source: QEMU Builder
# --------------------------------------------------------------------------

source "qemu" "windows-server-2022" {
  # VM Configuration
  vm_name          = "opensandbox-windows-server-2022"
  output_directory = var.output_directory
  format           = "qcow2"

  # Hardware
  accelerator  = "kvm"
  machine_type = "q35"
  cpus         = var.cpus
  memory       = var.memory
  disk_size    = var.disk_size

  # UEFI Firmware
  firmware = "/usr/share/OVMF/OVMF_CODE.fd"

  # CPU flags: Hyper-V enlightenments for Windows performance
  qemuargs = [
    ["-cpu", "host,kvm=on,+kvm_pv_unhalt,+kvm_pv_eoi,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_reset,hv_vpindex,hv_runtime,hv_relaxed,hv_synic,hv_stimer"],
    ["-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd"],
    ["-drive", "if=pflash,format=raw,file=${var.output_directory}/efivars.fd"],
    ["-device", "virtio-net-pci,netdev=user.0"],
    ["-serial", "stdio"],
  ]

  # Disk: VirtIO SCSI for best performance
  disk_interface = "virtio-scsi"
  disk_discard   = "unmap"
  disk_cache     = "none"

  # Network
  net_device = "virtio-net-pci"

  # ISO Configuration
  iso_url      = var.windows_iso_path
  iso_checksum = "none"

  # Additional CD-ROMs: autounattend + VirtIO drivers
  cd_files = ["${path.root}/../windows/autounattend.xml"]
  cd_label = "OEMDRV"

  secondary_iso_files {
    iso_url      = var.virtio_iso_path
    iso_checksum = "none"
  }

  # Boot
  boot_wait    = "5s"
  boot_command = ["<spacebar>"]

  # Display
  headless     = var.headless
  vnc_port_min = var.vnc_port_min
  vnc_port_max = var.vnc_port_max

  # WinRM Communicator
  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_port     = 5985
  winrm_timeout  = "60m"
  winrm_use_ssl  = false
  winrm_insecure = true

  # Shutdown
  shutdown_command = "shutdown /s /t 30 /f /d p:4:1 /c \"Packer build complete\""
  shutdown_timeout = "15m"
}

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

build {
  name    = "opensandbox-windows"
  sources = ["source.qemu.windows-server-2022"]

  # Wait for system stabilization after first boot
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # Copy execd binary into the VM (if provided)
  provisioner "file" {
    source      = var.execd_binary_path
    destination = "C:\\temp\\execd.exe"
    only        = var.execd_binary_path != "" ? ["qemu.windows-server-2022"] : []
  }

  # Install and register execd as a Windows service
  provisioner "powershell" {
    script = "${path.root}/../windows/install-execd.ps1"
  }

  # Configure SAC (Special Administration Console) for serial access
  provisioner "powershell" {
    inline = [
      "bcdedit /ems '{default}' on",
      "bcdedit /emssettings emsport:1 emsbaudrate:115200",
      "Write-Host 'SAC (Special Administration Console) enabled' -ForegroundColor Green",
    ]
  }

  # Cleanup: remove temp files, caches, logs to reduce image size
  provisioner "powershell" {
    script = "${path.root}/../windows/cleanup.ps1"
  }

  # Final shutdown (no sysprep — CLH uses COW overlays per sandbox)
  provisioner "powershell" {
    inline = [
      "Write-Host '=== OpenSandbox Windows Base Image Build Complete ===' -ForegroundColor Green",
      "Write-Host 'Image ready for Cloud Hypervisor' -ForegroundColor Green",
    ]
  }
}
