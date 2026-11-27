//
// multi.h — Protocol v4 (MULTI): parsed packet, parsing/validation and
// per-node continuity tracking.
//
// protocol_v4.h is the on-air format, multi.c the parsing + the
// duplicate/jump logic, all testable on the host (no ESP-IDF dependency other
// than esp_log.h, which is a stub in the tests).
//
#pragma once
#include <stdint.h>
#include <stdbool.h>

#include "protocol_v4.h"

// ---------------------------------------------------------------------------
// A validated v4 packet.
// ---------------------------------------------------------------------------
typedef struct {
    uint8_t  node_id;      // destination edge declared by the watch
    uint8_t  n_samples;
    uint32_t session_id;
    uint32_t seq_first;
    uint8_t  backlog;
    uint8_t  conn_no;
    uint32_t field[V4_MAX_SAMPLES][PROTO_NFIELDS];   // raw values: v3 fields 0-3 and
                                                     // 8-11 (or SENTINEL), 4-7 the
                                                     // telemetry (v4_tel_decode)
} multi_pkt_t;

typedef enum {
    MULTI_OK = 0,
    MULTI_ERR_LEN,         // length inconsistent with n_samples (or too short)
    MULTI_ERR_MAGIC,       // wrong magic or version
    MULTI_ERR_NSAMPLES,    // n_samples outside 1..V4_MAX_SAMPLES
    MULTI_ERR_CRC,         // CRC16 failed
} multi_result_t;

// Parses a v4 packet already reassembled by the v3 transport.
// Order of the checks: minimum length, magic/version, n_samples, exact
// length, CRC16. It discards at the first failure: no partial recovery.
multi_result_t multi_parse(const uint8_t *buf, uint32_t len, multi_pkt_t *p);

// Readable name of an outcome (for the log and events.csv).
const char *multi_result_name(multi_result_t r);

// ---------------------------------------------------------------------------
// Continuity as seen by THIS node.
//
// The watch sends the samples in increasing seq order and, at every
// reconnection, starts again from the first unconfirmed one. On a single edge
// therefore: seq < next_expected  <=>  sample already received here
// (duplicate). It happens when the last chunk arrived but its write response
// did not (link dropped at that very instant): the watch cannot know and
// sends it again.
//
// A forward jump is NOT a loss: in the meantime those samples were received by
// another edge. Real losses show up only when the files of all edges are
// merged (tools/merge_multi.py).
// ---------------------------------------------------------------------------
typedef struct {
    uint8_t  first_new;     // index of the 1st sample NEVER seen here (== n: all duplicates)
    bool     new_session;   // first packet of this session on this node
    bool     jump;          // the new samples do not follow the last one received here
    uint32_t expected;      // seq this node expected (valid if jump)
} multi_track_t;

// Updates the continuity state with a VALIDATED packet and returns its
// classification. A session different from the current one replaces it.
void multi_track(const multi_pkt_t *p, multi_track_t *t);

// Forgets session and numbering (used by the tests; on the device the state
// survives reconnections on purpose: the watch may come back).
void multi_track_reset(void);
