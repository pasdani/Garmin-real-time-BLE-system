//
// protocol_v4.h — APPLICATION PROTOCOL v4 (MULTI: one watch, several edges),
// ESP32 side.
//
// Exact mirror of `source/ProtocolV4.mc`: watch and ESP32 MUST agree on the
// same binary interpretation. The offset tables are reproduced IDENTICALLY in
// both files. C bitfields are FORBIDDEN.
//
// ===========================================================================
// PURPOSE
// ===========================================================================
// The watch moves among several ESP32s (edges) placed along the route. At any
// time it is connected to ONE only: the registered one with the best signal.
// When it changes edge (handoff) or loses the link, the undelivered samples
// stay in a queue on the watch and are sent again to the next edge. Besides
// the data, v4 therefore carries what is needed to rebuild the single stream
// OFFLINE from the files of the various edges: session, per-sample numbering,
// destination edge, connection number.
//
// ===========================================================================
// RELATION TO THE OTHER PROTOCOLS
// ===========================================================================
// Transport: the v3 one, unchanged. The v4 packet is the PAYLOAD of a
// transport packet with flags = PROTO_FMT_APP (0b11): that code point means
// "self-describing application payload" and the `proto_ver` byte (offset 1)
// tells v4 from v5. No compile-time flag: the same binary serves v3, v4 and v5.
//
// Samples: each has the geometry of the v3 FULL payload (12 BIG-endian uint32
// fields, 48 bytes); fields 0-3 and 8-11 also have its order, encodings and
// sentinels, fields 4-7 carry the radio telemetry (see SAMPLES). The WHOLE v4
// packet is big-endian.
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
//   Fields 0-3 and 8-11: as in the v3 FULL payload (see protocol_v3.h):
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
//   CRC-16/CCITT-FALSE (v3_crc16 in protocol_v3.h).
//
// SIZES: 16 + 48*n.
//   n=1 ->  64 bytes ->  4 full chunks (steady state: one sample every 5 s)
//   n=4 -> 208 bytes -> 13 chunks      (draining the queue)
//
// seq: starts from 0 at every session and is per SAMPLE, not per packet: it
// is the key used to deduplicate and merge the files of the various edges.
//
// ===========================================================================
// ACK: the write response of the LAST chunk
// ===========================================================================
// The watch writes the chunks WITH RESPONSE and considers the packet delivered
// only when ALL the writes had a positive outcome. NimBLE sends the write
// response after the access callback has returned, so the outcome of the last
// chunk reflects the validation of the whole packet: if the ESP32 discards it,
// it answers with an ATT error and the watch sends it again.
//
// ===========================================================================
// ADVERTISING — how the watch tells the edges apart
// ===========================================================================
// Besides the Service UUID, every edge publishes a Manufacturer Specific Data
// (company id 0xFFFF, reserved for testing by the Bluetooth SIG):
//
//   | Off | Type  | Field     | Notes                                         |
//   |-----|-------|-----------|-----------------------------------------------|
//   |  0  | uint8 | magic0    | 0x54 'T'                                      |
//   |  1  | uint8 | magic1    | 0x34 '4'                                      |
//   |  2  | uint8 | node_id   | 1..254, THIS_EDGE_NODE_ID in ble.c (at build) |
//   |  3  | uint8 | adv_flags | bit0 busy: connected, NON-connectable adv.    |
//
// Packet: flags (3) + 128-bit UUID (18) + this AD (8) = 29 bytes out of 31.
//
// The edge keeps advertising while it is connected (non-connectable, busy =
// 1): it is the only way the watch can measure the RSSI of the edge it is
// connected to, because Connect IQ does not expose the RSSI of a connection.
// Without it, the handoff would have no term of comparison.
//
#pragma once
#include <stdint.h>
#include <stdbool.h>

#include "protocol_v3.h"   // be32_read, PROTO_NFIELDS, PROTO_FULL_BYTES, v3_crc16

// --- Identification ---
#define V4_MAGIC           0xA5u   // = V5_MAGIC_UP: proto_ver decides
#define V4_VER             0x05u

// --- Geometry ---
#define V4_HDR_BYTES       14
#define V4_SAMPLE_BYTES    PROTO_FULL_BYTES   // 48: v3 FULL payload
#define V4_CRC_BYTES       2
#define V4_MAX_SAMPLES     4
#define V4_MAX_PKT_BYTES   (V4_HDR_BYTES + V4_MAX_SAMPLES * V4_SAMPLE_BYTES + V4_CRC_BYTES)  // 208

// --- Header offsets ---
#define V4_H_MAGIC         0
#define V4_H_VER           1
#define V4_H_NODE          2
#define V4_H_NSAMPLES      3
#define V4_H_SESSION       4
#define V4_H_SEQ           8
#define V4_H_BACKLOG       12
#define V4_H_CONNNO        13

// --- Radio telemetry: sample field indices and bits of the radio byte ---
#define V4_F_TEL_TIME      4
#define V4_F_TEL_LINK      5
#define V4_F_TEL_COUNT     6
#define V4_F_TEL_STATE     7
#define V4_R_STATE_MASK    0x03u   // bit0-1: 0 searching, 1 pairing, 2 connected
#define V4_R_SCAN_ON       0x04u   // bit2: BLE scan on
#define V4_R_ROAM_OK       0x08u   // bit3: roaming allowed
#define V4_RSSI_ABSENT     (-128)  // rssi not measured

// --- Advertising (Manufacturer Specific Data) ---
#define V4_ADV_COMPANY     0xFFFFu
#define V4_ADV_MAGIC0      0x54u   // 'T'
#define V4_ADV_MAGIC1      0x34u   // '4'
#define V4_ADV_BYTES       4       // payload after the company id
#define V4_A_MAGIC0        0
#define V4_A_MAGIC1        1
#define V4_A_NODE          2
#define V4_A_FLAGS         3
#define V4_ADV_F_BUSY      0x01u

static inline uint16_t v4_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

// Expected size of a v4 packet with n samples.
static inline uint32_t v4_expected_len(uint8_t n_samples) {
    return (uint32_t)V4_HDR_BYTES + (uint32_t)n_samples * V4_SAMPLE_BYTES + V4_CRC_BYTES;
}

// Radio telemetry of a sample, unpacked (fields 4-7).
typedef struct {
    uint16_t t_conn_s, t_scan_s, t_agg_s, tx_chunks;   // cumulative, mod 65536
    uint8_t  n_try, n_conn, n_ho, n_lost, n_fail;       // cumulative, mod 256
    uint8_t  radio;                                     // bit0-1 only (state)
    bool     scan_on, roam_ok;
    int8_t   rssi;                                      // V4_RSSI_ABSENT = not measured
    uint8_t  coda;
} v4_telemetry_t;

static inline void v4_tel_decode(const uint32_t f[PROTO_NFIELDS], v4_telemetry_t *t) {
    uint32_t tm = f[V4_F_TEL_TIME], ln = f[V4_F_TEL_LINK];
    uint32_t ct = f[V4_F_TEL_COUNT], st = f[V4_F_TEL_STATE];
    uint8_t  rb = (uint8_t)(st >> 16);
    t->t_conn_s  = (uint16_t)(tm >> 16);
    t->t_scan_s  = (uint16_t)(tm & 0xFFFFu);
    t->t_agg_s   = (uint16_t)(ln >> 16);
    t->tx_chunks = (uint16_t)(ln & 0xFFFFu);
    t->n_try     = (uint8_t)(ct >> 24);
    t->n_conn    = (uint8_t)(ct >> 16);
    t->n_ho      = (uint8_t)(ct >> 8);
    t->n_lost    = (uint8_t)ct;
    t->n_fail    = (uint8_t)(st >> 24);
    t->radio     = (uint8_t)(rb & V4_R_STATE_MASK);
    t->scan_on   = (rb & V4_R_SCAN_ON) != 0;
    t->roam_ok   = (rb & V4_R_ROAM_OK) != 0;
    // The byte is a two's complement int8: explicit sign extension, without
    // relying on the implementation-defined uint8 -> int8 conversion.
    uint8_t rs   = (uint8_t)(st >> 8);
    t->rssi      = (int8_t)((rs & 0x80u) ? (int)rs - 256 : (int)rs);
    t->coda      = (uint8_t)st;
}

// Name of the radio state printed on the console (radio=...). The names are
// kept as they are in the existing data and logs: ricerca = searching,
// aggancio = pairing, connesso = connected.
static inline const char *v4_radio_name(uint8_t radio) {
    switch (radio & V4_R_STATE_MASK) {
        case 0:  return "ricerca";
        case 1:  return "aggancio";
        case 2:  return "connesso";
        default: return "?";
    }
}

// MSD payload of the advertising (after the company id, which NimBLE wants at
// the start of the mfg_data buffer in little-endian: see ble.c).
static inline void v4_build_adv(uint8_t node_id, bool busy, uint8_t out[V4_ADV_BYTES]) {
    out[V4_A_MAGIC0] = V4_ADV_MAGIC0;
    out[V4_A_MAGIC1] = V4_ADV_MAGIC1;
    out[V4_A_NODE]   = node_id;
    out[V4_A_FLAGS]  = busy ? V4_ADV_F_BUSY : 0;
}
