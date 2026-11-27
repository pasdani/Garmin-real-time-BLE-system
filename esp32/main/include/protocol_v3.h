//
// protocol_v3.h — PROTOCOL v3, ESP32 side: the chunked transport, the FULL /
// DELTA / BATCH formats and the CRCs. The other protocols are v4
// (protocol_v4.h, MULTI) and v5 (protocol_v5.h, MONITOR).
//
// The transport and the CRCs are used by ALL versions: v4 and v5 travel inside
// this transport (flags = PROTO_FMT_APP) and close their packets with these CRCs.
//
// Exact mirror of `source/ProtocolV3.mc`: watch and ESP32 MUST agree on the
// same binary interpretation. The tables are reproduced IDENTICALLY on both
// sides. C bitfields are FORBIDDEN (implementation-defined order): only
// explicit shifts/masks, defined here in ONE place.
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
#pragma once
#include <stdint.h>

// --- Formats (flags field) ---
#define PROTO_FMT_FULL   0   // 00 — payload = 12 fields (48 B)
#define PROTO_FMT_DELTA  1   // 01 — payload = only the fields whose bit is set in the bitmask
#define PROTO_FMT_BATCH  2   // 10 — payload = N consecutive FULL samples (N*48 B)
#define PROTO_FMT_APP    3   // 11 — self-describing APPLICATION payload: v4 (protocol_v4.h)
                             //      or v5 (protocol_v5.h), told apart by the proto_ver byte

// PROTO_FMT_APP reuses this transport ENTIRELY: same header, same chunking,
// same reassembler. For PROTO_FMT_APP the `bitmask` field is 0 and the payload
// length is declared by the packet itself (n_samples), protected by its CRC-16.

// --- Header shifts and masks (exact mirror of ProtocolV3.mc) ---
#define PKTID_SHIFT   24
#define FLAGS_SHIFT   22
#define IDX_SHIFT     17
#define CNT_SHIFT     12
#define PKTID_MASK    0xFFu
#define FLAGS_MASK    0x03u
#define IDX_MASK      0x1Fu
#define CNT_MASK      0x1Fu
#define BITMASK_MASK  0xFFFu

// --- Payload / fields ---
#define PROTO_NFIELDS       12
#define PROTO_FIELD_BYTES   4
#define PROTO_FULL_BYTES    48
#define PROTO_CHUNK_PAYLOAD 16
#define PROTO_SENTINEL      0xFFFFFFFFu   // "value missing" -> printed as N/A

// --- Encoding offsets (informative: the ESP32 prints the raw value) ---
#define ALT_OFFSET      10000
#define HEADING_OFFSET  10000

// --- Field indices (i = also bit i of the bitmask) ---
enum {
    F_HR = 0, F_CADENCE, F_SPEED, F_DISTANCE, F_ALTITUDE, F_ASCENT,
    F_CALORIES, F_HEADING, F_TIMERTIME, F_BATTERY, F_ELAPSED, F_REALTIME
};

// Timestamp bits ALWAYS present in DELTA packets (8, 10, 11).
#define DELTA_FORCED_MASK ((1u << F_TIMERTIME) | (1u << F_ELAPSED) | (1u << F_REALTIME))

// --- Header extraction with explicit shifts/masks (NO bitfields) ---
static inline uint8_t  hdr_pktId(uint32_t h)   { return (uint8_t)((h >> PKTID_SHIFT) & PKTID_MASK); }
static inline uint8_t  hdr_flags(uint32_t h)   { return (uint8_t)((h >> FLAGS_SHIFT) & FLAGS_MASK); }
static inline uint8_t  hdr_idx(uint32_t h)     { return (uint8_t)((h >> IDX_SHIFT)   & IDX_MASK);   }
static inline uint8_t  hdr_cnt(uint32_t h)     { return (uint8_t)((h >> CNT_SHIFT)   & CNT_MASK);   }
static inline uint16_t hdr_bitmask(uint32_t h) { return (uint16_t)(h & BITMASK_MASK); }

// Header composition (used by the symmetry unit test).
static inline uint32_t hdr_pack(uint8_t pktId, uint8_t flags, uint8_t idx,
                                uint8_t cnt, uint16_t bitmask) {
    return ((uint32_t)(pktId   & PKTID_MASK)   << PKTID_SHIFT)
         | ((uint32_t)(flags   & FLAGS_MASK)   << FLAGS_SHIFT)
         | ((uint32_t)(idx     & IDX_MASK)     << IDX_SHIFT)
         | ((uint32_t)(cnt     & CNT_MASK)     << CNT_SHIFT)
         | ((uint32_t)(bitmask & BITMASK_MASK));
}

// Rebuilds a uint32 from 4 BIG-ENDIAN bytes.
static inline uint32_t be32_read(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

// Name of a v3 format, for the `fmt` column of the CSVs (console and SD).
static inline const char *v3_fmt_name(uint8_t f) {
    switch (f) {
        case PROTO_FMT_FULL:  return "FULL";
        case PROTO_FMT_DELTA: return "DELTA";
        case PROTO_FMT_BATCH: return "BATCH";
        default:              return "?";
    }
}

// 12-bit popcount (sizing of DELTA packets).
static inline int popcount12(uint16_t m) {
    int c = 0;
    for (int i = 0; i < PROTO_NFIELDS; i++) { if (m & (1u << i)) { c++; } }
    return c;
}

// ===========================================================================
// CRC-16/CCITT-FALSE — poly 0x1021, init 0xFFFF, no reflect, no xorout
// ===========================================================================
// Closes v4 and v5 packets. Check value: crc16("123456789") == 0x29B1. Per
// nibble, 16-entry table: the same form used on the Monkey C side, so the two
// sources can be read side by side, line by line.

static const uint16_t V3_CRC16_TAB[16] = {
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50A5, 0x60C6, 0x70E7,
    0x8108, 0x9129, 0xA14A, 0xB16B, 0xC18C, 0xD1AD, 0xE1CE, 0xF1EF
};

static inline uint16_t v3_crc16(const uint8_t *buf, uint32_t len) {
    uint16_t c = 0xFFFF;
    for (uint32_t i = 0; i < len; i++) {
        uint8_t b = buf[i];
        c = (uint16_t)((c << 4) ^ V3_CRC16_TAB[((c >> 12) ^ (b >> 4)) & 0x0F]);
        c = (uint16_t)((c << 4) ^ V3_CRC16_TAB[((c >> 12) ^ (b & 0x0F)) & 0x0F]);
    }
    return c;
}

// ===========================================================================
// CRC-8 — poly 0x07, init 0x00, no reflect, no xorout
// ===========================================================================
// Protects the v5 alerts (20 bytes). crc8("123456789") == 0xF4. Bit by bit: a
// few bytes, once in a while, do not justify a second table.
static inline uint8_t v3_crc8(const uint8_t *buf, uint32_t len) {
    uint8_t c = 0;
    for (uint32_t i = 0; i < len; i++) {
        c ^= buf[i];
        for (int k = 0; k < 8; k++) {
            c = (uint8_t)((c & 0x80) ? ((c << 1) ^ 0x07) : (c << 1));
        }
    }
    return c;
}
