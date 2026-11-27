//
// multi.c — Parsing and validation of protocol v4, per-node continuity.
//
// It does not write to SD and does not touch the BLE stack: it is pure with
// respect to the incoming packet (except for the continuity state), so that
// test_v4.c can compile it on the host and test the code that really runs on
// the device.
//
#include <string.h>

#include "esp_log.h"

#include "multi.h"

static const char *TAG = "MULTI";

// Continuity of the current session on this node.
static bool     s_have_session = false;
static uint32_t s_session      = 0;
static uint32_t s_next_seq     = 0;    // first seq not yet received here

void multi_track_reset(void) {
    s_have_session = false;
    s_session      = 0;
    s_next_seq     = 0;
}

const char *multi_result_name(multi_result_t r) {
    switch (r) {
        case MULTI_OK:           return "ok";
        case MULTI_ERR_LEN:      return "len";
        case MULTI_ERR_MAGIC:    return "magic";
        case MULTI_ERR_NSAMPLES: return "n_samples";
        case MULTI_ERR_CRC:      return "crc";
        default:                 return "?";
    }
}

multi_result_t multi_parse(const uint8_t *buf, uint32_t len, multi_pkt_t *p) {
    if (len < V4_HDR_BYTES + V4_CRC_BYTES) {
        ESP_LOGD(TAG, "DROP: packet too short (%lu B)", (unsigned long)len);
        return MULTI_ERR_LEN;
    }
    if (buf[V4_H_MAGIC] != V4_MAGIC || buf[V4_H_VER] != V4_VER) {
        ESP_LOGD(TAG, "DROP: magic=0x%02X ver=0x%02X", buf[V4_H_MAGIC], buf[V4_H_VER]);
        return MULTI_ERR_MAGIC;
    }

    uint8_t n = buf[V4_H_NSAMPLES];
    if (n == 0 || n > V4_MAX_SAMPLES) {
        ESP_LOGD(TAG, "DROP: n_samples=%u out of range", n);
        return MULTI_ERR_NSAMPLES;
    }
    if (len != v4_expected_len(n)) {
        ESP_LOGD(TAG, "DROP: len=%lu expected=%lu (n=%u)",
                 (unsigned long)len, (unsigned long)v4_expected_len(n), n);
        return MULTI_ERR_LEN;
    }

    uint32_t body = len - V4_CRC_BYTES;
    uint16_t crc_rx   = v4_be16(buf + body);
    uint16_t crc_calc = v3_crc16(buf, body);
    if (crc_rx != crc_calc) {
        ESP_LOGD(TAG, "DROP: CRC16 rx=0x%04X calc=0x%04X", crc_rx, crc_calc);
        return MULTI_ERR_CRC;
    }

    // --- The packet is intact ---
    memset(p, 0, sizeof(*p));
    p->node_id    = buf[V4_H_NODE];
    p->n_samples  = n;
    p->session_id = be32_read(buf + V4_H_SESSION);
    p->seq_first  = be32_read(buf + V4_H_SEQ);
    p->backlog    = buf[V4_H_BACKLOG];
    p->conn_no    = buf[V4_H_CONNNO];

    for (uint8_t s = 0; s < n; s++) {
        const uint8_t *sp = buf + V4_HDR_BYTES + (uint32_t)s * V4_SAMPLE_BYTES;
        for (int i = 0; i < PROTO_NFIELDS; i++) {
            p->field[s][i] = be32_read(sp + i * PROTO_FIELD_BYTES);
        }
    }

    return MULTI_OK;
}

void multi_track(const multi_pkt_t *p, multi_track_t *t) {
    memset(t, 0, sizeof(*t));

    if (!s_have_session || p->session_id != s_session) {
        // New session (or first packet since boot): no comparison with the
        // previous numbering, which belonged to another activity.
        s_have_session = true;
        s_session      = p->session_id;
        s_next_seq     = p->seq_first + p->n_samples;
        t->new_session = true;
        t->first_new   = 0;
        return;
    }

    uint32_t end = p->seq_first + p->n_samples;

    if (p->seq_first < s_next_seq) {
        // All or part of it already received here.
        uint32_t dup = s_next_seq - p->seq_first;
        if (dup > p->n_samples) { dup = p->n_samples; }
        t->first_new = (uint8_t)dup;
        ESP_LOGW(TAG, "DUP: seq %lu+%u, %lu already received",
                 (unsigned long)p->seq_first, p->n_samples, (unsigned long)dup);
    } else if (p->seq_first > s_next_seq) {
        // Forward jump: the samples in between were received by another edge
        // (or are lost: merging the files of all the edges will tell).
        t->jump     = true;
        t->expected = s_next_seq;
        ESP_LOGI(TAG, "JUMP: expected seq %lu, received %lu",
                 (unsigned long)s_next_seq, (unsigned long)p->seq_first);
    }

    if (end > s_next_seq) { s_next_seq = end; }
}
