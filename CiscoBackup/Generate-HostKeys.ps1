<#
powershell.exe -ExecutionPolicy Bypass -File "Generate-HostKeys.ps1"
    Generate-HostKeys.ps1
    -------------------------------------
    Parallel SSH host key discovery script
    with MITM-oriented comparison

    Compatible with:
      - PowerShell 5.1
      - Windows Server 2025
      - Fully offline mode
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve script root for both script-file and pasted execution
$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) {
    if ($PSCommandPath) {
        $ScriptRoot = Split-Path -Parent $PSCommandPath
    } elseif ($MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $ScriptRoot = (Get-Location).Path
    }
}
Set-Location  $ScriptRoot

$PlinkPath    = Join-Path $ScriptRoot "plink.exe"
$DevicesFile  = Join-Path $ScriptRoot "devices.txt"
$HostKeysFile = Join-Path $ScriptRoot "hostkeys.txt"

if (-not (Test-Path $PlinkPath))   { throw "Missing plink.exe (expected in $ScriptRoot)" }
if (-not (Test-Path $DevicesFile)) { throw "Missing devices.txt (expected in $ScriptRoot)" }

Write-Host "=== Parallel Auto HostKey Generator ===" -ForegroundColor Cyan

# ============================================================
# CREDENTIALS
# ============================================================
$Cred = Get-Credential -Message "Enter SSH credentials"
$Username = $Cred.UserName
$Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password)
)

# ============================================================
# LOAD DEVICES
# ============================================================
$Devices = Get-Content $DevicesFile |
    Where-Object { $_ -and $_.Trim() -notmatch '^(#|;)' } |
    ForEach-Object { $_.Trim() }

if ($Devices.Count -eq 0) { throw "devices.txt contains no valid entries." }

# ============================================================
# FINGERPRINT PARSER
# ============================================================
function Get-FingerprintFromText {
    param([string]$Text)

    # SHA256 (preferred)
    $sha = [regex]::Match($Text, "fingerprint\s+is\s+(SHA256:[A-Za-z0-9+/=]+)", "IgnoreCase")
    if ($sha.Success) { return $sha.Groups[1].Value }

    # Any SHA256 token
    $sha2 = [regex]::Match($Text, "(SHA256:[A-Za-z0-9+/=]+)")
    if ($sha2.Success) { return $sha2.Groups[1].Value }

    # Legacy MD5 hex colon format
    $md5 = [regex]::Match($Text, "([0-9a-f]{2}(?::[0-9a-f]{2}){15})", "IgnoreCase")
    if ($md5.Success) { return $md5.Groups[1].Value }

    return $null
}

# ============================================================
# WORKER (SCRIPTBLOCK EXECUTED IN PARALLEL)
# ============================================================
$ProbeScript = {
    param($Target,$PlinkPath,$Username,$Password)

    # Duplicate parser inside runspace to avoid scope issues
    function Get-FingerprintFromText {
        param([string]$Text)

        $sha = [regex]::Match($Text, "fingerprint\s+is\s+(SHA256:[A-Za-z0-9+/=]+)", "IgnoreCase")
        if ($sha.Success) { return $sha.Groups[1].Value }

        $sha2 = [regex]::Match($Text, "(SHA256:[A-Za-z0-9+/=]+)")
        if ($sha2.Success) { return $sha2.Groups[1].Value }

        $md5 = [regex]::Match($Text, "([0-9a-f]{2}(?::[0-9a-f]{2}){15})", "IgnoreCase")
        if ($md5.Success) { return $md5.Groups[1].Value }

        return $null
    }

    function Probe($Target,$PlinkPath,$Username,$Password) {
        try {
            # Attempt 1 — no credentials (host key is presented pre-auth)
            $args1 = @("-ssh","-v","-batch","-P","22",$Target,"exit")
            $out1 = & $PlinkPath @args1 2>&1
            $fp1 = Get-FingerprintFromText (($out1 | Out-String))
            if ($fp1) { return $fp1 }

            # Attempt 2 — with credentials (fallback)
            $args2 = @(
                "-ssh","-v","-batch","-noagent","-P","22",
                "-l",$Username,"-pw",$Password,
                $Target,"exit"
            )
            $out2 = & $PlinkPath @args2 2>&1
            $fp2 = Get-FingerprintFromText (($out2 | Out-String))
            return $fp2
        }
        catch {
            return $null
        }
    }

    $res = Probe -Target $Target -PlinkPath $PlinkPath -Username $Username -Password $Password
    return @{ Host = $Target; Fingerprint = $res }
}

# ============================================================
# SETUP RUNSPACE POOL
# ============================================================
$MaxThreads   = 10
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
$RunspacePool.Open()

$Jobs = @()
foreach ($dev in $Devices) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $RunspacePool
    $null = $ps.AddScript($ProbeScript).AddArgument($dev).AddArgument($PlinkPath).AddArgument($Username).AddArgument($Password)

    $Jobs += @{
        Pipe   = $ps
        Handle = $ps.BeginInvoke()
        Device = $dev
    }
}

# ============================================================
# PROGRESS BAR + RESULT COLLECTION
# ============================================================
$Total     = $Jobs.Count
$Completed = 0
$Output    = New-Object System.Collections.ArrayList

Write-Host ""
Write-Host "Probing $Total devices in parallel..." -ForegroundColor Cyan
Write-Host ""

foreach ($job in $Jobs) {
    $tmp = $job.Pipe.EndInvoke($job.Handle)
    $result = $tmp | Select-Object -First 1
    $job.Pipe.Dispose()

    $Completed++
    Write-Progress `
        -Activity "Discovering SSH Host Keys" `
        -Status    "Processing $($job.Device) ($Completed of $Total)" `
        -PercentComplete (($Completed / $Total) * 100)

    if ($result.Fingerprint) {
        Write-Host "  ✓ $($result.Host) → $($result.Fingerprint)" -ForegroundColor Green
        [void]$Output.Add("$($result.Host)    $($result.Fingerprint)")
    }
    else {
        Write-Host "  ✗ $($result.Host) → No fingerprint" -ForegroundColor Red
    }
}

Write-Progress -Activity "Discovering SSH Host Keys" -Completed

# ============================================================
# MITM DETECTION — HOSTKEYS.TXT (+ optional PuTTY cache)
# ============================================================
$OldMap = @{}
if (Test-Path $HostKeysFile) {
    foreach ($line in Get-Content $HostKeysFile) {
        if ($line -match '^(#|;)' -or -not $line.Trim()) { continue }
        $p = $line -split '\s+', 2
        if ($p.Count -eq 2) { $OldMap[$p[0]] = $p[1] }
    }
}

function Get-PuTTYStoredFingerprint {
    param([string]$Target)
    # Disabled to avoid false positives: PuTTY registry stores key blobs, not SHA256 strings
    return $null
}

$MITMReport = New-Object System.Collections.ArrayList

Write-Host ""
Write-Host "=== Comparing fingerprints with hostkeys.txt and PuTTY cache ===" -ForegroundColor Cyan

foreach ($entry in $Output) {
    $parts = $entry -split '\s+', 2
    $dev   = $parts[0]
    $newFP = $parts[1]

    $oldFP   = if ($OldMap.ContainsKey($dev)) { $OldMap[$dev] } else { $null }
    $puttyFP = Get-PuTTYStoredFingerprint -Target $dev  # currently always $null

    if (-not $newFP) {
        Write-Host "  → $dev : MISSING" -ForegroundColor Yellow
        [void]$MITMReport.Add("MISSING    $dev  NO-FINGERPRINT")
        continue
    }

    if ($oldFP) {
        if ($oldFP -eq $newFP) {
            Write-Host "  → $dev : UNCHANGED" -ForegroundColor Green
            [void]$MITMReport.Add("UNCHANGED  $dev  $newFP")
        }
        else {
            Write-Host "  → $dev : CHANGED (TXT mismatch)" -ForegroundColor Red
            [void]$MITMReport.Add("CHANGED    $dev  OLD-TXT=$oldFP  NEW=$newFP")
        }
        continue
    }

    Write-Host "  → $dev : ADDED" -ForegroundColor Cyan
    [void]$MITMReport.Add("ADDED      $dev  $newFP")
}

# Devices with no results
$Missing = $Devices | Where-Object { -not ($Output -match ("^{0}\s" -f [regex]::Escape($_))) }
foreach ($d in $Missing) {
    Write-Host "  → $d : MISSING" -ForegroundColor Yellow
    [void]$MITMReport.Add("MISSING    $d  NO-FINGERPRINT")
}

# Write MITM output
$ChangesFile = Join-Path $ScriptRoot "hostkeys-changes.txt"
$MITMReport | Out-File -FilePath $ChangesFile -Encoding UTF8 -Force

Write-Host ""
Write-Host "=== MITM comparison results written to ===" -ForegroundColor Cyan
Write-Host "   $ChangesFile"
Write-Host ""

# ============================================================
# WRITE UPDATED hostkeys.txt
# ============================================================
if ($Output.Count -gt 0) {
    $Output | Out-File -FilePath $HostKeysFile -Encoding UTF8 -Force
    Write-Host "Updated hostkeys.txt written."
}
else {
    Write-Host "No fingerprints gathered — hostkeys.txt NOT updated." -ForegroundColor Yellow
}

$RunspacePool.Close()
$RunspacePool.Dispose()

Write-Host ""
Write-Host "=== Completed ===" -ForegroundColor Green
Write-Host ""
