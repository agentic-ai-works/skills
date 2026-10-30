#!/usr/bin/env bash
# Static checks of the macOS pieces on any OS (the real thing needs a Mac): syntax, bash 3.2 habits,
# the CONFIG rewrite the installers do, AppleScript quoting, and the sandbox profile's structure.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"; S="$HERE/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

for f in scripts/bwsafe scripts/bwsafe-core install/install-macos.sh install/install-macos-root.sh; do
  bash -n "$S/$f" && ok "syntax: $f" || bad "syntax: $f"
done
python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$S/scripts/bwsafe-ui.py" && ok "syntax: bwsafe-ui.py" || bad "syntax: bwsafe-ui.py"

# the installers run under macOS's bash 3.2: no bash-4 only syntax
if grep -nE '\$\{[A-Za-z_]+(,,|\^\^)\}|declare -A|mapfile|readarray|\&\>>|\|\&' "$S"/install/install-macos*.sh "$S/scripts/bwsafe" >"$T/b4"; then bad "bash-4-only syntax in the macOS installers or client: $(head -3 "$T/b4")"; else ok "installers and client avoid bash-4-only syntax"; fi
if grep -nE '(^|[^[:alnum:]_])(sha256sum|readlink -f|stat -c|sed -i |date -d|base64 -d)' "$S"/install/install-macos*.sh | grep -v '^\S*:[0-9]*:\s*#' >"$T/gnu"; then bad "GNU-only tools in the macOS installers: $(head -3 "$T/gnu")"; else ok "installers avoid GNU-only tools"; fi

# AppleScript quoting helper from install-macos.sh
eval "$(sed -n '/^aq() /p' "$S/install/install-macos.sh")"
[ "$(aq 'a "b" \c')" = '"a \"b\" \\c"' ] && ok "aq: quotes and backslashes" || bad "aq: $(aq 'a "b" \c')"
[ "$(aq $'l1\nl2')" = '"l1" & linefeed & "l2"' ] && ok "aq: newlines" || bad "aq newline: $(aq $'l1\nl2')"

# the CONFIG rewrite (Easy installer and root installer use the same sed rules)
BASE="/Users/x/Library/Application Support/bwsafe"; BASH_BIN=/opt/homebrew/bin/bash; PYTHON_BIN=/usr/bin/python3; JQ_BIN_ABS=/opt/homebrew/bin/jq
sed -e "1s|.*|#!$BASH_BIN|" \
    -e "s|^BW_BIN=.*|BW_BIN=\"$BASE/bin/bw\"|" -e "s|^STATE=.*|STATE=\"$BASE/state\"|" -e "s|^RUN=.*|RUN=\"$BASE/state/run\"|" \
    -e "s|^SANDBOX=.*|SANDBOX=\"seatbelt\"|" -e "s|^UI_MODE=.*|UI_MODE=\"direct\"|" -e "s|^PYTHON=.*|PYTHON=\"$PYTHON_BIN\"|" \
    -e "s|^UI_HELPER=.*|UI_HELPER=\"$BASE/bin/bwsafe-ui.py\"|" -e "s|^SB_PROFILE=.*|SB_PROFILE=\"$BASE/bin/bwsafe.sb\"|" -e "s|^JQ_BIN=.*|JQ_BIN=\"$JQ_BIN_ABS\"|" \
    "$S/scripts/bwsafe-core" > "$T/core.mac"
bash -n "$T/core.mac" && ok "rewritten core still parses" || bad "rewritten core does not parse"
[ "$(head -1 "$T/core.mac")" = "#!$BASH_BIN" ] && ok "shebang points at the new bash" || bad "shebang"
for want in "SANDBOX=\"seatbelt\"" "UI_MODE=\"direct\"" "BW_BIN=\"$BASE/bin/bw\"" "SB_PROFILE=\"$BASE/bin/bwsafe.sb\"" "JQ_BIN=\"$JQ_BIN_ABS\""; do
  grep -qxF "$want" <(sed -n '1p;/^# --- CONFIG/,/^# --- END CONFIG/p' "$T/core.mac" | sed 's/ *#.*$//') && ok "config line: $want" || bad "config line missing: $want"
done
grep -c '^UI_SOCK=""' "$T/core.mac" | grep -qx 1 && ok "Easy leaves UI_SOCK empty" || bad "UI_SOCK"
# every setting the installers rewrite must exist exactly once in the core
for k in BW_BIN STATE RUN SANDBOX UI_MODE PYTHON UI_HELPER UI_SOCK SB_PROFILE JQ_BIN; do
  [ "$(grep -c "^$k=" "$S/scripts/bwsafe-core")" = 1 ] && ok "core has exactly one $k=" || bad "core $k= count"
done

# sandbox profile: balanced parentheses, deny default, only the intended writable places
python3 - "$S/scripts/bwsafe.sb" <<'EOF' && ok "profile: parentheses balance" || bad "profile: parentheses do not balance"
import sys,re
t=re.sub(r';.*','',open(sys.argv[1]).read()); t=re.sub(r'"[^"]*"','""',t)
d=0
for c in t:
    d+= (c=='(') - (c==')')
    if d<0: sys.exit(1)
sys.exit(0 if d==0 else 1)
EOF
grep -q '^(deny default)' "$S/scripts/bwsafe.sb" && ok "profile: deny by default" || bad "profile: no deny default"
W="$(awk '/file-write\*/{f=1} f&&/subpath|literal/{print} /^$/{f=0}' "$S/scripts/bwsafe.sb" | grep -o '"[^"]*"\|param "[A-Z]*"' | tr '\n' ' ')"
case "$W" in *'"/Users'*|*'"/private/var"'*|*'"/tmp'*|*'"/"'*) bad "profile: unexpected writable path: $W" ;; *) ok "profile: writable only DATA, TMPD and /dev/null" ;; esac
# the selftest must be wired into both installers
for f in install/install-macos.sh install/install-macos-root.sh; do grep -q 'selftest' "$S/$f" && ok "selftest runs in $f" || bad "no selftest in $f"; done
# SHA256SUMS must list every file the macOS installers use
for f in scripts/bwsafe-ui.py scripts/bwsafe.sb install/install-macos.sh install/install-macos-root.sh; do grep -q " $f\$" "$S/SHA256SUMS" && ok "SHA256SUMS lists $f" || bad "SHA256SUMS lacks $f (run tools/make-sums.sh)"; done
exit $fail
