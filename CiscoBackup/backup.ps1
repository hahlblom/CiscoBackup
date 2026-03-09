<#
    backup.ps1
    -----------
    Main orchestrator for the modular CiscoBackup engine.

    Folder structure expected:

      CiscoBackup\
        backup.ps1
        modules.ps1
        devices.txt
        hostkeys.txt (optional)
        plink.exe
        pscp.exe
        core\
            Utils.ps1
            Exec.ps1
            HostKey.ps1
            OSDetect.ps1
            Filesystems.ps1
            CopyCommands.ps1
            SCP.ps1
            Cleanup.ps1
            Normalize.ps1
#>

[CmdletBinding()]
param(
    [switch]$SeedCache,
    [switch]$SeedUsePassword,
    [switch]$SeedForce,
#    [switch]$Debug,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# FOLDERS & PATHS
# ============================================================

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptRoot

$PlinkPath    = Join-Path $ScriptRoot "plink.exe"
$PscpPath     = Join-Path $ScriptRoot "pscp.exe"
$DevicesFile  = Join-Path $ScriptRoot "devices.txt"
$HostkeysFile = Join-Path $ScriptRoot "hostkeys.txt"

foreach ($req in @($PlinkPath, $PscpPath, $DevicesFile)) {
    if (-not (Test-Path $req)) { throw "Required file missing: $req" }
}

# Ensure HostKey probing can find plink.exe
$Global:PlinkPath = $PlinkPath

# ============================================================
# DEBUG MODE
# ============================================================

$Global:DebugFolder = $null
$DateTag = (Get-Date).ToString("yyMMdd")
$OutputFolder = Join-Path $ScriptRoot $DateTag

if ($PSBoundParameters['Debug'] -or $DebugPreference -eq 'Continue') {
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }
    $Global:DebugFolder = Join-Path $OutputFolder "_debug"
    New-Item -ItemType Directory -Path $Global:DebugFolder -Force | Out-Null

    Write-Host "Debug logging enabled. Logs written to: $Global:DebugFolder" -ForegroundColor Yellow
}

# ============================================================
# IMPORT MODULES
# ============================================================

. "$ScriptRoot\modules.ps1" -BasePath $ScriptRoot

# ============================================================
# INITIALIZE GLOBALS
# ============================================================

$Global:SessionMode  = @{}   # populated by OSDetect per device
$Global:HostKeyMap   = @{}   # populated by Import-HostKeyFile
$Global:RemoteRunFile   = ""  # populated by modules
$Global:RemoteStartFile = ""  # populated by modules

if (-not (Get-Variable -Name 'SessionMode' -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:SessionMode = @{}
}
if (-not (Get-Variable -Name 'HostKeyMap' -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:HostKeyMap = @{}
}
if (-not (Get-Variable -Name 'RemoteRunFile' -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:RemoteRunFile = ""
}
if (-not (Get-Variable -Name 'RemoteStartFile' -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:RemoteStartFile = ""
}

# ============================================================
# CREDENTIALS
# ============================================================

$cred = Get-Credential -Message "Enter SSH/SCP credentials"
if (-not $cred) {
    Write-Err "Credentials were not provided. Aborting."
    return
}
$Global:Username = $cred.UserName
$Global:Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
)

# ============================================================
# LOAD HOSTKEY MAP
# ============================================================

Import-HostKeyFile -FilePath $HostkeysFile

# ============================================================
# LOAD DEVICES
# ============================================================

$DeviceList = Get-Content $DevicesFile |
    Where-Object { $_ -and $_.Trim() -notmatch '^(#|;)' } |
    ForEach-Object { $_.Trim() }

if (-not $DeviceList -or $DeviceList.Count -eq 0) {
    Write-Warn "No devices found in devices.txt. Nothing to do."
    return
}

# ============================================================
# SEED MODE
# ============================================================

if ($SeedCache) {
    $seedParams = @{
        Targets     = $DeviceList
        UsePassword = $SeedUsePassword
        Force       = $SeedForce
    }
    Seed-PuTTYHostKeyCache @seedParams
    return
}

# ============================================================
# DRY RUN MODE
# ============================================================

if ($DryRun) {
    Write-Info "=== DRY RUN MODE ==="
    Write-Warn "No SCP operations or config copies will be performed."

    foreach ($dev in $DeviceList) {
        Write-Info "Testing $dev ..."

        try {
            # Host key resolution
            if (Test-PuTTYCacheHasKey -TargetHost $dev) {
                $hk = "Test"
                Write-Info "Host key from PuTTY cache"
            }
            elseif ($Global:HostKeyMap.ContainsKey($dev)) {
                $hk = $Global:HostKeyMap[$dev]
                Write-Info "Host key from hostkeys.txt"
            }
            else {
                $hk = Resolve-HostKey -TargetHost $dev
                Write-Info "Host key discovered"
            }

            # OS detection
            $osParams = @{
                PlinkPath = $PlinkPath
                TargetHost = $dev
                Username = $Global:Username
                Password = $Global:Password
                UseHostKey = ([string]::IsNullOrWhiteSpace($hk) -eq $false)
                HostKey = $hk
            }
            $os = Get-DeviceOS @osParams

            Write-Info "OS Detected: $os"

            if ($Global:SessionMode.ContainsKey($dev) -and $Global:SessionMode[$dev] -eq 'Single') {
                Write-Warn "Autocommand detected - device in Single-Command mode"
                }
        }
         catch {
            Write-Err "ERROR: $($_.Exception.Message)"
        }

        Write-Host "A"
    }

    Write-Warn "Dry run complete. No changes performed."
    return
}

# ============================================================
# NORMAL BACKUP MODE
# ============================================================

Ensure-Folder $OutputFolder

$Results = New-Object System.Collections.ArrayList

foreach ($dev in $DeviceList) {

    $record = [ordered]@{
        Device  = $dev
        OS      = "Unknown"
        HostKey = ""
        Success = $false
        Message = ""
        Running = ""
        Startup = ""
    }

    Write-Info "=== Processing $dev ==="

    try {
        # Host key resolution
        if (Test-PuTTYCacheHasKey -TargetHost $dev) {
            $hk = ""
        }
        elseif ($Global:HostKeyMap.ContainsKey($dev)) {
            $hk = $Global:HostKeyMap[$dev]
        }
        else {
            $hk = Resolve-HostKey -TargetHost $dev
        }

        $record.HostKey = $hk

        # OS detection
        $osParams = @{
            PlinkPath = $PlinkPath
            TargetHost = $dev
            Username = $Global:Username
            Password = $Global:Password
            UseHostKey = ([string]::IsNullOrWhiteSpace($hk) -eq $false)
            HostKey = $hk
        }
        $os = Get-DeviceOS @osParams
        $record.OS = $os

        if ($os -eq "Unknown") {
            throw "Unable to determine OS"
        }

        # SCP enable
        $scpParams = @{
            PlinkPath = $PlinkPath
            TargetHost = $dev
            Username = $Global:Username
            Password = $Global:Password
            UseHostKey = ([string]::IsNullOrWhiteSpace($hk) -eq $false)
            HostKey = $hk
            OS = $os
        }
        Enable-SCPServer @scpParams

        # Copy remote configs
        $exportParams = @{
            PlinkPath = $PlinkPath
            TargetHost = $dev
            Username = $Global:Username
            Password = $Global:Password
            UseHostKey = ([string]::IsNullOrWhiteSpace($hk) -eq $false)
            HostKey = $hk
            OS = $os
        }
        $filesystem = Export-DeviceConfigs @exportParams

        # Temporary local paths
        $tmpRun   = Join-Path $OutputFolder ("{0}_running.tmp" -f $dev)
        $tmpStart = Join-Path $OutputFolder ("{0}_startup.tmp" -f $dev)

        # Download remote files
        $dlRunParams = @{
            PscpPath   = $PscpPath
            TargetHost = $dev
            Username   = $Global:Username
            Password   = $Global:Password
            UseHostKey = ([string]::IsNullOrWhiteSpace($hk) -eq $false)
            HostKey    = $hk
            RemotePath = "{0}{1}" -f $filesystem, $Global:RemoteRunFile
            LocalPath  = $tmpRun
        }
        Download-RemoteFile @dlRunParams

        $dlStartParams = @{
            PscpPath   = $PscpPath
            TargetHost = $dev
            Username   = $Global:Username
            Password   = $Global:Password
            UseHostKey = ([string]::IsNullOrWhiteSpace($hk) -eq $false)
            HostKey    = $hk
            RemotePath = "{0}{1}" -f $filesystem, $Global:RemoteStartFile
            LocalPath  = $tmpStart
        }
        Download-RemoteFile @dlStartParams

        # Finalize output names
        $finalParams = @{
            TempRunPath   = $tmpRun
            TempStartPath = $tmpStart
            OutputFolder  = $OutputFolder
            DeviceLabel   = $dev
        }
        $final = Finalize-ConfigFiles @finalParams

        $record.Running = $final.Running
        $record.Startup = $final.Startup
        $record.Success = $true

        # Cleanup remote temp files
        $cleanupParams = @{
            PlinkPath  = $PlinkPath
            TargetHost = $dev
            Username   = $Global:Username
            Password   = $Global:Password
            UseHostKey = ([string]::IsNullOrWhiteSpace($hk) -eq $false)
            HostKey    = $hk
            OS         = $os
            Filesystem = $filesystem
        }
        Cleanup-RemoteFiles @cleanupParams
    }
    catch {
        $record.Message = $_.Exception.Message

        # Cleanup any partial temp files
        Remove-Item (Join-Path $OutputFolder ("{0}_running.tmp" -f $dev)) -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $OutputFolder ("{0}_startup.tmp" -f $dev)) -ErrorAction SilentlyContinue

        Write-Err ("ERROR: {0}" -f $record.Message)
    }

    [void]$Results.Add([pscustomobject]$record)
    Write-Host ""
}

# ============================================================
# SUMMARY REPORT
# ============================================================

$SuccessCount = @($Results | Where-Object { $_.Success }).Count
$FailCount    = @($Results | Where-Object { -not $_.Success }).Count
$Total        = $Results.Count

$SummaryFile = Join-Path $OutputFolder "summary.txt"

$lines = @()
$lines += "Cisco Backup Summary Report"
$lines += ("Timestamp     : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$lines += ("Output folder : {0}" -f $OutputFolder)
$lines += ""
$lines += ("Total devices : {0}" -f $Total)
$lines += ("Successful    : {0}" -f $SuccessCount)
$lines += ("Failed        : {0}" -f $FailCount)
$lines += ""
$lines += "Results:"
$lines += "------------------------------------------"

foreach ($r in $Results) {
    if ($r.Success) {
        $runningLeaf = Split-Path $r.Running -Leaf
        $startupLeaf = Split-Path $r.Startup -Leaf
        $lines += ("SUCCESS - {0} [{1}] -> {2}, {3}" -f $r.Device, $r.OS, $runningLeaf, $startupLeaf)
    }
    else {
        $suffix = ""
        if ($Global:SessionMode.ContainsKey($r.Device) -and $Global:SessionMode[$r.Device] -eq 'Single') {
            $suffix = " (single-cmd mode)"
        }
        $lines += ("FAILED  - {0} [{1}] -> {2}{3}" -f $r.Device, $r.OS, $r.Message, $suffix)
    }
}

$lines | Out-File -FilePath $SummaryFile -Encoding UTF8 -Force

Write-Host "============================================" -ForegroundColor Yellow
Write-Host " Backup Complete" -ForegroundColor Yellow
Write-Host (" Total      : {0}" -f $Total)
Write-Host (" Success    : {0}" -f $SuccessCount)
Write-Host (" Failures   : {0}" -f $FailCount)
Write-Host (" Summary    : {0}" -f $SummaryFile)
Write-Host "============================================" -ForegroundColor Yellow
