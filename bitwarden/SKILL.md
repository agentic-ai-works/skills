---
name: bitwarden
description: Use Jens's Bitwarden vault without exposing secrets. List/search entries, get TOTP/2FA codes, feed a stored password or API key into a command, generate or store credentials, add/replace/remove authenticator keys. Trigger on Bitwarden, vault, "my password/API key for X", 2FA/TOTP code, "save this secret".
---

# Bitwarden (bwsafe)

One skill, one install, one login. The official `bw` CLI runs per call inside a bubblewrap sandbox, as the locked-down system user `bwsafe`. The agent's account cannot read the vault cache, the session key, the permissions or the audit log, and cannot edit the program. What the agent may do is decided by Jens in tick-box dialogs (`bwsafe configure`); until he has done that, everything is denied.

Command: `bwsafe` (in `~/.local/bin`). Run `bwsafe help` for the full list.

## Rules
- Never put a secret on a command line or in chat. Use `bwsafe run ... -- CMD` so the secret goes to the command's environment or stdin. `reveal --yes` only if Jens explicitly asks to see it.
- New passwords: `bwsafe generate NAME [USER]` (never shown) or `add ... --prompt` (Jens types it in a dialog). `--stdin` only for a secret you already legitimately hold.
- add/generate/addkey never overwrite. edit/setkey/rmkey/remove open an Approve dialog for Jens each time. On "not approved" (exit 6) do not retry; tell Jens what you wanted and why.
- Exit 5 means the permissions forbid it. Do not work around it; ask Jens to change them (`bwsafe configure`).
- Exit 3 = locked or not set up: ask Jens to run `bwsafe unlock` (master password dialog, session lasts 24 h).
- Entries are matched by exact NAME (add USER when several share a name). Only login entries are reachable. New entries go to folder `OpenClaw`.

## Commands (short)
read: `status`, `list [--folder F]`, `search Q`, `fields NAME`, `user NAME`, `code NAME [USER]`, `run [--field F] [--env VAR|--stdin] NAME [USER] -- CMD`, `reveal NAME --yes`
add: `generate NAME [USER] [--len N|--words N] [--uri U]`, `add NAME [USER] [--uri U] [--notes T] --stdin|--prompt`, `addkey NAME [USER] --stdin|--prompt`
update/delete (approval): `edit`, `setkey`, `rmkey`, `remove`
admin (Jens): `setup [EMAIL] [--us|--eu|--server URL]`, `configure`, `unlock`, `lock`, `sync`, `logout`, `log [N]`

## Permissions (`bwsafe configure`)
Jens ticks in three windows: actions (read / add / update / delete), where (everything, entries without a folder, individual folders), and what (passwords+usernames+notes, authenticator codes+keys). Stored in `/var/lib/bwsafe/policy.json` (writable only by `bwsafe`), enforced on every command, changes are audited. `bwsafe status` shows the current ones.

## Install / first use (Jens does the clicking)
1. `bash skills/bitwarden/install/install.sh [--expect FINGERPRINT]`: first checks every file against SHA256SUMS (and SHA256SUMS against the published fingerprint if given), then a window explains what will happen, then a sudo password prompt. It also retires the older rbw and `bwtotp` setups. Uninstall: `install.sh --uninstall [--purge]`. On macOS use `install/install-macos.sh` instead (Easy or Safer mode, untested; see docs/PLATFORMS.md).
2. `bwsafe setup`: a window asks which server (bitwarden.com, bitwarden.eu, or self-hosted such as Vaultwarden; flags `--us`, `--eu`, `--server URL` skip it; a self-signed/private certificate triggers a trust-this-certificate window), then windows for the API key (client_id, client_secret from your web vault > Settings > Security > Keys), the master password, and the permission tick-boxes. Done once.
3. Test offline any time: `bash skills/bitwarden/tests/offline-test.sh`.

## Limits to state honestly
- On X11 any program in Jens's desktop session could fake an Approve click, so that dialog is policy, not a wall. The `bwsafe` user separation is what protects the vault from the agent's own account.
- Codes and secrets fetched with `code`, `reveal` or `run` reach the agent process (and the model provider if printed). TOTP is riskier than passwords; keep it off unless needed.
