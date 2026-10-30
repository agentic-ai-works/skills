#!/usr/bin/env bash
# Test of bwsafe-ui.py (the macOS dialog helper) and of the core's macOS dialog bridge, on any OS,
# with a fake osascript. This tests the logic (JSON, AppleScript quoting, key mapping, fail-closed
# rules, the socket's peer check). It cannot test how real macOS dialogs look: that needs a Mac.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UI="$HERE/../scripts/bwsafe-ui.py"
T="$(mktemp -d)"; trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
SRV=""
fail=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2 / want: $3)"; fi; }

cat > "$T/osa" <<'EOF'
#!/bin/sh
# fake osascript -e SCRIPT: log the script; answer from FAKE_OSA_OUT / FAKE_OSA_RC / FAKE_OSA_SLEEP
printf '%s\n--END--\n' "$2" >> "$FAKE_OSA_LOG"
[ -n "$FAKE_OSA_SLEEP" ] && sleep "$FAKE_OSA_SLEEP"
[ -n "$FAKE_OSA_OUT" ] && printf '%s\n' "$FAKE_OSA_OUT"
exit "${FAKE_OSA_RC:-0}"
EOF
chmod +x "$T/osa"
export BWSAFE_OSASCRIPT="$T/osa" FAKE_OSA_LOG="$T/osa.log"
PY="python3 -I"
req() { $PY "$UI" ask <<<"$1"; }
val() { jq -c "$2" <<<"$1"; }

# --- entry ---
R="$(FAKE_OSA_OUT='s3cret"x' req '{"kind":"entry","title":"T","text":"Type \"it\"\nline2","seconds":30,"ok":"OK","cancel":"Cancel","hide":true}')"
check "entry returns the typed text" "$(val "$R" '.value')" '"s3cret\"x"'
grep -q 'with hidden answer' "$T/osa.log" && ok "hide => hidden answer" || bad "hide => hidden answer"
grep -q 'Type \\"it\\"" & linefeed & "line2' "$T/osa.log" && ok "quotes and newlines are escaped in AppleScript" || bad "AppleScript escaping"
grep -q 'giving up after 30' "$T/osa.log" && ok "timeout passed to the dialog" || bad "timeout missing"
: > "$T/osa.log"; R="$(FAKE_OSA_OUT=x req '{"kind":"entry","title":"T","text":"x","seconds":5,"hide":false}')"
grep -q 'hidden answer' "$T/osa.log" && bad "no hide => no hidden answer" || ok "no hide => visible entry"
# --- cancel / error / timeout => not ok ---
R="$(FAKE_OSA_RC=1 req '{"kind":"entry","title":"T","text":"x","seconds":5}')"
check "cancel (osascript rc 1) is a no" "$(val "$R" '.ok')" false
R="$(FAKE_OSA_SLEEP=8 req '{"kind":"entry","title":"T","text":"x","seconds":1}')"
check "a hung dialog times out as a no" "$(val "$R" '.ok')" false
R="$(req 'not json')"
check "garbage input is a no" "$(val "$R" '.ok')" false
R="$(req '{"kind":"shell","title":"T"}')"
check "unknown kind is a no" "$(val "$R" '.ok')" false
# --- question ---
R="$(FAKE_OSA_OUT=Approve req '{"kind":"question","title":"T","text":"ok?","seconds":10,"ok":"Approve","cancel":"Deny"}')"
check "question: Approve button" "$(val "$R" '.ok')" true
R="$(FAKE_OSA_OUT=Deny req '{"kind":"question","title":"T","text":"ok?","seconds":10,"ok":"Approve","cancel":"Deny"}')"
check "question: Deny button" "$(val "$R" '.ok')" false
R="$(FAKE_OSA_OUT= req '{"kind":"question","title":"T","text":"ok?","seconds":10,"ok":"Approve","cancel":"Deny"}')"
check "question: empty answer is a no" "$(val "$R" '.ok')" false
: > "$T/osa.log"; FAKE_OSA_OUT=Approve req '{"kind":"question","title":"T","text":"ok?","seconds":10,"ok":"Approve","cancel":"Deny"}' >/dev/null
grep -q 'default button "Deny"' "$T/osa.log" && ok "question: Return key defaults to Deny" || bad "default button is not Deny"
# --- radio / checklist: labels map back to keys ---
ITEMS='[{"key":"us","label":"bitwarden.com","on":true},{"key":"eu","label":"bitwarden.eu","on":false},{"key":"self","label":"Self-hosted","on":false}]'
R="$(FAKE_OSA_OUT='bitwarden.eu' req "{\"kind\":\"radio\",\"title\":\"T\",\"text\":\"x\",\"seconds\":10,\"items\":$ITEMS}")"
check "radio: label -> key" "$(val "$R" '.value')" '["eu"]'
R="$(FAKE_OSA_OUT='something else' req "{\"kind\":\"radio\",\"title\":\"T\",\"text\":\"x\",\"seconds\":10,\"items\":$ITEMS}")"
check "radio: unknown label is a no" "$(val "$R" '.ok')" false
R="$(FAKE_OSA_OUT=$'bitwarden.com\nSelf-hosted' req "{\"kind\":\"checklist\",\"title\":\"T\",\"text\":\"x\",\"seconds\":10,\"items\":$ITEMS}")"
check "checklist: several keys" "$(val "$R" '.value')" '["us","self"]'
R="$(FAKE_OSA_OUT= req "{\"kind\":\"checklist\",\"title\":\"T\",\"text\":\"x\",\"seconds\":10,\"items\":$ITEMS}")"
check "checklist: nothing ticked is ok with no keys" "$(val "$R" '.value')" '[]'
grep -q 'multiple selections allowed and empty selection allowed' "$T/osa.log" && ok "checklist allows multiple and empty" || bad "checklist flags"
grep -q 'default items {"bitwarden.com"}' "$T/osa.log" && ok "pre-ticked items are the defaults" || bad "default items"
D='[{"key":"a","label":"Same","on":false},{"key":"b","label":"Same","on":false}]'
R="$(FAKE_OSA_OUT='Same (2)' req "{\"kind\":\"radio\",\"title\":\"T\",\"text\":\"x\",\"seconds\":10,\"items\":$D}")"
check "duplicate labels are made unique" "$(val "$R" '.value')" '["b"]'

# --- socket: peer check ---
SOCK="$T/ui.sock"
FAKE_OSA_OUT=Approve $PY "$UI" serve "$SOCK" --allow "$(id -un)" & SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.3; done
[ -S "$SOCK" ] && ok "helper listens on its socket" || bad "no socket"
[ "$(stat -c %a "$SOCK")" = 660 ] && ok "socket mode 660" || bad "socket mode $(stat -c %a "$SOCK")"
R="$($PY "$UI" client "$SOCK" <<<'{"kind":"question","title":"T","text":"ok?","seconds":10,"ok":"Approve","cancel":"Deny"}')"
check "socket: the allowed account gets its dialog" "$(val "$R" '.ok')" true
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
OTHER="$(getent passwd | awk -F: -v me="$(id -un)" '$1!=me && $3>0 && $3<65000 {print $1; exit}')"
[ -z "$OTHER" ] && OTHER=root
[ "$OTHER" = "$(id -un)" ] && OTHER=nobody
rm -f "$SOCK"   # the killed server leaves its socket file behind; wait for the new one
$PY "$UI" serve "$SOCK" --allow "$OTHER" & SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.3; done
: > "$T/osa.log"
R="$($PY "$UI" client "$SOCK" <<<'{"kind":"question","title":"T","text":"ok?","seconds":10,"ok":"Approve","cancel":"Deny"}')"
check "socket: any other account is refused" "$(val "$R" '.ok')" false
[ ! -s "$T/osa.log" ] && ok "socket: refused request shows no dialog" || bad "dialog shown to a refused peer"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; SRV=""

# --- the core's bridge (UI_MODE=direct and socket), with the fake bw ---
command -v bwrap >/dev/null && command -v jq >/dev/null || { echo "skip core bridge tests (bwrap/jq missing)"; exit $fail; }
mkdir -p "$T/state" "$T/run"
cat > "$T/fakebw" <<'EOF'
#!/bin/sh
D=/data/store.json; [ -f $D ] || echo '{"folders":[],"items":[]}' > $D
case "$1 $2" in
 "--version "*) echo 0.0.0-fake; exit 0;;
 "status "*) echo '{"serverUrl":"https://vault.example.com","status":"unlocked"}'; exit 0;;
esac
[ "$BW_SESSION" = SESSIONKEY ] || { echo "not unlocked" >&2; exit 1; }
case "$1 $2" in
 "sync"*) exit 0;;
 "list items") jq '.items' $D;;
 "list folders") jq '.folders' $D;;
 "create folder") j=$(base64 -d); id=f$(date +%N); jq --arg id $id --argjson f "$j" '.folders+=[{id:$id,name:$f.name}]' $D > $D.n && mv $D.n $D; echo "{\"id\":\"$id\"}";;
 "create item") j=$(base64 -d); id=i$(date +%N); jq --arg id $id --argjson f "$j" '.items+=[$f+{id:$id}]' $D > $D.n && mv $D.n $D;;
 "get password") jq -r --arg id "$3" '.items[]|select(.id==$id)|.login.password' $D;;
 "get item") jq -c --arg id "$3" '.items[]|select(.id==$id)' $D;;
 "delete item") jq --arg id "$3" '.items|=map(select(.id!=$id))' $D > $D.n && mv $D.n $D;;
 encode*) base64 -w0; exit 0;;
 *) echo "fake bw: unhandled $*" >&2; exit 1;;
esac
EOF
chmod +x "$T/fakebw"
printf SESSIONKEY > "$T/run/session"
jq -nc '{read:true,add:true,update:true,delete:true,pwd:true,totp:false,all:true,nofolder:true,folderIds:[],folderNames:[]}' > "$T/state/policy.json"
mk() { sed -e "s#^BW_BIN=.*#BW_BIN=\"$T/fakebw\"#" -e "s#^STATE=.*#STATE=\"$T/state\"#" -e "s#^RUN=.*#RUN=\"$T/run\"#" \
  -e "s#^UI_MODE=.*#UI_MODE=\"$1\"#" -e "s#^UI_HELPER=.*#UI_HELPER=\"$UI\"#" -e "s#^UI_SOCK=.*#UI_SOCK=\"$T/ui.sock\"#" \
  -e "s#^PYTHON=.*#PYTHON=\"$(command -v python3)\"#" -e 's#^TLS_CHECK=1#TLS_CHECK=0#' "$HERE/../scripts/bwsafe-core" > "$T/core-$1"; chmod +x "$T/core-$1"; }
mk direct; mk socket
export DISPLAY=
run() { OUT="$("$CORE" "$@" 2>&1)"; RC=$?; }
CORE="$T/core-direct"
FAKE_OSA_OUT=Deny run remove Nothing;           [ "$RC" = 4 ] && ok "direct: missing entry reported before any dialog" || bad "direct remove nothing rc=$RC"
FAKE_OSA_OUT='pw-from-dialog' run add Site bob --prompt
check "direct: --prompt stores what the dialog returned" "$RC" 0
check "direct: the entry holds the typed password" "$(jq -r '.items[0].login.password' "$T/state/bwdata/store.json")" 'pw-from-dialog'
FAKE_OSA_OUT=Deny run remove Site bob
check "direct: Deny keeps the entry" "$RC" 6
check "direct: entry still there after Deny" "$(jq '.items|length' "$T/state/bwdata/store.json")" 1
FAKE_OSA_OUT=Approve run remove Site bob
check "direct: Approve deletes" "$RC" 0
FAKE_OSA_RC=1 run add Site2 --prompt
check "direct: cancelled password dialog stores nothing" "$RC" 6
PYBAD="$T/nopython"; sed -e "s#^PYTHON=.*#PYTHON=\"$PYBAD\"#" "$T/core-direct" > "$T/core-nopy"; chmod +x "$T/core-nopy"
CORE="$T/core-nopy" run add Site3 --prompt
check "missing helper/python fails closed" "$RC" 6
# socket mode through a real helper process
FAKE_OSA_OUT=viasock $PY "$UI" serve "$T/ui.sock" --allow "$(id -un)" & SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$T/ui.sock" ] && break; sleep 0.3; done
CORE="$T/core-socket"
run add Site4 --prompt
check "socket: --prompt through the helper process" "$RC" 0
check "socket: stored value" "$(jq -r '.items[]|select(.name=="Site4")|.login.password' "$T/state/bwdata/store.json")" viasock
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; SRV=""
FAKE_OSA_OUT=viasock run add Site5 --prompt
check "socket: helper not running fails closed" "$RC" 6
exit $fail
