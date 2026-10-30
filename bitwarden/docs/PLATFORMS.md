# Platforms

| Platform | Status | How |
|---|---|---|
| Linux (X11, or Wayland with XWayland) | Works | `install/install.sh` |
| Windows | WSL2 via install-windows.cmd (untested). Native: not built |
| macOS | **Easy and Safer built, UNTESTED on a real Mac**; Paranoid not built | `install/install-macos.sh` (Easy: no admin password; Safer: hidden `_bwsafe` user + sudoers + Seatbelt sandbox + a dialog helper in your session) |
| iOS / Android | Cannot host the vault helper | can act as the **approval device** (planned) |

## Windows
- **Works now (recommended): WSL2.** Install the Linux version inside WSL2 (Ubuntu). Dialogs need WSLg (Windows 11 / recent Win10), which supplies the X11/Wayland display. The agent must run inside WSL too.
- **Native port (future work).** The design maps cleanly, but every piece is replaced:
  - locked-down user -> a dedicated local Windows account (`bwsafe`), core launched via `runas`/a scheduled task, ACLs deny your account read access to `C:\ProgramData\bwsafe`
  - bubblewrap -> Windows Sandbox / AppContainer (or run `bw` as the `bwsafe` account with no network ACL beyond the server)
  - zenity -> a small PowerShell/WinForms dialog helper run in your session
  - sudoers rule -> a service/scheduled task triggered by a named pipe that only your account may open
  Estimated effort: a few days plus testing on real Windows. Needs a Windows machine to develop against.

## iOS (and Android)
An iPhone cannot run `bw` as a separate sandboxed user or give an agent shell access, so the helper itself cannot live there. What it *can* be is the **approval and password-entry device**: the core sends a push (OpenClaw node / ntfy / Signal) with the action text, and Approve/Deny on the phone replaces the desktop dialog. Benefit: the click happens on a different device, which removes the "same-session malware can fake the click" limit. Needs: an approval-channel option in the core (`APPROVER=desktop|ntfy`), a one-time pairing secret, signed replies. Master-password entry should stay on the desktop.

## macOS (Easy and Safer built; written without a Mac, so UNTESTED)
`bash install/install-macos.sh` verifies the files, checks that bash 4.4+, python3 and jq exist (it tells you what to `brew install` otherwise), then asks which mode. Same core, same policy tick-boxes, same dialogs on every mode; the modes differ in how much stands between the agent and the vault:

| | **Easy** | **Safer** (recommended) | **Paranoid** (not built) |
|---|---|---|---|
| Runs as | your own user | hidden `_bwsafe` user | `bw` + vault live in a Linux VM |
| Sandbox | Seatbelt (`sandbox-exec`) around `bw` | same, plus the separate user | the VM boundary |
| Admin password at install | no | yes (one-time) | yes, plus VM tool |
| Can the agent read the vault cache and session key? | **yes** (same user): policy and audit only, no wall | no | no |

Be plain about **Easy**: scoped permissions, approval dialogs and an audit log, but an agent running as you can bypass it by reading the cache directly. A seat belt against mistakes, not a lock. **Safer** is the Linux design with Seatbelt instead of namespaces. **Paranoid** (VM, dialogs crossing the VM boundary) stays future work.

How the parts map from Linux (as built):
- **Locked-down user (Safer):** `_bwsafe` created with `dscl` (hidden, shell `/usr/bin/false`, home `/var/empty`, id in 250-399). State in `/var/lib/bwsafe` (0700), root-owned core, profile and helper in `/usr/local/libexec/bwsafe`, one sudoers line (`/etc/sudoers.d/bwsafe`, checked with `visudo -cf`). The 24 h session key lives in `/var/lib/bwsafe/run` (macOS has no tmpfs `/run`); a LaunchDaemon empties it at every boot.
- **Sandbox:** `scripts/bwsafe.sb`, a deny-by-default Seatbelt profile: `bw` may read system libraries and certificates, write only its data dir and a private temp dir, and use the network. Weaker than bubblewrap (no PID/IPC namespaces). Apple marks `sandbox-exec` deprecated but it still works. The profile is a best guess made without a Mac: that is why both installers run `bwsafe selftest` (bw and jq must run; a canary file outside the allowed paths must be unreadable and unwritable) and remove everything again if it fails.
- **Dialogs:** `scripts/bwsafe-ui.py` shows `osascript` dialogs (hidden-answer entry, Approve/Deny with Deny as the default button, radio and tick-box lists via `choose from list`, timeouts, fail closed). Easy: the core calls it directly. Safer: a LaunchAgent runs it in your session on a Unix socket in `/var/db/bwsafe-ui`; it answers only the `_bwsafe` account (kernel-reported peer uid), so the agent cannot ask it for the master password. Limit, as on Linux: a program running as you can fake a click.
- **bw binary:** Bitwarden's official macOS build for your chip, pinned to a SHA-256 in the installer.
- **Portability work in the core:** BSD `stat`/`date`/`timeout`, LibreSSL without `openssl -ext`, bash 4.4+ from Homebrew (the installer writes it into the core's shebang).
- **Tests that run anywhere:** `tests/helper-test.sh` (dialog helper and the core's macOS dialog bridge with a fake osascript, including the socket peer check) and `tests/macos-static-test.sh` (syntax, bash-3.2 habits, config rewrite, profile structure). What only a Mac can show: whether the profile is complete, how the dialogs look, dscl/launchctl/sudoers behaviour. Please report problems with the macOS version and chip.
