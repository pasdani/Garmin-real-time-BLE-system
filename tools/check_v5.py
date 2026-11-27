#!/usr/bin/env python3
"""
check_v5.py — Generates the TEST VECTORS of protocol v5 (MONITOR, see
docs/v5_monitoring.md) and checks their consistency.

Like check_v4.py, it contains an independent implementation of the format,
written from the tables of the specification only, with struct and bitwise
CRCs, and not from the code of the watch or of the ESP32: it is the reference
both implementations are compared against.

What it covers:
  - uplink (watch -> ESP32): 16 B header, 12 B samples, CRC-16;
  - encoding of the 4 values (HR, battery, steps, altitude) as uint16, with the
    32-bit arithmetic of Monkey C Floats;
  - alerts (ESP32 -> watch): 20 B notification with CRC-8, plus a set of
    alerts to REJECT.

The generated vectors feed the C test (esp32/main/test/test_v5.c -> includes
v5_vectors.h). The watch side is verified on the device
(docs/v5_monitoring.md).

Usage:
    python tools/check_v5.py            # self-check and write v5_vectors.h
    python tools/check_v5.py --c        # same
    python tools/check_v5.py --check    # self-check only (writes nothing)

v5_vectors.h belongs to the ESP32 part of the project: for the watch side
--check is enough.
"""

import io
import os
import struct
import sys

# ---------------------------------------------------------------------------
# Format constants (mirror of docs/v5_monitoring.md and ProtocolV5.mc)
# ---------------------------------------------------------------------------
MAGIC_UP, MAGIC_DOWN, VER = 0xA5, 0x5A, 0x06
HDR_BYTES, SAMPLE_BYTES, CRC_BYTES = 16, 12, 2
MAX_SAMPLES = 8
CHUNK_PAYLOAD = 16

ABSENT = 0xFFFF                   # sentinel of the uint16 values
MAX_VALUE = 0xFFFE
ALT_OFFSET = 10000                # altitude: metres + 10000, as in v3

ALERT_BYTES, TEXT_BYTES = 20, 11
AL_VIBE, AL_TONE = 0x01, 0x02
VALUE_NONE = 0xFFFF


def crc16(data: bytes) -> int:
    """Bitwise CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflect, no xorout."""
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def crc8(data: bytes) -> int:
    """CRC-8: poly 0x07, init 0x00, no reflect, no xorout (ProtoV3.crc8)."""
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


# ---------------------------------------------------------------------------
# Encoding of the 4 values. On the watch the sensors give 32-bit Floats and the
# arithmetic stays 32-bit: here it is reproduced step by step, so the expected
# value is the one the watch really computes, not the "ideal" one.
# ---------------------------------------------------------------------------
def f32(v):
    return struct.unpack("<f", struct.pack("<f", v))[0]


def enc_u16(x, scale, off):
    """null -> ABSENT; otherwise x*scale+off rounded to the nearest integer and
    saturated to [0, MAX_VALUE]. Mirror of ProtoV5.encU16."""
    if x is None:
        return ABSENT
    if isinstance(x, int):
        v = x * scale + off                       # Number: integer arithmetic
    else:
        v = f32(f32(f32(x) * scale) + off)        # Float: all 32-bit
    if v <= 0:
        return 0
    v = int(f32(v + 0.5))                         # toNumber() truncates: v > 0
    return MAX_VALUE if v > MAX_VALUE else v


def enc_hr(bpm):
    return enc_u16(bpm, 1, 0)


def enc_batt(pct):
    return enc_u16(pct, 100, 0)


def enc_steps(steps):
    return enc_u16(steps, 1, 0)


def enc_alt(m):
    return enc_u16(m, 1, ALT_OFFSET)


# ---------------------------------------------------------------------------
# Uplink: header + samples + CRC-16, all big-endian
# ---------------------------------------------------------------------------
def build_packet(node, session, seq_first, backlog, conn_no, ev_ack, ev_user, samples):
    assert 0 <= len(samples) <= MAX_SAMPLES
    body = bytearray(struct.pack(">BBBBIIBBBB", MAGIC_UP, VER, node, len(samples),
                                 session & 0xFFFFFFFF, seq_first & 0xFFFFFFFF,
                                 min(backlog, 255), conn_no & 0xFF, ev_ack & 0xFF, ev_user & 0xFF))
    assert len(body) == HDR_BYTES
    for t, hr, batt, steps, alt in samples:
        body += struct.pack(">IHHHH", t & 0xFFFFFFFF, hr, batt, steps, alt)
    return bytes(body) + struct.pack(">H", crc16(bytes(body)))


# ---------------------------------------------------------------------------
# Alert: 20 bytes, CRC-8 over the first 19
# ---------------------------------------------------------------------------
def build_alert(node, seq, ev_type, alert, value, text):
    raw = text.encode("ascii")
    assert len(raw) <= TEXT_BYTES and all(0x20 <= b <= 0x7E for b in raw)
    body = struct.pack(">BBBBBBH", MAGIC_DOWN, VER, node, seq, ev_type, alert, value) \
        + raw + bytes(TEXT_BYTES - len(raw))
    assert len(body) == ALERT_BYTES - 1
    return body + bytes([crc8(body)])


def with_crc8(body19):
    return bytes(body19) + bytes([crc8(bytes(body19))])


# ---------------------------------------------------------------------------
# The vectors. Sample = [realTime, hr, batt, steps, alt] already encoded.
# ---------------------------------------------------------------------------
def make_packets():
    v = []

    # 0 — steady state: one sample every 5 s on a healthy link. 30 bytes = 2 chunks.
    v.append(dict(name="steady", node=2, session=1790000000, seq_first=0, backlog=0,
                  conn_no=1, ev_ack=0, ev_user=0,
                  samples=[[1790000005, 142, 8700, 5230, 10123]]))

    # 1 — confirmations only: no samples, it carries only ev_ack and ev_user.
    #     session_id = 0 is still a legal value of the format. 18 bytes = 2 chunks.
    v.append(dict(name="confirmations", node=1, session=0, seq_first=0, backlog=0,
                  conn_no=1, ev_ack=7, ev_user=6, samples=[]))

    # 2 — queue draining: 8 samples, the maximum. 114 bytes = 8 chunks.
    v.append(dict(name="drain", node=3, session=1790000000, seq_first=120, backlog=37,
                  conn_no=3, ev_ack=12, ev_user=11,
                  samples=[[1790000600 + 5 * i, 150 + i, 8650 - i, 6000 + 3 * i, 10200 + i]
                           for i in range(8)]))

    # 3 — sentinels (missing values) and header reductions: backlog above 255
    #     (saturates), conn_no above 255 (modulo).
    v.append(dict(name="sentinels", node=4, session=1790003600, seq_first=4095, backlog=1000,
                  conn_no=256 + 7, ev_ack=255, ev_user=1,
                  samples=[[1790003600, ABSENT, 4800, ABSENT, ABSENT],
                           [1790003605, 98, 4800, 0, 0]]))

    # 4 — limits: node 254, session and seq at the maximum of the Monkey C
    #     Number (signed int32), realTime above 2^31 (Long), values at the
    #     maximum. A swapped byte or a wrong sign extension would show up.
    v.append(dict(name="limits", node=254, session=2147483647, seq_first=2147483000, backlog=255,
                  conn_no=255, ev_ack=255, ev_user=255,
                  samples=[[0x7FFFFFFF, MAX_VALUE, 0x8001, 0x0102, 0xFF00],
                           [0xFFFFFFFE, 0, 10000, MAX_VALUE, 1]]))

    for x in v:
        x["bytes"] = build_packet(x["node"], x["session"], x["seq_first"], x["backlog"],
                                  x["conn_no"], x["ev_ack"], x["ev_user"], x["samples"])
    return v


def make_encodings():
    """Physical values (None = sensor without a value) -> expected uint16.

    The Floats are chosen far from the rounding boundaries: the aim is to check
    formula, offset and saturations, not the last bit of the Float."""
    cases = [
        # hr,   batt%,  steps,  altitude (m)
        (142,   87.0,   5230,   123.4),     # typical
        (None,  55.37,  0,      -12.6),     # HR missing, negative altitude
        (61,    100.0,  70000,  None),      # full battery, saturated steps, altitude missing
        (0,     0.0,    65534,  -20000.0),  # zeros; altitude below the range -> 0
        (255,   4.75,   None,   60000.0),   # steps missing; altitude above the range -> 65534
        (90,    None,   12345,  0.0),       # battery missing; zero altitude = offset
    ]
    out = []
    for hr, batt, steps, alt in cases:
        out.append(dict(inp=(hr, batt, steps, alt),
                        exp=(enc_hr(hr), enc_batt(batt), enc_steps(steps), enc_alt(alt))))
    return out


def make_alerts():
    a = [
        dict(name="test",      node=2,   seq=1,   ev_type=0, alert=0,
             value=VALUE_NONE, text="E2 #1"),
        dict(name="vibrate",   node=2,   seq=2,   ev_type=1, alert=AL_VIBE,
             value=45,         text=""),
        dict(name="both",      node=5,   seq=200, ev_type=3, alert=AL_VIBE | AL_TONE,
             value=120,        text="Danger!!!!!"),       # 11 characters: full text
        dict(name="limits",    node=254, seq=255, ev_type=2, alert=AL_TONE,
             value=MAX_VALUE,  text="~ !09AZaz"),         # edges of printable ASCII
    ]
    for x in a:
        x["bytes"] = build_alert(x["node"], x["seq"], x["ev_type"], x["alert"],
                                 x["value"], x["text"])
    return a


def make_bad_alerts(alerts):
    """Alerts the watch must DISCARD (each one breaks a single aspect)."""
    good = alerts[0]["bytes"]
    body = bytearray(good[:-1])

    bad = []
    m = bytearray(body); m[0] = MAGIC_UP
    bad.append(dict(name="magic", bytes=with_crc8(m)))         # uplink magic, correct CRC
    m = bytearray(body); m[1] = 0x03
    bad.append(dict(name="version", bytes=with_crc8(m)))       # wrong version, correct CRC
    bad.append(dict(name="crc", bytes=bytes(body) + bytes([good[-1] ^ 0x01])))
    m = bytearray(body); m[3] = 0
    bad.append(dict(name="seq0", bytes=with_crc8(m)))          # ev_seq 0 is not used
    bad.append(dict(name="short", bytes=bytes(good[:-1])))     # 19 bytes
    bad.append(dict(name="long", bytes=bytes(good) + b"\x00"))  # 21 bytes
    return bad


# ---------------------------------------------------------------------------
# Self-check: read back what was just written with struct, without reusing
# the writing functions.
# ---------------------------------------------------------------------------
def self_check(packets, encodings, alerts, bad):
    fails = 0
    for x in packets:
        b = x["bytes"]
        n = len(x["samples"])
        exp_len = HDR_BYTES + n * SAMPLE_BYTES + CRC_BYTES
        if len(b) != exp_len:
            print(f"[FAIL] {x['name']}: length {len(b)} != expected {exp_len}")
            fails += 1
            continue
        hdr = struct.unpack_from(">BBBBIIBBBB", b, 0)
        exp = (MAGIC_UP, VER, x["node"], n, x["session"], x["seq_first"], min(x["backlog"], 255),
               x["conn_no"] & 0xFF, x["ev_ack"], x["ev_user"])
        if hdr != exp:
            print(f"[FAIL] {x['name']}: header read back {hdr} != {exp}")
            fails += 1
        if crc16(b[:-2]) != struct.unpack_from(">H", b, len(b) - 2)[0]:
            print(f"[FAIL] {x['name']}: CRC16 does not close")
            fails += 1
        for i, s in enumerate(x["samples"]):
            got = list(struct.unpack_from(">IHHHH", b, HDR_BYTES + i * SAMPLE_BYTES))
            if got != [s[0] & 0xFFFFFFFF] + s[1:]:
                print(f"[FAIL] {x['name']}: sample {i} read back differently")
                fails += 1

    # Encoding: the cases must really hit the sentinel and the saturations.
    seen = set()
    for e in encodings:
        for v in e["exp"]:
            if not 0 <= v <= 0xFFFF:
                print(f"[FAIL] encoding {e['inp']}: {v} outside uint16")
                fails += 1
            seen.add(v)
    for must in (ABSENT, MAX_VALUE, 0):
        if must not in seen:
            print(f"[FAIL] the encoding cases do not cover the value {must}")
            fails += 1
    if enc_alt(0.0) != ALT_OFFSET or enc_batt(55.37) != 5537 or enc_alt(-12.6) != 9987:
        print("[FAIL] encoding: offset or rounding of altitude/battery")
        fails += 1

    for x in alerts:
        b = x["bytes"]
        if len(b) != ALERT_BYTES:
            print(f"[FAIL] alert {x['name']}: {len(b)} bytes")
            fails += 1
            continue
        magic, ver, node, seq, typ, al, val = struct.unpack_from(">BBBBBBH", b, 0)
        text = b[8:8 + TEXT_BYTES].split(b"\x00")[0].decode("ascii")
        if (magic, ver, node, seq, typ, al, val, text) != \
                (MAGIC_DOWN, VER, x["node"], x["seq"], x["ev_type"], x["alert"], x["value"], x["text"]):
            print(f"[FAIL] alert {x['name']}: read back differently")
            fails += 1
        if crc8(b[:-1]) != b[-1]:
            print(f"[FAIL] alert {x['name']}: CRC8 does not close")
            fails += 1
    for x in bad:
        b = x["bytes"]
        ok = (len(b) == ALERT_BYTES and b[0] == MAGIC_DOWN and b[1] == VER
              and b[3] != 0 and crc8(b[:-1]) == b[-1])
        if ok:
            print(f"[FAIL] alert to discard '{x['name']}' looks valid")
            fails += 1

    if crc16(b"123456789") != 0x29B1:
        print("[FAIL] crc16('123456789') != 0x29B1")
        fails += 1
    if crc8(b"123456789") != 0xF4:
        print("[FAIL] crc8('123456789') != 0xF4")
        fails += 1
    return fails


# ---------------------------------------------------------------------------
# File generation
# ---------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def carr(b):
    return ", ".join("0x%02X" % x for x in b)


def write_c(packets, encodings, alerts, bad):
    path = os.path.join(ROOT, "esp32", "main", "test", "v5_vectors.h")
    max_len = HDR_BYTES + MAX_SAMPLES * SAMPLE_BYTES + CRC_BYTES
    o = io.StringIO()
    o.write("//\n// v5_vectors.h — GENERATED by tools/check_v5.py. DO NOT edit by hand.\n"
            "// Test vectors of protocol v5, from the independent Python reference.\n"
            "// Specification: docs/v5_monitoring.md.\n//\n"
            "#pragma once\n#include <stdint.h>\n\n")
    o.write("#define V5V_MAX_LEN %d\n#define V5V_MAX_SAMPLES %d\n\n" % (max_len, MAX_SAMPLES))
    o.write("typedef struct {\n"
            "    const char *name;\n"
            "    uint8_t  node_id;\n"
            "    uint8_t  n_samples;\n"
            "    uint32_t session_id;\n"
            "    uint32_t seq_first;\n"
            "    uint8_t  backlog;\n"
            "    uint8_t  conn_no;\n"
            "    uint8_t  ev_ack;\n"
            "    uint8_t  ev_user;\n"
            "    uint32_t real_time[V5V_MAX_SAMPLES];\n"
            "    uint16_t value[V5V_MAX_SAMPLES][4];   // hr, batt, steps, alt (encoded)\n"
            "    uint32_t len;\n"
            "    uint8_t  bytes[V5V_MAX_LEN];\n"
            "} v5_vec_t;\n\n")
    o.write("static const v5_vec_t V5_PACKETS[] = {\n")
    for x in packets:
        s = x["samples"] + [[0, 0, 0, 0, 0]] * (MAX_SAMPLES - len(x["samples"]))
        o.write("    { \"%s\", %du, %du, %du, %du, %du, %du, %du, %du,\n"
                % (x["name"], x["node"], len(x["samples"]), x["session"], x["seq_first"],
                   min(x["backlog"], 255), x["conn_no"] & 0xFF, x["ev_ack"], x["ev_user"]))
        o.write("      { %s },\n" % ", ".join("%du" % (r[0] & 0xFFFFFFFF) for r in s))
        o.write("      { %s },\n" % ", ".join("{ %s }" % ", ".join("%du" % v for v in r[1:]) for r in s))
        o.write("      %d,\n      { %s } },\n" % (len(x["bytes"]), carr(x["bytes"])))
    o.write("};\n#define V5_PACKETS_N ((int)(sizeof(V5_PACKETS)/sizeof(V5_PACKETS[0])))\n\n")

    o.write("typedef struct {\n"
            "    const char *name;\n"
            "    uint8_t  node_id, ev_seq, ev_type, alert;\n"
            "    uint16_t ev_value;\n"
            "    const char *text;\n"
            "    uint8_t  bytes[%d];\n"
            "} v5_alert_t;\n\n" % ALERT_BYTES)
    o.write("static const v5_alert_t V5_ALERTS[] = {\n")
    for x in alerts:
        o.write("    { \"%s\", %du, %du, %du, %du, %du, \"%s\",\n      { %s } },\n"
                % (x["name"], x["node"], x["seq"], x["ev_type"], x["alert"], x["value"],
                   x["text"].replace("\\", "\\\\").replace("\"", "\\\""), carr(x["bytes"])))
    o.write("};\n#define V5_ALERTS_N ((int)(sizeof(V5_ALERTS)/sizeof(V5_ALERTS[0])))\n\n")

    o.write("// Alerts to discard: variable length (19-21 bytes).\n"
            "typedef struct { const char *name; uint32_t len; uint8_t bytes[%d]; } v5_bad_alert_t;\n\n"
            % (ALERT_BYTES + 1))
    o.write("static const v5_bad_alert_t V5_BAD_ALERTS[] = {\n")
    for x in bad:
        o.write("    { \"%s\", %du, { %s } },\n" % (x["name"], len(x["bytes"]), carr(x["bytes"])))
    o.write("};\n#define V5_BAD_ALERTS_N ((int)(sizeof(V5_BAD_ALERTS)/sizeof(V5_BAD_ALERTS[0])))\n")

    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(o.getvalue())
    return path


def main():
    check_only = "--check" in sys.argv
    packets = make_packets()
    encodings = make_encodings()
    alerts = make_alerts()
    bad = make_bad_alerts(alerts)

    fails = self_check(packets, encodings, alerts, bad)
    if fails:
        print(f"[KO] {fails} checks failed on the generated vectors")
        return 1

    print(f"[OK] {len(packets)} packets + {len(encodings)} encodings + {len(alerts)} alerts "
          f"+ {len(bad)} to discard, self-check passed (proto_ver 0x{VER:02X})")
    for x in packets:
        print(f"     {x['name']:<13} {len(x['samples'])} samples -> {len(x['bytes'])} bytes, "
              f"{-(-len(x['bytes']) // CHUNK_PAYLOAD)} chunks")

    if not check_only:
        print("[GEN]", write_c(packets, encodings, alerts, bad))
    return 0


if __name__ == "__main__":
    sys.exit(main())
