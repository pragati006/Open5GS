#!/usr/bin/env python3
# Minimal baresip ctrl_tcp client (netstring-framed JSON commands).
# Usage: baresip-ctrl.py <command> [params]
#   e.g. baresip-ctrl.py dial sip:ue1@10.100.0.10
#        baresip-ctrl.py listcalls
#        baresip-ctrl.py hangup
import socket, sys, json

HOST, PORT = "127.0.0.1", 4444
cmd = sys.argv[1] if len(sys.argv) > 1 else "listcalls"
params = sys.argv[2] if len(sys.argv) > 2 else ""

payload = json.dumps({"command": cmd, "params": params})
netstring = f"{len(payload)}:{payload},".encode()

s = socket.create_connection((HOST, PORT), timeout=5)
s.sendall(netstring)
s.settimeout(3)
buf = b""
try:
    while True:
        chunk = s.recv(65535)
        if not chunk:
            break
        buf += chunk
except socket.timeout:
    pass
s.close()
print(buf.decode(errors="replace") if buf else "(no reply)")
