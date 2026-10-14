#!/usr/bin/env python3
"""Minimal LPD (RFC 1179) client - the other print protocol the Apeos
2350 NDA documents besides port 9100.

The device advertises _printer._tcp with rp=printer, so the queue name is
"printer".

    python3 lpdprint.py <file> [ip] [queue]
"""
import getpass
import socket
import sys
import time

path = sys.argv[1]
ip = sys.argv[2] if len(sys.argv) > 2 else "192.168.1.100"
queue = sys.argv[3] if len(sys.argv) > 3 else "printer"

with open(path, "rb") as fh:
    data = fh.read()

host = socket.gethostname().split(".")[0]
user = getpass.getuser()
ctrl = (
    "H%s\n" % host
    + "P%s\n" % user
    + "J%s\n" % path.rsplit("/", 1)[-1]
    + "ldfA001%s\n" % host
    + "UdfA001%s\n" % host
    + "N%s\n" % path.rsplit("/", 1)[-1]
).encode()

s = socket.create_connection((ip, 515), timeout=15)
s.settimeout(15)
try:
    # Receive job: \x02<queue>\n
    s.sendall(b"\x02" + queue.encode() + b"\n")
    ack = s.recv(1)
    if ack != b"\x00":
        sys.exit("LPD refused receive-job command, got %r" % ack)
    # Control file: \x02<len> <name>\n<data>\x00
    s.sendall(b"\x02" + str(len(ctrl)).encode() + b" cfA001%s\n" % host.encode())
    s.sendall(ctrl + b"\x00")
    if s.recv(1) != b"\x00":
        sys.exit("LPD refused control file")
    # Data file: \x03<len> <name>\n<data>\x00
    s.sendall(b"\x03" + str(len(data)).encode() + b" dfA001%s\n" % host.encode())
    s.sendall(data + b"\x00")
    if s.recv(1) != b"\x00":
        sys.exit("LPD refused data file")
finally:
    s.close()

print("LPD: sent %d bytes from %s -> %s:%s" % (len(data), path, ip, queue))
