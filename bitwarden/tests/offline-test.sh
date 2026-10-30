#!/usr/bin/env bash
# Offline test of bwsafe-core with a fake bw and a fake zenity (dummy data only).
# Needs bwrap, jq. Does not touch the real vault or the installed copy.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state" "$T/run"

cat > "$T/fakebw" <<'EOF'
#!/bin/sh
D=/data/store.json; [ -f $D ] || echo '{"folders":[],"items":[]}' > $D
case "$1 $2" in
 "--version "*) echo 0.0.0-fake; exit 0;;
 "config server") echo "$3" > /data/server; echo "$NODE_EXTRA_CA_CERTS" > /data/caenv; exit 0;;
 "status "*) if [ -f /data/loggedin ]; then s=locked; [ "$BW_SESSION" = SESSIONKEY ] && s=unlocked; else s=unauthenticated; fi; echo "{\"serverUrl\":\"$(cat /data/server 2>/dev/null)\",\"status\":\"$s\"}"; exit 0;;
 "login --apikey") [ -n "$BW_CLIENTID" ] && [ -n "$BW_CLIENTSECRET" ] && touch /data/loggedin && exit 0; exit 1;;
 "unlock --passwordenv") [ "$BW_PASSWORD" = pw123 ] && printf SESSIONKEY && exit 0; echo bad >&2; exit 1;;
 "lock "*|"logout "*) exit 0;;
 "generate "*) echo "Gen3rated-Passw0rd-xyz"; exit 0;;
 encode*) base64 -w0; exit 0;;
esac
[ "$BW_SESSION" = SESSIONKEY ] || { echo "not unlocked" >&2; exit 1; }
case "$1 $2" in
 "sync"*) exit 0;;
 "list items") if [ -n "$4" ]; then jq --arg s "$4" '.items|map(select(.name|contains($s)))' $D; else jq '.items' $D; fi;;
 "list folders") jq '.folders' $D;;
 "create folder") j=$(base64 -d); id=f$(date +%N); jq --arg id $id --argjson f "$j" '.folders+=[{id:$id,name:$f.name}]' $D > $D.n && mv $D.n $D; echo "{\"id\":\"$id\"}";;
 "create item") j=$(base64 -d); id=i$(date +%N); jq --arg id $id --argjson f "$j" '.items+=[$f+{id:$id}]' $D > $D.n && mv $D.n $D;;
 "get item") jq -c --arg id "$3" '.items[]|select(.id==$id)' $D;;
 "get password") jq -r --arg id "$3" '.items[]|select(.id==$id)|.login.password' $D;;
 "get username") jq -r --arg id "$3" '.items[]|select(.id==$id)|.login.username' $D;;
 "get totp") t=$(jq -r --arg id "$3" '.items[]|select(.id==$id)|.login.totp' $D); [ "$t" != null ] && echo 123456 || exit 1;;
 "edit item") j=$(base64 -d); jq --arg id "$3" --argjson f "$j" '.items|=map(if .id==$id then $f else . end)' $D > $D.n && mv $D.n $D;;
 "delete item") jq --arg id "$3" '.items|=map(select(.id!=$id))' $D > $D.n && mv $D.n $D;;
 *) echo "fake bw: unhandled $*" >&2; exit 1;;
esac
EOF
cat > "$T/zenity" <<'EOF'
#!/bin/bash
case " $* " in
  *" --entry "*) v=$(head -n1 "$FAKE_PIN_FILE"); sed -i 1d "$FAKE_PIN_FILE"; if [ -n "$v" ]; then echo "$v"; exit 0; else exit 1; fi;;
  *" --list "*) v=$(head -n1 "$FAKE_LIST_FILE"); sed -i 1d "$FAKE_LIST_FILE"; tr ' ' '\n' <<<"$v"; exit 0;;
  *" --question "*) if [ "$FAKE_APPROVE" = yes ]; then exit 0; else exit 1; fi;;
esac
exit 1
EOF
chmod +x "$T/fakebw" "$T/zenity"

sed -e "s#^BW_BIN=.*#BW_BIN=\"$T/fakebw\"#" -e "s#^STATE=.*#STATE=\"$T/state\"#" -e "s#^RUN=.*#RUN=\"$T/run\"#" \
    -e "s#^ZENITY=.*#ZENITY=\"$T/zenity\"#" "$HERE/../scripts/bwsafe-core" > "$T/core-tls"
sed -e 's#^TLS_CHECK=1#TLS_CHECK=0#' "$T/core-tls" > "$T/core"   # most tests use fake host names: no certificate probe
chmod +x "$T/core" "$T/core-tls"
export FAKE_PIN_FILE="$T/pins" FAKE_LIST_FILE="$T/lists" FAKE_APPROVE=yes DISPLAY=:1
fail=0
run() { OUT="$("${CORE:-$T/core}" "$@" 2>&1)"; RC=$?; }
expect() { # expect RC SUBSTRING DESC
  if [ "$RC" = "$1" ] && [[ "$OUT" == *"$2"* ]]; then echo "ok   $3"; else echo "FAIL $3 (rc=$RC) $OUT"; fail=1; fi
}
nogo() { # nogo SUBSTRING-that-must-be-absent DESC
  if [[ "$OUT" != *"$1"* ]]; then echo "ok   $2"; else echo "FAIL $2: $OUT"; fail=1; fi
}

run list;                                       expect 5 "no permissions" "no policy => nothing allowed"
run setup --server http://evil.test;            expect 2 "not a usable server" "http to a remote host is refused"
run setup --server "https://a b";               expect 2 "not a usable server" "server with a space is refused"
run setup --server ftp://x.test;                expect 2 "not a usable server" "non-https scheme is refused"
run setup --us --eu;                            expect 2 "exclusive" "two server flags are refused"
# server picked in the dialog: self-hosted, address typed (trailing slash is stripped)
printf 'https://vault.example.com/\nuser.abc\nsecret\npw123\n' > "$FAKE_PIN_FILE"
# dialogs: server radio, then configure: actions, folders, secrets
printf 'self\nread add update delete\n__all__\npwd totp\n' > "$FAKE_LIST_FILE"
run setup me@x.test;                            expect 0 "permissions saved" "setup: dialog-chosen self-hosted server + login + unlock + configure"
run status;                                     expect 0 "server: https://vault.example.com " "self-hosted server was set"
# a second account on the EU cloud via flag (forget the login first)
rm -f "$T"/state/*/loggedin
printf 'user.abc\nsecret\npw123\n' > "$FAKE_PIN_FILE"
printf 'read add update delete\n__all__\npwd totp\n' > "$FAKE_LIST_FILE"
run setup me@x.eu --eu;                         expect 0 "permissions saved" "setup with --eu"
run status;                                     expect 0 "server: https://vault.bitwarden.eu" "EU server was set"
[ ! -e "$T/state/extra-ca.pem" ] && echo "ok   no extra certificate for a normal server" || { echo "FAIL extra certificate present for a normal server"; fail=1; }

# self-hosted server with a self-signed certificate (local TLS server; skipped without openssl)
if command -v openssl >/dev/null && command -v curl >/dev/null; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 2 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
  PORT=$((20000 + RANDOM % 20000))
  openssl s_server -accept "$PORT" -cert "$T/c.pem" -key "$T/k.pem" -www -quiet >/dev/null 2>&1 & SRV=$!
  trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
  sleep 1
  SELF="https://localhost:$PORT"
  setup_pins() { printf 'user.abc\nsecret\npw123\n' > "$FAKE_PIN_FILE"; printf 'read add update delete\n__all__\npwd totp\n' > "$FAKE_LIST_FILE"; }
  rm -f "$T"/state/*/loggedin; setup_pins
  CORE="$T/core-tls"
  FAKE_APPROVE=no run setup --server "$SELF";   expect 6 "not trusted" "declining the self-signed certificate cancels setup"
  [ ! -e "$T/state/extra-ca.pem" ] && echo "ok   declined certificate was not stored" || { echo "FAIL declined certificate stored"; fail=1; }
  setup_pins
  run setup --server "$SELF";                   expect 0 "trusted certificate" "approving the self-signed certificate"
  [ -s "$T/state/extra-ca.pem" ] && echo "ok   certificate stored" || { echo "FAIL certificate not stored"; fail=1; }
  [ "$(cat "$T"/state/bwdata/caenv)" = "/opt/extra-ca.pem" ] && echo "ok   sandbox gets NODE_EXTRA_CA_CERTS" || { echo "FAIL sandbox lacks NODE_EXTRA_CA_CERTS"; fail=1; }
  run status;                                   expect 0 "trusted private certificate" "status shows the trusted certificate"
  rm -f "$T"/state/*/loggedin; setup_pins
  run setup --eu;                               expect 0 "permissions saved" "switching back to a public server"
  [ ! -e "$T/state/extra-ca.pem" ] && echo "ok   certificate dropped when the server changes" || { echo "FAIL certificate kept"; fail=1; }
  CORE=""
  kill "$SRV" 2>/dev/null
else
  echo "skip self-signed certificate tests (openssl or curl missing)"
fi

run generate GitHub jens;                       expect 0 "random password" "generate"
nogo "Gen3rated" "generated password not echoed"
run generate GitHub jens;                       expect 7 "already exists" "generate never overwrites"
run add Site bob --uri https://x.test --stdin <<< 'hunter2'; expect 0 "stored" "add"
run add Site bob --stdin <<< 'other';           expect 7 "already exists" "add never overwrites"
run list;                                       expect 0 "GitHub" "list shows entries"
run list --folder OpenClaw;                     expect 0 "OpenClaw" "list by folder"
run search Site;                                expect 0 "bob" "search"
run fields Site bob;                            expect 0 "password" "fields"
run user Site bob;                              expect 0 "bob" "user"
run secret --purpose run Site bob;              expect 0 "hunter2" "secret (for run/reveal)"
run addkey Site bob --stdin <<< 'JBSWY3DPEHPK3PXP'; expect 0 "attached" "addkey on existing entry"
run addkey Site bob --stdin <<< 'JBSWY3DPEHPK3PXP'; expect 7 "already has" "addkey refuses to replace"
run addkey Bad --stdin <<< 'not a key!!';       expect 2 "does not look like" "bad key rejected"
run code Site bob;                              expect 0 "123456" "code"
run code Nope;                                  expect 4 "no entry" "missing entry"

FAKE_APPROVE=no run edit Site bob --stdin <<< 'new1'; expect 6 "not approved" "edit denied"
run edit Site bob --stdin <<< 'new1';           expect 0 "replaced" "edit approved"
run secret Site bob;                            expect 0 "new1" "edit took effect"
FAKE_APPROVE=no run setkey Site bob --stdin <<< 'KRSXG5CTMVRXEZLU'; expect 6 "not approved" "setkey denied"
run setkey Site bob --stdin <<< 'KRSXG5CTMVRXEZLU'; expect 0 "replaced" "setkey approved"
FAKE_APPROVE=no run rmkey Site bob;             expect 6 "not approved" "rmkey denied"
run rmkey Site bob;                             expect 0 "removed" "rmkey approved"
FAKE_APPROVE=no run remove Site bob;            expect 6 "not approved" "remove denied"
run remove Site bob;                            expect 0 "trash" "remove approved"

# --- policy: only folder OpenClaw, read+add, passwords only ---
FID="$(jq -r '.folders[]|select(.name=="OpenClaw")|.id' "$T/state/bwdata/store.json")"
jq -nc --arg f "$FID" '{read:true,add:true,update:false,delete:false,pwd:true,totp:false,all:false,nofolder:false,folderIds:[$f],folderNames:["OpenClaw"]}' > "$T/state/policy.json"
# an entry outside the allowed folder
jq '.items+=[{id:"iOUT",type:1,name:"Outside",folderId:null,login:{username:"u",password:"p",totp:"JBSWY3DPEHPK3PXP"}}]' "$T/state/bwdata/store.json" > "$T/s.n" && mv "$T/s.n" "$T/state/bwdata/store.json"
run list;                                       nogo "Outside" "list hides entries outside the folder scope"
run secret Outside;                             expect 4 "no entry" "entry outside scope unreachable"
run code GitHub jens;                           expect 5 "'totp' is switched off" "totp blocked by policy"
run edit GitHub jens --stdin <<< 'x';           expect 5 "'update'" "update blocked by policy"
run remove GitHub jens;                         expect 5 "'delete'" "delete blocked by policy"
run add Elsewhere --folder Nope --stdin <<< 'x'; expect 4 "no folder named" "unknown folder"
run add Unfiled --no-folder --stdin <<< 'x';    expect 5 "not permitted" "unfoldered add blocked by policy"
run add Fine --stdin <<< 'x';                   expect 0 "stored" "add inside allowed folder"
run list;                                       expect 0 "n/a" "TOTP column is n/a when totp is off"
nogo "yes" "no key info leaks when totp is off"

run lock;                                       expect 0 "locked" "lock"
run list;                                       expect 3 "locked" "locked after lock"
run log 80;                                     expect 0 "approved:edit" "audit log"
if grep -q 'JBSWY3DPEHPK3PXP\|pw123\|SESSIONKEY\|KRSXG5\|hunter2\|new1\|Gen3rated' "$T/state/audit.log"; then echo "FAIL secret in audit log"; fail=1; else echo "ok   no secrets in audit log"; fi
run selftest;                                   expect 0 "selftest passed" "selftest: sandbox works and is closed"
[ ! -e "$T/state/selftest-canary" ] && echo "ok   selftest cleans up its canary" || { echo "FAIL canary left behind"; fail=1; }
[ "$(stat -c %a "$T/state")" = 700 ] && echo "ok   state dir is 700" || { echo "FAIL state perms"; fail=1; }
exit $fail
