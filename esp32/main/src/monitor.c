//
// monitor.c — Parsing and validation of protocol v5, per-node continuity.
//
// It does not write to SD and does not touch the BLE stack: it is pure with
// respect to the incoming packet (except for the continuity state), so that
// test_v5.c can compile it on the host and test the code that really runs on
// the device.
//
#include <stdio.h>
#include <string.h>

#include "esp_log.h"

#include "monitor.h"

static const char *TAG = "MONITOR";

// Continuity of the current session on this node. Separate from the v4 one
// (multi.c): the two protocols number their samples independently.
static bool     s_have_session = false;
static uint32_t s_session      = 0;
static uint32_t s_next_seq     = 0;    // first seq not yet received here

void monitor_track_reset(void) {
    s_have_session = false;
    s_session      = 0;
    s_next_seq     = 0;
}

const char *monitor_result_name(monitor_result_t r) {
    switch (r) {
        case MONITOR_OK:           return "ok";
        case MONITOR_ERR_LEN:      return "len";
        case MONITOR_ERR_MAGIC:    return "magic";
        case MONITOR_ERR_NSAMPLES: return "n_samples";
        case MONITOR_ERR_CRC:      return "crc";
        default:                   return "?";
    }
}

monitor_result_t monitor_parse(const uint8_t *buf, uint32_t len, monitor_pkt_t *p) {
    if (len < v5_expected_len(0)) {
        ESP_LOGD(TAG, "DROP: packet too short (%lu B)", (unsigned long)len);
        return MONITOR_ERR_LEN;
    }
    if (buf[V5_H_MAGIC] != V5_MAGIC_UP || buf[V5_H_VER] != V5_VER) {
        ESP_LOGD(TAG, "DROP: magic=0x%02X ver=0x%02X", buf[V5_H_MAGIC], buf[V5_H_VER]);
        return MONITOR_ERR_MAGIC;
    }

    uint8_t n = buf[V5_H_NSAMPLES];
    if (n > V5_MAX_SAMPLES) {
        ESP_LOGD(TAG, "DROP: n_samples=%u above the maximum", n);
        return MONITOR_ERR_NSAMPLES;
    }
    if (len != v5_expected_len(n)) {
        ESP_LOGD(TAG, "DROP: len=%lu expected=%lu (n=%u)",
                 (unsigned long)len, (unsigned long)v5_expected_len(n), n);
        return MONITOR_ERR_LEN;
    }

    uint32_t body = len - V5_CRC_BYTES;
    uint16_t crc_rx   = v5_be16(buf + body);
    uint16_t crc_calc = v3_crc16(buf, body);
    if (crc_rx != crc_calc) {
        ESP_LOGD(TAG, "DROP: CRC16 rx=0x%04X calc=0x%04X", crc_rx, crc_calc);
        return MONITOR_ERR_CRC;
    }

    // --- The packet is intact ---
    memset(p, 0, sizeof(*p));
    p->node_id    = buf[V5_H_NODE];
    p->n_samples  = n;
    p->session_id = be32_read(buf + V5_H_SESSION);
    p->seq_first  = be32_read(buf + V5_H_SEQ);
    p->backlog    = buf[V5_H_BACKLOG];
    p->conn_no    = buf[V5_H_CONNNO];
    p->ev_ack     = buf[V5_H_EV_ACK];
    p->ev_user    = buf[V5_H_EV_USER];

    for (uint8_t s = 0; s < n; s++) {
        const uint8_t *sp = buf + V5_HDR_BYTES + (uint32_t)s * V5_SAMPLE_BYTES;
        p->s[s].real_time = be32_read(sp + V5_S_TIME);
        p->s[s].hr        = v5_be16(sp + V5_S_HR);
        p->s[s].batt      = v5_be16(sp + V5_S_BATT);
        p->s[s].steps     = v5_be16(sp + V5_S_STEPS);
        p->s[s].alt       = v5_be16(sp + V5_S_ALT);
    }
    return MONITOR_OK;
}

void monitor_track(const monitor_pkt_t *p, monitor_track_t *t) {
    memset(t, 0, sizeof(*t));

    // Confirmations only: the seq_first of these packets is the NEXT seq of
    // the watch, not a sample. Counting it would shift the numbering.
    if (p->n_samples == 0) { return; }

    if (!s_have_session || p->session_id != s_session) {
        // New session (or first packet since boot): no comparison with the
        // previous numbering, which belonged to another session.
        s_have_session = true;
        s_session      = p->session_id;
        s_next_seq     = p->seq_first + p->n_samples;
        t->new_session = true;
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
        // Forward jump: the samples in between were received by another edge.
        t->jump     = true;
        t->expected = s_next_seq;
        ESP_LOGI(TAG, "JUMP: expected seq %lu, received %lu",
                 (unsigned long)s_next_seq, (unsigned long)p->seq_first);
    }

    if (end > s_next_seq) { s_next_seq = end; }
}

void monitor_fmt_u16(uint16_t v, char out[MONITOR_TXT_LEN]) {
    if (v == V5_ABSENT) { snprintf(out, MONITOR_TXT_LEN, "N/A"); return; }
    snprintf(out, MONITOR_TXT_LEN, "%u", (unsigned)v);
}

// Two decimals with integer arithmetic: no float for a division by 100.
void monitor_fmt_batt(uint16_t v, char out[MONITOR_TXT_LEN]) {
    if (v == V5_ABSENT) { snprintf(out, MONITOR_TXT_LEN, "N/A"); return; }
    snprintf(out, MONITOR_TXT_LEN, "%u.%02u", (unsigned)(v / 100u), (unsigned)(v % 100u));
}

void monitor_fmt_alt(uint16_t v, char out[MONITOR_TXT_LEN]) {
    if (v == V5_ABSENT) { snprintf(out, MONITOR_TXT_LEN, "N/A"); return; }
    snprintf(out, MONITOR_TXT_LEN, "%d", (int)v - V5_ALT_OFFSET);
}
