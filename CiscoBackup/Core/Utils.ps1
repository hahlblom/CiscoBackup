<#
    Utils.ps1
    ---------
    Shared utility functions for the CiscoBackup modular engine.

    All helpers here are:
      - PowerShell 5.1 compatible
      - 100% offline safe
      - non-interactive
      - dependency-free
#>

# ============================================================
# TIMESTAMP HELPERS
# ============================================================

function New-Timestamp {
    # Returns a compact timestamp for filenames/logging
    return (Get-Date).ToString("yyyyMMdd_HHmmss")
}

function New-TimeTag {
    # Returns a high-resolution tag for debug files
    return (Get-Date).ToString("HHmmssfff")
}

# ============================================================
# TEMP FILE (PS 5.1-safe)
# ============================================================

function New-SafeTempFile {
    # PowerShell 5.1 does NOT support New-TemporaryFile
    $file = [System.IO.Path]::GetTempFileName()
    if (-not $file) { throw "Failed to create temporary file." }
    return $file
}

# ============================================================
# PATH + FILENAME HELPERS
# ============================================================

function Join-SafePath {
    param(
        [Parameter(Mandatory=$true)][string]$Path1,
        [Parameter(Mandatory=$true)][string]$Path2
    )
    return (Join-Path $Path1 $Path2)
}

function Ensure-Folder {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# ============================================================
# LOGGING
# ============================================================

# Debug logging is optional and only active when $Global:DebugFolder is set.
# The loader / orchestrator will set this variable.

function Write-DebugFile {
    param(
        [string]$Prefix,
        [string[]]$Content
    )

    if (-not $Global:DebugFolder) { return }

    $tag = New-TimeTag
    $file = Join-Path $Global:DebugFolder ("{0}_{1}.log" -f $Prefix, $tag)

    try {
        $Content | Out-File -FilePath $file -Encoding UTF8 -Force
    }
    catch {
        # Debug logging must never interrupt execution
    }
}

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

# Records both human-readable error and debug log version
function Write-FormattedError {
    param(
        [string]$Context,
        [System.Exception]$Exception
    )

    $msg = "$Context : $($Exception.Message)"
    Write-Err $msg

    Write-DebugFile -Prefix "error" -Content @(
        "CONTEXT: $Context",
        "MESSAGE: $($Exception.Message)",
        "STACK: $($Exception.StackTrace)"
    )
}

# ============================================================
# PROCESS ARGUMENT QUOTING
# ============================================================

function Escape-Argument {
    param([string]$Text)

    # Wraps argument safely for plink/pscp (PS5.1-safe)
    if ($Text -match '\s') {
        return '"' + ($Text -replace '"', '\"') + '"'
    }
    return $Text
}

# ============================================================
# PROCESS RESULT OBJECT
# ============================================================

function New-ProcessResult {
    param(
        [int]$ExitCode,
        [string]$StdOut,
        [string]$StdErr,
        [bool]$Success
    )

    return [pscustomobject]@{
        ExitCode = $ExitCode
        StdOut   = $StdOut
        StdErr   = $StdErr
        Success  = $Success
    }
}

# ============================================================
# GENERAL TEXT HELPERS
# ============================================================

function Join-Text {
    param([string[]]$Lines)
    return ($Lines -join "`r`n")
}

function Contains-Text {
    param(
        [string]$Haystack,
        [string]$Needle
    )
    return ($Haystack -match [regex]::Escape($Needle))
}

function Strip-Null {
    # Removes null bytes that some Cisco devices output randomly
    param([string]$Text)
    return $Text -replace "`0",""
}

# ============================================================
# SUCCESS MARKERS
# ============================================================

function New-SuccessMarker {
    return "SUCCESS:" + (New-Guid).Guid
}

# Marker generator used by SCP / copy-commands to confirm success
# Example appended to remote output: "SUCCESS:<guid>"