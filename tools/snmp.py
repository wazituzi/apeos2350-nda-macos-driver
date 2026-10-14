#!/usr/bin/env python3
"""Minimal SNMP v1 GET (no external deps) to fingerprint the printer.

Queries sysDescr / sysObjectID / hrDeviceDescr and the SNMPv1 community
strings 'public' and 'private' (read-only queries, nothing is changed).
"""
import socket
import sys

IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.100"

OIDS = {
    "sysDescr": "1.3.6.1.2.1.1.1.0",
    "sysObjectID": "1.3.6.1.2.1.1.2.0",
    "sysUpTime": "1.3.6.1.2.1.1.3.0",
    "sysName": "1.3.6.1.2.1.1.5.0",
    "hrDeviceDescr": "1.3.6.1.2.1.25.3.2.1.3.1",
}


def enc_len(n):
    if n < 0x80:
        return bytes([n])
    out = b""
    while n:
        out = bytes([n & 0xFF]) + out
        n >>= 8
    return bytes([0x80 | len(out)]) + out


def tlv(tag, value):
    return bytes([tag]) + enc_len(len(value)) + value


def enc_int(n):
    if n == 0:
        return b"\x00"
    out = b""
    while n:
        out = bytes([n & 0xFF]) + out
        n >>= 8
    if out[0] & 0x80:
        out = b"\x00" + out
    return out


def enc_oid(oid):
    parts = [int(x) for x in oid.split(".")]
    body = bytes([parts[0] * 40 + parts[1]])
    for p in parts[2:]:
        if p < 0x80:
            body += bytes([p])
        else:
            chunk = bytes([p & 0x7F])
            p >>= 7
            while p:
                chunk = bytes([(p & 0x7F) | 0x80]) + chunk
                p >>= 7
            body += chunk
    return body


def snmp_get(oid, community=b"public", timeout=3.0):
    req = tlv(0xA0, tlv(0x02, enc_int(0)) + tlv(0x04, community) + tlv(0xA0, tlv(0x02, enc_int(1)) + tlv(0x02, enc_int(0)) + tlv(0x02, enc_int(0)) + tlv(0x30, tlv(0x06, enc_oid(oid)) + tlv(0x05, b""))))
    msg = tlv(0x30, tlv(0x02, enc_int(0)) + tlv(0x04, community) + req)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(msg, (IP, 161))
        data, _ = s.recvfrom(65535)
        return data
    except Exception as e:  # noqa: BLE001
        return b"ERR:" + str(e).encode()
    finally:
        s.close()


def parse_strings(data):
    """Crude but effective: pull printable ASCII runs out of the response."""
    out, cur = [], ""
    for b in data:
        if 32 <= b < 127:
            cur += chr(b)
        else:
            if len(cur) >= 4:
                out.append(cur)
            cur = ""
    if len(cur) >= 4:
        out.append(cur)
    return out


def main():
    for comm in (b"public", b"private"):
        print("=" * 66)
        print("### community=%s" % comm.decode())
        print("=" * 66)
        for name, oid in OIDS.items():
            r = snmp_get(oid, comm)
            if r.startswith(b"ERR:"):
                print("  %-14s %s" % (name, r.decode()))
                if b"timed out" in r or b"Timeout" in r:
                    break
            else:
                print("  %-14s %s" % (name, " | ".join(parse_strings(r))[:160]))
        print()
    # walk printer MIB description subtree (getnext would be needed; just try a few)
    print("=== MIB-II sysDescr raw hexdump sample ===")
    r = snmp_get("1.3.6.1.2.1.1.1.0", b"public")
    print(r[:120].hex())


if __name__ == "__main__":
    main()
