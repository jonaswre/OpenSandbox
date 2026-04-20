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

$ErrorActionPreference = "Stop"

# Resolve execd binary path (default: C:\opensandbox\execd.exe)
$ExecdPath = if ($env:EXECD) { $env:EXECD } else { "C:\opensandbox\execd.exe" }

# Resolve env file path (default: C:\opensandbox\.env)
$ExecdEnvs = if ($env:EXECD_ENVS) { $env:EXECD_ENVS } else { "C:\opensandbox\.env" }

# Create env file directory and file if they do not already exist
$EnvDir = Split-Path -Parent $ExecdEnvs
if (-not (Test-Path $EnvDir)) {
    try {
        New-Item -ItemType Directory -Path $EnvDir -Force | Out-Null
    } catch {
        Write-Warning "failed to create dir for EXECD_ENVS=$ExecdEnvs : $_"
    }
}
if (-not (Test-Path $ExecdEnvs)) {
    try {
        New-Item -ItemType File -Path $ExecdEnvs -Force | Out-Null
    } catch {
        Write-Warning "failed to create EXECD_ENVS=$ExecdEnvs : $_"
    }
}
$env:EXECD_ENVS = $ExecdEnvs

# Start execd daemon as a background process
Write-Host "starting OpenSandbox Execd daemon at $ExecdPath."
$ExecdProc = Start-Process -FilePath $ExecdPath -PassThru -NoNewWindow

# Determine entrypoint command
# Priority: $env:BOOTSTRAP_CMD > -c <args> > positional args > wait for execd
$Cmd = ""
if ($env:BOOTSTRAP_CMD) {
    $Cmd = $env:BOOTSTRAP_CMD
} elseif ($args.Count -ge 2 -and $args[0] -eq "-c") {
    $Cmd = $args[1..($args.Count - 1)] -join " "
}

if ($Cmd -ne "") {
    # Run the command string via cmd /c to support chained shell commands
    & cmd.exe /c $Cmd
    exit $LASTEXITCODE
}

if ($args.Count -gt 0) {
    # Execute positional arguments as a command with its parameters
    & $args[0] $args[1..($args.Count - 1)]
    exit $LASTEXITCODE
}

# Default: keep the process alive by waiting for the execd process to exit
Write-Host "no entrypoint specified; waiting for execd (pid $($ExecdProc.Id)) to exit."
$ExecdProc.WaitForExit()
exit $ExecdProc.ExitCode
