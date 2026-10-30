# bwsafe: Bitwarden for AI agents, with permissions you control

Lets an AI agent (OpenClaw, Claude Code, any shell agent) use your Bitwarden vault **without ever being able to read it freely**.

- The agent never sees your master password or the vault file. Bitwarden's official `bw` CLI runs as a separate locked-down system user, inside a bubblewrap sandbox, per call.
- **You decide what it may do** in tick-box dialogs: read / add / update / delete, which folders, passwords and/or authenticator (TOTP) codes. Default: deny everything.
- Passwords go straight into commands (`bwsafe run NAME -- cmd`) instead of into the chat. New passwords are generated inside the vault and never shown.
- Update and delete need your **Approve** click every time. Everything is written to an audit log (names only, never secrets).
- Add/replace/remove authenticator keys and fetch 2FA codes.

## Install (Linux, X11 or Wayland/XWayland, GNOME/KDE/etc.)
Requires: `bwrap` (bubblewrap), `jq`, `zenity`, `xhost`, `sudo`/polkit, `curl`, `unzip`.
```
bash install/install.sh      # explains itself in a window, then asks for your sudo password
bwsafe setup you@example.com             # a window asks: bitwarden.com, bitwarden.eu or self-hosted (or pass --us / --eu / --server https://your.vault)
```
Self-hosted Vaultwarden or Bitwarden works with `--server` (https only; http is accepted just for localhost). If the server's certificate is self-signed or from a private CA, setup notices, shows you its fingerprint and asks; only if you click "Trust it" is that one certificate added to the sandbox (the rest of the system is untouched, and it is dropped when you log out or pick another server). A private CA must send its certificate in the chain (fullchain.pem), otherwise setup says so.

### Getting your Bitwarden API key
`bwsafe setup` logs in with your **personal API key** instead of your password, so you need two values once. You do not need a developer account or any paid plan.
1. Open your web vault: <https://vault.bitwarden.com> (US), <https://vault.bitwarden.eu> (EU) or your own server's address.
2. Log in, then go to **Settings > Security > Keys** (older versions: Account settings > Security > Keys).
3. Click **View API key** and type your master password.
4. Copy the `client_id` (looks like `user.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) and the `client_secret`.
5. Paste them into the two setup windows when `bwsafe setup` asks. They go straight into the sandbox user's login and are not written to the chat or the audit log.

Notes:
- The API key is *not* your master password. The master password is typed separately, only into the unlock dialog, and is what actually decrypts the vault. Someone with only the API key can log in but cannot read your vault.
- Use **Rotate API key** on the same page if the key ever leaks. After rotating, run `bwsafe logout` and `bwsafe setup` again.
- Both the `client_id` and `client_secret` belong to *your* account. Do not use an organization key; the setup expects the personal one (`user.` prefix).
- If your account uses two-step login, the API key skips it for login, but the master password is still needed to unlock.
- Self-hosted (Vaultwarden or Bitwarden): the same page exists in your server's web vault, and setup asks for the server address first.

**Verifying the download.** The release ships `SHA256SUMS`; `install.sh` checks every file against it before anything runs as root, and `bash install/install.sh --expect FINGERPRINT` also checks `SHA256SUMS` against the fingerprint published with the release (`--verify-only` checks and changes nothing). The privileged script is read once, checked, and that exact text is what runs as root. Bitwarden's `bw` is downloaded from Bitwarden's GitHub release and must match a SHA-256 pinned in the installer. Maintainers: run `tools/make-sums.sh` before each release and publish the fingerprint it prints.

Uninstall: `bash install/install.sh --uninstall [--purge]`.
Tests (no real vault needed): `bash tests/offline-test.sh`, `bash tests/helper-test.sh`, `bash tests/macos-static-test.sh`.

## Honest limits
- The Approve dialog is policy, not a wall: on X11/XWayland any program in your desktop session can fake a click. The separation protects the vault from the *agent's account*; it does not protect against malware already running as you.
- Anything an agent fetches (`code`, `reveal`) enters its context and goes to its model provider. Keep TOTP off unless you need it.
- Not an audited product. Read `scripts/bwsafe-core` (one file) before trusting it. Bitwarden is a trademark of Bitwarden Inc.; this project is unaffiliated. The `bw` CLI is downloaded from Bitwarden at install time, not bundled.

See `docs/PLATFORMS.md` for Windows / macOS / iOS and `docs/SERVICE.md` for paid setup.

## License
MIT, see LICENSE.

## macOS (Easy or Safer) - untested
```
bash install/install-macos.sh [--mode easy|safer] [--expect FINGERPRINT]
```
Needs bash 4.4+, python3 and jq (`brew install bash jq`; `xcode-select --install` for python3). A window asks which mode: **Safer** (recommended; hidden `_bwsafe` account, one admin password; the agent cannot read the vault) or **Easy** (no admin password, runs as you; permissions, Approve windows and audit log, but the agent could read the files directly: a seat belt, not a lock). `bw` runs in a Seatbelt sandbox in both. The installer ends with `bwsafe selftest` and removes itself again if the sandbox does not work or does not hold. Uninstall: `install-macos.sh --uninstall [--purge]`. Written without a Mac to test on: please report problems with your macOS version and chip. See docs/PLATFORMS.md.

## Windows (via WSL2) - untested
Run `install\install-windows.cmd` (or `install-windows.ps1 -Expect FINGERPRINT`). It verifies the files, turns on WSL2 and Ubuntu if missing (one UAC click, maybe one restart, then it resumes), creates a password-less Linux user, enables systemd, and runs the normal Linux installer inside Ubuntu with a temporary sudo rule that it removes afterwards. Dialogs need WSLg (Windows 11, or Windows 10 with `wsl --update`). Keep LF line endings (the repo's `.gitattributes` does). Written without a Windows machine to test on: please report problems.
