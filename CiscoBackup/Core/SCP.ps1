<#
    SCP.ps1
    --------
    Handles:
      - Enabling SCP server on Cisco devices (IOS, IOS-XE, NX-OS, ASA, IOS-XR)
      - Downloading remote config files via pscp.exe
      - Integrating with Exec.ps1 and CopyCommands.ps1
      - Respecting autocommand "single-command" fallback
#>

# Requires:
#   Invoke-PlinkSmart        (Exec.ps1)
#   New-PscpArgsDownload     (Exec.ps1)
#   Get-PreferredFilesystems (Filesystems.ps1)
#   New-CopyCommands         (CopyCommands.ps1)
#   Write-Warn / Write-Info  (Utils.ps1)

# ============================================================
# ENABLE SCP SERVER PER OS
# ============================================================

function Enable-SCPServer {
    param(
        [Parameter(Mandatory=$true)][string]$PlinkPath,
        [Parameter(Mandatory=$true)][string]$TargetHost,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$Password,
        [Parameter(Mandatory=$true)][bool]$UseHostKey,
        [string]$HostKey,
        [Parameter(Mandatory=$true)][string]$OS,
        [int]$TimeoutSec = 45
    )

    # If this device is flagged for single-command fallback, skip SCP enabling.
    if ($Global:SessionMode.ContainsKey($TargetHost) -and $Global:SessionMode[$TargetHost] -eq 'Single') {
        Write-Warn "$TargetHost is in Single-Command mode - skipping SCP enabling"
        return
    }

    $commands = switch ($OS) {
        "NX-OS" {
            @(
                "configure terminal",
                "feature scp-server",
                "exit"
            )
        }
        "ASA" {
            @(
                "configure terminal",
                "ssh scopy enable",
                "exit"
            )
        }
        "IOS-XR" {
            @(
                "configure terminal",
                "ssh scp server enable",
                "commit",
                "end"
            )
        }
        "IOS-XE" {
            @(
                "configure terminal",
                "ip scp server enable",
                "end"
            )
        }
        "IOS" {
            @(
                "configure terminal",
                "ip scp server enable",
                "end"
            )
        }
        default {
            @(
                "configure terminal",
                "ip scp server enable",
                "end"
            )
        }
    }

    try {
        [void](Invoke-PlinkSmart `
            -PlinkPath $PlinkPath `
            -TargetHost $TargetHost `
            -Username $Username `
            -Password $Password `
            -UseHostKey:$UseHostKey `
            -HostKey $HostKey `
            -Commands $commands `
            -TimeoutSec $TimeoutSec
        )
    }
    catch {
        # Non-fatal: downstream copy may already work if SCP is enabled
        Write-DebugFile -Prefix "scp-enable" -Content @(
            "Failed to enable SCP server",
            "Device: $TargetHost",
            "OS: $OS",
            "Error: $($_.Exception.Message)"
        )
    }
}

# ============================================================
# PSCP DOWNLOAD
# ============================================================

function Download-RemoteFile {
    param(
        [Parameter(Mandatory=$true)][string]$PscpPath,
        [Parameter(Mandatory=$true)][string]$TargetHost,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$Password,
        [Parameter(Mandatory=$true)][bool]$UseHostKey,
        [string]$HostKey,
        [Parameter(Mandatory=$true)][string]$RemotePath,
        [Parameter(Mandatory=$true)][string]$LocalPath,
        [int]$TimeoutSec = 90
    )

    $pscpArgs = New-PscpArgsDownload `
        -TargetHost $TargetHost `
        -Username $Username `
        -Password $Password `
        -UseHostKey:$UseHostKey `
        -HostKey $HostKey `
        -RemotePath $RemotePath `
        -LocalPath $LocalPath

    $result = Invoke-ExternalProcess -Executable $PscpPath -Arguments $pscpArgs -TimeoutSec $TimeoutSec

    if (-not $result.Success) {
        throw "PSCP failed downloading '$RemotePath': $($result.StdErr)"
    }
}

# ============================================================
# EXPORT (COPY) REMOTE CONFIGS
# ============================================================

function Export-DeviceConfigs {
    param(
        [Parameter(Mandatory=$true)][string]$PlinkPath,
        [Parameter(Mandatory=$true)][string]$TargetHost,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$Password,
        [Parameter(Mandatory=$true)][bool]$UseHostKey,
        [string]$HostKey,
        [Parameter(Mandatory=$true)][string]$OS
    )

    $filesystems = Get-PreferredFilesystems -OS $OS

    foreach ($fs in $filesystems) {

        try {
            $cmds = New-CopyCommands -OS $OS -Filesystem $fs

            # Copy running-config
            $runResult = Invoke-PlinkSmart `
                -PlinkPath $PlinkPath `
                -TargetHost $TargetHost `
                -Username $Username `
                -Password $Password `
                -UseHostKey:$UseHostKey `
                -HostKey $HostKey `
                -Commands @($cmds.Running, $cmds.CheckRun) `
                -TimeoutSec 60

            if ($runResult.StdOut -notmatch [regex]::Escape($Global:RemoteRunFile)) {
                throw "Running-config not found on $fs"
            }

            # Copy startup-config
            $startResult = Invoke-PlinkSmart `
                -PlinkPath $PlinkPath `
                -TargetHost $TargetHost `
                -Username $Username `
                -Password $Password `
                -UseHostKey:$UseHostKey `
                -HostKey $HostKey `
                -Commands @($cmds.Startup, $cmds.CheckStart) `   # <-- correct
                -TimeoutSec 60

            if ($startResult.StdOut -notmatch [regex]::Escape($Global:RemoteStartFile)) {
                throw "Startup-config not found on $fs"
            }

            # Success return filesystem used
            return $fs
        }
        catch {
            Write-Warn "  Filesystem $($fs) failed on $($TargetHost): $($_.Exception.Message)"
        }
    }

    throw "Unable to export configs - all filesystems failed on $TargetHost"
}
