<#
    Filesystems.ps1
    ----------------
    Provides filesystem selection logic for Cisco platforms.

    Responsibilities:
      - Return list of preferred filesystems for each OS
      - No network calls
      - Deterministic, offline-safe
#>

function Get-PreferredFilesystems {
    param(
        [Parameter(Mandatory=$true)]
        [string]$OS
    )

    switch ($OS) {

        # -------------------------------------------------------
        # IOS: Classic IOS
        # -------------------------------------------------------
        "IOS" {
            # Most common IOS storage naming
            return @(
                "flash:",
                "bootflash:",
                "nvram:"          # fallback
            )
        }

        # -------------------------------------------------------
        # IOS-XE: typically bootflash:, sometimes flash:
        # -------------------------------------------------------
        "IOS-XE" {
            return @(
                "bootflash:",
                "flash:",
                "nvram:"          # fallback
            )
        }

        # -------------------------------------------------------
        # NX-OS: main filesystem is always bootflash:
        # -------------------------------------------------------
        "NX-OS" {
            return @(
                "bootflash:",
                "volatile:",       # some NX-OS variants
                "sup-bootflash:"  # dual-supervisor systems
            )
        }

        # -------------------------------------------------------
        # ASA: may have multiple disks
        # -------------------------------------------------------
        "ASA" {
            return @(
                "disk0:",
                "disk1:",
                "flash:"          # legacy ASA 5505 etc
            )
        }

        # -------------------------------------------------------
        # IOS-XR: uses disk0:, filesystem is sometimes RW-restricted
        # -------------------------------------------------------
        "IOS-XR" {
            return @(
                "disk0:",
                "disk1:",
                "harddisk:"       # some platforms
            )
        }

        # -------------------------------------------------------
        # Unknown OS — attempt safest general fallbacks
        # -------------------------------------------------------
        default {
            return @(
                "flash:",
                "bootflash:",
                "disk0:",
                "nvram:"
            )
        }
    }
}