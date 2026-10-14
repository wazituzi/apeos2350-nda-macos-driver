#!/usr/bin/env python3
"""Probe the FUJIFILM Apeos 2350 NDA: PJL identity/config + HTTP fingerprint.

Read-only probes. PJL INFO commands do not print anything.
"""
import socket
import sys
import urllib.request

IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.100"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9100

UEL = b"\x1b%-12345X"


def pjl(commands, wait=2.5):
    """Open one PJL session on port 9100, send commands, collect replies."""
    out = []
    try:
        s = socket.create_connection((IP, PORT), timeout=6)
    except OSError as e:
        return "CONNECT FAILED: %s" % e
    s.settimeout(wait)
    try:
        for cmd in commands:
            s.sendall(UEL + cmd + b"\r\n")
        s.sendall(UEL + b"@PJL EOJ\r\n" + UEL)
        while True:
            try:
                buf = s.recv(65536)
            except socket.timeout:
                break
            if not buf:
                break
            out.append(buf)
    finally:
        s.close()
    return b"".join(out)


def show(title, data):
    print("=" * 70)
    print("### " + title)
    print("=" * 70)
    if isinstance(data, bytes):
        if not data:
            print("(no response)")
        else:
            for line in data.decode("latin-1").replace("\r\n", "\n").split("\n"):
                if line.strip():
                    print(line)
    else:
        print(data)
    print()


def main():
    print("Target: %s:%d\n" % (IP, PORT))

    show("@PJL INFO ID (model)", pjl([b"@PJL INFO ID"]))
    show("@PJL INFO STATUS", pjl([b"@PJL INFO STATUS"]))
    show("@PJL INFO CONFIG (1/3)", pjl([b"@PJL INFO CONFIG"]))
    show(
        "@PJL INFO VARIABLES",
        pjl([b"@PJL INFO VARIABLES"]),
    )

    # HTTP: grab the web UI landing page title so we know what we're talking to.
    for url in ("http://%s/" % IP, "http://%s/home.html" % IP):
        try:
            with urllib.request.urlopen(url, timeout=6) as r:
                body = r.read(4000).decode("utf-8", "replace")
            head = body.split("<title>")[-1].split("</title>")[0] if "<title>" in body else ""
            print("HTTP %s -> %s | title=%r | %d bytes" % (url, r.status, head.strip(), len(body)))
        except Exception as e:  # noqa: BLE001
            print("HTTP %s -> ERROR %s" % (url, e))


if __name__ == "__main__":
    main()
