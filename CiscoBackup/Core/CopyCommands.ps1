<#
    CopyCommands.ps1
    -----------------
    Generates all remote copy + verification commands needed to:
      - Write running-config to a temporary file (non-interactive)
      - Write startup-config to a temporary file (non-interactive)
      - Check they exist on the chosen filesystem

    Modules that rely on this:
      - Export-DeviceConfigs (backup orchestrator)
      - SCP.ps1 (downloads the resulting temp files)
      - Cleanup.ps1 (removes remote files afterwards)
#>

# These names must match the values expected in other modules
# They are imported and shared globally.

if (-not (Get-Variable -Name 'RemoteRunFile' -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:RemoteRunFile = "running-config.tmp"
}
if (-not (Get-Variable -Name 'RemoteStartFile' -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:RemoteStartFile = "startup-config.tmp"
}


function New-CopyCommands {
    param(
        [Parameter(Mandatory=$true)][string]$OS,
        [Parameter(Mandatory=$true)][string]$Filesystem
    )

    #
    # Expected returned structure:
    #
    # @{
    #    Running    = "<cmd to export running-config non-interactively>"
    #    Startup    = "<cmd to export startup-config non-interactively>"
    #    CheckRun   = "<cmd to verify remote file exists>"
    #    CheckStart = "<cmd to verify startup file exists>"
    # }
    #
    # Each command is designed to be used with:
    #   Invoke-PlinkSmart  (Exec.ps1)
    #

    $remoteRunFile   = $Global:RemoteRunFile
    $remoteStartFile = $Global:RemoteStartFile

    $runRemote   = "${Filesystem}${remoteRunFile}"
    $startRemote = "${Filesystem}${remoteStartFile}"

    switch ($OS) {

        # ----------------------------------------------------------
        # IOS Classic (non-interactive via standalone redirect)
        #   Using "redirect <dest> <command>" so command does not
        #   start with "show" (avoids single-command no-more injection).
        # ----------------------------------------------------------
        "IOS" {
            return @{
                Running    = "redirect $runRemote show running-config"
                Startup    = "redirect $startRemote show startup-config"
                CheckRun   = "dir $Filesystem | include $remoteRunFile"
                CheckStart = "dir $Filesystem | include $remoteStartFile"
            }
        }

        # ----------------------------------------------------------
        # IOS-XE (same pattern as IOS)
        # ----------------------------------------------------------
        "IOS-XE" {
            return @{
                Running    = "redirect $runRemote show running-config"
                Startup    = "redirect $startRemote show startup-config"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }

        # ----------------------------------------------------------
        # NX-OS
        #   Use "show ... | no-more | redirect <dest>"
        #   Executes single-command normalization won't add another no-more
        #   because it's already present.
        # ----------------------------------------------------------
        "NX-OS" {
            return @{
                Running    = "show running-config | no-more | redirect $runRemote"
                Startup    = "show startup-config | no-more | redirect $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }

        # ----------------------------------------------------------
        # ASA
        #   Use copy with /noconfirm to avoid prompts.
        # ----------------------------------------------------------
        "ASA" {
            return @{
                Running    = "copy /noconfirm running-config $runRemote"
                Startup    = "copy /noconfirm startup-config $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }

        # ----------------------------------------------------------
        # IOS-XR
        #   Use "show ... | save <dest>" (non-interactive on XR).
        #   Note: XR's notion of startup-config may vary by version.
        # ----------------------------------------------------------
        "IOS-XR" {
            return @{
                Running    = "show running-config | save $runRemote"
                Startup    = "show startup-config | save $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }

        # ----------------------------------------------------------
        # Unknown: Best-effort generic "show | redirect"
        #   Safer than "copy ..." in batch mode (fewer prompts).
        # ----------------------------------------------------------
        default {
            return @{
                Running    = "show running-config | redirect $runRemote"
                Startup    = "show startup-config | redirect $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }
    }
}
