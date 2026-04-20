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
    Configures networking for CLH TAP bridge environments.

.DESCRIPTION
    Applies a static IP to the first Ethernet adapter (e.g. VirtIO NetKVM),
    or verifies DHCP is active when no static IP is requested.
    Validates connectivity to the gateway and prints a final network summary.

.PARAMETER StaticIP
    Static IPv4 address to assign (e.g. "10.44.0.2"). When omitted, DHCP mode
    is assumed and no IP changes are made.

.PARAMETER SubnetMask
    Subnet mask in dotted-decimal notation. Defaults to "255.255.255.0".

.PARAMETER Gateway
    Default gateway address. Defaults to "10.44.0.1".

.PARAMETER DnsServer
    Primary DNS server address. Defaults to "8.8.8.8".

.EXAMPLE
    .\setup-networking.ps1
    .\setup-networking.ps1 -StaticIP "10.44.0.2"
    .\setup-networking.ps1 -StaticIP "10.44.0.5" -Gateway "10.44.0.1" -DnsServer "1.1.1.1"
#>

param(
    [string]$StaticIP   = "",
    [string]$SubnetMask = "255.255.255.0",
    [string]$Gateway    = "10.44.0.1",
    [string]$DnsServer  = "8.8.8.8"
)

$ErrorActionPreference = "Stop"

Write-Host "=== OpenSandbox network setup ===" -ForegroundColor Cyan

# Helper: convert dotted subnet mask to prefix length
function ConvertTo-PrefixLength {
    param([string]$Mask)
    $octets = $Mask -split '\.'
    $bits = 0
    foreach ($octet in $octets) {
        $byte = [Convert]::ToInt32($octet)
        while ($byte -gt 0) {
            $bits += ($byte -band 1)
            $byte = $byte -shr 1
        }
    }
    return $bits
}

# Resolve first Ethernet adapter
Write-Host "[1/3] Resolving network adapter"
$adapter = Get-NetAdapter | Where-Object {
    $_.Status -eq "Up" -and $_.PhysicalMediaType -match "802\.3|Unspecified"
} | Select-Object -First 1

if ($null -eq $adapter) {
    # Fall back to any Up adapter
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
}

if ($null -eq $adapter) {
    throw "No active network adapter found. Cannot configure networking."
}

Write-Host "      Using adapter: $($adapter.Name) ($($adapter.InterfaceDescription))"
$ifIndex = $adapter.InterfaceIndex

if ($StaticIP -ne "") {
    # Static IP path
    $prefixLen = ConvertTo-PrefixLength -Mask $SubnetMask

    Write-Host "[2/3] Configuring static IP"
    Write-Host "      IP      : $StaticIP"
    Write-Host "      Prefix  : /$prefixLen ($SubnetMask)"
    Write-Host "      Gateway : $Gateway"
    Write-Host "      DNS     : $DnsServer"

    # Remove existing IP addresses and routes on this interface
    $existingAddrs = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($addr in $existingAddrs) {
        Remove-NetIPAddress -InputObject $addr -Confirm:$false -ErrorAction SilentlyContinue
    }

    $existingRoutes = Get-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($route in $existingRoutes) {
        Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Disable DHCP and set static address + gateway
    Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Disabled -ErrorAction SilentlyContinue

    New-NetIPAddress `
        -InterfaceIndex $ifIndex `
        -IPAddress $StaticIP `
        -PrefixLength $prefixLen `
        -DefaultGateway $Gateway | Out-Null

    # Set DNS server
    Set-DnsClientServerAddress `
        -InterfaceIndex $ifIndex `
        -ServerAddresses @($DnsServer)

    Write-Host "      Static IP applied."

} else {
    # DHCP path
    Write-Host "[2/3] No static IP requested — ensuring DHCP is active"

    $ipIface = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ipIface -and $ipIface.Dhcp -ne "Enabled") {
        Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Enabled
        # Remove any lingering static gateway
        Remove-NetRoute -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "      DHCP enabled on $($adapter.Name)."
    } else {
        Write-Host "      DHCP already enabled on $($adapter.Name)."
    }

    Write-Host ""
    Write-Host "      Current IP configuration:"
    Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Format-List IPAddress, PrefixLength, PrefixOrigin |
        Out-String | Write-Host
}

# Step 3: Connectivity check
Write-Host "[3/3] Testing connectivity to gateway: $Gateway"
$ping = Test-NetConnection -ComputerName $Gateway -WarningAction SilentlyContinue
if ($ping.PingSucceeded) {
    Write-Host "      Gateway reachable. RTT: $($ping.PingReplyDetails.RoundtripTime) ms" -ForegroundColor Green
} else {
    Write-Warning "Gateway $Gateway did not respond to ping."
    Write-Host "      The adapter may still be initialising. Check connectivity manually." -ForegroundColor Yellow
}

# Final summary
Write-Host ""
Write-Host "=== Network configuration summary ===" -ForegroundColor Green
$finalAddrs = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$finalDns   = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
$finalGw    = (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
               Select-Object -First 1).NextHop

Write-Host "  Adapter : $($adapter.Name) ($($adapter.InterfaceDescription))"
foreach ($addr in $finalAddrs) {
    Write-Host "  IP      : $($addr.IPAddress)/$($addr.PrefixLength) [$($addr.PrefixOrigin)]"
}
Write-Host "  Gateway : $(if ($finalGw) { $finalGw } else { '(none)' })"
Write-Host "  DNS     : $(if ($finalDns) { $finalDns -join ', ' } else { '(none)' })"
Write-Host "  Gateway reachable: $($ping.PingSucceeded)"
