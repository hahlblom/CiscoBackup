<#
    OSDetect.ps1
    ------------
    Determines the operating system type of a Cisco device by parsing
    the output of "show version".

    Supported:
      - IOS
      - IOS-XE
      - NX-OS
      - ASA
      - IOS-XR
      - Unknown (fallback)
#>

# Requires:
#   Invoke-PlinkSmart (from Exec.ps1)
#   Write-DebugFile, Write-Warn (from Utils.ps1)

function Get-DeviceOS {
    param(
        [Parameter(Mandatory=$true)][string]$PlinkPath,
        [Parameter(Mandatory=$true)][string]$TargetHost,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$Password,
        [Parameter(Mandatory=$true)][bool]$UseHostKey,
        [Parameter()][string]$HostKey,
        [int]$TimeoutSec = 45
    )

    # Always attempt "show version"
    $res = Invoke-PlinkSmart 
        -PlinkPath $PlinkPath 
        -TargetHost $TargetHost 
        -Username $Username 
        -Password $Password 
        -UseHostKey:$UseHostKey 
        -HostKey $HostKey 
        -Commands @("show version") 
        -TimeoutSec $TimeoutSec

    $txt = ($res.StdOut + "`n" + $res.StdErr)

    # Strip null bytes if any
    $txt = Strip-Null $txt

    # --------------------------------------------------------
    # OS pattern matching (regex-based)
    # --------------------------------------------------------

    switch -Regex ($txt) {

        "NX[\-\ ]?OS" {
            return "NX-OS"
        }

        "Adaptive Security Appliance" {
            # ASA sometimes prints this instead of simply "ASA"
            return "ASA"
        }

        "ASA[0-9]* Software" {
            return "ASA"
        }

        "IOS[\-\ ]?XR" {
            return "IOS-XR"
        }

        "IOS[\-\ ]?XE" {
            return "IOS-XE"
        }

        "Cisco IOS Software" {
            return "IOS"
        }

        # Some IOS devices print just “IOS” in banner
        " IOS " {
            return "IOS"
        }

        default {
            # Unknown OS — write debug dump
            Write-Warn "Unable to confidently parse OS for device $TargetHost"

            Write-DebugFile -Prefix "osdetect" -Content @(
                "Device: $TargetHost",
                "Raw text: ",
                $txt
            )

            return "Unknown"
        }
    }
}