#!/bin/bash
# Privileged half of the macOS "Safer" installer (UNTESTED on a real Mac).
# install-macos.sh checks this text against SHA256SUMS and runs it as root through osascript's
# "with administrator privileges", passing OWNER, OWNER_UID, SKILL_DIR, CORE_SHA256, UI_SHA256,
# SB_SHA256, PYTHON_BIN, BASH_BIN and JQ_BIN_ABS in the environment.
#   sudo OWNER=you ... bash install-macos-root.sh [--uninstall [--purge]]   also works.
# Must stay compatible with bash 3.2 (the bash that ships with macOS).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root (use install-macos.sh)" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "this is the macOS installer" >&2; exit 1; }
OWNER="${OWNER:-}"; OWNER_UID="${OWNER_UID:-}"
[ -n "$OWNER" ] && [ "$OWNER" != root ] || { echo "run it from your normal account (OWNER is not set)" >&2; exit 1; }
[ "$(id -u "$OWNER" 2>/dev/null)" = "$OWNER_UID" ] || { echo "OWNER and OWNER_UID do not agree" >&2; exit 1; }
SKILL_DIR="${SKILL_DIR:-}"
SVC=_bwsafe
LIBX=/usr/local/libexec/bwsafe
STATE=/var/lib/bwsafe
UIDIR=/var/db/bwsafe-ui
SUDOERS=/etc/sudoers.d/bwsafe
UI_PLIST=/Library/LaunchAgents/com.bwsafe.ui.plist
CLEAN_PLIST=/Library/LaunchDaemons/com.bwsafe.cleanrun.plist
# Bitwarden's official CLI, pinned: version and the SHA-256 that Bitwarden's GitHub release publishes for each zip.
BW_VERSION="2026.10.0"
BW_SHA256_AMD64="39602a597ca63127c22ee3844546f3fe06079e4f67be7b9a7ea4e30ede8721d0"
BW_SHA256_ARM64="062c880508678b8d936ab2522a3a1e92d60f52b5c534e71406e9b47329e95207"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$OWNER_UID/com.bwsafe.ui" 2>/dev/null || true
  launchctl bootout system/com.bwsafe.cleanrun 2>/dev/null || true
  rm -f "$SUDOERS" "$UI_PLIST" "$CLEAN_PLIST"
  rm -rf "$LIBX" "$UIDIR"
  if [ "${2:-}" = "--purge" ]; then
    dscl . -delete "/Users/$SVC" 2>/dev/null || true
    dscl . -delete "/Groups/$SVC" 2>/dev/null || true
    rm -rf "$STATE"
    echo "removed; the $SVC user and the vault cache are deleted"
  else
    echo "removed; the $SVC user and $STATE are kept (use --uninstall --purge to delete them)"
  fi
  exit 0
fi

[ -d "$SKILL_DIR/scripts" ] || { echo "SKILL_DIR is wrong: $SKILL_DIR" >&2; exit 1; }
for v in CORE_SHA256 UI_SHA256 SB_SHA256 PYTHON_BIN BASH_BIN JQ_BIN_ABS; do
  eval "[ -n \"\${$v:-}\" ]" || { echo "missing $v (run install-macos.sh instead)" >&2; exit 1; }
done
for b in "$PYTHON_BIN" "$BASH_BIN" "$JQ_BIN_ABS"; do [ -x "$b" ] || { echo "missing program: $b" >&2; exit 1; }; done
"$PYTHON_BIN" -c 'pass' || { echo "python3 does not work (install the Xcode command line tools: xcode-select --install)" >&2; exit 1; }
[ "$("$BASH_BIN" -c 'echo $((BASH_VERSINFO[0]*100+BASH_VERSINFO[1]))')" -ge 404 ] || { echo "bash 4.4 or newer needed: brew install bash" >&2; exit 1; }
grep -Eq '^[#@]includedir[[:space:]]+/(private/)?etc/sudoers.d' /etc/sudoers || { echo "/etc/sudoers does not include /etc/sudoers.d; refusing to guess" >&2; exit 1; }

# Everything below works on copies in a root-only directory, so nobody can swap a file after it was checked.
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
echo "== check the files"
cp "$SKILL_DIR/scripts/bwsafe-core" "$W/core"
cp "$SKILL_DIR/scripts/bwsafe-ui.py" "$W/ui.py"
cp "$SKILL_DIR/scripts/bwsafe.sb" "$W/bwsafe.sb"
[ "$(sha "$W/core")" = "$CORE_SHA256" ] || { echo "bwsafe-core does not match its checksum; aborting" >&2; exit 1; }
[ "$(sha "$W/ui.py")" = "$UI_SHA256" ] || { echo "bwsafe-ui.py does not match its checksum; aborting" >&2; exit 1; }
[ "$(sha "$W/bwsafe.sb")" = "$SB_SHA256" ] || { echo "bwsafe.sb does not match its checksum; aborting" >&2; exit 1; }
"$BASH_BIN" -n "$W/core"

if [ -n "${BW_SRC:-}" ] && [ -x "$BW_SRC" ]; then
  echo "== using the bw you chose: $BW_SRC"; cp "$BW_SRC" "$W/bw"
else
  case "$(uname -m)" in
    arm64) BW_ZIP="bw-macos-arm64-$BW_VERSION.zip"; BW_WANT="$BW_SHA256_ARM64" ;;
    x86_64) BW_ZIP="bw-macos-$BW_VERSION.zip"; BW_WANT="$BW_SHA256_AMD64" ;;
    *) echo "unsupported CPU $(uname -m); set BW_SRC=/path/to/bw" >&2; exit 1 ;;
  esac
  echo "== downloading Bitwarden's official CLI $BW_VERSION (not bundled with this skill)"
  curl -fsSL "https://github.com/bitwarden/clients/releases/download/cli-v$BW_VERSION/$BW_ZIP" -o "$W/bw.zip"
  [ "$(sha "$W/bw.zip")" = "$BW_WANT" ] || { echo "downloaded bw does not match the pinned checksum; aborting" >&2; exit 1; }
  echo "checksum ok ($BW_WANT)"
  unzip -q "$W/bw.zip" bw -d "$W"
fi

echo "== the hidden $SVC user and group"
if ! id "$SVC" >/dev/null 2>&1; then
  # a free id in the system range 250-399, unused as both user id and group id
  ID=""
  n=399
  while [ "$n" -ge 250 ]; do
    if ! dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$n" && ! dscl . -list /Groups PrimaryGroupID | awk '{print $2}' | grep -qx "$n"; then ID="$n"; break; fi
    n=$((n - 1))
  done
  [ -n "$ID" ] || { echo "no free system id found" >&2; exit 1; }
  dscl . -create "/Groups/$SVC"
  dscl . -create "/Groups/$SVC" PrimaryGroupID "$ID"
  dscl . -create "/Groups/$SVC" RealName "bwsafe"
  dscl . -create "/Users/$SVC"
  dscl . -create "/Users/$SVC" UniqueID "$ID"
  dscl . -create "/Users/$SVC" PrimaryGroupID "$ID"
  dscl . -create "/Users/$SVC" UserShell /usr/bin/false
  dscl . -create "/Users/$SVC" RealName "bwsafe"
  dscl . -create "/Users/$SVC" NFSHomeDirectory /var/empty
  dscl . -create "/Users/$SVC" IsHidden 1
  dscl . -create "/Users/$SVC" Password '*'
fi
id "$SVC" >/dev/null || { echo "could not create the $SVC user" >&2; exit 1; }

echo "== directories"
install -d -o "$SVC" -g "$SVC" -m 700 "$STATE" "$STATE/run"
install -d -o root -g wheel -m 755 /usr/local /usr/local/libexec "$LIBX"
install -d -o "$OWNER" -g "$SVC" -m 750 "$UIDIR"      # your dialog helper puts its socket here; only $SVC may use it

echo "== root-owned programs (bw sha256 below; compare with Bitwarden's release if you like)"
install -o root -g wheel -m 755 "$W/bw" "$LIBX/bw"
shasum -a 256 "$LIBX/bw"
install -o root -g wheel -m 755 "$W/ui.py" "$LIBX/bwsafe-ui.py"
install -o root -g wheel -m 644 "$W/bwsafe.sb" "$LIBX/bwsafe.sb"
# the core: fix its shebang to a bash that is new enough and point its CONFIG at this install
sed -e "1s|.*|#!$BASH_BIN|" \
    -e "s|^BW_BIN=.*|BW_BIN=\"$LIBX/bw\"|" \
    -e "s|^STATE=.*|STATE=\"$STATE\"|" \
    -e "s|^RUN=.*|RUN=\"$STATE/run\"|" \
    -e "s|^SANDBOX=.*|SANDBOX=\"seatbelt\"|" \
    -e "s|^UI_MODE=.*|UI_MODE=\"socket\"|" \
    -e "s|^PYTHON=.*|PYTHON=\"$PYTHON_BIN\"|" \
    -e "s|^UI_HELPER=.*|UI_HELPER=\"$LIBX/bwsafe-ui.py\"|" \
    -e "s|^UI_SOCK=.*|UI_SOCK=\"$UIDIR/ui.sock\"|" \
    -e "s|^SB_PROFILE=.*|SB_PROFILE=\"$LIBX/bwsafe.sb\"|" \
    -e "s|^JQ_BIN=.*|JQ_BIN=\"$JQ_BIN_ABS\"|" \
    "$W/core" > "$W/core.out"
grep -q '^SANDBOX="seatbelt"' "$W/core.out" && grep -q '^UI_MODE="socket"' "$W/core.out" || { echo "could not write the core's settings" >&2; exit 1; }
install -o root -g wheel -m 755 "$W/core.out" "$LIBX/bwsafe-core"

echo "== boot task: clear the 24 h session key at every restart"
cat > "$W/clean.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.bwsafe.cleanrun</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>rm -rf $STATE/run/* 2&gt;/dev/null; exit 0</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF
install -o root -g wheel -m 644 "$W/clean.plist" "$CLEAN_PLIST"
launchctl bootout system/com.bwsafe.cleanrun 2>/dev/null || true
launchctl bootstrap system "$CLEAN_PLIST" 2>/dev/null || echo "(boot task will load at the next restart)"

echo "== dialog helper (runs in your login session, answers only $SVC)"
cat > "$W/ui.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.bwsafe.ui</string>
<key>ProgramArguments</key><array>
<string>$PYTHON_BIN</string><string>-I</string><string>$LIBX/bwsafe-ui.py</string><string>serve</string><string>$UIDIR/ui.sock</string>
<string>--allow</string><string>$SVC</string><string>--group</string><string>$SVC</string><string>--uid</string><string>$OWNER_UID</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
EOF
install -o root -g wheel -m 644 "$W/ui.plist" "$UI_PLIST"
launchctl bootout "gui/$OWNER_UID/com.bwsafe.ui" 2>/dev/null || true
launchctl bootstrap "gui/$OWNER_UID" "$UI_PLIST" 2>/dev/null || echo "(the dialog helper could not start now; it starts at your next login)"

echo "== sudoers: $OWNER may run exactly one program, as $SVC, without a password"
printf '%s ALL=(%s) NOPASSWD: %s/bwsafe-core\n' "$OWNER" "$SVC" "$LIBX" > "$W/sudoers"
visudo -cf "$W/sudoers" >/dev/null
install -o root -g wheel -m 440 "$W/sudoers" "$SUDOERS"

echo "== self-test (the sandbox must work and must hold)"
sleep 1
if sudo -u "$OWNER" sudo -n -u "$SVC" "$LIBX/bwsafe-core" selftest; then
  echo
  echo "Done. Next: 'bwsafe setup' (windows on your desktop: bitwarden.com, .eu or self-hosted)."
else
  rm -f "$SUDOERS"
  echo >&2
  echo "The self-test FAILED, so the sudo rule was removed again and bwsafe cannot be used. Nothing runs as $SVC." >&2
  echo "Please report this (macOS version, chip) so the sandbox profile can be fixed. Uninstall: bash install-macos.sh --uninstall --purge" >&2
  exit 1
fi
