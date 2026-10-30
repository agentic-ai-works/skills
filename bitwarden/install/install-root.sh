#!/usr/bin/env bash
# Privileged half of the installer. Normally started by install.sh through pkexec, but
# `sudo bash install-root.sh [--uninstall [--purge]]` works as well.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo or pkexec (or use install.sh)" >&2; exit 1; }
OWNER="${SUDO_USER:-}"
if [ -z "$OWNER" ] && [ -n "${PKEXEC_UID:-}" ]; then OWNER="$(id -nu "$PKEXEC_UID")"; fi
[ -n "$OWNER" ] && [ "$OWNER" != root ] || { echo "run it from your normal account" >&2; exit 1; }
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
OWNER_UID="$(id -u "$OWNER")"
# install.sh passes the verified text of this script with `bash -c`, plus SKILL_DIR and CORE_SHA256.
if [ -z "${SKILL_DIR:-}" ]; then SKILL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"; fi
CORE_SRC="$SKILL_DIR/scripts/bwsafe-core"
# Bitwarden's official CLI, pinned: version and the SHA-256 that Bitwarden's GitHub release publishes for each zip.
BW_VERSION="2026.10.0"
BW_SHA256_AMD64="269b67559caab860d1737f7554b32bdb8be9285d5689fee55193c137a0df9973"
BW_SHA256_ARM64="2fe9d8a18dc4c35ea2f9e3e42a4021f14f129ef47e80b6cea1e3b34176f1583a"
DISPLAY_VAL="${DISPLAY_VAL:-:1}"
XAUTH="${XAUTH:-}"
if [ -z "$XAUTH" ]; then
  for c in "/run/user/$OWNER_UID/gdm/Xauthority" "$OWNER_HOME/.Xauthority" /run/user/$OWNER_UID/.mutter-Xwaylandauth.*; do [ -f "$c" ] && { XAUTH="$c"; break; }; done
fi
SVC=bwsafe
AUTOSTART="$OWNER_HOME/.config/autostart/bwsafe-xhost.desktop"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f /etc/sudoers.d/bwsafe /etc/tmpfiles.d/bwsafe.conf "$AUTOSTART"
  rm -rf /opt/bwsafe /run/bwsafe
  if [ "${2:-}" = "--purge" ]; then userdel "$SVC" 2>/dev/null || true; rm -rf /var/lib/bwsafe; echo "removed, vault cache and user deleted"
  else echo "removed; user and /var/lib/bwsafe kept (use --uninstall --purge to delete them)"; fi
  exit 0
fi

for b in bwrap jq xhost; do command -v "$b" >/dev/null || { echo "missing: $b" >&2; exit 1; }; done
[ -x /usr/bin/zenity ] || { echo "missing: zenity (apt install zenity)" >&2; exit 1; }
[ -f "$CORE_SRC" ] || { echo "core script not found: $CORE_SRC" >&2; exit 1; }

# Everything below works on copies in a root-only directory, so nobody can swap a file after it was checked.
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

echo "== check the helper script"
cp "$CORE_SRC" "$W/core"
WANT_CORE="${CORE_SHA256:-$(awk '$2=="scripts/bwsafe-core"{print $1}' "$SKILL_DIR/SHA256SUMS" 2>/dev/null || true)}"
if [ -z "$WANT_CORE" ]; then
  [ "${BWSAFE_ALLOW_UNVERIFIED:-}" = 1 ] || { echo "no checksum to verify the helper script against (use install.sh, or set BWSAFE_ALLOW_UNVERIFIED=1 knowingly)" >&2; exit 1; }
  echo "WARNING: helper script not verified"
elif [ "$(sha256sum "$W/core" | cut -d' ' -f1)" != "$WANT_CORE" ]; then
  echo "helper script does not match its checksum; aborting" >&2; exit 1
fi
bash -n "$W/core"

# Where does the bw binary come from? An explicit BW_SRC (you chose it), a root-owned copy from an earlier install, or a pinned download.
BW_FROM=""
for c in "${BW_SRC:-}" /opt/bwsafe/bin/bw /opt/bwtotp/bin/bw; do
  if [ -n "$c" ] && [ -x "$c" ]; then BW_FROM="$c"; break; fi
done
if [ -n "$BW_FROM" ]; then
  echo "== using the existing bw: $BW_FROM"
  cp "$BW_FROM" "$W/bw"
else
  case "$(uname -m)" in
    x86_64|amd64) BW_ZIP="bw-linux-$BW_VERSION.zip"; BW_WANT="$BW_SHA256_AMD64" ;;
    aarch64|arm64) BW_ZIP="bw-linux-arm64-$BW_VERSION.zip"; BW_WANT="$BW_SHA256_ARM64" ;;
    *) echo "unsupported CPU $(uname -m); set BW_SRC=/path/to/bw" >&2; exit 1 ;;
  esac
  echo "== downloading Bitwarden's official CLI $BW_VERSION (not bundled with this skill)"
  command -v curl >/dev/null && command -v unzip >/dev/null || { echo "need curl and unzip, or set BW_SRC=/path/to/bw" >&2; exit 1; }
  curl -fsSL "https://github.com/bitwarden/clients/releases/download/cli-v$BW_VERSION/$BW_ZIP" -o "$W/bw.zip"
  [ "$(sha256sum "$W/bw.zip" | cut -d' ' -f1)" = "$BW_WANT" ] || { echo "downloaded bw does not match the pinned checksum; aborting" >&2; exit 1; }
  echo "checksum ok ($BW_WANT)"
  unzip -q "$W/bw.zip" bw -d "$W"
fi

echo "== retire the older setups (rbw agent service, separate bwtotp user)"
systemctl disable --now bwsafe-agent.service 2>/dev/null || true
rm -f /etc/systemd/system/bwsafe-agent.service; systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/bwsafe/bin/rbw /opt/bwsafe/bin/rbw-agent /opt/bwsafe/bin/pinentry-zenity /opt/bwsafe/libexec/bwsafe-editor
rm -rf /var/lib/bwsafe/config /var/lib/bwsafe/data /var/lib/bwsafe/cache /var/lib/bwsafe/state
rm -f /etc/sudoers.d/bwtotp /etc/tmpfiles.d/bwtotp.conf "$OWNER_HOME/.config/autostart/bwtotp-xhost.desktop"
rm -rf /opt/bwtotp /run/bwtotp /var/lib/bwtotp
id bwtotp >/dev/null 2>&1 && userdel bwtotp 2>/dev/null || true

echo "== user and directories"
id "$SVC" >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/bwsafe --no-create-home "$SVC"
install -d -o "$SVC" -g "$SVC" -m 700 /var/lib/bwsafe
install -d -o root -g root -m 755 /opt/bwsafe /opt/bwsafe/bin /opt/bwsafe/libexec

echo "== root-owned programs (bw sha256 below; compare with Bitwarden's release if you like)"
install -o root -g root -m 755 "$W/bw" /opt/bwsafe/bin/bw
sha256sum /opt/bwsafe/bin/bw
sed "s|^export DISPLAY=.*|export DISPLAY=\"$DISPLAY_VAL\"|" "$W/core" > "$W/core.out"
install -o root -g root -m 755 "$W/core.out" /opt/bwsafe/libexec/bwsafe-core

echo "== runtime dir (tmpfs, holds the 24 h session key)"
printf 'd /run/bwsafe 0700 %s %s -\n' "$SVC" "$SVC" > /etc/tmpfiles.d/bwsafe.conf
systemd-tmpfiles --create /etc/tmpfiles.d/bwsafe.conf

echo "== sudoers: $OWNER may run exactly one program, as $SVC, without a password"
printf '%s ALL=(%s) NOPASSWD: /opt/bwsafe/libexec/bwsafe-core\n' "$OWNER" "$SVC" > "$W/sudoers"
visudo -cf "$W/sudoers" >/dev/null
install -o root -g root -m 440 "$W/sudoers" /etc/sudoers.d/bwsafe

echo "== desktop access for the dialogs (X11: lets only user $SVC open windows)"
install -d -o "$OWNER" -g "$OWNER" "$OWNER_HOME/.config/autostart"
cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=bwsafe dialog access
Exec=xhost +SI:localuser:$SVC
NoDisplay=true
EOF
chown "$OWNER:$OWNER" "$AUTOSTART"
runuser -u "$OWNER" -- env DISPLAY="$DISPLAY_VAL" XAUTHORITY="$XAUTH" xhost "+SI:localuser:$SVC" || echo "(could not run xhost now; it will run at your next login)"

echo "== self-test"
if ! runuser -u "$OWNER" -- sudo -n -u "$SVC" /opt/bwsafe/libexec/bwsafe-core selftest; then
  rm -f /etc/sudoers.d/bwsafe
  echo "The self-test FAILED, so the sudo rule was removed again and bwsafe cannot be used. Please report this." >&2
  exit 1
fi
echo
echo "Done. Next: 'bwsafe setup' (dialogs on the desktop: bitwarden.com, .eu or self-hosted)."
