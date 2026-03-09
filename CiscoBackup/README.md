# CiscoBackup

A modular PowerShell engine for automated SSH-based configuration backup of Cisco network devices. Supports IOS, IOS-XE, IOS-XR, NX-OS, and ASA platforms.

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

---

## Setup

**1. Clone or download** the repository into a local folder, e.g. `D:\CiscoBackup`.

**2. Place `plink.exe` and `pscp.exe`** in the script root alongside `backup.ps1`.

**3. Populate `devices.txt`** with one device hostname or IP per line:

```
192.168.1.1
core-switch-01
border-router.corp.local
# Lines starting with # or ; are ignored
```

**4. (Optional) Populate `hostkeys.txt`** to pre-supply SSH host keys for devices not yet in the PuTTY registry cache. Format is hostname/IP followed by the fingerprint, separated by whitespace:

```
192.168.1.1   ssh-ed25519 255 SHA256:AAAA...
core-switch-01  rsa2@22:core-switch-01 0x23,...
```

**5. Seed PuTTY host key cache** for new devices (recommended before first backup run):

```powershell
.\backup.ps1 -SeedCache
```

This opens an interactive plink session per device so you can manually accept and cache each host key. Use `-SeedUsePassword` to also supply credentials during seeding, and `-SeedForce` to re-seed devices already present in the cache.

---

## Usage

### Normal backup run

```powershell
.\backup.ps1
```

You will be prompted for SSH credentials. All devices in `devices.txt` are processed sequentially. Output files are written to a dated subfolder, e.g. `.\250614\`.

### Dry run (no changes)

```powershell
.\backup.ps1 -DryRun
```

Tests host key resolution and OS detection for every device. No SCP operations or config copies are performed. Useful for validating new devices before committing to a full backup.

### Seed PuTTY host key cache

```powershell
# Interactive seeding (key-based)
.\backup.ps1 -SeedCache

# Include password during seeding
.\backup.ps1 -SeedCache -SeedUsePassword

# Re-seed even if key already cached
.\backup.ps1 -SeedCache -SeedForce
```

### Debug logging

```powershell
.\backup.ps1 -Debug
```

Writes per-device debug logs to `.\<date>\_debug\`. Useful for diagnosing SCP failures or OS detection mismatches.

---

## Output

Each run creates a dated output folder (`.\YYMMDD\`) containing:

```
250614\
  core-switch-01-running.conf
  core-switch-01-startup.conf
  border-router-running.conf
  border-router-startup.conf
  summary.txt
  _debug\                     # only present when -Debug is used
    core-switch-01-scp-enable.log
    ...
```

Output filenames are derived from the `hostname` directive found inside the config file itself. If no hostname is found, the device's IP or DNS label from `devices.txt` is used as a fallback. If two devices share the same hostname, the device label is appended to prevent overwriting.

### Summary report

`summary.txt` is written at the end of every run:

```
Cisco Backup Summary Report
Timestamp     : 2025-06-14 02:15:44
Output folder : D:\CiscoBackup\250614

Total devices : 5
Successful    : 4
Failed        : 1

Results:
------------------------------------------
SUCCESS - 192.168.1.1 [IOS-XE] -> core-rtr-running.conf, core-rtr-startup.conf
SUCCESS - 192.168.1.2 [NX-OS]  -> dist-sw01-running.conf, dist-sw01-startup.conf
FAILED  - 192.168.1.5 [Unknown] -> Unable to determine OS
```

---

## Host Key Resolution

The engine resolves SSH host keys using a three-tier priority:

| Priority | Source | Notes |
|---|---|---|
| 1 | PuTTY registry cache | Preferred — use `-SeedCache` to populate |
| 2 | `hostkeys.txt` | Offline override for devices not yet cached |
| 3 | Live probe via `plink -v` | Auto-discovery, used as last resort |

If none of these succeed, the device is skipped with an error in the summary.

---

## Supported Platforms

| OS | SCP Enable Command | Config Export Method |
|---|---|---|
| IOS | `ip scp server enable` | `redirect <file> show running-config` |
| IOS-XE | `ip scp server enable` | `redirect <file> show running-config` |
| NX-OS | `feature scp-server` | `show running-config \| no-more \| redirect <file>` |
| ASA | `ssh scopy enable` | `copy /noconfirm running-config <file>` |
| IOS-XR | `ssh scp server enable` | `show running-config \| save <file>` |

---

## Security Notes

- Credentials are entered interactively via `Get-Credential` and are never stored to disk.
- The password is held in memory for the duration of the script run and passed to `plink`/`pscp` as a process argument. On shared systems, consider using SSH key authentication with `plink -i` instead.
- `hostkeys.txt` should be treated as sensitive — it contains SSH fingerprints that are used to verify device identity.

---

## Troubleshooting

**`Import-HostKeyFile` not recognized**
Ensure `modules.ps1` uses a top-level `foreach` loop to dot-source core files, not a wrapper function. Functions dot-sourced inside another function do not propagate to the caller's scope.

**`Variable '$Global:HostKeyMap' cannot be retrieved`**
All global variables (`$Global:SessionMode`, `$Global:HostKeyMap`, `$Global:RemoteRunFile`, `$Global:RemoteStartFile`) must be initialized after the module import in `backup.ps1`. Use `Get-Variable` guards to avoid overwriting values set by modules.

**`A parameter with the name 'Debug' was defined multiple times`**
Remove `[switch]$Debug` from the `param()` block in `backup.ps1`. When `[CmdletBinding()]` is present, `-Debug` is a reserved common parameter. Use `$DebugPreference` or `-Verbose` instead, or rename the parameter to `$DebugMode`.

**Encoding errors / mojibake characters (`â€"`, `â€¢`)**
All `.ps1` files must be saved as **UTF-8 without BOM**. Avoid copy-pasting script content from browsers, Word documents, or PDF viewers. Re-type affected lines manually in your editor.

**`Variable reference is not valid: ':' was not followed by a valid variable name`**
Any variable immediately followed by a colon inside a double-quoted string must be wrapped in `$()`, e.g. `"Device $($TargetHost): failed"`.

---

## License

MIT — see `LICENSE` for details.