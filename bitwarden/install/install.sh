#!/usr/bin/env bash
# Installer for the bitwarden skill, run by the human (never needs the agent's powers).
#   bash install.sh [--expect FINGERPRINT]   verifies the files, explains what it will do in a dialog,
#                                            then asks for your sudo password (pkexec) and installs
#   bash install.sh --uninstall [--purge]
#   bash install.sh --verify-only            only check the checksums, change nothing
# --expect: the SHA256SUMS fingerprint published with the download (listing page / release notes).
# Step 2 (install-root.sh) does the privileged work; this wrapper verifies and explains it first.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SKILL_DIR="$(dirname "$HERE")"
ROOT_PART="$HERE/install-root.sh"
export DISPLAY="${DISPLAY:-:1}"
# Elevation: pkexec (GUI prompt) on a normal desktop; plain sudo in WSL2, which has no polkit agent.
if grep -qi microsoft /proc/version 2>/dev/null; then ELEV=(sudo); else ELEV=(pkexec); fi

say() { # say TEXT: show on the desktop if possible, always print
  printf '%s\n' "$1"
  command -v zenity >/dev/null && zenity --info --no-markup --width=560 --title="OpenClaw Bitwarden installer" --text="$1" >/dev/null 2>&1 || true
}
fail() { say "$1"; exit 1; }

EXPECT="${EXPECT_SUMS_SHA256:-}"
if [ "${1:-}" = "--expect" ]; then [ $# -ge 2 ] || { echo "--expect needs a fingerprint" >&2; exit 2; }; EXPECT="$2"; shift 2; fi

# 1. Verify the files against SHA256SUMS (and SHA256SUMS against the published fingerprint).
SUMS_FILE="$SKILL_DIR/SHA256SUMS"
[ -f "$SUMS_FILE" ] || fail "SHA256SUMS is missing, so the files cannot be verified. Download the skill again from the official place."
SUMS_SHA="$(sha256sum "$SUMS_FILE" | cut -d' ' -f1)"
if [ -n "$EXPECT" ] && [ "${EXPECT,,}" != "$SUMS_SHA" ]; then
  fail "The SHA256SUMS fingerprint does not match the one you gave.
  yours:  $EXPECT
  actual: $SUMS_SHA
Do not install. Download the skill again from the official place."
fi
(cd "$SKILL_DIR" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1 \
  || fail "A file does not match SHA256SUMS (it was changed or damaged). Nothing was installed. Download the skill again from the official place."

# Read the privileged script ONCE, check that exact text, and hand that text to the elevated shell, so it cannot be swapped between the check and the run.
ROOT_SCRIPT="$(cat "$ROOT_PART"; printf x)"; ROOT_SCRIPT="${ROOT_SCRIPT%x}"
WANT_ROOT="$(awk '$2=="install/install-root.sh"{print $1}' "$SUMS_FILE")"
[ -n "$WANT_ROOT" ] && [ "$(printf '%s' "$ROOT_SCRIPT" | sha256sum | cut -d' ' -f1)" = "$WANT_ROOT" ] || fail "install-root.sh does not match SHA256SUMS. Nothing was installed."
CORE_SHA256="$(awk '$2=="scripts/bwsafe-core"{print $1}' "$SUMS_FILE")"
[ -n "$CORE_SHA256" ] || fail "scripts/bwsafe-core is not listed in SHA256SUMS. Nothing was installed."

if [ "${1:-}" = "--verify-only" ]; then echo "verified. fingerprint: $SUMS_SHA"; exit 0; fi

elevate() { "${ELEV[@]}" env PKEXEC_UID="$(id -u)" DISPLAY_VAL="$DISPLAY" XAUTH="${XAUTHORITY:-}" SKILL_DIR="$SKILL_DIR" CORE_SHA256="$CORE_SHA256" \
  bash -c "$ROOT_SCRIPT" install-root.sh "$@"; }

if [ "${1:-}" = "--uninstall" ]; then
  TXT="This REMOVES the OpenClaw Bitwarden helper:
 - the root-owned programs in /opt/bwsafe
 - the sudo rule in /etc/sudoers.d/bwsafe
 - the desktop-access autostart entry"
  [ "${2:-}" = "--purge" ] && TXT="$TXT
 - the 'bwsafe' system user and its stored vault cache, permissions and audit log (--purge)"
  zenity --question --no-markup --width=560 --title="OpenClaw Bitwarden uninstall" --ok-label="Continue" --cancel-label="Cancel" \
    --text="$TXT

Next you will be asked for your sudo password." || exit 1
  exec "${ELEV[@]}" env PKEXEC_UID="$(id -u)" DISPLAY_VAL="$DISPLAY" XAUTH="${XAUTHORITY:-}" SKILL_DIR="$SKILL_DIR" CORE_SHA256="$CORE_SHA256" \
    bash -c "$ROOT_SCRIPT" install-root.sh "$@"
fi

if command -v zenity >/dev/null; then
  zenity --question --no-markup --width=620 --title="OpenClaw Bitwarden installer" --ok-label="Continue" --cancel-label="Cancel" --text="OpenClaw wants to install a safer Bitwarden helper. The files were checked against their checksums${EXPECT:+ and the fingerprint you gave}.
Fingerprint of this download: ${SUMS_SHA:0:32}...
${EXPECT:-(Compare it with the one published by the author, or run again with --expect FINGERPRINT.)}

With your sudo password, this installer will:

 1. Create a locked-down system user 'bwsafe' (no login, no shell, no home access). Your vault cache, your permissions and the audit log live in its folder /var/lib/bwsafe, which your normal account (and so OpenClaw) cannot read.
 2. Install root-owned programs in /opt/bwsafe: Bitwarden's official 'bw' command (downloaded from Bitwarden's GitHub release and checked against a pinned checksum) and the helper script. OpenClaw cannot modify them.
 3. Add ONE sudo rule: your account may run that helper script as 'bwsafe' without a password. Nothing else.
 4. Add a small desktop autostart entry so that user can show you approval / password windows.
 5. Remove the older separate 'bwtotp' and rbw-based setups, if present (they are replaced by this one).

Afterwards you log into Bitwarden ONCE (choose bitwarden.com, bitwarden.eu or your own server; then an API-key login plus your master password, typed into windows only you see) and tick what OpenClaw may do.

Continue?" || { echo "cancelled"; exit 1; }
else
  echo "zenity missing; proceeding without the explanation dialog" >&2
fi

if elevate; then
  say "Installed.

Next, run 'bwsafe setup'. Windows follow: which Bitwarden server (bitwarden.com, bitwarden.eu or self-hosted), your API key (client_id, client_secret), your master password, and the permission tick-boxes."
else
  say "The installation failed or was cancelled. Nothing is half-configured that matters; you can run it again."
  exit 1
fi
