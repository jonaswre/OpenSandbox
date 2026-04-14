# Copyright 2024 OpenSandbox Authors
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

<#
.SYNOPSIS
    Installs the OpenSandbox execd daemon into a Windows base image.

.DESCRIPTION
    This script runs during image preparation (via Packer/WinRM or manually).
    It creates the OpenSandbox directory, copies the execd binary, creates a
    default .env file, registers execd as a Windows service, and configures
    the inbound firewall rule.

.PARAMETER ExecdSource
    Path to the execd.exe binary to install. Defaults to C:\temp\execd.exe.

.EXAMPLE
    .\install-execd.ps1
    .\install-execd.ps1 -ExecdSource "D:\build\execd.exe"
#>

param(
    [string]$ExecdSource = "C:\temp\execd.exe"
)

$ErrorActionPreference = "Stop"

$InstallDir     = "C:\opensandbox"
$ExecdDest      = "$InstallDir\execd.exe"
$EnvFile        = "$InstallDir\.env"
$ServiceName    = "OpenSandboxExecd"
$ServiceDisplay = "OpenSandbox Execd"
$ServiceDesc    = "OpenSandbox execution daemon for sandbox operations"
$FirewallRule   = "OpenSandbox-Execd-In"
$ListenPort     = 8080

Write-Host "=== OpenSandbox execd installer ===" -ForegroundColor Cyan

# Step 1: Create install directory
Write-Host "[1/6] Creating install directory: $InstallDir"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Host "      Created $InstallDir"
} else {
    Write-Host "      Directory already exists, skipping."
}

# Step 2: Copy execd binary
Write-Host "[2/6] Copying execd binary from: $ExecdSource"
if (Test-Path $ExecdSource) {
    Copy-Item -Path $ExecdSource -Destination $ExecdDest -Force
    Write-Host "      Copied to $ExecdDest"
} else {
    Write-Warning "execd binary not found at '$ExecdSource'."
    Write-Host ""
    Write-Host "  To install manually, copy the binary and re-run this script:" -ForegroundColor Yellow
    Write-Host "    Copy-Item <path\to\execd.exe> -Destination '$ExecdDest'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Continuing without binary — operator must copy execd.exe before" -ForegroundColor Yellow
    Write-Host "  starting the service." -ForegroundColor Yellow
    Write-Host ""
}

# Step 3: Create default .env file
Write-Host "[3/6] Creating default .env file: $EnvFile"
if (-not (Test-Path $EnvFile)) {
    $envContent = @"
# OpenSandbox execd configuration
# Adjust values as needed before starting the service.

EXECD_LISTEN_ADDR=0.0.0.0:$ListenPort
"@
    Set-Content -Path $EnvFile -Value $envContent -Encoding UTF8
    Write-Host "      Created $EnvFile"
} else {
    Write-Host "      .env file already exists, skipping."
}

# Step 4: Register Windows service
Write-Host "[4/6] Registering Windows service: $ServiceName"
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $existingService) {
    New-Service `
        -Name $ServiceName `
        -BinaryPathName $ExecdDest `
        -DisplayName $ServiceDisplay `
        -Description $ServiceDesc `
        -StartupType Automatic | Out-Null
    Write-Host "      Service '$ServiceName' registered."
} else {
    Write-Host "      Service '$ServiceName' already registered, skipping."
}

# Step 5: Create inbound firewall rule
Write-Host "[5/6] Creating firewall rule: $FirewallRule (TCP $ListenPort inbound)"
$existingRule = Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue
if ($null -eq $existingRule) {
    New-NetFirewallRule `
        -DisplayName $FirewallRule `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $ListenPort `
        -Action Allow `
        -Enabled True | Out-Null
    Write-Host "      Firewall rule created."
} else {
    Write-Host "      Firewall rule already exists, skipping."
}

# Step 6: Verify service registration
Write-Host "[6/6] Verifying service registration"
$svc = Get-Service -Name $ServiceName -ErrorAction Stop
Write-Host "      Service name:    $($svc.Name)"
Write-Host "      Display name:    $($svc.DisplayName)"
Write-Host "      Status:          $($svc.Status)"
Write-Host "      Start type:      $($svc.StartType)"

# Summary
Write-Host ""
Write-Host "=== Install complete ===" -ForegroundColor Green
Write-Host "  Install dir : $InstallDir"
Write-Host "  Binary      : $ExecdDest"
Write-Host "  Env file    : $EnvFile"
Write-Host "  Service     : $ServiceName (Automatic, not yet started)"
Write-Host "  Firewall    : TCP $ListenPort inbound allowed"
Write-Host ""
Write-Host "Start the service with:"
Write-Host "  Start-Service -Name '$ServiceName'"
