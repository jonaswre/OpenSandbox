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
    Pre-template cleanup script to reduce base image size.

.DESCRIPTION
    Removes unnecessary files, caches, and logs before capturing the Windows
    base image. Adapted from 5-nodes/runner cleanup.ps1.

.EXAMPLE
    .\cleanup.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "=== OpenSandbox Windows image cleanup ===" -ForegroundColor Cyan

function Get-DiskFreeGB {
    $drive = Get-PSDrive -Name C
    return [math]::Round($drive.Free / 1GB, 2)
}

$beforeGB = Get-DiskFreeGB
Write-Host "Disk free before cleanup: ${beforeGB} GB"
Write-Host ""

# Step 1: Disable hibernation
Write-Host "[1/12] Disabling hibernation"
powercfg /hibernate off
Write-Host "       Done."

# Step 2: Clear Windows Update cache
Write-Host "[2/12] Clearing Windows Update cache"
$wuService = "wuauserv"
$wuDownloadDir = "C:\Windows\SoftwareDistribution\Download"
try {
    Stop-Service -Name $wuService -Force -ErrorAction SilentlyContinue
    Write-Host "       Stopped $wuService"
} catch {
    Write-Host "       $wuService was not running."
}
if (Test-Path $wuDownloadDir) {
    Remove-Item -Path "$wuDownloadDir\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "       Cleared $wuDownloadDir"
}

# Step 3: Clear Windows Temp
Write-Host "[3/12] Clearing C:\Windows\Temp"
Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "       Done."

# Step 4: Clear user temp directories
Write-Host "[4/12] Clearing user temp directories"
$tempDirs = @(
    $env:TEMP,
    $env:TMP,
    "$env:USERPROFILE\AppData\Local\Temp"
)
foreach ($dir in ($tempDirs | Sort-Object -Unique)) {
    if ($dir -and (Test-Path $dir)) {
        Remove-Item -Path "$dir\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "       Cleared $dir"
    }
}

# Step 5: Empty Recycle Bin
Write-Host "[5/12] Emptying Recycle Bin"
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
Write-Host "       Done."

# Step 6: Clear Prefetch cache
Write-Host "[6/12] Clearing Prefetch cache"
$prefetchDir = "C:\Windows\Prefetch"
if (Test-Path $prefetchDir) {
    Remove-Item -Path "$prefetchDir\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "       Cleared $prefetchDir"
} else {
    Write-Host "       Prefetch directory not found, skipping."
}

# Step 7: Clear event logs
Write-Host "[7/12] Clearing all event logs"
$logs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 }
foreach ($log in $logs) {
    try {
        [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($log.LogName)
    } catch {
        # Some logs (e.g. Security) may require elevated privileges; skip silently.
    }
}
Write-Host "       Done."

# Step 8: Clear PowerShell history
Write-Host "[8/12] Clearing PowerShell history"
$psHistoryPath = (Get-PSReadlineOption -ErrorAction SilentlyContinue).HistorySavePath
if ($psHistoryPath -and (Test-Path $psHistoryPath)) {
    Remove-Item -Path $psHistoryPath -Force -ErrorAction SilentlyContinue
    Write-Host "       Cleared $psHistoryPath"
} else {
    # Fallback to well-known default location
    $fallback = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
    if (Test-Path $fallback) {
        Remove-Item -Path $fallback -Force -ErrorAction SilentlyContinue
        Write-Host "       Cleared $fallback"
    } else {
        Write-Host "       No PowerShell history file found."
    }
}

# Step 9: DISM component store cleanup
Write-Host "[9/12] Running DISM component cleanup (this may take several minutes)"
$dismResult = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "DISM exited with code $LASTEXITCODE. Output:"
    $dismResult | Write-Host
} else {
    Write-Host "       DISM cleanup complete."
}

# Step 10: Clear DNS cache
Write-Host "[10/12] Clearing DNS cache"
Clear-DnsClientCache
Write-Host "        Done."

# Step 11: Remove Windows.old
Write-Host "[11/12] Removing C:\Windows.old (if exists)"
if (Test-Path "C:\Windows.old") {
    Remove-Item -Path "C:\Windows.old" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "        Removed C:\Windows.old"
} else {
    Write-Host "        C:\Windows.old not found, skipping."
}

# Step 12: Disk space summary
Write-Host "[12/12] Disk space summary"
$afterGB  = Get-DiskFreeGB
$savedGB  = [math]::Round($afterGB - $beforeGB, 2)

Write-Host ""
Write-Host "=== Cleanup complete ===" -ForegroundColor Green
Write-Host "  Free before : ${beforeGB} GB"
Write-Host "  Free after  : ${afterGB} GB"
Write-Host "  Space freed : ${savedGB} GB"
