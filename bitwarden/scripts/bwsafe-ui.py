#!/usr/bin/env python3
"""bwsafe-ui: the dialog helper for the macOS port of bwsafe (UNTESTED on a real Mac).

The core (bwsafe-core) may run as the hidden user _bwsafe, which cannot open windows in your
login session. This helper does that part, in your session, with osascript:

  bwsafe-ui.py ask                  read one JSON request on stdin, show the dialog, print one JSON reply
  bwsafe-ui.py serve SOCK [--allow USER] [--group GROUP] [--uid UID]
                                    (--uid: do nothing unless run by that uid)
                                    listen on a Unix socket; only the account USER (default _bwsafe)
                                    may ask. Runs as a LaunchAgent in your session.
  bwsafe-ui.py client SOCK          send the request on stdin to a `serve` process, print its reply

Request:  {"kind": "entry|question|radio|checklist", "title", "text", "seconds", "ok", "cancel",
           "hide": bool, "items": [{"key", "label", "on"}]}
Reply:    {"ok": true, "value": ...}  or  {"ok": false}.   Only a clean positive answer is ok:
          Cancel, close, timeout, crash and malformed input are all {"ok": false} (fail closed).
          value: typed text (entry), "" (question), list of chosen keys (radio, checklist).

Standard library only. Set BWSAFE_OSASCRIPT to replace osascript (used by the tests).
"""
import json
import os
import pwd
import grp
import socket
import struct
import subprocess
import sys

OSASCRIPT = os.environ.get("BWSAFE_OSASCRIPT", "/usr/bin/osascript")
MAX_REQ = 65536
KINDS = ("entry", "question", "radio", "checklist")


def q(s):
    """An AppleScript string literal (backslash and quote escaped, newlines as linefeed)."""
    s = str(s).replace("\\", "\\\\").replace('"', '\\"')
    return '"' + s.replace("\r\n", "\n").replace("\r", "\n").replace("\n", '" & linefeed & "') + '"'


def label_list(labels):
    return "{" + ", ".join(q(x) for x in labels) + "}"


def build(req):
    """Return (applescript, labels->keys map or None)."""
    kind = req["kind"]
    title, text = str(req.get("title", "")), str(req.get("text", ""))
    ok = str(req.get("ok") or "OK")
    cancel = str(req.get("cancel") or "Cancel")
    secs = max(1, min(int(req.get("seconds", 120)), 900))
    pre = "try\n tell current application to activate\nend try\n"
    if kind == "entry":
        hid = " with hidden answer" if req.get("hide") else ""
        return (pre + "set r to display dialog %s default answer \"\"%s with title %s buttons {%s, %s} "
                "default button %s cancel button %s giving up after %d\n"
                "if gave up of r then error number -128\nreturn text returned of r\n"
                % (q(text), hid, q(title), q(cancel), q(ok), q(ok), q(cancel), secs)), None
    if kind == "question":
        # the default button is Cancel, so a stray Return key never approves
        return (pre + "set r to display dialog %s with title %s buttons {%s, %s} default button %s "
                "cancel button %s giving up after %d\n"
                "if gave up of r then error number -128\nreturn button returned of r\n"
                % (q(text), q(title), q(cancel), q(ok), q(cancel), q(cancel), secs)), None
    items = req.get("items") or []
    labels, mapping, defaults, seen = [], {}, [], set()
    for it in items:
        lab = str(it.get("label", it.get("key", "")))
        base, n = lab, 2
        while lab in seen:
            lab = "%s (%d)" % (base, n)
            n += 1
        seen.add(lab)
        labels.append(lab)
        mapping[lab] = str(it["key"])
        if it.get("on"):
            defaults.append(lab)
    if not labels:
        raise ValueError("no items")
    multi = " with multiple selections allowed and empty selection allowed" if kind == "checklist" else ""
    dflt = (" default items " + label_list(defaults)) if defaults else ""
    if kind == "radio" and len(defaults) > 1:
        dflt = " default items " + label_list(defaults[:1])
    return (pre + "set r to choose from list %s with prompt %s with title %s OK button name %s "
            "cancel button name %s%s%s\n"
            "if r is false then error number -128\n"
            "set AppleScript's text item delimiters to linefeed\nreturn r as text\n"
            % (label_list(labels), q(text), q(title), q(ok), q(cancel), dflt, multi)), mapping


def ask(req):
    """Show the dialog; return the reply dict. Never raises."""
    try:
        if not isinstance(req, dict) or req.get("kind") not in KINDS:
            return {"ok": False}
        script, mapping = build(req)
        secs = max(1, min(int(req.get("seconds", 120)), 900))
        p = subprocess.run([OSASCRIPT, "-e", script], capture_output=True, text=True, timeout=secs + 5)
        if p.returncode != 0:
            return {"ok": False}
        out = p.stdout.rstrip("\n")
        kind = req["kind"]
        if kind == "entry":
            return {"ok": True, "value": out}
        if kind == "question":
            return {"ok": out == str(req.get("ok") or "OK"), "value": ""}
        chosen = [mapping[x] for x in out.split("\n") if x in mapping] if out else []
        if kind == "radio" and not chosen:
            return {"ok": False}
        return {"ok": True, "value": chosen}
    except Exception:
        return {"ok": False}


def peer_uid(conn):
    """The uid of the process on the other end of a Unix socket, or None."""
    try:
        if sys.platform == "darwin":
            # getsockopt(SOL_LOCAL=0, LOCAL_PEERCRED=1) -> struct xucred { u_int version; uid_t uid; ... }
            raw = conn.getsockopt(0, 1, 76)
            return struct.unpack("II", raw[:8])[1]
        raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        return struct.unpack("3i", raw)[1]
    except Exception:
        return None


def read_line(conn):
    buf = b""
    while b"\n" not in buf and len(buf) < MAX_REQ:
        chunk = conn.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf.split(b"\n", 1)[0]


def serve(path, user, group):
    try:
        allowed = pwd.getpwnam(user).pw_uid
    except KeyError:
        sys.exit("bwsafe-ui: no such account: " + user)
    old = os.umask(0o117)
    try:
        if os.path.exists(path):
            os.unlink(path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
    finally:
        os.umask(old)
    os.chmod(path, 0o660)
    if group:
        try:   # on macOS a new file inherits the directory's group anyway; chown needs group membership
            os.chown(path, -1, grp.getgrnam(group).gr_gid)
        except (KeyError, PermissionError, OSError):
            pass
    srv.listen(4)
    while True:
        conn, _ = srv.accept()
        try:
            conn.settimeout(10)
            uid = peer_uid(conn)
            if uid is None or uid != allowed:
                conn.sendall(b'{"ok":false}\n')   # not the core: refuse without showing anything
                continue
            try:
                req = json.loads(read_line(conn).decode("utf-8"))
            except Exception:
                req = None
            conn.settimeout(None)
            conn.sendall((json.dumps(ask(req)) + "\n").encode())
        except Exception:
            pass
        finally:
            conn.close()


def client(path):
    data = sys.stdin.buffer.readline()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.sendall(data if data.endswith(b"\n") else data + b"\n")
    print(read_line(s).decode("utf-8"))


def main(argv):
    if len(argv) >= 2 and argv[1] == "ask":
        try:
            req = json.loads(sys.stdin.read(MAX_REQ))
        except Exception:
            req = None
        print(json.dumps(ask(req)))
    elif len(argv) >= 3 and argv[1] == "serve":
        user, group, only_uid, rest = "_bwsafe", None, None, argv[3:]
        while rest:
            if rest[0] == "--allow" and len(rest) > 1:
                user, rest = rest[1], rest[2:]
            elif rest[0] == "--group" and len(rest) > 1:
                group, rest = rest[1], rest[2:]
            elif rest[0] == "--uid" and len(rest) > 1:
                only_uid, rest = int(rest[1]), rest[2:]
            else:
                sys.exit("usage: bwsafe-ui.py serve SOCK [--allow USER] [--group GROUP] [--uid UID]")
        if only_uid is not None and os.getuid() != only_uid:
            sys.exit(0)   # a LaunchAgent for another user's session: nothing to do (exit 0 = launchd does not respawn)
        serve(argv[2], user, group)
    elif len(argv) == 3 and argv[1] == "client":
        client(argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
