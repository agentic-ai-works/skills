#!/bin/bash
# Installer for the bitwarden skill on macOS (UNTESTED on a real Mac: written without one).
#   bash install-macos.sh [--mode easy|safer] [--expect FINGERPRINT]
#   bash install-macos.sh --verify-only
#   bash install-macos.sh --uninstall [--purge]
# Two modes (a window asks if you do not pass --mode):
#   Easy   runs as you, no admin password. Gives permissions, approval windows and an audit log, but an
#          agent running as you could read the files directly: a seat belt, not a lock.
#   Safer  also creates a hidden user _bwsafe that owns the vault cache; needs your admin password once.
#          The agent's account cannot read the vault, session key, permissions or audit log.
# Both put bw in a Seatbelt sandbox, and both run `bwsafe selftest` at the end and refuse to finish
# if the sandbox does not work or does not hold.
# Must stay compatible with bash 3.2 (the bash that ships with macOS).
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "this is the macOS installer (Linux: install.sh)" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$HERE")"
ROOT_PART="$HERE/install-macos-root.sh"
TITLE="OpenClaw Bitwarden installer"
BASE="$HOME/Library/Application Support/bwsafe"
BW_VERSION="2026.10.0"
BW_SHA256_AMD64="39602a597ca63127c22ee3844546f3fe06079e4f67be7b9a7ea4e30ede8721d0"
BW_SHA256_ARM64="062c880508678b8d936ab2522a3a1e92d60f52b5c534e71406e9b47329e95207"

# AppleScript string literal of $1
aq() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} NR>1{print "\" & linefeed & \""} {print}' | sed -e 's/^/"/' -e 's/$/"/'; }
HAVE_GUI=1; [ -x /usr/bin/osascript ] && [ -z "${SSH_CONNECTION:-}" ] || HAVE_GUI=0
say() { printf '%s\n' "$1"; [ "$HAVE_GUI" = 1 ] && osascript -e "display dialog $(aq "$1") with title $(aq "$TITLE") buttons {\"OK\"} default button \"OK\"" >/dev/null 2>&1 || true; }
fail() { say "$1"; exit 1; }
# choose TEXT CANCEL-BUTTON [BUTTON...] -> prints the chosen button (empty on cancel); the last button is the default
choose() {
  local text="$1" cancel="$2" list b last
  shift 2
  list="$(aq "$cancel")"; for b in "$@"; do list="$list, $(aq "$b")"; last="$b"; done
  if [ "$HAVE_GUI" = 1 ]; then
    osascript -e "button returned of (display dialog $(aq "$text") with title $(aq "$TITLE") buttons {$list} default button $(aq "$last") cancel button $(aq "$cancel"))" 2>/dev/null || true
  else
    printf '%s\n[e] %s  [s] %s  [anything else] %s: ' "$text" "${1:-}" "$last" "$cancel" >&2; read -r a
    if [ "$a" = s ]; then echo "$last"; elif [ "$a" = e ]; then echo "$1"; fi
  fi
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

MODE="${BWSAFE_MODE:-}"; EXPECT="${EXPECT_SUMS_SHA256:-}"; ACTION=install; PURGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) [ $# -ge 2 ] || { echo "--mode needs easy or safer" >&2; exit 2; }; MODE="$2"; shift 2 ;;
    --expect) [ $# -ge 2 ] || { echo "--expect needs a fingerprint" >&2; exit 2; }; EXPECT="$2"; shift 2 ;;
    --verify-only) ACTION=verify; shift ;;
    --uninstall) ACTION=uninstall; shift ;;
    --purge) PURGE="--purge"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in ""|easy|safer) ;; *) echo "--mode must be easy or safer" >&2; exit 2 ;; esac

# 1. Verify the files against SHA256SUMS (and SHA256SUMS against the published fingerprint).
SUMS_FILE="$SKILL_DIR/SHA256SUMS"
[ -f "$SUMS_FILE" ] || fail "SHA256SUMS is missing, so the files cannot be verified. Download the skill again from the official place."
SUMS_SHA="$(sha "$SUMS_FILE")"
if [ -n "$EXPECT" ] && [ "$(printf '%s' "$EXPECT" | tr 'A-F' 'a-f')" != "$SUMS_SHA" ]; then
  fail "The SHA256SUMS fingerprint does not match the one you gave.
  yours:  $EXPECT
  actual: $SUMS_SHA
Do not install. Download the skill again from the official place."
fi
(cd "$SKILL_DIR" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) \
  || fail "A file does not match SHA256SUMS (it was changed or damaged). Nothing was installed. Download the skill again from the official place."
sum_of() { awk -v f="$1" '$2==f{print $1}' "$SUMS_FILE"; }
CORE_SHA256="$(sum_of scripts/bwsafe-core)"; UI_SHA256="$(sum_of scripts/bwsafe-ui.py)"; SB_SHA256="$(sum_of scripts/bwsafe.sb)"
[ -n "$CORE_SHA256" ] && [ -n "$UI_SHA256" ] && [ -n "$SB_SHA256" ] || fail "a program file is not listed in SHA256SUMS. Nothing was installed."
# Read the privileged script ONCE, check that exact text, and run that text, so it cannot be swapped between the check and the run.
ROOT_SCRIPT="$(cat "$ROOT_PART"; printf x)"; ROOT_SCRIPT="${ROOT_SCRIPT%x}"
WANT_ROOT="$(sum_of install/install-macos-root.sh)"
[ -n "$WANT_ROOT" ] && [ "$(printf '%s' "$ROOT_SCRIPT" | shasum -a 256 | awk '{print $1}')" = "$WANT_ROOT" ] || fail "install-macos-root.sh does not match SHA256SUMS. Nothing was installed."
[ "$ACTION" = verify ] && { echo "verified. fingerprint: $SUMS_SHA"; exit 0; }

# run the verified root script with administrator rights (the macOS password window)
ME="$(id -un)"
case "$SKILL_DIR$HOME$ME" in *\'*|*\"*|*\\*) fail "A folder or user name contains a quote or backslash; move the skill to a plain path and run again." ;; esac
elevate() { # elevate ROOT-ARGS...
  local b64 cmd
  b64="$(printf '%s' "$ROOT_SCRIPT" | base64 | tr -d '\n')"
  cmd="env OWNER='$ME' OWNER_UID='$(id -u)' SKILL_DIR='$SKILL_DIR' CORE_SHA256='$CORE_SHA256' UI_SHA256='$UI_SHA256' SB_SHA256='$SB_SHA256' PYTHON_BIN='${PYTHON_BIN:-}' BASH_BIN='${BASH_BIN:-}' JQ_BIN_ABS='${JQ_BIN_ABS:-}' /bin/bash -c \"\$(printf %s '$b64' | base64 -D)\" install-macos-root.sh $* 2>&1"
  if [ "$HAVE_GUI" = 1 ]; then osascript -e "do shell script $(aq "$cmd") with administrator privileges"
  else sudo /bin/bash -c "$cmd"; fi
}

installed_safer() { [ -x /usr/local/libexec/bwsafe/bwsafe-core ]; }
installed_easy()  { [ -x "$BASE/bin/bwsafe-core" ]; }

if [ "$ACTION" = uninstall ]; then
  did=0
  if installed_safer || [ -f /etc/sudoers.d/bwsafe ]; then
    [ "$(choose "This REMOVES the Safer-mode helper: the programs in /usr/local/libexec/bwsafe, the sudo rule and the two background tasks${PURGE:+, and (--purge) the hidden _bwsafe user with the vault cache, permissions and audit log}. Your admin password is needed." Cancel Remove)" = Remove ] || exit 1
    elevate --uninstall $PURGE; did=1
  fi
  if installed_easy || [ -d "$BASE" ]; then
    rm -rf "$BASE/bin"; [ -n "$PURGE" ] && rm -rf "$BASE"; did=1
    echo "removed the Easy-mode programs${PURGE:+ and all its data}"
  fi
  [ "$did" = 1 ] || echo "nothing to remove"
  exit 0
fi

# 2. Tools the core needs: bash 4.4+, python3, jq, and Bitwarden's bw (downloaded below).
BASH_BIN=""
for c in /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if [ -x "$c" ] && [ "$("$c" -c 'echo $((BASH_VERSINFO[0]*100+BASH_VERSINFO[1]))')" -ge 404 ]; then BASH_BIN="$c"; break; fi
done
PYTHON_BIN=""
for c in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  [ -x "$c" ] && "$c" -c pass >/dev/null 2>&1 && { PYTHON_BIN="$c"; break; }
done
JQ_BIN_ABS=""
for c in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq; do [ -x "$c" ] && "$c" -n 1 >/dev/null 2>&1 && { JQ_BIN_ABS="$c"; break; }; done
MISS=""
[ -n "$BASH_BIN" ]   || MISS="$MISS
 - a newer bash:       brew install bash       (macOS ships bash 3.2; the helper needs 4.4 or newer)"
[ -n "$PYTHON_BIN" ] || MISS="$MISS
 - python3:            xcode-select --install  (or: brew install python)"
[ -n "$JQ_BIN_ABS" ] || MISS="$MISS
 - jq:                 brew install jq"
if [ -n "$MISS" ]; then
  fail "bwsafe needs a few more tools first (Homebrew is at https://brew.sh):$MISS

Install them, then run this installer again."
fi
export BASH_BIN PYTHON_BIN JQ_BIN_ABS
installed_safer && echo "note: Safer mode is already installed; this run will update it."

# 3. Which mode?
if [ -z "$MODE" ]; then
  ANS="$(choose "OpenClaw wants to install a Bitwarden helper. The files were checked against their checksums${EXPECT:+ and the fingerprint you gave}.
Fingerprint of this download: ${SUMS_SHA:0:32}...

Choose how much protection you want:

SAFER (recommended): creates a hidden user account '_bwsafe' (needs your admin password once). Your vault cache, permissions and audit log belong to it, so OpenClaw, which runs as you, cannot read them or call Bitwarden directly.

EASY: no admin password, everything runs as you. You still get tick-box permissions, Approve windows and an audit log, but a program running as you (including an agent) could read the files directly. A seat belt against mistakes, not a lock.

In both modes Bitwarden's own 'bw' command runs inside a macOS sandbox, and a self-test must pass before anything is usable." Cancel Easy Safer)"
  case "$ANS" in Easy) MODE=easy ;; Safer) MODE=safer ;; *) echo cancelled; exit 1 ;; esac
fi

if [ "$MODE" = safer ]; then
  if elevate; then
    say "Installed (Safer mode).

Next, run 'bwsafe setup'. Windows follow: which Bitwarden server, your API key, your master password, and the permission tick-boxes."
  else
    say "The installation failed or was cancelled. Nothing that matters is half-configured; you can run it again."; exit 1
  fi
  exit 0
fi

# ---- Easy mode: everything in your own Library folder, no admin rights ----
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
echo "== Easy mode: files go to $BASE"
BW_FROM="${BW_SRC:-}"
if [ -z "$BW_FROM" ] && [ -x "$BASE/bin/bw" ]; then BW_FROM="$BASE/bin/bw"; fi
if [ -n "$BW_FROM" ] && [ -x "$BW_FROM" ]; then
  echo "== using the existing bw: $BW_FROM"; cp "$BW_FROM" "$W/bw"
else
  case "$(uname -m)" in
    arm64) BW_ZIP="bw-macos-arm64-$BW_VERSION.zip"; BW_WANT="$BW_SHA256_ARM64" ;;
    x86_64) BW_ZIP="bw-macos-$BW_VERSION.zip"; BW_WANT="$BW_SHA256_AMD64" ;;
    *) fail "unsupported CPU $(uname -m); set BW_SRC=/path/to/bw" ;;
  esac
  echo "== downloading Bitwarden's official CLI $BW_VERSION (not bundled with this skill)"
  curl -fsSL "https://github.com/bitwarden/clients/releases/download/cli-v$BW_VERSION/$BW_ZIP" -o "$W/bw.zip"
  [ "$(sha "$W/bw.zip")" = "$BW_WANT" ] || fail "The downloaded bw does not match the pinned checksum. Nothing was installed."
  echo "checksum ok ($BW_WANT)"
  unzip -q "$W/bw.zip" bw -d "$W"
fi
chmod 755 "$W/bw"
# copy the checked files first, check the copies, and install only those
cp "$SKILL_DIR/scripts/bwsafe-core" "$W/core"; cp "$SKILL_DIR/scripts/bwsafe-ui.py" "$W/ui.py"; cp "$SKILL_DIR/scripts/bwsafe.sb" "$W/bwsafe.sb"
[ "$(sha "$W/core")" = "$CORE_SHA256" ] && [ "$(sha "$W/ui.py")" = "$UI_SHA256" ] && [ "$(sha "$W/bwsafe.sb")" = "$SB_SHA256" ] || fail "A file changed while installing. Nothing was installed."
mkdir -p "$BASE/bin" "$BASE/state/run"; chmod 700 "$BASE" "$BASE/state" "$BASE/state/run"
cp "$W/bw" "$BASE/bin/bw"; cp "$W/ui.py" "$BASE/bin/bwsafe-ui.py"; cp "$W/bwsafe.sb" "$BASE/bin/bwsafe.sb"
chmod 755 "$BASE/bin/bw" "$BASE/bin/bwsafe-ui.py"; chmod 644 "$BASE/bin/bwsafe.sb"
shasum -a 256 "$BASE/bin/bw"
sed -e "1s|.*|#!$BASH_BIN|" \
    -e "s|^BW_BIN=.*|BW_BIN=\"$BASE/bin/bw\"|" \
    -e "s|^STATE=.*|STATE=\"$BASE/state\"|" \
    -e "s|^RUN=.*|RUN=\"$BASE/state/run\"|" \
    -e "s|^SANDBOX=.*|SANDBOX=\"seatbelt\"|" \
    -e "s|^UI_MODE=.*|UI_MODE=\"direct\"|" \
    -e "s|^PYTHON=.*|PYTHON=\"$PYTHON_BIN\"|" \
    -e "s|^UI_HELPER=.*|UI_HELPER=\"$BASE/bin/bwsafe-ui.py\"|" \
    -e "s|^SB_PROFILE=.*|SB_PROFILE=\"$BASE/bin/bwsafe.sb\"|" \
    -e "s|^JQ_BIN=.*|JQ_BIN=\"$JQ_BIN_ABS\"|" \
    "$W/core" > "$BASE/bin/bwsafe-core"
chmod 755 "$BASE/bin/bwsafe-core"
grep -q '^UI_MODE="direct"' "$BASE/bin/bwsafe-core" || fail "Could not write the settings. Nothing is usable."

echo "== self-test (the sandbox must work and must hold)"
if "$BASE/bin/bwsafe-core" selftest; then
  say "Installed (Easy mode).

Reminder: in Easy mode OpenClaw runs as you and could read the vault cache directly. The permissions, Approve windows and audit log are guard rails, not a lock. Use Safer mode if that matters (bash install-macos.sh --mode safer).

Next, run 'bwsafe setup'."
else
  rm -rf "$BASE/bin"
  fail "The self-test FAILED, so the installed files were removed again. Please report this (macOS version, chip) so the sandbox profile can be fixed."
fi
