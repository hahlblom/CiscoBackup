<#
    CopyCommands.ps1
    -----------------
    Generates all remote copy + verification commands needed to:
      - Copy running-config to a temporary file
      - Copy startup-config to a temporary file
      - Check they exist on the chosen filesystem

    Modules that rely on this:
      - Export-DeviceConfigs (backup orchestrator)
      - SCP.ps1 (downloads the resulting temp files)
      - Cleanup.ps1 (removes remote files afterwards)
#>

# These names must match the values expected in other modules
# They are imported and shared globally.

if (-not $Global:RemoteRunFile)   { $Global:RemoteRunFile   = "running-config.tmp" }
if (-not $Global:RemoteStartFile) { $Global:RemoteStartFile = "startup-config.tmp" }


function New-CopyCommands {
    param(
        [Parameter(Mandatory=$true)][string]$OS,
        [Parameter(Mandatory=$true)][string]$Filesystem
    )

    #
    # Expected returned structure:
    #
    # @{
    #    Running    = "<cmd to copy running-config>"
    #    Startup    = "<cmd to copy startup-config>"
    #    CheckRun   = "<cmd to verify remote file exists>"
    #    CheckStart = "<cmd to verify startup file exists>"
    # }
    #
    # Each command is designed to be used with:
    #   Invoke-PlinkSmart  (Exec.ps1)
    #

    $runRemote   = "${Filesystem}${Global:RemoteRunFile}"
    $startRemote = "${Filesystem}${Global:RemoteStartFile}"

    switch ($OS) {

        # ----------------------------------------------------------
        # IOS Classic
        # ----------------------------------------------------------
        "IOS" {
            return @{
                Running    = "copy running-config $runRemote"
                Startup    = "copy startup-config $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }

        # ----------------------------------------------------------
        # IOS-XE
        # ----------------------------------------------------------
        "IOS-XE" {
            return @{
                Running    = "copy running-config $runRemote"
                Startup    = "copy startup-config $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }

        # ----------------------------------------------------------
        # NX-OS
        # ----------------------------------------------------------
        "NX-OS" {
            return @{
                Running    = "copy running-config $runRemote"
                Startup    = "copy startup-config $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }

        # ----------------------------------------------------------
        # ASA
        # ----------------------------------------------------------
        "ASA" {
            return @{
                Running    = "copy running-config $runRemote"
                Startup    = "copy startup-config $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }

        # ----------------------------------------------------------
        # IOS-XR
        # ----------------------------------------------------------
        "IOS-XR" {
            return @{
                Running    = "copy running-config $runRemote"
                Startup    = "copy startup-config $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }

        # ----------------------------------------------------------
        # Unknown: Best-effort generic IOS syntax
        # ----------------------------------------------------------
        default {
            return @{
                Running    = "copy running-config $runRemote"
                Startup    = "copy startup-config $startRemote"
                CheckRun   = "dir $Filesystem | include $($Global:RemoteRunFile)"
                CheckStart = "dir $Filesystem | include $($Global:RemoteStartFile)"
            }
        }
    }
}
