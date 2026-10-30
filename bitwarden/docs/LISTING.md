# Listing text (ClawHub / Gumroad / GitHub)

**Title:** bwsafe: let your AI agent use Bitwarden without trusting it with the vault
**Short:** Official `bw` CLI in a sandbox as a locked-down user. You tick what the agent may do (read / add / update / delete, folders, passwords and/or TOTP). Passwords go into commands, not chat. Update and delete need your click.
**Tags:** bitwarden, vaultwarden, passwords, totp, 2fa, security, agent, sandbox
**Requires:** Linux with bubblewrap, jq, zenity, sudo/polkit. Windows via WSL2 (untested); macOS Easy and Safer modes (untested, needs bash 4.4+, python3, jq); native Windows is planned (docs/PLATFORMS.md).
**Price idea:** free core (MIT, see LICENSE) on ClawHub/GitHub; paid: setup service and a supported "Pro" build later (Windows native, phone approvals).
**Disclaimer line:** Unofficial; not affiliated with Bitwarden Inc. Not independently audited.
