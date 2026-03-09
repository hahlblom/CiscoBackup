<#
    Module Loader for CiscoBackup
    Loads all engine components under /core
#>
param(
    [string]$BasePath = $PSScriptRoot
)

$coreFiles = @(
    "Utils",
    "Exec",
    "HostKey",
    "OSDetect",
    "Filesystems",
    "CopyCommands",
    "SCP",
    "Cleanup",
    "Normalize"
)

foreach ($name in $coreFiles) {
    $path = Join-Path $BasePath ("core\" + $name + ".ps1")
    if (-not (Test-Path $path)) {
        throw "Module file missing: $path"
    }
    . $path
}

Write-Verbose "All backup core modules imported successfully."