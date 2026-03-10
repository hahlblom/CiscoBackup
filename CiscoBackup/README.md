# CiscoBackup

A modular PowerShell engine for automated SSH-based configuration backup of Cisco network devices. Supports IOS, IOS-XE, IOS-XR, NX-OS, and ASA platforms.
And no it's still not working.
---

## Features

- Automatic OS detection per device (IOS, IOS-XE, IOS-XR, NX-OS, ASA)
- SSH host key resolution via PuTTY registry cache, static file, or live probe
- Non-interactive config export using OS-appropriate commands
- SCP download of running-config and startup-config
- Hostname extraction from config files for human-readable output filenames
- Duplicate hostname collision detection
- Remote temp file cleanup after download
- Dry-run mode for connectivity and OS detection testing
- Host key seeding mode for new device onboarding
- Debug file logging per device
- Per-device error isolation — one failure never stops the rest
- Summary report written to disk after every run

---

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- [PuTTY](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) — `plink.exe` and `pscp.exe` must be placed in the script root
- SSH access to target devices with a user that has privilege to run `show` commands and enable SCP server
- `Set-ExecutionPolicy RemoteSigned` or equivalent to allow local script execution

---

## Folder Structure

```
CiscoBackup\
  backup.ps1          # Main orchestrator
  modules.ps1         # Module loader
  devices.txt         # List of device hostnames or IPs (one per line)
  hostkeys.txt        # Optional: static SSH host key overrides
  plink.exe           # PuTTY CLI SSH client
  pscp.exe            # PuTTY SCP client
  core\
    Utils.ps1         # Logging helpers (Write-Info, Write-Warn, Write-Err)
    Exec.ps1          # plink/pscp invocation and process management
    HostKey.ps1       # Host key acquisition and PuTTY cache management
    OSDetect.ps1      # Cisco OS fingerprinting via SSH banner/prompt
    Filesystems.ps1   # OS-specific filesystem preference lists
    CopyCommands.ps1  # Generates remote copy/verify commands per OS
    SCP.ps1           # SCP server enablement and file download
    Cleanup.ps1       # Remote temp file deletion after backup
    Normalize.ps1     # Hostname extraction, filename sanitization, file finalization
```

## License


MIT — see `LICENSE` for details.
