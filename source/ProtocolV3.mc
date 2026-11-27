import Toybox.Lang;

//
// ProtocolV3.mc — PROTOCOL v3, Garmin side: the chunked transport, the FULL /
// DELTA / BATCH formats and the CRCs. The other protocols are v4
// (ProtocolV4.mc, MULTI) and v5 (ProtocolV5.mc, MONITOR).
//
// The transport and the CRCs are used by ALL versions: v4 and v5 travel inside
// this transport (flags = FMT_APP) and close their packets with these CRCs.
//
// C mirror: esp32/main/include/protocol_v3.h. The tables are reproduced
// IDENTICALLY on both sides. Bitfields are FORBIDDEN: only explicit
// shifts/masks on both sides.
//
//   chunk = HEADER (4 bytes) + PAYLOAD (1..16 bytes)
//
// HEADER: one uint32 word, sent BIG-ENDIAN.
//
//   | Bit   | Field   | Width | Meaning                                              |
//   |-------|---------|-------|------------------------------------------------------|
//   | 31-24 | pktId   | 8     | logical packet ID, mod 256; same on all its chunks   |
//   | 23-22 | flags   | 2     | 00=FULL, 01=DELTA, 10=BATCH, 11=application (v4/v5)  |
//   | 21-17 | idx     | 5     | chunk index in the packet, from 0; payload at idx*16 |
//   | 16-12 | cnt     | 5     | total number of chunks in the packet (1..31)         |
//   | 11-0  | bitmask | 12    | DELTA only: bit i = field i present; FULL/BATCH = 0  |
//
//   header = (pktId << 24) | (flags << 22) | (idx << 17) | (cnt << 12) | bitmask
//
module ProtoV3 {

    // --- Formats (flags field) ---
    const FMT_FULL  = 0;   // 00 — payload = 12 fields (48 B)
    const FMT_DELTA = 1;   // 01 — payload = only the fields whose bit is set in the bitmask
    const FMT_BATCH = 2;   // 10 — payload = N consecutive FULL samples (N*48 B)
    const FMT_APP   = 3;   // 11 — self-describing APPLICATION payload: v4 (ProtocolV4.mc)
                           //      or v5 (ProtocolV5.mc), told apart by the proto_ver byte

    // FMT_APP reuses this transport ENTIRELY: same header, same chunking, same
    // reassembler. For FMT_APP the `bitmask` field is 0 and the payload length
    // is declared by the packet itself (n_samples), protected by its CRC-16.

    // --- Header shifts and masks (exact mirror of protocol_v3.h) ---
    const PKTID_SHIFT   = 24;
    const FLAGS_SHIFT   = 22;
    const IDX_SHIFT     = 17;
    const CNT_SHIFT     = 12;
    const PKTID_MASK    = 0xFF;   // 8 bits
    const FLAGS_MASK    = 0x03;   // 2 bits
    const IDX_MASK      = 0x1F;   // 5 bits
    const CNT_MASK      = 0x1F;   // 5 bits
    const BITMASK_MASK  = 0xFFF;  // 12 bits

    // --- Payload / fields ---
    const NFIELDS       = 12;     // the 12 values of the logical payload
    const FIELD_BYTES   = 4;      // every field = uint32
    const FULL_BYTES    = 48;     // 12 * 4
    const CHUNK_PAYLOAD = 16;     // max payload per chunk (20 B on-air - 4 B header)
    const SENTINEL      = 0xFFFFFFFFl; // "value missing" (Long: 0xFFFFFFFF does not fit a signed Number)

    // --- Value encoding offsets (no negative raw values) ---
    const ALT_OFFSET     = 10000;  // altitude: metres + 10000
    const HEADING_OFFSET = 10000;  // heading: rad*1000 + 10000

    // --- Field indices (i = also bit i of the bitmask) ---
    const F_HR        = 0;
    const F_CADENCE   = 1;
    const F_SPEED     = 2;   // m/s * 100 (fixed-point)
    const F_DISTANCE  = 3;   // metres (truncated)
    const F_ALTITUDE  = 4;   // metres + ALT_OFFSET
    const F_ASCENT    = 5;
    const F_CALORIES  = 6;
    const F_HEADING   = 7;   // rad*1000 + HEADING_OFFSET
    const F_TIMERTIME = 8;   // ms
    const F_BATTERY   = 9;   // % * 100
    const F_ELAPSED   = 10;  // ms since the activity started
    const F_REALTIME  = 11;  // epoch seconds UTC

    // Timestamp bits ALWAYS present in DELTA packets (8, 10, 11).
    // 0x100 | 0x400 | 0x800 = 0xD00
    const DELTA_FORCED_MASK = (1 << F_TIMERTIME) | (1 << F_ELAPSED) | (1 << F_REALTIME);

    // Builds the 32-bit header word. Returns a Number (32 bits) from which
    // extracting the bytes with >>N & 0xFF stays correct even if bit 31 is 1.
    function packHeader(pktId as Number, flags as Number, idx as Number, cnt as Number, bitmask as Number) as Number {
        return ((pktId & PKTID_MASK)   << PKTID_SHIFT)
             | ((flags & FLAGS_MASK)   << FLAGS_SHIFT)
             | ((idx   & IDX_MASK)     << IDX_SHIFT)
             | ((cnt   & CNT_MASK)     << CNT_SHIFT)
             | ( bitmask & BITMASK_MASK);
    }

    // Writes a 32-bit integer as 4 BIG-ENDIAN bytes into `buf` at `off`.
    // Accepts a Number or a Long (field values may be SENTINEL = Long).
    function putBe32(buf as ByteArray, off as Number, v) as Void {
        buf[off + 0] = ((v >> 24) & 0xFF).toNumber();
        buf[off + 1] = ((v >> 16) & 0xFF).toNumber();
        buf[off + 2] = ((v >>  8) & 0xFF).toNumber();
        buf[off + 3] = ( v        & 0xFF).toNumber();
    }

    // 12-bit popcount (used to size DELTA packets).
    function popcount12(m as Number) as Number {
        var c = 0;
        for (var i = 0; i < NFIELDS; i++) {
            if ((m & (1 << i)) != 0) { c++; }
        }
        return c;
    }

    // =======================================================================
    // CRC-16/CCITT-FALSE — poly 0x1021, init 0xFFFF, no reflect, no xorout
    // =======================================================================
    // Closes v4 and v5 packets. Check value: crc16("123456789") == 0x29B1.
    // Implemented per NIBBLE (16-entry table) instead of per bit: on the 62
    // bytes covered by the CRC of a steady-state v4 packet that is 124 lookups
    // against 496 interpreted iterations. The table is allocated ONCE (lazy
    // init) and then reused.

    var _crcTab = null;

    function crcTable() as Array<Number> {
        if (_crcTab == null) {
            _crcTab = [
                0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50A5, 0x60C6, 0x70E7,
                0x8108, 0x9129, 0xA14A, 0xB16B, 0xC18C, 0xD1AD, 0xE1CE, 0xF1EF
            ];
        }
        return _crcTab;
    }

    // CRC of the first `len` bytes of `buf`.
    function crc16(buf as ByteArray, len as Number) as Number {
        var t = crcTable();
        var c = 0xFFFF;
        for (var i = 0; i < len; i++) {
            var b = buf[i] & 0xFF;
            c = ((c << 4) & 0xFFFF) ^ t[((c >> 12) ^ (b >> 4)) & 0x0F];
            c = ((c << 4) & 0xFFFF) ^ t[((c >> 12) ^ (b & 0x0F)) & 0x0F];
        }
        return c & 0xFFFF;
    }

    // =======================================================================
    // CRC-8 — poly 0x07, init 0x00, no reflect, no xorout
    // =======================================================================
    // Protects the v5 alerts (20 bytes). crc8("123456789") == 0xF4. Bit by
    // bit: a few bytes, once in a while, do not justify a second table.

    function crc8(buf as ByteArray, len as Number) as Number {
        var c = 0;
        for (var i = 0; i < len; i++) {
            c = (c ^ (buf[i] & 0xFF)) & 0xFF;
            for (var k = 0; k < 8; k++) {
                if ((c & 0x80) != 0) {
                    c = ((c << 1) ^ 0x07) & 0xFF;
                } else {
                    c = (c << 1) & 0xFF;
                }
            }
        }
        return c & 0xFF;
    }
}
