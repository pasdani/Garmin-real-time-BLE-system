#!/usr/bin/env python3
"""
merge_multi.py — Rebuilds the single stream of a session from the microSD
files of all the edges: v4 (MULTI, multi_<session>_n<node>.csv) and v5
(MONITOR, monitor_<session>_n<node>.csv). The type is recognised from the file
name; merging, duplicates, gaps and the edge sequence work the same for both.

Each edge wrote only the samples received while the watch was connected to
it. Once the cards are copied into one or more folders, this script:

  - merges the files by session_id and deduplicates by seq (a retransmission
    after a lost write response arrives twice, on the same edge or on two);
  - checks that the copies of the same seq have IDENTICAL values (if not, it
    is a bug, not a duplicate);
  - lists the seq gaps and CLASSIFIES them with conn_no (progressive number
    of the connection, written in every row):
      * if between the last sample before the gap and the first one after it
        at least one connection number is missing, that connection happened
        with an edge that left no files: an edge WITHOUT SD
        (THIS_EDGE_HAS_SD = 0), or one whose card was not copied. A loss
        accepted by design;
      * otherwise the gap is a REAL LOSS of the system: samples that no edge
        received (typically the watch queue overflowing after an hour without
        edges);
  - estimates the samples left on the watch at the end of the session
    (backlog field of the last packet): they are not gaps, but they never
    arrived;
  - rebuilds the edge sequence (who received what, in seq order) and
    summarises the events of each edge (edge_n<node>_events.csv);
  - v4, BATTERY AND RADIO: from the first to the last received sample it
    computes the watch battery drop and, with the radio telemetry (proto_ver
    0x05, fields 4-7 of the sample), how long the watch was connected, pairing
    and with the scan on, how many pairings, handoffs, lost links, chunks and
    failed packets. The counters are cumulative: TWO rows are enough (for
    example those of a single edge with SD at the start and end of the
    activity), even if the samples in between went to other edges;
  - v5, SESSION VALUES: duration, heart rate (minimum, mean, maximum), battery
    drop, steps taken in the session and minimum and maximum altitude. v5 has
    no radio telemetry.

Usage:
    python tools/merge_multi.py <folder_or_file> [...] [--out merged.csv] [--session S]

Example (cards of the edges with SD copied into sd/e1, sd/e2, ...):
    python tools/merge_multi.py sd --out session.csv

Exit code: 0 = no real loss, 1 = no file to process (or session without
data), 2 = samples LOST, 3 = conflicting copies.
Samples that ended up on edges without SD do not change the exit code: they
are a design choice.

Standard library only.
"""

import argparse
import csv
import glob
import os
import re
import sys
from collections import defaultdict

DATA_RE = re.compile(r"(multi|monitor)_(\d+)_n(\d+)\.csv$", re.IGNORECASE)
EVENTS_RE = re.compile(r"edge_n(\d+)_events\.csv$", re.IGNORECASE)

# Service columns of the data file; all the others are the sample fields.
SERVICE = {"rx_ms", "node", "session", "seq", "conn_no", "backlog", "dup"}

# Radio telemetry (proto_ver 0x05). The ESP32 can write it already split
# (TEL_COLS) or as the 4 raw words of fields 4-7 (TEL_RAW).
TEL_COLS = ["t_conn_s", "t_scan_s", "t_agg_s", "tx_chunks", "n_try", "n_conn", "n_ho",
            "n_lost", "n_fail", "radio", "scan_on", "roam_ok", "rssi", "coda"]
TEL_RAW = ["tel_time", "tel_link", "tel_count", "tel_state"]

# Cumulative counters and their modulus (width of the field in the packet).
TEL_CUMUL = [("t_conn_s", 65536), ("t_scan_s", 65536), ("t_agg_s", 65536),
             ("tx_chunks", 65536), ("n_try", 256), ("n_conn", 256), ("n_ho", 256),
             ("n_lost", 256), ("n_fail", 256)]
BATT_SENTINEL = 4294967295

# Radio state names, the same as the ESP32 console (v4_radio_name in
# protocol_v4.h): ricerca = searching, aggancio = pairing, connesso = connected.
RADIO_NAMES = {0: "ricerca", 1: "aggancio", 2: "connesso"}


def decode_raw_telemetry(words):
    """The 4 words of fields 4-7 -> dict (see ProtocolV4.mc)."""
    a, b, c, d = words
    rs = (d >> 8) & 0xFF
    return dict(t_conn_s=a >> 16, t_scan_s=a & 0xFFFF, t_agg_s=b >> 16, tx_chunks=b & 0xFFFF,
                n_try=c >> 24, n_conn=(c >> 16) & 0xFF, n_ho=(c >> 8) & 0xFF, n_lost=c & 0xFF,
                n_fail=d >> 24, radio=(d >> 16) & 0x03, scan_on=(d >> 18) & 1,
                roam_ok=(d >> 19) & 1, rssi=rs - 256 if rs & 0x80 else rs, coda=d & 0xFF)


def telemetry_of(r):
    """Telemetry of a row, or None if the file does not contain it."""
    try:
        if all(k in r and r[k] != "" for k in TEL_COLS):
            return {k: int(r[k]) for k in TEL_COLS}
        if all(k in r and r[k] != "" for k in TEL_RAW):
            return decode_raw_telemetry([int(r[k]) for k in TEL_RAW])
    except ValueError:
        pass
    return None


def find_files(paths):
    data, events = [], []
    for p in paths:
        cands = [p] if os.path.isfile(p) else glob.glob(os.path.join(p, "**", "*.csv"), recursive=True)
        for f in cands:
            name = os.path.basename(f)
            if DATA_RE.search(name):
                data.append(f)
            elif EVENTS_RE.search(name):
                events.append(f)
    return sorted(set(data)), sorted(set(events))


def load_rows(files):
    """session -> list of rows (dict) of all the edges."""
    by_session = defaultdict(list)
    for f in files:
        kind = "v5" if DATA_RE.search(os.path.basename(f)).group(1).lower() == "monitor" else "v4"
        with open(f, newline="", encoding="utf-8") as fh:
            for r in csv.DictReader(fh):
                try:
                    r["_seq"] = int(r["seq"])
                    r["_node"] = int(r["node"])
                    r["_session"] = int(r["session"])
                    r["_dup"] = int(r["dup"])
                    r["_backlog"] = int(r["backlog"])
                    r["_conn"] = int(r["conn_no"])
                except (KeyError, ValueError):
                    continue            # truncated row (power off in the middle of a write)
                r["_file"] = f
                r["_kind"] = kind
                r["_cols"] = [c for c in (r.keys()) if c not in SERVICE and not c.startswith("_")]
                by_session[r["_session"]].append(r)
    return by_session


def ranges(nums):
    """[1,2,3,7,9,10] -> [(1,3),(7,7),(9,10)]"""
    out = []
    for n in sorted(nums):
        if out and n == out[-1][1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return [tuple(x) for x in out]


def fmt_ranges(rs, limit=12):
    parts = ["%d" % a if a == b else "%d-%d" % (a, b) for a, b in rs[:limit]]
    if len(rs) > limit:
        parts.append("... (+%d ranges)" % (len(rs) - limit))
    return ", ".join(parts)


def merge_session(session, rows):
    by_seq = defaultdict(list)
    for r in rows:
        by_seq[r["_seq"]].append(r)

    conflicts = []
    merged = []
    for seq in sorted(by_seq):
        copies = by_seq[seq]
        values = {tuple(c[f] for f in c["_cols"]) for c in copies}
        if len(values) > 1:
            conflicts.append(seq)
        # First reception: the copy not marked dup, on a tie the one of the first edge.
        first = sorted(copies, key=lambda c: (c["_dup"], c["_node"]))[0]
        merged.append(dict(first, _copies=len(copies),
                           _nodes=sorted({c["_node"] for c in copies})))

    seqs = [m["_seq"] for m in merged]
    max_seq = max(seqs)
    missing = sorted(set(range(0, max_seq + 1)) - set(seqs))

    # Gap classification. The watch delivers the samples IN ORDER and numbers
    # the connections (conn_no, +1 at every pairing): the samples of a gap were
    # delivered, if at all, in a connection between the one of the previous
    # sample (cp) and the one of the next (cn). If in between there is at
    # least one number that appears in no file, that connection went to an
    # edge that does not write: that is where they ended up.
    # conn_no is mod 256: the difference is taken modulo 256. Before the first
    # sample it is 0 (no connection yet).
    conn_of = {m["_seq"]: m["_conn"] for m in merged}
    gaps = []
    for a, b in ranges(missing):
        cp = conn_of.get(a - 1, 0)
        cn = conn_of[b + 1]                     # exists: the gap ends before max_seq
        skipped = (cn - cp) % 256 - 1           # connections without files in between
        gaps.append(dict(frm=a, to=b, n=b - a + 1, cp=cp, cn=cn,
                         kind="nosd" if skipped >= 1 else "lost"))
    lost = [g for g in gaps if g["kind"] == "lost"]
    nosd = [g for g in gaps if g["kind"] == "nosd"]

    # Last received packet (highest seq): its backlog tells how many samples
    # were still on the watch after it. If no later packet arrived, those
    # samples were never delivered.
    last = max(rows, key=lambda r: (r["_seq"], -r["_backlog"]))
    tail_left = last["_backlog"]

    # Edge sequence in seq order (who received first). A new segment at every
    # change of edge AND at every new connection: going back to the same edge
    # after a lost link is an event worth seeing.
    timeline = []
    for m in merged:
        if (timeline and timeline[-1]["node"] == m["_node"]
                and timeline[-1]["conn"] == m["_conn"]):
            timeline[-1]["to"] = m["_seq"]
            timeline[-1]["rt_to"] = m["realTime"]
        else:
            timeline.append(dict(node=m["_node"], frm=m["_seq"], to=m["_seq"],
                                 rt_from=m["realTime"], rt_to=m["realTime"],
                                 conn=m["_conn"]))

    per_node = defaultdict(int)
    for m in merged:
        per_node[m["_node"]] += 1

    kind = rows[0]["_kind"]
    battery = battery_radio(merged) if kind == "v4" else None
    values = monitor_summary(merged) if kind == "v5" else None

    return dict(
        kind=kind, battery=battery, values=values,
        merged=merged, missing=missing, conflicts=conflicts, tail_left=tail_left,
        gaps=gaps, lost=lost, nosd=nosd,
        timeline=timeline, per_node=dict(per_node),
        rows=len(rows), unique=len(merged), max_seq=max_seq,
        dup_rows=len(rows) - len(merged),
        max_backlog=max(r["_backlog"] for r in rows),
        conns=len({r["_conn"] for r in rows}),
    )


def battery_radio(merged):
    """Battery and radio from the first to the last sample with a valid battery.

    The two samples are all it takes: the telemetry counters are cumulative,
    so their difference also covers what happened on the edges without SD,
    whose samples are in no file."""
    rows = [m for m in merged
            if m.get("watchBatt", "") not in ("", str(BATT_SENTINEL)) and m.get("realTime", "") != ""]
    if len(rows) < 2:
        return None
    a, b = rows[0], rows[-1]
    t0, t1 = int(a["realTime"]), int(b["realTime"])
    out = dict(rows=len(rows), seq0=a["_seq"], seq1=b["_seq"], t0=t0, t1=t1, dt=t1 - t0,
               b0=int(a["watchBatt"]) / 100.0, b1=int(b["watchBatt"]) / 100.0)
    out["db"] = out["b0"] - out["b1"]
    out["rate"] = out["db"] / (out["dt"] / 3600.0) if out["dt"] > 0 else None

    ta, tb = telemetry_of(a), telemetry_of(b)
    if ta is not None and tb is not None:
        out["tel"] = {k: (tb[k] - ta[k]) % mod for k, mod in TEL_CUMUL}
        out["tel_last"] = tb
    return out


def print_battery(bt):
    print("-" * 72)
    if bt is None:
        print("Battery and radio: at least 2 samples with the battery are needed.")
        return
    dt = bt["dt"]
    print("Battery and radio (from seq %d to seq %d, %d samples with battery):"
          % (bt["seq0"], bt["seq1"], bt["rows"]))
    print("  elapsed time           %8.1f min" % (dt / 60.0))
    rate = ("%.2f %%/h" % bt["rate"]) if bt["rate"] is not None else "-"
    print("  battery                %6.2f %% -> %.2f %%   drop %.2f points   (%s)"
          % (bt["b0"], bt["b1"], bt["db"], rate))
    tel = bt.get("tel")
    if tel is None:
        print("  radio telemetry        missing (file without the proto_ver 0x05 columns)")
        return

    def pct(v):
        return ("%5.1f %%" % (100.0 * v / dt)) if dt > 0 else "  -"
    print("  connected              %8d s   %s of the time" % (tel["t_conn_s"], pct(tel["t_conn_s"])))
    print("  pairing                %8d s   %s" % (tel["t_agg_s"], pct(tel["t_agg_s"])))
    print("  scan on                %8d s   %s" % (tel["t_scan_s"], pct(tel["t_scan_s"])))
    print("  pairings               %8d succeeded out of %d attempts" % (tel["n_conn"], tel["n_try"]))
    print("  end of connection      %8d intended handoffs, %d lost links" % (tel["n_ho"], tel["n_lost"]))
    print("  chunks sent            %8d   failed packets %d" % (tel["tx_chunks"], tel["n_fail"]))
    last = bt["tel_last"]
    state = RADIO_NAMES.get(last["radio"], "?")
    rssi = "--" if last["rssi"] == -128 else "%d dBm" % last["rssi"]
    print("  at the last sample     radio=%s, RSSI %s, coda %d" % (state, rssi, last["coda"]))
    if dt > 65535:
        print("  WARNING: beyond 18.2 h the 16-bit counters wrap around: intermediate "
              "samples are needed to rebuild them.")


def _num(v, conv):
    """Value of a v5 column, or None for "N/A" (missing data) or empty."""
    try:
        return conv(v)
    except (TypeError, ValueError):
        return None


def monitor_summary(merged):
    """v5: the 4 values of the session from the rebuilt samples (in seq order).

    Steps are the daily counter: the increments between consecutive samples
    with data are summed, so a gap (samples gone to an edge without SD) takes
    nothing away, and a reset at midnight counts as a restart from 0."""
    def series(col, conv):
        return [(m["_seq"], v) for m in merged for v in [_num(m.get(col), conv)] if v is not None]

    rt = series("realTime", int)
    hr = [v for _, v in series("hr", int)]
    batt = series("batt", float)
    steps = [v for _, v in series("steps", int)]
    alt = [v for _, v in series("alt", int)]
    out = dict(n=len(merged), seq0=merged[0]["_seq"], seq1=merged[-1]["_seq"],
               na={c: sum(1 for m in merged if _num(m.get(c), float) is None)
                   for c in ("hr", "batt", "steps", "alt")})
    if len(rt) >= 2:
        out["t0"], out["t1"] = rt[0][1], rt[-1][1]
    if hr:
        out["hr"] = (min(hr), sum(hr) / len(hr), max(hr))
    if len(batt) >= 2:
        rt_of = dict(rt)
        (s0, b0), (s1, b1) = batt[0], batt[-1]
        dt = (rt_of.get(s1, 0) - rt_of.get(s0, 0)) if s0 in rt_of and s1 in rt_of else 0
        out["batt"] = (b0, b1, b0 - b1, (b0 - b1) / (dt / 3600.0) if dt > 0 else None)
    if steps:
        out["steps"] = (steps[0], steps[-1],
                        sum(b - a if b >= a else b for a, b in zip(steps, steps[1:])))
    if alt:
        out["alt"] = (min(alt), max(alt), alt[0], alt[-1])
    return out


def print_monitor(v):
    print("-" * 72)
    print("Session values (seq %d..%d, %d samples received):" % (v["seq0"], v["seq1"], v["n"]))
    if "t0" in v:
        print("  duration               %8.1f min   (realTime %d..%d)"
              % ((v["t1"] - v["t0"]) / 60.0, v["t0"], v["t1"]))
    if "hr" in v:
        print("  heart rate             min %d   mean %.1f   max %d bpm" % v["hr"])
    if "batt" in v:
        b0, b1, db, rate = v["batt"]
        print("  battery                %6.2f %% -> %.2f %%   drop %.2f points   (%s)"
              % (b0, b1, db, ("%.2f %%/h" % rate) if rate is not None else "-"))
    if "steps" in v:
        a, b, tot = v["steps"]
        print("  steps                  %8d in the session   (daily counter %d -> %d)" % (tot, a, b))
    if "alt" in v:
        print("  altitude               min %d m   max %d m   (start %d m, end %d m)" % v["alt"])
    na = ", ".join("%s %d" % (c, n) for c, n in v["na"].items() if n)
    if na:
        print("  samples without data   %s" % na)


def summarize_events(files, session=None):
    out = {}
    for f in files:
        node = int(EVENTS_RE.search(os.path.basename(f)).group(1))
        counts = defaultdict(int)
        with open(f, newline="", encoding="utf-8") as fh:
            for r in csv.DictReader(fh):
                ev = r.get("event", "")
                if session is not None and ev not in ("boot", "connect", "disconnect"):
                    try:
                        if int(r.get("session") or 0) != session:
                            continue
                    except ValueError:
                        continue
                if ev == "disconnect":
                    reason = (r.get("a") or "").lower()
                    ev = {"0x213": "disconnect (closed by the watch)",
                          "0x208": "disconnect (link lost)",
                          "0x216": "disconnect (closed by the edge, simulation)"}.get(reason, "disconnect " + reason)
                counts[ev] += 1
        out[node] = dict(counts)
    return out


def write_merged(path, session, merged):
    cols = merged[0]["_cols"]
    extra = [] if all(c in cols for c in TEL_COLS) or not all(c in cols for c in TEL_RAW) else TEL_COLS
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["session", "seq", "node", "copies", "nodes", "conn_no", "backlog"] + cols + extra)
        for m in merged:
            t = telemetry_of(m) if extra else None
            w.writerow([session, m["_seq"], m["_node"], m["_copies"],
                        "|".join(str(n) for n in m["_nodes"]), m["_conn"], m["_backlog"]]
                       + [m.get(f, "") for f in cols] + ([t[k] for k in extra] if t else []))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="folders (searched recursively) or CSV files")
    ap.add_argument("--out", help="merged CSV (with several sessions: one file per session, suffix _<session>)")
    ap.add_argument("--session", type=int, help="process only this session")
    a = ap.parse_args()

    data_files, event_files = find_files(a.paths)
    if not data_files:
        print("No multi_<session>_n<node>.csv (v4) or monitor_<session>_n<node>.csv (v5) file found.")
        return 1

    by_session = load_rows(data_files)
    sessions = [a.session] if a.session is not None else sorted(by_session)
    rc = 0

    for s in sessions:
        rows = by_session.get(s)
        if not rows:
            print("Session %d: no data." % s)
            rc = 1
            continue
        res = merge_session(s, rows)
        nodes = sorted({r["_node"] for r in rows})

        print("=" * 72)
        print("Session %d  %s  (edges with data: %s)"
              % (s, "v5 MONITOR" if res["kind"] == "v5" else "v4 MULTI",
                 ", ".join("E%d" % n for n in nodes)))
        print("-" * 72)
        print("Unique samples          %6d   (seq 0..%d)" % (res["unique"], res["max_seq"]))
        print("Total rows              %6d   of which duplicates: %d" % (res["rows"], res["dup_rows"]))
        print("Connections seen        %6d   max queue on the watch: %d"
              % (res["conns"], res["max_backlog"]))
        for n in nodes:
            print("  first received by E%-3d %6d" % (n, res["per_node"].get(n, 0)))

        n_nosd = sum(g["n"] for g in res["nosd"])
        n_lost = sum(g["n"] for g in res["lost"])
        if n_nosd:
            conns = sorted({c for g in res["nosd"] for c in range(g["cp"] + 1, g["cn"])})
            print("To edges without files  %6d   seq: %s"
                  % (n_nosd, fmt_ranges([(g["frm"], g["to"]) for g in res["nosd"]])))
            print("                                (connections %s: edge without SD or card not copied)"
                  % ", ".join(str(c % 256) for c in conns))
        if n_lost:
            print("LOST (no edge)          %6d   seq: %s"
                  % (n_lost, fmt_ranges([(g["frm"], g["to"]) for g in res["lost"]])))
            rc = max(rc, 2)
        else:
            print("LOST (no edge)               0")
        if res["tail_left"]:
            print("Left on the watch       %6d   (backlog of the last packet: %s"
                  " before delivering them)"
                  % (res["tail_left"], "app closed" if res["kind"] == "v5" else "activity closed"))
        if res["conflicts"]:
            print("CONFLICTS               %6d   seq with DIFFERENT copies: %s"
                  % (len(res["conflicts"]), fmt_ranges(ranges(res["conflicts"]))))
            rc = max(rc, 3)

        print("-" * 72)
        print("Edge sequence (by seq):")
        rows_tl = [(t["frm"], t) for t in res["timeline"]] + [(g["frm"], g) for g in res["gaps"]]
        for _, t in sorted(rows_tl, key=lambda x: x[0]):
            if "node" in t:
                print("  E%-3d seq %6d..%-6d  realTime %s..%s  (conn %d)"
                      % (t["node"], t["frm"], t["to"], t["rt_from"], t["rt_to"], t["conn"]))
            elif t["kind"] == "nosd":
                print("  --   seq %6d..%-6d  edge without files (conn %s)"
                      % (t["frm"], t["to"], ",".join(str(c % 256) for c in range(t["cp"] + 1, t["cn"]))))
            else:
                print("  !!   seq %6d..%-6d  LOST" % (t["frm"], t["to"]))

        if res["kind"] == "v5":
            print_monitor(res["values"])
        else:
            print_battery(res["battery"])

        ev = summarize_events(event_files, s)
        if ev:
            print("-" * 72)
            print("Edge events (boot/connect/disconnect: all; the rest: this session):")
            for n in sorted(ev):
                items = ", ".join("%s=%d" % (k, v) for k, v in sorted(ev[n].items()))
                print("  E%-3d %s" % (n, items or "-"))

        if a.out:
            path = a.out
            if len(sessions) > 1:
                root, ext = os.path.splitext(a.out)
                path = "%s_%d%s" % (root, s, ext or ".csv")
            write_merged(path, s, res["merged"])
            print("-" * 72)
            print("[GEN]", path)

    return rc


if __name__ == "__main__":
    sys.exit(main())
