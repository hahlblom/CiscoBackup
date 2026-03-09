<#
    Exec.ps1
    --------
    Execution engine for plink.exe and pscp.exe

    Responsibilities:
      - unified external process execution
      - timeout handling
      - debug logging
      - plink/pscp argument generation
      - multi-command vs single-command mode
#>

# Requires Utils.ps1 (loaded by modules.ps1)

# Global session-mode map: Multi = normal, Single = autocommand fallback
if (-not $Global:SessionMode) {
    $Global:SessionMode = @{}
}

# ============================================================
# EXTERNAL PROCESS RUNNER
# ============================================================

function Invoke-ExternalProcess {
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [int]$TimeoutSec = 30
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $quotedArgs = $Arguments | ForEach-Object { Escape-Argument $_ }
    $psi.Arguments = ($quotedArgs -join " ")
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        $null = $proc.Start()
    }
    catch {
        throw "Failed to start process '$Executable': $($_.Exception.Message)"
    }

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        throw "Process '$Executable' timed out after $TimeoutSec seconds."
    }

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()

    # Debug logging
    Write-DebugFile -Prefix ([System.IO.Path]::GetFileNameWithoutExtension($Executable)) -Content @(
        "EXE: $Executable",
        "ARGS: $($quotedArgs -join ' ')",
        "EXIT: $($proc.ExitCode)",
        "----- STDERR -----",
        $stderr,
        "----- STDOUT -----",
        $stdout
    )

    return New-ProcessResult -ExitCode $proc.ExitCode -StdOut (Strip-Null $stdout) -StdErr (Strip-Null $stderr) -Success ($proc.ExitCode -eq 0)
}

# ============================================================
# PLINK ARGUMENT GENERATORS
# ============================================================

function New-PlinkArgsBase {
    param(
        [string]$Username,
        [string]$Password,
        [switch]$UseHostKey,
        [string]$HostKey
    )

    $args = @(
        "-ssh",
        "-batch",
        "-noagent",
        "-P","22",
        "-l", $Username,
        "-pw", $Password
    )

    if ($UseHostKey -and $HostKey) {
        $args += @("-hostkey", $HostKey)
    }

    return $args
}

function New-PlinkArgsSingle {
    param(
        [string]$TargetHost,
        [string]$Username,
        [string]$Password,
        [bool]$UseHostKey,
        [string]$HostKey,
        [string]$Command
    )

    $args = New-PlinkArgsBase -Username $Username -Password $Password -UseHostKey:$UseHostKey -HostKey $HostKey
    $args += @($TargetHost, $Command)
    return $args
}

function New-PlinkArgsMulti {
    param(
        [string]$TargetHost,
        [string]$Username,
        [string]$Password,
        [bool]$UseHostKey,
        [string]$HostKey,
        [string]$CommandFile
    )

    $args = New-PlinkArgsBase -Username $Username -Password $Password -UseHostKey:$UseHostKey -HostKey $HostKey
    $args += @($TargetHost, "-m", $CommandFile)
    return $args
}

# ============================================================
# PSCP ARGUMENT GENERATOR
# ============================================================

function New-PscpArgsDownload {
    param(
        [string]$TargetHost,
        [string]$Username,
        [string]$Password,
        [bool]$UseHostKey,
        [string]$HostKey,
        [string]$RemotePath,
        [string]$LocalPath
    )

    $args = @(
        "-scp",
        "-batch",
        "-P","22",
        "-l", $Username,
        "-pw", $Password
    )

    if ($UseHostKey -and $HostKey) {
        $args += @("-hostkey", $HostKey)
    }

    # Important: no extra quotes, pscp handles paths natively
    $args += @("${TargetHost}:$RemotePath", $LocalPath)

    return $args
}

# ============================================================
# AUTOCOMMAND ERROR DETECTION
# ============================================================

$Global:AutoCommandPatterns = @(
    "Line has invalid autocommand",
    "unexpectedly closed network connection",
    "Cannot answer interactive prompts in batch mode"
)

function Test-AutoCommandFailure {
    param([string]$Text)

    foreach ($p in $Global:AutoCommandPatterns) {
        if ($Text -match $p) { return $true }
    }
    return $false
}

# ============================================================
# PLINK EXECUTION: MULTI-COMMAND MODE
# ============================================================

function Invoke-PlinkMultiCommand {
    param(
        [string]$PlinkPath,
        [string]$TargetHost,
        [string]$Username,
        [string]$Password,
        [bool]$UseHostKey,
        [string]$HostKey,
        [string[]]$Commands,
        [int]$TimeoutSec
    )

    $cmdFile = New-SafeTempFile

    try {
        # Exec-mode commands for all Cisco platforms
        "terminal length 0"  | Out-File -FilePath $cmdFile -Encoding ASCII
        "terminal pager 0"   | Out-File -FilePath $cmdFile -Encoding ASCII -Append

        foreach ($cmd in $Commands) {
            $cmd | Out-File -FilePath $cmdFile -Encoding ASCII -Append
        }

        "exit" | Out-File -FilePath $cmdFile -Encoding ASCII -Append

        $args = New-PlinkArgsMulti -TargetHost $TargetHost -Username $Username -Password $Password `
            -UseHostKey:$UseHostKey -HostKey $HostKey -CommandFile $cmdFile

        return Invoke-ExternalProcess -Executable $PlinkPath -Arguments $args -TimeoutSec $TimeoutSec
    }
    finally {
        Remove-Item $cmdFile -ErrorAction SilentlyContinue
    }
}

# ============================================================
# PLINK EXECUTION: SINGLE-COMMAND MODE
# ============================================================

function Normalize-ShowCmd {
    param([string]$Command)

    # Applies '| no-more' for show commands
    if ($Command -match '^\s*show\s+' -and $Command -notmatch '\|\s*no-more') {
        return "$Command | no-more"
    }
    return $Command
}

function Invoke-PlinkSingleCommand {
    param(
        [string]$PlinkPath,
        [string]$TargetHost,
        [string]$Username,
        [string]$Password,
        [bool]$UseHostKey,
        [string]$HostKey,
        [string]$Command,
        [int]$TimeoutSec
    )

    $cmd = Normalize-ShowCmd -Command $Command

    $args = New-PlinkArgsSingle -TargetHost $TargetHost -Username $Username -Password $Password `
        -UseHostKey:$UseHostKey -HostKey $HostKey -Command $cmd

    return Invoke-ExternalProcess -Executable $PlinkPath -Arguments $args -TimeoutSec $TimeoutSec
}

# ============================================================
# SMART EXECUTION WRAPPER
# ============================================================

function Invoke-PlinkSmart {
    param(
        [string]$PlinkPath,
        [string]$TargetHost,
        [string]$Username,
        [string]$Password,
        [bool]$UseHostKey,
        [string]$HostKey,
        [string[]]$Commands,
        [int]$TimeoutSec
    )

    # If already tagged as single-command, skip multi-attempt
    if ($Global:SessionMode.ContainsKey($TargetHost) -and $Global:SessionMode[$TargetHost] -eq 'Single') {

        $out = New-Object System.Text.StringBuilder
        $err = New-Object System.Text.StringBuilder
        $exit = 0

        foreach ($cmd in $Commands) {
            $r = Invoke-PlinkSingleCommand -PlinkPath $PlinkPath -TargetHost $TargetHost `
                -Username $Username -Password $Password -UseHostKey:$UseHostKey -HostKey $HostKey `
                -Command $cmd -TimeoutSec $TimeoutSec

            if ($r.ExitCode -ne 0) { $exit = $r.ExitCode }
            [void]$out.AppendLine($r.StdOut)
            [void]$err.AppendLine($r.StdErr)

            if ($r.ExitCode -ne 0) { break }
        }

        return New-ProcessResult -ExitCode $exit -StdOut $out.ToString() -StdErr $err.ToString() -Success ($exit -eq 0)
    }

    # Attempt multi-command first
    $multi = Invoke-PlinkMultiCommand -PlinkPath $PlinkPath -TargetHost $TargetHost `
        -Username $Username -Password $Password -UseHostKey:$UseHostKey -HostKey $HostKey `
        -Commands $Commands -TimeoutSec $TimeoutSec

    if ($multi.Success) { return $multi }

    # If autocommand detected, fallback permanently to single-command
    if (Test-AutoCommandFailure -Text ($multi.StdErr + "`n" + $multi.StdOut)) {
        $Global:SessionMode[$TargetHost] = 'Single'

        $out = New-Object System.Text.StringBuilder
        $err = New-Object System.Text.StringBuilder
        $exit = 0

        foreach ($cmd in $Commands) {
            $r = Invoke-PlinkSingleCommand -PlinkPath $PlinkPath -TargetHost $TargetHost `
                -Username $Username -Password $Password -UseHostKey:$UseHostKey -HostKey $HostKey `
                -Command $cmd -TimeoutSec $TimeoutSec

            if ($r.ExitCode -ne 0) { $exit = $r.ExitCode }
            [void]$out.AppendLine($r.StdOut)
            [void]$err.AppendLine($r.StdErr)

            if ($r.ExitCode -ne 0) { break }
        }

        return New-ProcessResult -ExitCode $exit -StdOut $out.ToString() -StdErr $err.ToString() -Success ($exit -eq 0)
    }

    # Otherwise return the multi-failure
    return $multi
}