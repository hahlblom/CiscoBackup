<#
    HostKey.ps1
    ------------
    Handles all host-key acquisition methods:

      1. PuTTY registry cache (preferred)
      2. hostkeys.txt mapping (offline override)
      3. Live probing via plink -v
      4. Seeding mode for manual cache population

    Requirements:
      - plink.exe must be present in script root
      - Utils.ps1 must be loaded before this file
#>

# ============================================================
# GLOBAL STATE
# ============================================================

# Host key map loaded from hostkeys.txt
if (-not (Get-Variable -Name 'HostKeyMap' -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:HostKeyMap = @{}
}


# ============================================================
# LOAD hostkeys.txt (key-value mapping)
# ============================================================

function Import-HostKeyFile {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) { return }

    foreach ($line in Get-Content $FilePath) {
        if (-not $line.Trim()) { continue }
        if ($line -match '^(#|;)') { continue }

        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2) {
            $Global:HostKeyMap[$parts[0]] = $parts[1]
        }
    }
}

# ============================================================
# PUTTY REGISTRY CHECK
# ============================================================

function Test-PuTTYCacheHasKey {
    param([string]$TargetHost)

    $keyPath = 'HKCU:\Software\SimonTatham\PuTTY\SshHostKeys'

    try {
        if (-not (Test-Path $keyPath)) { return $false }

        $algPrefixes = @(
            'ssh-ed25519',
            'ecdsa-sha2-nistp256',
            'ecdsa-sha2-nistp384',
            'ecdsa-sha2-nistp521',
            'rsa2'
        )

        $item = Get-Item $keyPath
        $names = $item.Property

        foreach ($alg in $algPrefixes) {
            $name = "$alg@22:$TargetHost"
            if ($names -contains $name) { return $true }
        }

        return $false
    }
    catch {
        return $false
    }
}

# ============================================================
# LIVE HOST-KEY PROBE (plink -v)
# ============================================================

function Parse-HostKeyFingerprint {
    param([string]$Text)

    # Prefer SHA256 fingerprints
    $sha = [regex]::Match($Text, "fingerprint\s+is\s+(SHA256:[A-Za-z0-9+/=]+)", 'IgnoreCase')
    if ($sha.Success) { return $sha.Groups[1].Value }

    # Fallback - any SHA256 token
    $sha2 = [regex]::Match($Text, "(SHA256:[A-Za-z0-9+/=]+)")
    if ($sha2.Success) { return $sha2.Groups[1].Value }

    # Legacy MD5
    $md5 = [regex]::Match($Text, "([0-9a-f]{2}(?::[0-9a-f]{2}){15})", 'IgnoreCase')
    if ($md5.Success) { return $md5.Groups[1].Value }

    return $null
}

function Probe-HostKey {
    param(
        [string]$TargetHost,
        [int]$TimeoutSec = 45
    )

    # --- Attempt 1: minimal (no credentials)
    $args1 = @("-ssh","-v","-batch","-P","22",$TargetHost,"exit")

    try {
        $probe1 = Invoke-ExternalProcess -Executable $Global:PlinkPath -Arguments $args1 -TimeoutSec $TimeoutSec
        $fp1 = Parse-HostKeyFingerprint -Text ($probe1.StdErr + "`n" + $probe1.StdOut)
        if ($fp1) { return $fp1 }
    }
    catch {
        # ignore - fall through
    }

    # --- Attempt 2: with credentials
    $args2 = @(
        "-ssh","-v","-batch","-noagent","-P","22",
        "-l",$Global:Username,
        "-pw",$Global:Password,
        $TargetHost,"exit"
    )

    $probe2 = Invoke-ExternalProcess -Executable $Global:PlinkPath -Arguments $args2 -TimeoutSec $TimeoutSec
    $fp2 = Parse-HostKeyFingerprint -Text ($probe2.StdErr + "`n" + $probe2.StdOut)

    if ($fp2) { return $fp2 }

    throw "Unable to extract SSH host key fingerprint for $TargetHost"
}

# ============================================================
# MAIN RESOLVER: RETURNS BEST AVAILABLE HOST KEY
# ============================================================

function Resolve-HostKey {
    param(
        [string]$TargetHost,
        [switch]$ForceProbe
    )

    # 1. Registry cache (best)
    if (-not $ForceProbe) {
        if (Test-PuTTYCacheHasKey -TargetHost $TargetHost) {
            return ""
        }
    }

    # 2. hostkeys.txt
    if (-not $ForceProbe) {
        if ($Global:HostKeyMap.ContainsKey($TargetHost)) {
            return $Global:HostKeyMap[$TargetHost]
        }
    }

    # 3. Live probe
    return Probe-HostKey -TargetHost $TargetHost
}

# ============================================================
# HOST-KEY SEEDING MODE (manual acceptance)
# ============================================================

function Seed-PuTTYHostKeyCache {
    param(
        [string[]]$Targets,
        [switch]$UsePassword,
        [switch]$Force
    )
    Write-Info "=== PuTTY Host-Key Cache Seeding ==="
    foreach ($t in $Targets) {
        if (-not $Force) {
            if (Test-PuTTYCacheHasKey -TargetHost $t) {
                Write-Warn "  * $t : already present (skipped)"
                continue
            }
        }
        $plinkArgs = @("-ssh", "-P", "22", "-l", $Global:Username)
        if ($UsePassword) {
            $plinkArgs += @("-pw", $Global:Password)
        }
        $plinkArgs += @($t, "exit")
        Write-Warn "Seeding $t - accept host key manually when prompted..."
        & $Global:PlinkPath @plinkArgs
        Write-Info "  (Returned from $t)"
    }
    Write-Info "Seeding complete."
}