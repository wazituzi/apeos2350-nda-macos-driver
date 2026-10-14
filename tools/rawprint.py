#!/usr/bin/env python3
"""Send a raw file to a network printer's JetDirect / RAW port (9100).

Used to probe which page description language the device actually digests,
bypassing CUPS entirely.

    python3 rawprint.py <file> [ip] [port]
"""
import socket
import sys
import time

path = sys.argv[1]
ip = sys.argv[2] if len(sys.argv) > 2 else "192.168.1.100"
port = int(sys.argv[3]) if len(sys.argv) > 3 else 9100

with open(path, "rb") as fh:
    data = fh.read()

UEL = b"\x1b%-12345X"

s = socket.create_connection((ip, port), timeout=10)
s.settimeout(10)
try:
    s.sendall(UEL)          # universal exit: clears any half-finished job
    s.sendall(data)
    s.sendall(UEL)          # flush / end of job
    s.shutdown(socket.SHUT_WR)
    time.sleep(0.4)
    try:
        s.recv(4096)        # some devices report status back
    except socket.timeout:
        pass
finally:
    s.close()

print("sent %d bytes from %s -> %s:%d" % (len(data), path, ip, port))
