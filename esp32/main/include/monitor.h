//
// monitor.h — Protocol v5 (MONITOR): parsed packet, parsing/validation and
// per-node continuity tracking.
//
// protocol_v5.h is the on-air format, monitor.c the parsing + the
// duplicate/jump logic, all testable on the host (no ESP-IDF dependency other
// than esp_log.h, which is a stub in the tests). Same structure as multi.h for
// v4, with a continuity state of its own.
//
#pragma once
#include <stdint.h>
#include <stdbool.h>

#include "protocol_v5.h"

// ---------------------------------------------------------------------------
// A validated v5 packet. The values stay encoded as on-air (V5_ABSENT = value
// missing): the monitor_fmt_*() functions translate them.
// ---------------------------------------------------------------------------
typedef struct {
    uint32_t real_time;    // UTC epoch (s)
    uint16_t hr;           // bpm
    uint16_t batt;         // % x 100
    uint16_t steps;        // steps of the day
    uint16_t alt;          // metres + V5_ALT_OFFSET
} monitor_sample_t;

typedef struct {
    uint8_t  node_id;      // destination edge declared by the watch
    uint8_t  n_samples;    // 0 = alert confirmations only
    uint32_t session_id;
    uint32_t seq_first;    // meaningless with n_samples = 0
    uint8_t  backlog;
    uint8_t  conn_no;
    uint8_t  ev_ack;       // last alert received from this edge (cumulative)
    uint8_t  ev_user;      // last alert confirmed by the user (cumulative)
    monitor_sample_t s[V5_MAX_SAMPLES];
} monitor_pkt_t;

// Same codes as multi_result_t: the reject event of edge_n<node>_events.csv
// writes them in column a, and for v4 and v5 they mean the same thing.
typedef enum {
    MONITOR_OK = 0,
    MONITOR_ERR_LEN = 1,       // length inconsistent with n_samples (or too short)
    MONITOR_ERR_MAGIC = 2,     // wrong magic or version
    MONITOR_ERR_NSAMPLES = 3,  // n_samples above V5_MAX_SAMPLES
    MONITOR_ERR_CRC = 4,       // CRC16 failed
} monitor_result_t;

// Parses a v5 packet already reassembled by the v3 transport.
// Order of the checks: minimum length, magic/version, n_samples, exact
// length, CRC16. It discards at the first failure: no partial recovery.
// n_samples = 0 is valid: a confirmations-only packet (ev_ack, ev_user).
monitor_result_t monitor_parse(const uint8_t *buf, uint32_t len, monitor_pkt_t *p);

// Readable name of an outcome (for the log).
const char *monitor_result_name(monitor_result_t r);

// ---------------------------------------------------------------------------
// Continuity as seen by THIS node: same rules as v4 (see multi.h).
// seq < next expected => duplicate (write response lost); forward jump => the
// samples in between were received by another edge. A confirmations-only
// packet (n_samples = 0) carries no seq and does not touch the state.
// ---------------------------------------------------------------------------
typedef struct {
    uint8_t  first_new;     // index of the 1st sample NEVER seen here (== n: all duplicates)
    bool     new_session;   // first packet with samples of this session on this node
    bool     jump;          // the new samples do not follow the last one received here
    uint32_t expected;      // seq this node expected (valid if jump)
} monitor_track_t;

// Updates the continuity state with a VALIDATED packet and returns its
// classification. A session different from the current one replaces it.
// With n_samples = 0 it returns all zeros and changes nothing.
void monitor_track(const monitor_pkt_t *p, monitor_track_t *t);

// Forgets session and numbering (used by the tests; on the device the state
// survives reconnections on purpose: the watch may come back).
void monitor_track_reset(void);

// ---------------------------------------------------------------------------
// Values as text, as in the CSV and on the console: "N/A" for a missing value.
//   hr, steps: the number as it is;
//   batt:      % with two decimals (8700 -> "87.00");
//   alt:       metres, offset removed (10123 -> "123", 0 -> "-10000").
// ---------------------------------------------------------------------------
#define MONITOR_TXT_LEN 12

void monitor_fmt_u16(uint16_t v, char out[MONITOR_TXT_LEN]);
void monitor_fmt_batt(uint16_t v, char out[MONITOR_TXT_LEN]);
void monitor_fmt_alt(uint16_t v, char out[MONITOR_TXT_LEN]);
