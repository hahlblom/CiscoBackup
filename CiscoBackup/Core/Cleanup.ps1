<#
    Cleanup.ps1
    ------------
    Handles cleanup of temporary configuration files created on devices
    after they have been exported and downloaded.

    Responsibilities:
      - OS-specific deletion commands
      - Silent failure (cleanup must never interrupt a backup)
      - Uses Exec.ps1 (Invoke-PlinkSmart)
#>

# Requires:
#   Invoke-PlinkSmart   (Exec.ps1)
#   Write-DebugFile     (Utils.ps1)
#   $Global:RemoteRunFile, $Global:RemoteStartFile  (CopyCommands.ps1)

function New-DeleteCommands {
    param(
        [Parameter(Mandatory=$true)][string]$OS,
        [Parameter(Mandatory=$true)][string]$Filesystem
    )

    # Build absolute paths:
    $remoteRunFile   = $Global:RemoteRunFile
    $remoteStartFile = $Global:RemoteStartFile

    $runPath   = "${Filesystem}${remoteRunFile}"
    $startPath = "${Filesystem}${remoteStartFile}"

    switch ($OS) {

        "ASA" {
            # ASA uses /noconfirm
            return @(
                "delete /noconfirm $runPath",
                "delete /noconfirm $startPath"
            )
        }

        "NX-OS" {
            # NX-OS uses 'no-confirm'
            return @(
                "delete $runPath no-confirm",
                "delete $startPath no-confirm"
            )
        }

        "IOS-XR" {
            # IOS-XR often prompts unless special flags are available
            # Keep original behavior (best-effort), rely on silent failure
            return @(
                "delete $runPath",
                "delete $startPath"
            )
        }

        # IOS, IOS-XE, fallback
        default {
            # IOS accepts /force to skip confirmation
            return @(
                "delete /force $runPath",
                "delete /force $startPath"
            )
        }
    }
}

function Cleanup-RemoteFiles {
    param(
        [Parameter(Mandatory=$true)][string]$PlinkPath,
        [Parameter(Mandatory=$true)][string]$TargetHost,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$Password,
        [Parameter(Mandatory=$true)][bool]$UseHostKey,
        [string]$HostKey,
        [Parameter(Mandatory=$true)][string]$OS,
        [Parameter(Mandatory=$true)][string]$Filesystem
    )

    $deleteCmds = New-DeleteCommands -OS $OS -Filesystem $Filesystem

    try {
        [void](Invoke-PlinkSmart `
            -PlinkPath $PlinkPath `
            -TargetHost $TargetHost `
            -Username $Username `
            -Password $Password `
            -UseHostKey:$UseHostKey `
            -HostKey $HostKey `
            -Commands $deleteCmds `
            -TimeoutSec 45
        )
    }
    catch {
        Write-DebugFile -Prefix "cleanup" -Content @(
            "Cleanup failed",
            "Device: $($TargetHost)",
            "OS: $($OS)",
            "Filesystem: $($Filesystem)",
            "Error: $($_.Exception.Message)"
        )
    }
}
