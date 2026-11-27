import Toybox.Lang;

//
// ProtocolV5.mc — PROTOCOL v5 (MONITOR: device app, 4 values, alerts from the
// edges), Garmin side.
//
// The full specification is docs/v5_monitoring.md, the single source of truth
// for V5. Here are the offset tables, reproduced IDENTICALLY in the C mirror
// esp32/main/include/protocol_v5.h. The Python reference of the format is
// tools/check_v5.py.
//
// ===========================================================================
// RELATION TO THE OTHER PROTOCOLS
// ===========================================================================
// Transport: the v3 one, unchanged (Chunker, flags = ProtoV3.FMT_APP). Same
// magic as v4: proto_ver = 0x06 tells them apart. All big-endian, like v4. The
// CRCs are those of ProtocolV3.mc (ProtoV3.crc16, ProtoV3.crc8).
//
// ===========================================================================
// UPLINK — FR255 -> ESP32
// ===========================================================================
//
// HEADER — 16 bytes (the first 14 are those of v4)
//
//   | Off | Type   | Field      | Notes                                         |
//   |-----|--------|------------|-----------------------------------------------|
//   |  0  | uint8  | magic      | 0xA5                                          |
//   |  1  | uint8  | proto_ver  | 0x06                                          |
//   |  2  | uint8  | node_id    | DESTINATION edge                              |
//   |  3  | uint8  | n_samples  | 0..8; 0 = alert confirmations only            |
//   |  4  | uint32 | session_id | epoch of the app opening (the session)        |
//   |  8  | uint32 | seq_first  | seq of the 1st sample (with n = 0: the next)  |
//   | 12  | uint8  | backlog    | samples queued AFTER these (saturates at 255) |
//   | 13  | uint8  | conn_no    | connection number in the session (mod 256)    |
//   | 14  | uint8  | ev_ack     | last alert RECEIVED from this edge            |
//   | 15  | uint8  | ev_user    | last alert CONFIRMED by the user              |
//
//   ev_ack and ev_user are cumulative (7 also confirms 6); 0 = none.
//
// SAMPLE — 12 bytes
//
//   | Off | Type   | Field    | Encoding                                       |
//   |-----|--------|----------|------------------------------------------------|
//   |  0  | uint32 | realTime | UTC epoch (s)                                  |
//   |  4  | uint16 | hr       | bpm                                            |
//   |  6  | uint16 | batt     | % x 100 (0..10000)                             |
//   |  8  | uint16 | steps    | steps of the day                               |
//   | 10  | uint16 | alt      | metres + 10000                                 |
//
//   Missing value: 0xFFFF. Values are rounded to the nearest integer and
//   saturated to 0..0xFFFE (encU16).
//
// TRAILER — 2 bytes: BE uint16 crc16 over EVERYTHING else.
//
// SIZES: 18 + 12*n.  n=0 -> 18 B (2 chunks), n=1 -> 30 B (2 chunks),
//                    n=4 -> 66 B (5 chunks), n=8 -> 114 B (8 chunks).
//
// ===========================================================================
// ALERT — ESP32 -> FR255, one 20-byte notification on the ALERT
// characteristic (51FF12BB-3ED8-46E5-B4F9-D64E25E01DBB)
// ===========================================================================
//
//   | Off | Type     | Field     | Notes                                      |
//   |-----|----------|-----------|--------------------------------------------|
//   |  0  | uint8    | magic     | 0x5A                                       |
//   |  1  | uint8    | proto_ver | 0x06                                       |
//   |  2  | uint8    | node_id   | sending edge                               |
//   |  3  | uint8    | ev_seq    | 1..255 per edge; 0 is not used             |
//   |  4  | uint8    | ev_type   | 0 test, 1 info, 2 warning, 3 danger        |
//   |  5  | uint8    | alert     | bit0 vibration, bit1 sound; 0 = message    |
//   |  6  | uint16   | ev_value  | parameter; 0xFFFF = none                   |
//   |  8  | char[11] | text      | ASCII, zero-padded; empty = type text      |
//   | 19  | uint8    | crc8      | over bytes 0..18                           |
//
module ProtoV5 {

    // --- Identification ---
    const MAGIC_UP   = 0xA5;
    const MAGIC_DOWN = 0x5A;
    const VER        = 0x06;

    // --- Uplink geometry ---
    const HDR_BYTES    = 16;
    const SAMPLE_BYTES = 12;
    const CRC_BYTES    = 2;
    const MAX_SAMPLES  = 8;
    const MAX_BACKLOG  = 255;

    // --- Header offsets ---
    const H_MAGIC    = 0;
    const H_VER      = 1;
    const H_NODE     = 2;
    const H_NSAMPLES = 3;
    const H_SESSION  = 4;
    const H_SEQ      = 8;
    const H_BACKLOG  = 12;
    const H_CONNNO   = 13;
    const H_EV_ACK   = 14;
    const H_EV_USER  = 15;

    // --- Sample offsets ---
    const S_TIME  = 0;
    const S_HR    = 4;
    const S_BATT  = 6;
    const S_STEPS = 8;
    const S_ALT   = 10;

    // --- Values ---
    const ABSENT     = 0xFFFF;    // "value missing"
    const MAX_VALUE  = 0xFFFE;    // largest value present
    const ALT_OFFSET = 10000;     // altitude: metres + 10000, as in v3

    // --- Alert ---
    const ALERT_BYTES = 20;
    const TEXT_BYTES  = 11;
    const A_MAGIC = 0;
    const A_VER   = 1;
    const A_NODE  = 2;
    const A_SEQ   = 3;
    const A_TYPE  = 4;
    const A_ALERT = 5;
    const A_VALUE = 6;
    const A_TEXT  = 8;
    const A_CRC8  = 19;

    const AL_VIBE = 0x01;         // bits of the alert field
    const AL_TONE = 0x02;

    const EV_TEST   = 0;          // ev_type
    const EV_INFO   = 1;
    const EV_WARN   = 2;
    const EV_DANGER = 3;

    const VALUE_NONE = 0xFFFF;

    // Indices of the Array returned by parseAlert.
    const P_NODE  = 0;
    const P_SEQ   = 1;
    const P_TYPE  = 2;
    const P_ALERT = 3;
    const P_VALUE = 4;
    const P_TEXT  = 5;

    // -----------------------------------------------------------------------
    // Encoding of the 4 values
    // -----------------------------------------------------------------------

    // x*scale + off rounded to the nearest integer and saturated to
    // 0..MAX_VALUE; null -> ABSENT. With a Float all the arithmetic stays 32
    // bits, which is what the Python reference reproduces.
    function encU16(x, scale as Number, off as Number) as Number {
        if (x == null) { return ABSENT; }
        var v = x * scale + off;
        if (v <= 0) { return 0; }
        v = (v + 0.5).toNumber();          // v > 0: truncating = rounding down
        return (v > MAX_VALUE) ? MAX_VALUE : v;
    }

    function encHr(bpm) as Number      { return encU16(bpm, 1, 0); }
    function encBatt(pct) as Number    { return encU16(pct, 100, 0); }
    function encSteps(steps) as Number { return encU16(steps, 1, 0); }
    function encAlt(m) as Number       { return encU16(m, 1, ALT_OFFSET); }

    // -----------------------------------------------------------------------
    // Uplink
    // -----------------------------------------------------------------------

    function putBe16(buf as ByteArray, off as Number, v as Number) as Void {
        buf[off]     = (v >> 8) & 0xFF;
        buf[off + 1] = v & 0xFF;
    }

    // A 12-byte sample from values ALREADY encoded (encHr, encBatt...).
    function packSample(realTime, hr as Number, batt as Number,
                        steps as Number, alt as Number) as ByteArray {
        var b = new [SAMPLE_BYTES]b;
        ProtoV3.putBe32(b, S_TIME, realTime);
        putBe16(b, S_HR, hr);
        putBe16(b, S_BATT, batt);
        putBe16(b, S_STEPS, steps);
        putBe16(b, S_ALT, alt);
        return b;
    }

    // Complete packet: header + already serialised samples + CRC. With empty
    // `samples` it is a confirmations-only packet (n_samples = 0).
    function buildPacket(node as Number, sessionId as Number, seqFirst as Number,
                         backlog as Number, connNo as Number, evAck as Number,
                         evUser as Number, samples as ByteArray) as ByteArray {
        var pkt = new [HDR_BYTES]b;
        pkt[H_MAGIC]    = MAGIC_UP;
        pkt[H_VER]      = VER;
        pkt[H_NODE]     = node & 0xFF;
        pkt[H_NSAMPLES] = samples.size() / SAMPLE_BYTES;
        ProtoV3.putBe32(pkt, H_SESSION, sessionId);
        ProtoV3.putBe32(pkt, H_SEQ, seqFirst);
        // Informative, as in v4: it saturates instead of wrapping.
        pkt[H_BACKLOG]  = (backlog > MAX_BACKLOG) ? MAX_BACKLOG : backlog;
        pkt[H_CONNNO]   = connNo & 0xFF;
        pkt[H_EV_ACK]   = evAck & 0xFF;
        pkt[H_EV_USER]  = evUser & 0xFF;
        pkt.addAll(samples);

        var crc = ProtoV3.crc16(pkt, pkt.size());
        var tr = new [CRC_BYTES]b;
        putBe16(tr, 0, crc);
        pkt.addAll(tr);
        return pkt;
    }

    // -----------------------------------------------------------------------
    // Alert
    // -----------------------------------------------------------------------

    // Validates a notification and decodes it into [node, ev_seq, ev_type,
    // alert, ev_value, text] (P_* indices), or null. Order of the checks:
    // length, magic, version, CRC-8, ev_seq != 0. Of the alert bits only
    // vibration and sound are kept: the others are reserved.
    function parseAlert(v) as Array? {
        if (v == null || !(v instanceof ByteArray) || v.size() != ALERT_BYTES) { return null; }
        if (v[A_MAGIC] != MAGIC_DOWN || v[A_VER] != VER) { return null; }
        if (ProtoV3.crc8(v, A_CRC8) != v[A_CRC8]) { return null; }
        if (v[A_SEQ] == 0) { return null; }

        // Text: up to the first 0. A byte outside printable ASCII cannot come
        // from the firmware: it becomes "?" instead of reaching the screen.
        var text = "";
        for (var i = A_TEXT; i < A_TEXT + TEXT_BYTES; i++) {
            var c = v[i];
            if (c == 0) { break; }
            text += ((c >= 0x20 && c <= 0x7E) ? c : 0x3F).toChar().toString();
        }
        return [v[A_NODE], v[A_SEQ], v[A_TYPE], v[A_ALERT] & (AL_VIBE | AL_TONE),
                (v[A_VALUE] << 8) | v[A_VALUE + 1], text];
    }
}
