<#
    Normalize.ps1
    --------------
    Hostname extraction, filename sanitization, and final output
    file movement for CiscoBackup modular system.

    Responsibilities:
      - Read hostname from downloaded config (running or startup)
      - Fallback to device label if hostname not found
      - Replace invalid filename characters
      - Move temp files into final paths
#>

# Utils.ps1 required:
#   Write-Warn, Write-Info

# ============================================================
# EXTRACT HOSTNAME FROM CONFIG FILE
# ============================================================

function Get-HostnameFromConfig {
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath
    )

    if (-not (Test-Path $ConfigPath)) {
        return $null
    }

    # Read all lines (ASCII-safe)
    $lines = Get-Content -Path $ConfigPath -ErrorAction SilentlyContinue
    if (-not $lines) { return $null }

    foreach ($line in $lines) {
        $trim = $line.Trim()

        # IOS / XE / NX-OS
        if ($trim -match '^hostname\s+(.+)$') {
            return $Matches[1].Trim()
        }

        # Some NX-OS / older IOS variant
        if ($trim -match '^switchname\s+(.+)$') {
           return $Matches[1].Trim()
        }

        # ASA and others sometimes use "hostname <name>" as well
        # fallback already captured above

        # IOS-XR often uses "hostname <router-name>"
        if ($trim -match '^sysname\s+(.+)$') {
            return $Matches[1].Trim()
        }
    }

    return $null
}

# ============================================================
# SANITIZE HOSTNAME FOR FILENAME SAFETY
# ============================================================

function Sanitize-Hostname {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "_" }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($c in $invalid) {
        $Name = $Name.Replace($c, "_")
    }
    $Name = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($Name)) { return "_" }
    return $Name
}

# ============================================================
# FINALIZE FILES
# ============================================================

function Finalize-ConfigFiles {
    param(
        [Parameter(Mandatory=$true)][string]$TempRunPath,
        [Parameter(Mandatory=$true)][string]$TempStartPath,
        [Parameter(Mandatory=$true)][string]$OutputFolder,
        [Parameter(Mandatory=$true)][string]$DeviceLabel
    )

    #
    # 1. Extract hostname from running-config, then startup-config, else fallback
    #

    $hostname = Get-HostnameFromConfig -ConfigPath $TempRunPath

    if (-not $hostname) {
        $hostname = Get-HostnameFromConfig -ConfigPath $TempStartPath
    }

    if (-not $hostname) {
        $hostname = $DeviceLabel
    }

    $hostname = Sanitize-Hostname -Name $hostname

    #
    # 2. Establish final target filenames
    #

    $finalRun   = Join-Path $OutputFolder ("{0}-running.conf" -f $hostname)
    $finalStart = Join-Path $OutputFolder ("{0}-startup.conf" -f $hostname)

    if (Test-Path $finalRun) {
       $finalRun   = Join-Path $OutputFolder ("{0}_{1}-running.conf" -f $hostname, $DeviceLabel)
        $finalStart = Join-Path $OutputFolder ("{0}_{1}-startup.conf" -f $hostname, $DeviceLabel)
        Write-Warn "Hostname collision for '$hostname' - using device label suffix for $DeviceLabel"
    }

    #
    # 3. Move temporary files to their final names
    #

    try {
        Move-Item -Path $TempRunPath -Destination $finalRun -Force
        Move-Item -Path $TempStartPath -Destination $finalStart -Force
    }
    catch {
        throw "Failed to finalize config files for $($DeviceLabel): $($_.Exception.Message)"
    }

    return @{
        Hostname = $hostname
        Running  = $finalRun
        Startup  = $finalStart
    }
}