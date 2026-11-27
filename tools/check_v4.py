#!/usr/bin/env python3
"""
check_v4.py — Generates the TEST VECTORS of protocol v4 (MULTI) and checks
their consistency.

It contains an independent implementation of the format, written from the
offset table only and with a bitwise CRC instead of a per-nibble one, and not
from the code of the watch or of the ESP32: it is the reference both
implementations are compared against.

The generated vectors feed the C test (esp32/main/test/test_v4.c -> includes
v4_vectors.h). The watch side is verified on the device.

Usage:
    python tools/check_v4.py            # self-check and write v4_vectors.h
    python tools/check_v4.py --c        # same
    python tools/check_v4.py --check    # self-check only (writes nothing)

v4_vectors.h belongs to the ESP32 part of the project: for the watch side
--check is enough.
"""

import io
import os
import struct
import sys

# ---------------------------------------------------------------------------
# Format constants (mirror of ProtocolV4.mc / protocol_v4.h)
# ---------------------------------------------------------------------------
MAGIC, VER = 0xA5, 0x05
HDR_BYTES, SAMPLE_BYTES, CRC_BYTES = 14, 48, 2
NFIELDS = 12
MAX_SAMPLES = 4
SENTINEL = 0xFFFFFFFF

# Advertising: Manufacturer Specific Data, company id 0xFFFF (reserved for testing)
ADV_COMPANY = 0xFFFF
ADV_MAGIC = (0x54, 0x34)          # "T4"
ADV_F_BUSY = 0x01

# Radio telemetry in fields 4-7 of the sample (see ProtocolV4.mc)
T_FIELDS = (4, 5, 6, 7)
R_SCAN_ON, R_ROAM_OK = 0x04, 0x08
RSSI_ABSENT = -128


def pack_telemetry(t):
    """Packs a telemetry dict into the 4 uint32 of fields 4-7.

    Written with struct (big-endian bytes) and not with shifts, on purpose: it
    is a derivation independent from the shift/mask one of the two sides."""
    st = (t["radio"] & 0x03) | (R_SCAN_ON if t["scan_on"] else 0) | (R_ROAM_OK if t["roam_ok"] else 0)
    raw = struct.pack(">HH", t["t_conn_s"] & 0xFFFF, t["t_scan_s"] & 0xFFFF) \
        + struct.pack(">HH", t["t_agg_s"] & 0xFFFF, t["tx_chunks"] & 0xFFFF) \
        + struct.pack(">BBBB", t["n_try"] & 0xFF, t["n_conn"] & 0xFF, t["n_ho"] & 0xFF, t["n_lost"] & 0xFF) \
        + struct.pack(">BBbB", t["n_fail"] & 0xFF, st, t["rssi"], min(t["coda"], 255))
    return list(struct.unpack(">IIII", raw))


def unpack_telemetry(w):
    """Inverse of pack_telemetry: from the 4 uint32 to the fields (already reduced to their modulus)."""
    a, b, c, d = w
    return dict(
        t_conn_s=a >> 16, t_scan_s=a & 0xFFFF, t_agg_s=b >> 16, tx_chunks=b & 0xFFFF,
        n_try=c >> 24, n_conn=(c >> 16) & 0xFF, n_ho=(c >> 8) & 0xFF, n_lost=c & 0xFF,
        n_fail=d >> 24, radio=(d >> 16) & 0x03, scan_on=bool((d >> 16) & R_SCAN_ON),
        roam_ok=bool((d >> 16) & R_ROAM_OK),
        rssi=((d >> 8) & 0xFF) - 256 if (d >> 8) & 0x80 else (d >> 8) & 0xFF,
        coda=d & 0xFF)


TEL_KEYS = ("t_conn_s", "t_scan_s", "t_agg_s", "tx_chunks", "n_try", "n_conn", "n_ho",
            "n_lost", "n_fail", "radio", "scan_on", "roam_ok", "rssi", "coda")


def tel(t_conn_s, t_scan_s, t_agg_s, tx_chunks, n_try, n_conn, n_ho, n_lost, n_fail,
        radio, scan_on, roam_ok, rssi, coda):
    return dict(zip(TEL_KEYS, (t_conn_s, t_scan_s, t_agg_s, tx_chunks, n_try, n_conn, n_ho,
                               n_lost, n_fail, radio, scan_on, roam_ok, rssi, coda)))


def crc16(data: bytes) -> int:
    """Bitwise CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflect, no xorout."""
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def be16(v):
    return bytes([(v >> 8) & 0xFF, v & 0xFF])


def be32(v):
    v &= 0xFFFFFFFF
    return bytes([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])


# ---------------------------------------------------------------------------
# Building a v4 packet
# ---------------------------------------------------------------------------
def build_packet(node, session, seq_first, backlog, conn_no, samples):
    assert 1 <= len(samples) <= MAX_SAMPLES
    hdr = bytes([MAGIC, VER, node, len(samples)]) + be32(session) \
        + be32(seq_first) + bytes([min(backlog, 255), conn_no & 0xFF])
    assert len(hdr) == HDR_BYTES

    body = bytearray(hdr)
    for s in samples:
        assert len(s) == NFIELDS
        for v in s:
            body += be32(v)
    return bytes(body) + be16(crc16(bytes(body)))


def build_adv(node, busy):
    """Payload of the Manufacturer Specific Data AFTER the company id."""
    return bytes([ADV_MAGIC[0], ADV_MAGIC[1], node, ADV_F_BUSY if busy else 0])


def adv_ad_structure(node, busy):
    """Complete AD structure as it appears in the advertising packet."""
    payload = bytes([ADV_COMPANY & 0xFF, ADV_COMPANY >> 8]) + build_adv(node, busy)
    return bytes([len(payload) + 1, 0xFF]) + payload


# ---------------------------------------------------------------------------
# The vectors. Field order:
#   hr, cad, speed, dist, tel_time, tel_link, tel_count, tel_state,
#   timer, battery(%*100), elapsed, realTime
# ---------------------------------------------------------------------------
def sample(hr, cad, speed, dist, t, timer, batt, elapsed, real):
    """A v4 sample: 8 v3 fields + the telemetry `t` (dict) in fields 4-7."""
    return [hr, cad, speed, dist] + pack_telemetry(t) + [timer, batt, elapsed, real]


def make_telemetry():
    """Telemetry packing cases, shared with both sides."""
    return [
        # Session start: all zero, searching, RSSI not measured.
        dict(name="zero", t=tel(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, True, True, RSSI_ABSENT, 0)),
        # A typical hour: almost always connected, scan always on.
        dict(name="hour", t=tel(3540, 3590, 12, 2840, 3, 3, 1, 1, 0, 2, True, True, -67, 0)),
        # Pairing in progress, roaming not allowed, long queue (saturates at 255).
        dict(name="pairing", t=tel(1200, 1500, 45, 900, 9, 7, 2, 4, 3, 1, False, False, -90, 400)),
        # Limits and moduli: values wider than their fields wrap around.
        dict(name="wraparound", t=tel(65536 + 5, 70000, 65535, 65536 + 9, 256 + 2, 255, 300, 511,
                                      257, 2, True, False, -1, 255)),
    ]


def make_vectors():
    v = []

    # 0 — steady state: one sample per packet, empty queue. It is the case of
    #     every 5 s on a healthy link: 64 bytes = 4 full chunks, no short chunk.
    v.append(dict(
        name="steady", node=2, session=1790000000, seq_first=0, backlog=0, conn_no=1,
        samples=[sample(142, 168, 312, 12500,
                        tel(120, 125, 2, 96, 1, 1, 0, 0, 0, 2, True, True, -67, 0),
                        125000, 5500, 125400, 1790000125)]))

    # 1 — queue draining after an uncovered area: 4 consecutive samples,
    #     backlog still to send. 208 bytes = 13 chunks.
    v.append(dict(
        name="drain", node=1, session=1790000000, seq_first=120, backlog=37, conn_no=3,
        samples=[sample(150 + i, 170, 330 + i, 20000 + 16 * i,
                        tel(400, 600 + 5 * i, 20, 310, 3, 2, 0, 1, 1, 0, True, True,
                            RSSI_ABSENT, 40 + i),
                        600000 + 5000 * i, 5400, 600800 + 5000 * i,
                        1790000600 + 5 * i) for i in range(4)]))

    # 2 — sentinels (missing values) and saturation of the backlog (>255) and
    #     of conn_no (mod 256). The backlog is informative: it saturates instead
    #     of wrapping.
    v.append(dict(
        name="sentinels", node=3, session=1790003600, seq_first=4095, backlog=1000, conn_no=256 + 7,
        samples=[sample(SENTINEL, SENTINEL, 0, 0,
                        tel(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, True, True, RSSI_ABSENT, 0),
                        3600000, 4800, 3605000, 1790003600),
                 sample(98, SENTINEL, 0, 0,
                        tel(3, 5, 1, 4, 1, 1, 0, 0, 0, 2, True, True, -72, 0),
                        3605000, 4800, 3610000, 1790003605)]))

    # 3 — limits: node 254, seq and session at the maximum of the Monkey C
    #     Number (signed int32), fields at the uint32 maximum minus one, so that
    #     a swapped byte or a wrong sign extension would show up.
    v.append(dict(
        name="limits", node=254, session=2147483647, seq_first=2147483000, backlog=255, conn_no=255,
        samples=[[0xFFFFFFFE, 0x80000000, 0x7FFFFFFF, 0x01020304] * 3 for _ in range(3)]))

    for x in v:
        x["bytes"] = build_packet(x["node"], x["session"], x["seq_first"],
                                  x["backlog"], x["conn_no"], x["samples"])
    return v


def make_advs():
    a = [dict(node=1, busy=False), dict(node=2, busy=True), dict(node=254, busy=False)]
    for x in a:
        x["payload"] = build_adv(x["node"], x["busy"])
        x["ad"] = adv_ad_structure(x["node"], x["busy"])
    return a


# ---------------------------------------------------------------------------
# Self-check: read back what was just written with struct, without reusing
# the writing functions.
# ---------------------------------------------------------------------------
def self_check(vectors, advs, tels=()):
    fails = 0
    for x in tels:
        w = pack_telemetry(x["t"])
        back = unpack_telemetry(w)
        t = x["t"]
        exp = dict(t_conn_s=t["t_conn_s"] & 0xFFFF, t_scan_s=t["t_scan_s"] & 0xFFFF,
                   t_agg_s=t["t_agg_s"] & 0xFFFF, tx_chunks=t["tx_chunks"] & 0xFFFF,
                   n_try=t["n_try"] & 0xFF, n_conn=t["n_conn"] & 0xFF, n_ho=t["n_ho"] & 0xFF,
                   n_lost=t["n_lost"] & 0xFF, n_fail=t["n_fail"] & 0xFF, radio=t["radio"],
                   scan_on=t["scan_on"], roam_ok=t["roam_ok"], rssi=t["rssi"],
                   coda=min(t["coda"], 255))
        if back != exp:
            print(f"[FAIL] telemetry {x['name']}: {back} != {exp}")
            fails += 1
        # Bits 4-7 of the radio byte must stay zero (reserved).
        if (w[3] >> 20) & 0x0F:
            print(f"[FAIL] telemetry {x['name']}: reserved bits of the radio byte not zero")
            fails += 1
    for x in vectors:
        b = x["bytes"]
        n = len(x["samples"])
        exp_len = HDR_BYTES + n * SAMPLE_BYTES + CRC_BYTES
        if len(b) != exp_len:
            print(f"[FAIL] {x['name']}: length {len(b)} != expected {exp_len}")
            fails += 1
            continue
        magic, ver, node, ns, sess, seq, bk, cn = struct.unpack_from(">BBBBIIBB", b, 0)
        if (magic, ver) != (MAGIC, VER):
            print(f"[FAIL] {x['name']}: magic/version")
            fails += 1
        if (node, ns, sess, seq, bk, cn) != (x["node"], n, x["session"], x["seq_first"],
                                             min(x["backlog"], 255), x["conn_no"] & 0xFF):
            print(f"[FAIL] {x['name']}: header read back differently")
            fails += 1
        if crc16(b[:-2]) != struct.unpack_from(">H", b, len(b) - 2)[0]:
            print(f"[FAIL] {x['name']}: CRC16 does not close")
            fails += 1
        for i, s in enumerate(x["samples"]):
            got = list(struct.unpack_from(">12I", b, HDR_BYTES + i * SAMPLE_BYTES))
            if got != [v & 0xFFFFFFFF for v in s]:
                print(f"[FAIL] {x['name']}: sample {i} read back differently")
                fails += 1

    for x in advs:
        ad = x["ad"]
        if ad[0] != len(ad) - 1 or ad[1] != 0xFF:
            print(f"[FAIL] adv node {x['node']}: malformed AD structure")
            fails += 1
        if struct.unpack_from("<H", ad, 2)[0] != ADV_COMPANY or ad[4:] != x["payload"]:
            print(f"[FAIL] adv node {x['node']}: company id / payload")
            fails += 1

    # Constraint of the (legacy, 31-byte) advertising packet: flags (3) +
    # 128-bit UUID (18) + this AD structure. If it does not fit,
    # ble_gap_adv_set_fields fails and the ESP32 can no longer be found by anyone.
    total = 3 + 18 + len(advs[0]["ad"])
    if total > 31:
        print(f"[FAIL] advertising of {total} bytes > 31")
        fails += 1

    if crc16(b"123456789") != 0x29B1:
        print("[FAIL] crc16('123456789') != 0x29B1")
        fails += 1
    return fails


# ---------------------------------------------------------------------------
# File generation
# ---------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def carr(b):
    return ", ".join("0x%02X" % x for x in b)


def write_c(vectors, advs, tels):
    path = os.path.join(ROOT, "esp32", "main", "test", "v4_vectors.h")
    max_len = HDR_BYTES + MAX_SAMPLES * SAMPLE_BYTES + CRC_BYTES
    o = io.StringIO()
    o.write("//\n// v4_vectors.h — GENERATED by tools/check_v4.py. DO NOT edit by hand.\n"
            "// Test vectors of protocol v4, from the independent Python reference.\n//\n"
            "#pragma once\n#include <stdint.h>\n\n")
    o.write("#define V4V_MAX_LEN %d\n\n" % max_len)
    o.write("typedef struct {\n"
            "    const char *name;\n"
            "    uint8_t  node_id;\n"
            "    uint8_t  n_samples;\n"
            "    uint32_t session_id;\n"
            "    uint32_t seq_first;\n"
            "    uint8_t  backlog;\n"
            "    uint8_t  conn_no;\n"
            "    uint32_t field[%d][%d];\n"
            "    uint32_t len;\n"
            "    uint8_t  bytes[V4V_MAX_LEN];\n"
            "} v4_vec_t;\n\n" % (MAX_SAMPLES, NFIELDS))
    o.write("static const v4_vec_t V4_VECTORS[] = {\n")
    for x in vectors:
        rows = []
        for i in range(MAX_SAMPLES):
            s = x["samples"][i] if i < len(x["samples"]) else [0] * NFIELDS
            rows.append("{ " + ", ".join("0x%08Xu" % (v & 0xFFFFFFFF) for v in s) + " }")
        o.write("    { \"%s\", %du, %du, %du, %du, %du, %du,\n      { %s },\n"
                % (x["name"], x["node"], len(x["samples"]), x["session"], x["seq_first"],
                   min(x["backlog"], 255), x["conn_no"] & 0xFF, ",\n        ".join(rows)))
        o.write("      %d,\n      { %s } },\n" % (len(x["bytes"]), carr(x["bytes"])))
    o.write("};\n#define V4_VECTORS_N ((int)(sizeof(V4_VECTORS)/sizeof(V4_VECTORS[0])))\n\n")

    o.write("typedef struct { uint8_t node_id; uint8_t busy; uint8_t payload[4]; } v4_adv_t;\n\n")
    o.write("static const v4_adv_t V4_ADVS[] = {\n")
    for x in advs:
        o.write("    { %du, %du, { %s } },\n" % (x["node"], 1 if x["busy"] else 0, carr(x["payload"])))
    o.write("};\n#define V4_ADVS_N ((int)(sizeof(V4_ADVS)/sizeof(V4_ADVS[0])))\n\n")

    # Telemetry: the 4 uint32 of fields 4-7 and the values the decoder must
    # derive from them (already reduced to the modulus of each field width).
    o.write("typedef struct {\n    const char *name;\n    uint32_t word[4];\n"
            "    uint16_t t_conn_s, t_scan_s, t_agg_s, tx_chunks;\n"
            "    uint8_t  n_try, n_conn, n_ho, n_lost, n_fail;\n"
            "    uint8_t  radio, scan_on, roam_ok;\n    int8_t   rssi;\n    uint8_t  coda;\n"
            "} v4_tel_t;\n\n")
    o.write("static const v4_tel_t V4_TELS[] = {\n")
    for x in tels:
        w = pack_telemetry(x["t"])
        d = unpack_telemetry(w)
        o.write("    { \"%s\", { %s },\n      %du, %du, %du, %du,  %du, %du, %du, %du, %du,  %du, %du, %du,  %d, %du },\n"
                % (x["name"], ", ".join("0x%08Xu" % v for v in w),
                   d["t_conn_s"], d["t_scan_s"], d["t_agg_s"], d["tx_chunks"],
                   d["n_try"], d["n_conn"], d["n_ho"], d["n_lost"], d["n_fail"],
                   d["radio"], int(d["scan_on"]), int(d["roam_ok"]), d["rssi"], d["coda"]))
    o.write("};\n#define V4_TELS_N ((int)(sizeof(V4_TELS)/sizeof(V4_TELS[0])))\n")

    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(o.getvalue())
    return path


def main():
    check_only = "--check" in sys.argv
    vectors = make_vectors()
    advs = make_advs()
    tels = make_telemetry()

    fails = self_check(vectors, advs, tels)
    if fails:
        print(f"[KO] {fails} checks failed on the generated vectors")
        return 1

    print(f"[OK] {len(vectors)} packets + {len(advs)} advertising + {len(tels)} telemetry cases, "
          f"self-check passed (proto_ver 0x{VER:02X})")
    for x in vectors:
        print(f"     {x['name']:<12} {len(x['samples'])} samples -> {len(x['bytes'])} bytes, "
              f"{-(-len(x['bytes']) // 16)} chunks")
    print(f"     advertising: 3 + 18 + {len(advs[0]['ad'])} = {21 + len(advs[0]['ad'])} bytes out of 31")

    if not check_only:
        print("[GEN]", write_c(vectors, advs, tels))
    return 0


if __name__ == "__main__":
    sys.exit(main())
