import Toybox.Lang;

//
// ProtocolV4.mc — APPLICATION PROTOCOL v4 (MULTI: one watch, several edges),
// Garmin side.
//
// C mirror: `esp32/main/include/protocol_v4.h`. The specification is
// docs/protocol.md; the offset tables are reproduced IDENTICALLY in both
// files.
//
// ===========================================================================
// RELATION TO THE OTHER PROTOCOLS
// ===========================================================================
// Transport: the v3 one, unchanged (Chunker, pktId/idx/cnt). The v4 packet
// travels with flags = ProtoV3.FMT_APP: that code point carries a
// self-describing application payload, and `proto_ver` (offset 1) tells v4
// from v5. The samples are the v3 FULL payload (12 BE uint32 fields, 48 B), so
// the WHOLE v4 packet is big-endian.
//
// ===========================================================================
// PACKET — FR255 -> ESP32
// ===========================================================================
//
// HEADER — 14 bytes
//
//   | Off | Type   | Field      | Notes                                        |
//   |-----|--------|------------|----------------------------------------------|
//   |  0  | uint8  | magic      | 0xA5 (the same as v5: proto_ver decides)     |
//   |  1  | uint8  | proto_ver  | 0x05                                         |
//   |  2  | uint8  | node_id    | DESTINATION edge, read from its advertising  |
//   |  3  | uint8  | n_samples  | 1..4                                         |
//   |  4  | uint32 | session_id | UTC epoch (s) of the activity start          |
//   |  8  | uint32 | seq_first  | seq of the 1st sample; the next ones are +1  |
//   | 12  | uint8  | backlog    | samples still queued AFTER this one (sat.255)|
//   | 13  | uint8  | conn_no    | connection number in the session (mod 256)   |
//
// SAMPLES — 48 bytes x n_samples: 12 BE uint32 fields, in v3 order.
//
//   Fields 0-3 and 8-11: as in the v3 FULL payload (see ProtocolV3.mc):
//   hr, cad, speed, dist, timer, battery (%*100), elapsed, realTime.
//
//   Fields 4-7: RADIO TELEMETRY of the watch, in place of altitude, ascent,
//   kcal and heading (not needed for this study). Same size: the radio
//   traffic does not change. Read at the SAME instant as the battery.
//
//   | Field | Name      | Content (BE uint32)                                     |
//   |-------|-----------|---------------------------------------------------------|
//   |   4   | tel_time  | (t_conn_s << 16) | t_scan_s                             |
//   |   5   | tel_link  | (t_agg_s << 16)  | tx_chunks                            |
//   |   6   | tel_count | (n_try << 24) | (n_conn << 16) | (n_ho << 8) | n_lost   |
//   |   7   | tel_state | (n_fail << 24) | (radio << 16) | (rssi << 8) | coda     |
//
//   CUMULATIVE since the activity start (reset at every new session):
//     t_conn_s  seconds connected to an edge                   (mod 65536)
//     t_scan_s  seconds with the BLE scan on                   (mod 65536)
//     t_agg_s   seconds pairing (pairDevice in progress)       (mod 65536)
//     tx_chunks chunks written with a positive outcome         (mod 65536)
//     n_try     pairing attempts (calls to pairDevice)         (mod 256)
//     n_conn    successful connections                         (mod 256)
//     n_ho      intended handoffs (better signal)              (mod 256)
//     n_lost    links lost or abandoned because of errors      (mod 256)
//     n_fail    failed packets (write with negative outcome)   (mod 256)
//   INSTANTANEOUS:
//     radio     bit0-1 state (0 searching, 1 pairing, 2 connected), bit2
//               scan on, bit3 roaming allowed, bit4-7 = 0
//     rssi      int8, filtered RSSI of the current edge; -128 = not measured
//     coda      samples queued before this one (saturates at 255)
//
//   Being cumulative, the difference between ANY TWO received samples (for
//   example the first and the last of an SD file) tells what the radio did in
//   between, even if those samples went to other edges. Limits of a two-point
//   comparison: 18.2 h for the seconds, 255 events for the 8-bit counters
//   (beyond that they wrap around).
//
// TRAILER — 2 bytes: BE uint16 crc16 over the WHOLE packet except the trailer.
//   CRC-16/CCITT-FALSE (ProtoV3.crc16).
//
// SIZES: 16 + 48*n.
//   n=1 ->  64 bytes ->  4 full chunks (steady state: one sample every 5 s)
//   n=4 -> 208 bytes -> 13 chunks      (draining the queue)
//
// ACK: the packet is delivered when ALL the writes of its chunks (done WITH
// RESPONSE) had a positive outcome. The ESP32 answers the last chunk only after
// validating the whole packet: an ATT error = send it again.
//
// ===========================================================================
// ADVERTISING — how the edges are told apart
// ===========================================================================
// Manufacturer Specific Data, company id 0xFFFF (reserved for testing):
//
//   | Off | Type  | Field     | Notes                                         |
//   |-----|-------|-----------|-----------------------------------------------|
//   |  0  | uint8 | magic0    | 0x54 'T'                                      |
//   |  1  | uint8 | magic1    | 0x34 '4'                                      |
//   |  2  | uint8 | node_id   | 1..254, fixed when the ESP32 is built         |
//   |  3  | uint8 | adv_flags | bit0 busy: connected, NON-connectable adv.    |
//
// The edge keeps advertising while connected (non-connectable, busy = 1): it
// is the only way to know the RSSI of the edge the watch is connected to,
// because Connect IQ does not expose the RSSI of a connection.
//
module ProtoV4 {

    // --- Identification ---
    const MAGIC = 0xA5;
    const VER   = 0x05;

    // --- Geometry ---
    const HDR_BYTES    = 14;
    const SAMPLE_BYTES = 48;      // = ProtoV3.FULL_BYTES
    const CRC_BYTES    = 2;
    const MAX_SAMPLES  = 4;
    const MAX_BACKLOG  = 255;     // saturation of the backlog field

    // --- Header offsets ---
    const H_MAGIC    = 0;
    const H_VER      = 1;
    const H_NODE     = 2;
    const H_NSAMPLES = 3;
    const H_SESSION  = 4;
    const H_SEQ      = 8;
    const H_BACKLOG  = 12;
    const H_CONNNO   = 13;

    // --- Advertising ---
    const ADV_COMPANY = 0xFFFF;
    const ADV_MAGIC0  = 0x54;     // 'T'
    const ADV_MAGIC1  = 0x34;     // '4'
    const ADV_BYTES   = 4;
    const A_NODE      = 2;
    const A_FLAGS     = 3;
    const ADV_F_BUSY  = 0x01;

    // --- Radio telemetry in fields 4-7 of the sample ---
    const T_TIME  = 4;
    const T_LINK  = 5;
    const T_COUNT = 6;
    const T_STATE = 7;
    const R_SCAN_ON  = 0x04;      // bits of the radio byte
    const R_ROAM_OK  = 0x08;
    const RSSI_ABSENT = -128;
    const MAX_CODA   = 255;

    // Packs the telemetry into the 4 values of fields 4-7. Pure: all counters
    // arrive already computed, here only masks and shifts are applied (as on
    // the C side, which unpacks them with the same masks).
    function packTelemetry(tConnS as Number, tScanS as Number, tAggS as Number,
                           txChunks as Number, nTry as Number, nConn as Number,
                           nHo as Number, nLost as Number, nFail as Number,
                           radio as Number, scanOn as Boolean, roamOk as Boolean,
                           rssi as Number, coda as Number) as Array<Number> {
        var st = (radio & 0x03) | (scanOn ? R_SCAN_ON : 0) | (roamOk ? R_ROAM_OK : 0);
        var c = (coda > MAX_CODA) ? MAX_CODA : coda;
        return [
            ((tConnS & 0xFFFF) << 16) | (tScanS & 0xFFFF),
            ((tAggS & 0xFFFF) << 16) | (txChunks & 0xFFFF),
            ((nTry & 0xFF) << 24) | ((nConn & 0xFF) << 16) | ((nHo & 0xFF) << 8) | (nLost & 0xFF),
            ((nFail & 0xFF) << 24) | ((st & 0xFF) << 16) | ((rssi & 0xFF) << 8) | (c & 0xFF)
        ];
    }

    // Builds the complete packet: header + samples + CRC.
    // `samples` are already serialised (48 bytes each, from SampleRing.bytes):
    // no field is touched here, the bytes are appended and closed with the CRC.
    function buildPacket(node as Number, sessionId as Number, seqFirst as Number,
                         backlog as Number, connNo as Number, samples as ByteArray) as ByteArray {
        var pkt = new [HDR_BYTES]b;
        pkt[H_MAGIC]    = MAGIC;
        pkt[H_VER]      = VER;
        pkt[H_NODE]     = node & 0xFF;
        pkt[H_NSAMPLES] = samples.size() / SAMPLE_BYTES;
        ProtoV3.putBe32(pkt, H_SESSION, sessionId);
        ProtoV3.putBe32(pkt, H_SEQ, seqFirst);
        // The backlog is informative (how far behind the watch is): it
        // saturates instead of wrapping, so 256 is not read as 0.
        pkt[H_BACKLOG]  = (backlog > MAX_BACKLOG) ? MAX_BACKLOG : backlog;
        pkt[H_CONNNO]   = connNo & 0xFF;
        pkt.addAll(samples);

        var crc = ProtoV3.crc16(pkt, pkt.size());
        var tr = new [CRC_BYTES]b;
        tr[0] = (crc >> 8) & 0xFF;     // big-endian, like the rest of v4
        tr[1] = crc & 0xFF;
        pkt.addAll(tr);
        return pkt;
    }

    // Decodes the Manufacturer Specific Data of an advertisement.
    // Returns [node_id, adv_flags], or null if it is not a v4 edge.
    //
    // The documentation of ScanResult.getManufacturerSpecificData() only says
    // "decoded according to the Core Spec", without saying whether the company
    // id stays at the start of the returned bytes. Both forms are therefore
    // accepted: the magic at offset 0 or at offset 2 (after 0xFF 0xFF, which
    // cannot be mistaken for "T4").
    function parseAdv(md) as Array<Number>? {
        if (md == null || !(md instanceof ByteArray)) { return null; }
        for (var o = 0; o <= 2; o += 2) {
            if (md.size() >= o + ADV_BYTES
                && md[o] == ADV_MAGIC0 && md[o + 1] == ADV_MAGIC1) {
                return [md[o + A_NODE], md[o + A_FLAGS]];
            }
        }
        return null;
    }
}
