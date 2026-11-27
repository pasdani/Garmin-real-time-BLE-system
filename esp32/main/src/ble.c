//
// ble.c — BLE GATT peripheral for the ESP32-CAM (ESP-IDF v5.5, NimBLE), protocols v3/v4/v5.
//
// Receives the chunks on the DATA characteristic, decodes the header
// (shifts/masks as in protocol_v3.h), reassembles the logical packets keyed by
// pktId, applies the integrity checks and routes them to the parser by `flags`
// (FULL/DELTA/BATCH). It prints one CSV row per sample (N/A for the sentinels)
// and keeps the "last known" state for DELTA. On disconnection it restarts
// advertising.
//
// flags = APP carries a self-describing application payload: the proto_ver
// byte chooses between v4 (0x05, MULTI, several edges) and v5 (0x06, MONITOR);
// any other value is rejected. For v4 and v5 the ATT outcome of the last chunk
// IS the packet ACK, and the edge keeps advertising (non-connectable) while
// connected: that is what lets the watch compare its RSSI with that of the
// other edges.
//
// V5 (Monitoring): the data arrive like v4 (monitor.c,
// monitor_<session>_n<node>.csv), and the edge sends simulated ALERTS to the
// watch app on the ALERT characteristic, only if the watch has subscribed to
// it (protocol_v5.h). Every alert is sent once, without retransmission: the
// alert confirmations (ev_ack, ev_user) are only read and printed.
//
#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "ble.h"
#include "protocol_v3.h"
#include "protocol_v4.h"
#include "protocol_v5.h"
#include "multi.h"
#include "multi_log.h"
#include "monitor.h"
#include "monitor_log.h"
#include "config.h"

static const char *TAG  = "GARMIN_BLE";
static const char *DTAG = "PROTO";   // protocol DEBUG log

// ===========================================================================
// BOARD CONFIGURATION — THE ONLY LINES TO CHANGE FROM ONE ESP32 TO ANOTHER.
// The rest of the firmware is identical on all boards. The first two say
// WHICH board it is (fleet table), the others HOW it behaves in the test
// (pass-by simulation, simulated V5 alerts).
//
//   THIS_EDGE_NODE_ID  ID of the edge node (protocol v4), 1-254. Every
//                      physical board must have a different one: two boards
//                      with the same ID are seen by the watch as ONE edge (same
//                      node_id in the advertising, same name, same SD file
//                      names). The watch connects only to IDs from
//                      Cfg.MULTI_NODE_MIN to MULTI_NODE_MAX (currently 1-10).
//
//   THIS_EDGE_HAS_SD   1 = the board has the microSD slot (ESP32-CAM AI-Thinker).
//                      0 = it does not: the mount is never attempted (GPIO 2,
//                      14 and 15 stay untouched), valid v4 and v5 packets are
//                      confirmed to the watch and then DISCARDED, and only the
//                      console rows remain of the data.
//
//   Example fleet                   THIS_EDGE_NODE_ID   THIS_EDGE_HAS_SD
//   ESP32-CAM AI-Thinker            1                   1
//   ESP32-CAM AI-Thinker            2                   1
//   ESP32-CAM WROVER (no SD)        3                   0
//   ESP32-WROVER                    4                   0
//   ESP32-WROVER                    5                   0
//   ESP32-WROVER                    6                   0
//   (3 is an ESP32-CAM with an ESP32-WROVER module: the microSD slot is not
//   fitted on the board)
//
//   THIS_EDGE_ON_S     PASS-BY SIMULATION of the watch. In the field the runner
//   THIS_EDGE_OFF_S    enters the range of the edge for a few seconds and then
//                      moves away; on the bench this cannot be reproduced, so
//                      the edge disappears instead: it stays "on" (visible and
//                      connectable) for ON seconds, then "off" (invisible) for
//                      OFF seconds, cycling continuously from boot, which
//                      starts "on". E.g. 10 / 120: visible 10 s every 2
//                      minutes. "Off" is NOT a reset: only the radio stops
//                      (advertising stopped, current connection closed by the
//                      edge). SD, seq continuity and uptime go on.
//                      THIS_EDGE_OFF_S 0 = simulation disabled, always on (the
//                      normal behaviour).
//
//   THIS_EDGE_EVENT_S      SIMULATED ALERTS of V5 (Monitoring), to the watch
//   THIS_EDGE_EVENT_ALERT  on the ALERT characteristic.
//                          The first one is sent as soon as the watch
//                          subscribes to ALERT, then one every EVENT_S seconds
//                          while it stays subscribed, each sent once. Only the
//                          Monitor watch app subscribes: with a data field
//                          (v3, v4) nothing is sent.
//                          EVENT_S: 0 = no alerts, otherwise at least 20.
//                          EVENT_ALERT: 0 message only, 1 vibration, 2 sound,
//                          3 both, 4 rotating by alert number (#1 message,
//                          #2 vibration, #3 sound, #4 both, #5 message
//                          again...).
//
// For a board: set the lines, then `idf.py -p <PORT> flash monitor`, and at
// boot check the line "edge node N ('EDGE-N'), SD ..., ...".
// ===========================================================================
#define THIS_EDGE_NODE_ID  1
#define THIS_EDGE_HAS_SD   1
#define THIS_EDGE_ON_S     10
#define THIS_EDGE_OFF_S    0
#define THIS_EDGE_EVENT_S      30
#define THIS_EDGE_EVENT_ALERT  4

_Static_assert(THIS_EDGE_NODE_ID >= 1 && THIS_EDGE_NODE_ID <= 254,
               "THIS_EDGE_NODE_ID must be between 1 and 254");
_Static_assert(THIS_EDGE_HAS_SD == 0 || THIS_EDGE_HAS_SD == 1,
               "THIS_EDGE_HAS_SD must be 0 or 1");
_Static_assert(THIS_EDGE_ON_S >= 1 && THIS_EDGE_ON_S <= 86400,
               "THIS_EDGE_ON_S must be between 1 and 86400 (one day)");
_Static_assert(THIS_EDGE_OFF_S >= 0 && THIS_EDGE_OFF_S <= 86400,
               "THIS_EDGE_OFF_S must be between 0 (disabled) and 86400");
_Static_assert(THIS_EDGE_EVENT_S == 0 || (THIS_EDGE_EVENT_S >= 20 && THIS_EDGE_EVENT_S <= 86400),
               "THIS_EDGE_EVENT_S must be 0 (no alerts) or between 20 and 86400");
_Static_assert(THIS_EDGE_EVENT_ALERT >= 0 && THIS_EDGE_EVENT_ALERT <= 4,
               "THIS_EDGE_EVENT_ALERT must be between 0 and 4");

// Read by the rest of the firmware as EDGE_NODE_ID and EDGE_HAS_SD (config.h).
const uint8_t g_edge_node_id = THIS_EDGE_NODE_ID;
const bool    g_edge_has_sd  = THIS_EDGE_HAS_SD;

// BLE name (scan response and GAP name): the node ID appears in the name, so
// in nRF Connect (or any scanner) the edges can be told apart at a glance. The
// watch does NOT use the name: the v3 variants look for the Service UUID, v4
// and v5 for the Manufacturer Specific Data.
#define NAME_STR_(x) #x
#define NAME_STR(x)  NAME_STR_(x)
#define DEVICE_NAME  "EDGE-" NAME_STR(THIS_EDGE_NODE_ID)

// ---------------------------------------------------------------------------
// UUIDs — BLE_UUID128_INIT wants the 16 bytes in LITTLE-ENDIAN order.
// ---------------------------------------------------------------------------
// Service:      A07498CA-AD5B-474E-940D-16F1F14E8972
static const ble_uuid128_t svc_uuid = BLE_UUID128_INIT(
    0x72, 0x89, 0x4E, 0xF1, 0xF1, 0x16, 0x0D, 0x94,
    0x4E, 0x47, 0x5B, 0xAD, 0xCA, 0x98, 0x74, 0xA0);
// DATA:         51FF12BB-3ED8-46E5-B4F9-D64E25E01DB5
static const ble_uuid128_t data_uuid = BLE_UUID128_INIT(
    0xB5, 0x1D, 0xE0, 0x25, 0x4E, 0xD6, 0xF9, 0xB4,
    0xE5, 0x46, 0xD8, 0x3E, 0xBB, 0x12, 0xFF, 0x51);
// ALERT:        51FF12BB-3ED8-46E5-B4F9-D64E25E01DBB
// V5 ALERTS (protocol_v5.h): NOTIFY, 20 bytes per notification. NimBLE adds by
// itself the CCCD required by the NOTIFY flag; that descriptor is what the
// watch writes to subscribe. Only the Monitor watch app subscribes: for the
// edge "subscribed to ALERT" means "it is a V5 watch", so alerts never reach
// the v3 and v4 data fields, which register the DATA characteristic only.
static const ble_uuid128_t alert_uuid = BLE_UUID128_INIT(
    0xBB, 0x1D, 0xE0, 0x25, 0x4E, 0xD6, 0xF9, 0xB4,
    0xE5, 0x46, 0xD8, 0x3E, 0xBB, 0x12, 0xFF, 0x51);

static uint8_t own_addr_type;
static uint16_t alert_val_handle;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static void advertise(void);
static void alert_set_sub(bool on);

// true while a central is connected: the advertising becomes NON-connectable
// and carries the busy bit (see advertise()).
static bool s_busy = false;

// Pass-by simulation (THIS_EDGE_ON_S / THIS_EDGE_OFF_S): true during the "off"
// phase, in which advertise() publishes nothing. It changes only in
// sim_phase(), a NimBLE callout: it runs in the stack task, the same context
// as gap_event() and advertise(), hence no races on s_busy, s_conn_handle and
// the advertising.
static bool s_sim_off = false;
static struct ble_npl_callout s_sim_co;

// V5 alerts (THIS_EDGE_EVENT_S / THIS_EDGE_EVENT_ALERT). Like the simulation,
// they change only in the stack task (gap_event() and the alert_tick()
// callout), hence no races. s_alert_sub = the connected watch is subscribed to
// ALERT: written by BLE_GAP_EVENT_SUBSCRIBE, cleared by the disconnection.
static bool    s_alert_sub = false;
static uint8_t s_alert_seq = 0;      // last ev_seq used (0 = none yet)
static struct ble_npl_callout s_alert_co;

// ---------------------------------------------------------------------------
// "Last known" state of the 12 fields (base for merging the DELTAs) + FIFO of
// the reconstructed samples, drained by the SD module (one row per sample).
// ---------------------------------------------------------------------------
static garmin_sample_t g_data;         // initialised in ble_init()

#define SAMPLE_QUEUE_LEN 32            // BATCH burst = 6 samples: ample margin
static QueueHandle_t s_sample_q = NULL;

// Queues the current snapshot as a sample for the SD logger (non-blocking).
static void sample_ready(void) {
    if (s_sample_q != NULL && xQueueSend(s_sample_q, &g_data, 0) != pdTRUE) {
        ESP_LOGW(TAG, "sample queue full: sample lost (SD slow or missing?)");
    }
}

bool ble_pop_sample(garmin_sample_t *out) {
    if (s_sample_q == NULL) { return false; }
    return xQueueReceive(s_sample_q, out, 0) == pdTRUE;
}

// v4 and v5 queues: accepted packets of each protocol and edge events, all
// drained by the SD task. The events are created here (connections,
// rejections, duplicates) but the SD card is touched only from core 1.
static QueueHandle_t s_multi_q = NULL;
static QueueHandle_t s_mon_q   = NULL;
static QueueHandle_t s_mev_q   = NULL;

// Session of the last accepted packet, v4 or v5: used to date the connection
// events, which arrive before the first packet of the connection. Data fields
// and Monitor never run together on the watch.
static uint32_t s_session = 0;

bool ble_pop_multi(multi_record_t *out) {
    if (s_multi_q == NULL) { return false; }
    return xQueueReceive(s_multi_q, out, 0) == pdTRUE;
}

bool ble_pop_monitor(monitor_record_t *out) {
    if (s_mon_q == NULL) { return false; }
    return xQueueReceive(s_mon_q, out, 0) == pdTRUE;
}

bool ble_pop_multi_event(multi_event_t *out) {
    if (s_mev_q == NULL) { return false; }
    return xQueueReceive(s_mev_q, out, 0) == pdTRUE;
}

static uint32_t uptime_ms(void) {
    return (uint32_t)(esp_timer_get_time() / 1000ULL);
}

// Queues an event for edge_n<node>_events.csv (non-blocking).
static void mev(uint8_t type, uint32_t session, uint32_t a, uint32_t b) {
    if (s_mev_q == NULL) { return; }
    multi_event_t e = {
        .uptime_ms = uptime_ms(), .type = type, .session = session, .a = a, .b = b,
    };
    if (xQueueSend(s_mev_q, &e, 0) != pdTRUE) {
        ESP_LOGW(TAG, "event queue full: event lost");
    }
}

// ---------------------------------------------------------------------------
// Diagnostic counters (break-even analysis)
// ---------------------------------------------------------------------------
static uint32_t cnt_full = 0, cnt_delta = 0, cnt_batch = 0, cnt_multi = 0, cnt_monitor = 0;
static uint32_t cnt_dropped = 0;
static uint32_t delta_popcount_sum = 0;   // sum of the DELTA bitmask popcounts
static uint32_t delta_pkt_count = 0;      // number of DELTA packets (for the average)

// ---------------------------------------------------------------------------
// Reassembly buffer (one at a time, key = pktId)
// ---------------------------------------------------------------------------
#define MAX_CHUNKS    31
#define MAX_PKT_BYTES (MAX_CHUNKS * PROTO_CHUNK_PAYLOAD)   // 496

static struct {
    bool     active;
    uint8_t  pktId;
    uint8_t  flags;
    uint8_t  cnt;
    uint16_t bitmask;
    uint32_t got_mask;                 // idx bits of the chunks already received
    int      received;                 // number of distinct chunks received
    uint16_t chunk_len[MAX_CHUNKS];    // payload length per idx
    uint8_t  buf[MAX_PKT_BYTES];
} rx;

static void rx_reset(void) {
    memset(&rx, 0, sizeof(rx));
    rx.active = false;
}

// ---------------------------------------------------------------------------
// CSV print: realTime,elapsed,hr,cad,speed,dist,alt,ascent,kcal,heading,timer,watchBatt,fmt
// N/A for the sentinels. Column order -> field indices.
// ---------------------------------------------------------------------------
static void print_csv(const uint32_t *fld, uint8_t fmt) {
    // Column -> field index map.
    static const int COL[PROTO_NFIELDS] = {
        F_REALTIME, F_ELAPSED, F_HR, F_CADENCE, F_SPEED, F_DISTANCE,
        F_ALTITUDE, F_ASCENT, F_CALORIES, F_HEADING, F_TIMERTIME, F_BATTERY
    };
    char line[256];
    int n = 0;
    for (int c = 0; c < PROTO_NFIELDS; c++) {
        uint32_t v = fld[COL[c]];
        if (v == PROTO_SENTINEL) {
            n += snprintf(line + n, sizeof(line) - n, "N/A");
        } else {
            n += snprintf(line + n, sizeof(line) - n, "%lu", (unsigned long)v);
        }
        line[n++] = ',';
    }
    n += snprintf(line + n, sizeof(line) - n, "%s", v3_fmt_name(fmt));
    printf("%s\n", line);
}

// ---------------------------------------------------------------------------
// Parsers of the three formats (on a complete and VALIDATED packet)
// ---------------------------------------------------------------------------
static void parse_full(const uint8_t *buf) {
    for (int i = 0; i < PROTO_NFIELDS; i++) {
        g_data.field[i] = be32_read(buf + i * PROTO_FIELD_BYTES);
    }
    g_data.fmt = PROTO_FMT_FULL;
    cnt_full++;
    print_csv(g_data.field, PROTO_FMT_FULL);
    sample_ready();
}

static void parse_delta(const uint8_t *buf, uint16_t bitmask) {
    // Only the fields whose bit is set, in increasing order; the others stay "last known".
    int off = 0;
    for (int i = 0; i < PROTO_NFIELDS; i++) {
        if (bitmask & (1u << i)) {
            g_data.field[i] = be32_read(buf + off);
            off += PROTO_FIELD_BYTES;
        }
    }
    g_data.fmt = PROTO_FMT_DELTA;
    cnt_delta++;
    delta_popcount_sum += popcount12(bitmask);
    delta_pkt_count++;
    print_csv(g_data.field, PROTO_FMT_DELTA);
    sample_ready();
}

static void parse_batch(const uint8_t *buf, uint8_t cnt) {
    int samples = cnt / 3;                 // 3 chunks = 48 B = 1 sample
    for (int s = 0; s < samples; s++) {
        const uint8_t *sp = buf + s * PROTO_FULL_BYTES;
        for (int i = 0; i < PROTO_NFIELDS; i++) {
            g_data.field[i] = be32_read(sp + i * PROTO_FIELD_BYTES);
        }
        g_data.fmt = PROTO_FMT_BATCH;
        print_csv(g_data.field, PROTO_FMT_BATCH);   // one row per sample
        sample_ready();                             // every sample of the block queued
    }
    cnt_batch++;
}

// ---------------------------------------------------------------------------
// PROTOCOL v4 — complete MULTI packet.
//
// Returns true if the packet is ACCEPTED: this is the outcome that goes back
// to the watch as the write response of the last chunk, i.e. its ACK. So only
// what the watch must send again is rejected:
//   - a packet that fails validation (nobody can trust it);
//   - a valid packet with no room to write it: confirming it and then losing
//     it here would be worse than leaving it in the watch queue.
// Duplicates instead are ACCEPTED: they are already here, resending them is
// useless. On a board without SD (EDGE_HAS_SD = 0) the queue to the SD is not
// used: a valid packet is always confirmed and then discarded.
// ---------------------------------------------------------------------------
static bool on_multi_packet(const uint8_t *buf, uint32_t len) {
    static multi_record_t rec;   // static: ~220 B, too much for the BLE task stack

    multi_result_t r = multi_parse(buf, len, &rec.p);
    if (r != MULTI_OK) {
        cnt_dropped++;
        mev(MEV_REJECT, s_session, (uint32_t)r, len);
        ESP_LOGW(DTAG, "v4 DROPPED (%s, %lu B): the watch will send it again",
                 multi_result_name(r), (unsigned long)len);
        return false;
    }

    // Checked BEFORE updating the continuity: a packet rejected because the
    // queue is full will come back, and at its second arrival it must not look
    // like a duplicate.
    if (EDGE_HAS_SD && (s_multi_q == NULL || uxQueueSpacesAvailable(s_multi_q) == 0)) {
        mev(MEV_QUEUE_FULL, rec.p.session_id, rec.p.seq_first, 0);
        ESP_LOGW(DTAG, "v4 seq=%lu rejected: SD queue full (slow SD?)",
                 (unsigned long)rec.p.seq_first);
        return false;
    }

    multi_track_t t;
    multi_track(&rec.p, &t);
    s_session = rec.p.session_id;

    if (t.new_session) { mev(MEV_SESSION, rec.p.session_id, rec.p.seq_first, 0); }
    if (t.jump)        { mev(MEV_JUMP, rec.p.session_id, t.expected, rec.p.seq_first); }
    if (t.first_new)   { mev(MEV_DUP, rec.p.session_id, rec.p.seq_first, t.first_new); }
    if (rec.p.node_id != EDGE_NODE_ID) {
        // Accepted anyway: the data are intact, and rejecting them would make
        // the watch spin. But it is almost certainly a flashing mistake (two
        // boards with the same ID), so it is written down.
        mev(MEV_NODE_MISMATCH, rec.p.session_id, rec.p.node_id, EDGE_NODE_ID);
        ESP_LOGW(DTAG, "v4 addressed to node %u, this is node %u",
                 rec.p.node_id, (unsigned)EDGE_NODE_ID);
    }

    rec.rx_ms     = uptime_ms();
    rec.first_new = t.first_new;
    if (EDGE_HAS_SD) {
        xQueueSend(s_multi_q, &rec, 0);   // there is room: checked above, single producer
    }

    // On the console: hr and telemetry of the LAST sample of the packet (the most recent).
    const uint32_t *last = rec.p.field[rec.p.n_samples - 1];
    char hr[12];
    uint32_t v = last[F_HR];
    if (v == PROTO_SENTINEL) { snprintf(hr, sizeof(hr), "N/A"); }
    else                     { snprintf(hr, sizeof(hr), "%lu", (unsigned long)v); }

    v4_telemetry_t tel;
    v4_tel_decode(last, &tel);
    char rssi[8];
    if (tel.rssi == V4_RSSI_ABSENT) { snprintf(rssi, sizeof(rssi), "N/A"); }
    else                            { snprintf(rssi, sizeof(rssi), "%d", (int)tel.rssi); }

    ESP_LOGI(DTAG, "v4 S=%lu seq=%lu+%u backlog=%u conn=%u hr=%s radio=%s rssi=%s t_conn=%us%s%s",
             (unsigned long)rec.p.session_id, (unsigned long)rec.p.seq_first,
             rec.p.n_samples, rec.p.backlog, rec.p.conn_no, hr,
             v4_radio_name(tel.radio), rssi, (unsigned)tel.t_conn_s,
             t.first_new ? " [DUP]" : "", t.jump ? " [JUMP]" : "");
    return true;
}

// ---------------------------------------------------------------------------
// PROTOCOL v5 — complete MONITOR packet.
//
// Same rules as v4 (on_multi_packet): the outcome goes back to the watch as
// the ACK; only an invalid packet is rejected or, on boards with SD, a valid
// one that finds no room in the queue; duplicates are confirmed. The events go
// into the same edge_n<node>_events.csv as v4.
//
// A confirmations-only packet (n_samples = 0) is always confirmed: it writes
// no rows, does not go through the queue and does not touch the seq
// continuity. ev_ack and ev_user are only printed: the edge does not resend
// alerts, so it does not need the confirmations.
// ---------------------------------------------------------------------------
static bool on_monitor_packet(const uint8_t *buf, uint32_t len) {
    static monitor_record_t rec;   // static like the v4 one: off the BLE task stack

    monitor_result_t r = monitor_parse(buf, len, &rec.p);
    if (r != MONITOR_OK) {
        cnt_dropped++;
        mev(MEV_REJECT, s_session, (uint32_t)r, len);
        ESP_LOGW(DTAG, "v5 DROPPED (%s, %lu B): the watch will send it again",
                 monitor_result_name(r), (unsigned long)len);
        return false;
    }
    const bool acks_only = (rec.p.n_samples == 0);

    // Checked BEFORE updating the continuity, as for v4.
    if (!acks_only && EDGE_HAS_SD && (s_mon_q == NULL || uxQueueSpacesAvailable(s_mon_q) == 0)) {
        mev(MEV_QUEUE_FULL, rec.p.session_id, rec.p.seq_first, 0);
        ESP_LOGW(DTAG, "v5 seq=%lu rejected: SD queue full (slow SD?)",
                 (unsigned long)rec.p.seq_first);
        return false;
    }

    monitor_track_t t;
    monitor_track(&rec.p, &t);     // with n_samples = 0 nothing changes
    s_session = rec.p.session_id;

    if (t.new_session) { mev(MEV_SESSION, rec.p.session_id, rec.p.seq_first, 0); }
    if (t.jump)        { mev(MEV_JUMP, rec.p.session_id, t.expected, rec.p.seq_first); }
    if (t.first_new)   { mev(MEV_DUP, rec.p.session_id, rec.p.seq_first, t.first_new); }
    if (rec.p.node_id != EDGE_NODE_ID) {
        // Accepted anyway, as for v4: almost certainly a flashing mistake.
        mev(MEV_NODE_MISMATCH, rec.p.session_id, rec.p.node_id, EDGE_NODE_ID);
        ESP_LOGW(DTAG, "v5 addressed to node %u, this is node %u",
                 rec.p.node_id, (unsigned)EDGE_NODE_ID);
    }

    if (acks_only) {
        ESP_LOGI(DTAG, "v5 confirmations ev_ack=%u ev_user=%u", rec.p.ev_ack, rec.p.ev_user);
        return true;
    }

    rec.rx_ms     = uptime_ms();
    rec.first_new = t.first_new;
    if (EDGE_HAS_SD) {
        xQueueSend(s_mon_q, &rec, 0);   // there is room: checked above, single producer
    }

    // On the console: the values of the LAST sample of the packet (the most
    // recent), with the unit only if the value is present.
    const monitor_sample_t *last = &rec.p.s[rec.p.n_samples - 1];
    char hr[MONITOR_TXT_LEN], batt[MONITOR_TXT_LEN], steps[MONITOR_TXT_LEN], alt[MONITOR_TXT_LEN];
    monitor_fmt_u16(last->hr, hr);
    monitor_fmt_batt(last->batt, batt);
    monitor_fmt_u16(last->steps, steps);
    monitor_fmt_alt(last->alt, alt);

    ESP_LOGI(DTAG, "v5 S=%lu seq=%lu+%u backlog=%u conn=%u hr=%s batt=%s%s steps=%s alt=%s%s "
                   "ev_ack=%u ev_user=%u%s%s",
             (unsigned long)rec.p.session_id, (unsigned long)rec.p.seq_first,
             rec.p.n_samples, rec.p.backlog, rec.p.conn_no, hr,
             batt, last->batt == V5_ABSENT ? "" : "%", steps,
             alt, last->alt == V5_ABSENT ? "" : "m", rec.p.ev_ack, rec.p.ev_user,
             t.first_new ? " [DUP]" : "", t.jump ? " [JUMP]" : "");
    return true;
}

// ---------------------------------------------------------------------------
// Complete packet: integrity checks -> parser. Returns true if accepted.
// ---------------------------------------------------------------------------
static bool packet_complete(void) {
    uint8_t cnt = rx.cnt;

    // Non-last chunks must be full (16 B): the positional copy at idx*16
    // assumes it. (check #2, structure)
    for (int i = 0; i < cnt - 1; i++) {
        if (rx.chunk_len[i] != PROTO_CHUNK_PAYLOAD) {
            ESP_LOGD(DTAG, "DROP pktId=%u: short non-last chunk %d (%u B)",
                     rx.pktId, i, rx.chunk_len[i]);
            cnt_dropped++;
            return false;
        }
    }
    uint32_t total = (uint32_t)(cnt - 1) * PROTO_CHUNK_PAYLOAD + rx.chunk_len[cnt - 1];

    switch (rx.flags) {
    case PROTO_FMT_FULL:
        // check #3: exactly 48 B, bitmask = 0
        if (rx.bitmask != 0 || total != PROTO_FULL_BYTES) {
            ESP_LOGD(DTAG, "DROP pktId=%u FULL: total=%lu bitmask=0x%03X",
                     rx.pktId, (unsigned long)total, rx.bitmask);
            cnt_dropped++;
            return false;
        }
        parse_full(rx.buf);
        return true;

    case PROTO_FMT_DELTA: {
        // check #4: total = 4*popcount(bitmask); bits 8, 10, 11 always set
        uint32_t expect = (uint32_t)4 * popcount12(rx.bitmask);
        if (total != expect ||
            (rx.bitmask & DELTA_FORCED_MASK) != DELTA_FORCED_MASK) {
            ESP_LOGD(DTAG, "DROP pktId=%u DELTA: total=%lu expect=%lu mask=0x%03X",
                     rx.pktId, (unsigned long)total, (unsigned long)expect, rx.bitmask);
            cnt_dropped++;
            return false;
        }
        parse_delta(rx.buf, rx.bitmask);
        return true;
    }

    case PROTO_FMT_BATCH:
        // check #5: bitmask=0, cnt%3==0, total = cnt*16 (all chunks full)
        if (rx.bitmask != 0 || (cnt % 3) != 0 ||
            total != (uint32_t)cnt * PROTO_CHUNK_PAYLOAD) {
            ESP_LOGD(DTAG, "DROP pktId=%u BATCH: total=%lu cnt=%u mask=0x%03X",
                     rx.pktId, (unsigned long)total, cnt, rx.bitmask);
            cnt_dropped++;
            return false;
        }
        parse_batch(rx.buf, cnt);
        return true;

    case PROTO_FMT_APP:
        // v4 and v5 declare their own length inside the payload (n_samples)
        // and protect it with a CRC16: here the structural check of the
        // transport (bitmask 0) is enough, the parser does the rest.
        if (rx.bitmask != 0) {
            ESP_LOGD(DTAG, "DROP pktId=%u APP: bitmask=0x%03X != 0",
                     rx.pktId, rx.bitmask);
            cnt_dropped++;
            return false;
        }
        // Self-describing payload: proto_ver (offset 1, identical in v4 and
        // v5) chooses the protocol. The magic is the same on purpose. Only
        // 0x06 goes to v5; every other version is evaluated by v4, which
        // accepts only 0x05 and rejects the rest (reject event, reason magic):
        // an unknown version thus gets an ATT error instead of being confirmed
        // and lost.
        if (v5_route_monitor(rx.buf, total)) {
            cnt_monitor++;
            return on_monitor_packet(rx.buf, total);
        }
        cnt_multi++;
        return on_multi_packet(rx.buf, total);

    default:
        ESP_LOGD(DTAG, "DROP pktId=%u: unhandled flags (%u)", rx.pktId, rx.flags);
        cnt_dropped++;
        return false;
    }
}

// ---------------------------------------------------------------------------
// Ingestion of a single chunk received on the DATA characteristic.
//
// Returns the ATT outcome of the write (0 = success), which NimBLE sends back
// to the central as the write response AFTER this function has returned.
//
//   - v3 (FULL/DELTA/BATCH): ALWAYS 0. The three variants of the battery
//     experiment must see no difference on air.
//   - flags = APP (v4/v5): a discarded chunk answers with an error, and the
//     LAST chunk answers success only if the packet was reassembled AND
//     accepted. For v4 this is the packet ACK: the watch removes it from its
//     queue only if all the writes succeeded.
// ---------------------------------------------------------------------------
static int on_chunk(const uint8_t *w, uint16_t wlen) {
    if (wlen < 4) {
        ESP_LOGD(DTAG, "DROP: write too short (%u B)", wlen);
        cnt_dropped++;
        return 0;
    }
    uint32_t h = be32_read(w);
    uint8_t  pktId   = hdr_pktId(h);
    uint8_t  flags   = hdr_flags(h);
    uint8_t  idx     = hdr_idx(h);
    uint8_t  cnt     = hdr_cnt(h);
    uint16_t bitmask = hdr_bitmask(h);
    uint16_t plen    = wlen - 4;

    // Outcome to return if this chunk (or its packet) is discarded.
    const int reject = (flags == PROTO_FMT_APP) ? BLE_ATT_ERR_UNLIKELY : 0;

    ESP_LOGD(DTAG, "chunk pktId=%u flags=%u idx=%u/%u mask=0x%03X plen=%u",
             pktId, flags, idx, cnt, bitmask, plen);

    // Basic checks on the single chunk.
    if (cnt == 0 || cnt > MAX_CHUNKS || idx >= cnt || plen > PROTO_CHUNK_PAYLOAD) {
        ESP_LOGD(DTAG, "DROP chunk pktId=%u: invalid cnt/idx/plen", pktId);
        cnt_dropped++;
        return reject;
    }

    // New packet? (none being assembled, or a different pktId)
    if (!rx.active || rx.pktId != pktId) {
        if (rx.active && rx.pktId != pktId) {
            ESP_LOGD(DTAG, "pktId changed (%u->%u): dropping incomplete (%d/%u chunks)",
                     rx.pktId, pktId, rx.received, rx.cnt);
            cnt_dropped++;   // previous packet incomplete (typically: disconnection)
        }
        rx_reset();
        rx.active   = true;
        rx.pktId    = pktId;
        rx.flags    = flags;
        rx.cnt      = cnt;
        rx.bitmask  = bitmask;
    } else {
        // check #1: flags/cnt/bitmask identical on all chunks of the same pktId
        if (rx.flags != flags || rx.cnt != cnt || rx.bitmask != bitmask) {
            ESP_LOGD(DTAG, "DROP pktId=%u: inconsistent header between chunks", pktId);
            cnt_dropped++;
            rx_reset();
            return reject;
        }
        // check #2: duplicate idx
        if (rx.got_mask & (1u << idx)) {
            ESP_LOGD(DTAG, "DROP pktId=%u: duplicate idx %u", pktId, idx);
            cnt_dropped++;
            rx_reset();
            return reject;
        }
    }

    // Positional copy at idx*16.
    memcpy(rx.buf + (uint32_t)idx * PROTO_CHUNK_PAYLOAD, w + 4, plen);
    rx.chunk_len[idx] = plen;
    rx.got_mask |= (1u << idx);
    rx.received++;

    // Packet complete?
    if (rx.received == rx.cnt) {
        bool accepted = packet_complete();   // validates and (if ok) routes to the parser
        rx_reset();
        // Periodic log of the counters (average DELTA popcount for the break-even).
        uint32_t avg_x100 = delta_pkt_count ? (delta_popcount_sum * 100 / delta_pkt_count) : 0;
        ESP_LOGD(DTAG, "counts: FULL=%lu DELTA=%lu BATCH=%lu MULTI=%lu MONITOR=%lu dropped=%lu avgDeltaPopcount=%lu.%02lu",
                 (unsigned long)cnt_full, (unsigned long)cnt_delta, (unsigned long)cnt_batch,
                 (unsigned long)cnt_multi, (unsigned long)cnt_monitor, (unsigned long)cnt_dropped,
                 (unsigned long)(avg_x100 / 100), (unsigned long)(avg_x100 % 100));
        return accepted ? 0 : reject;
    }

    // The watch sends the chunks in order: if the last one has arrived and the
    // packet is not complete, something in between was lost. The write
    // response of the last chunk is the packet ACK: it cannot be a success.
    // (The buffer stays: the next pktId will replace it.)
    if (idx == cnt - 1) {
        ESP_LOGD(DTAG, "pktId=%u: last chunk arrived but %d/%u received",
                 pktId, rx.received, rx.cnt);
        return reject;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Connection established: state, event, busy advertising. Called by
// gap_event() and, as a safety net, by chr_access() if a write arrives on a
// connection that gap_event() has not registered.
// ---------------------------------------------------------------------------
static void conn_established(uint16_t conn_handle) {
    if (s_conn_handle == conn_handle) { return; }   // already registered
    s_conn_handle = conn_handle;   // needed to notify and for the simulation
    mev(MEV_CONNECT, s_session, conn_handle, 0);
    ESP_LOGI(TAG, "Garmin connected");
    if (s_sim_off) {
        // Connection born at the very moment of switching to "off": while
        // "off" the edge does not exist, so it is closed at once.
        ble_gap_terminate(conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        return;
    }
    // The edge stays visible while connected too, but NON-connectable and
    // with the busy bit: the watch can thus measure its RSSI and compare it
    // with that of the other edges to decide the handoff (Connect IQ does not
    // expose the RSSI of an active connection).
    s_busy = true;
    advertise();
}

// ---------------------------------------------------------------------------
// Characteristic access callback: the only writable one is DATA (chunk
// writes). ALERT is NOTIFY only and never goes through here.
// ---------------------------------------------------------------------------
static int chr_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt, void *arg) {
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        // Simulation: while "off" the edge does not exist. A write here means a
        // connection that survived the switch: it is closed and the data are
        // not processed (for the watch it is like being out of range).
        if (s_sim_off) {
            ble_gap_terminate(conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            return BLE_ATT_ERR_UNLIKELY;
        }
        // Safety net: a connection that gap_event() has not seen (see
        // BLE_GAP_EVENT_CONNECT) is registered at the first write.
        if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
            ESP_LOGW(TAG, "Write on an unregistered connection (handle %u): registering it",
                     conn_handle);
            conn_established(conn_handle);
        }

        uint8_t buf[4 + PROTO_CHUNK_PAYLOAD];   // header + payload (max 20 B)
        uint16_t len = 0;
        int rc = ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf), &len);
        if (rc != 0) { return BLE_ATT_ERR_UNLIKELY; }

        if (ble_uuid_cmp(ctxt->chr->uuid, &data_uuid.u) == 0) {
            return on_chunk(buf, len);
        }
    }
    return BLE_ATT_ERR_UNLIKELY;
}

// ---------------------------------------------------------------------------
// GATT service definition (1 service, 2 characteristics: DATA, ALERT)
// ---------------------------------------------------------------------------
static const struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = &data_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                // V5 ALERTS. NOTIFY only: no read, no write. NimBLE generates
                // the CCCD, and the Monitor watch app writes it at every
                // connection.
                .uuid = &alert_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &alert_val_handle,
            },
            { 0 }
        },
    },
    { 0 }
};

// ---------------------------------------------------------------------------
// GAP: connection / disconnection (advertising restarted on disconnection)
// ---------------------------------------------------------------------------
static int gap_event(struct ble_gap_event *event, void *arg) {
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT: {
        // ESP-IDF 5.5 NimBLE, peripheral role: this event does NOT arrive at
        // connection time, but after the stack has read the version and the
        // supported features of the central, and it carries the outcome of
        // that last read (ble_gap_rx_rd_rem_sup_feat_complete in ble_gap.c). If
        // the central refuses it, status != 0 but the link is ALIVE and the
        // watch writes normally: the FR255 answers 0x1A
        // (BLE_ERR_UNSUPP_REM_FEATURE), i.e. it does not support the feature
        // exchange started by the peripheral (optional since Bluetooth 4.1),
        // verified on the device. So what counts is whether the connection
        // exists, not the status. Real failures: 0x3E (never established) and
        // EAGAIN (dropped before the event: no DISCONNECT will arrive).
        int st = event->connect.status;
        struct ble_gap_conn_desc desc;
        bool alive = (st == 0)
            || (st != BLE_HS_EAGAIN && st != BLE_ERR_CONN_ESTABLISHMENT
                && ble_gap_conn_find(event->connect.conn_handle, &desc) == 0);
        if (!alive) {
            ESP_LOGW(TAG, "Connection failed (status=0x%X); restarting advertising", st);
            advertise();
            return 0;
        }
        if (st != 0) {
            ESP_LOGW(TAG, "Connection with status=0x%X (reading the central features "
                          "failed) but link alive: treating it as successful", st);
        }
        conn_established(event->connect.conn_handle);
        return 0;
    }
    case BLE_GAP_EVENT_DISCONNECT:
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        ESP_LOGW(TAG, "Garmin disconnected (reason=0x%03X); restarting advertising",
                 event->disconnect.reason);
        // reason: 0x213 = closed by the watch (e.g. handoff to another edge),
        // 0x208 = supervision timeout (link lost), 0x216 = closed by this edge
        // (simulation, "off" phase). This is what tells, in events.csv, an
        // intended edge change from an unintended one.
        mev(MEV_DISCONNECT, s_session, (uint32_t)event->disconnect.reason, 0);
        rx_reset();                 // drop any half-received packet
        alert_set_sub(false);       // the subscription is valid for one connection only
        s_busy = false;
        advertise();
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == alert_val_handle) {
            // CCCD of ALERT: only the V5 watch app writes it. When the
            // connection closes NimBLE sends the same event, with
            // cur_notify = 0 and reason TERM.
            ESP_LOGI(TAG, "V5 alerts %s%s",
                     event->subscribe.cur_notify ? "ENABLED by the watch" : "disabled",
                     event->subscribe.reason == BLE_GAP_SUBSCRIBE_REASON_TERM
                         ? " (end of connection)" : "");
            alert_set_sub(event->subscribe.cur_notify);
        }
        return 0;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        return 0;
    default:
        return 0;
    }
}

// ---------------------------------------------------------------------------
// Advertising: Service UUID + Manufacturer Specific Data in the main packet,
// name in the scan response.
//
//   free  (no central)     : connectable,     busy = 0
//   busy  (connected)      : NON-connectable, busy = 1
//   off   (simulation)     : no advertising
//
// The Service UUID stays for the v3 variants, which look for it. The MSD
// (company 0xFFFF, "T4", node_id, flags) is for v4 and v5: it identifies WHICH
// edge and whether it is busy. Total 3 + 18 + 8 = 29 bytes out of the 31 of
// the legacy packet.
// ---------------------------------------------------------------------------
static void advertise(void) {
    // Always reconfigured while stopped: fields and mode change between "free"
    // and "busy", and NimBLE does not update them on an active advertising.
    if (ble_gap_adv_active()) { ble_gap_adv_stop(); }

    // While "off" the edge publishes nothing. This holds for all callers
    // (disconnection, failed connection, ADV_COMPLETE): none of them can turn
    // it back on before the phase expires.
    if (s_sim_off) { return; }

    // mfg_data: LITTLE-endian company id first (as in the Core Spec), then the
    // v4 payload. Static: NimBLE copies it in set_fields, but this way it does
    // not live on the host task stack.
    static uint8_t mfg[2 + V4_ADV_BYTES];
    mfg[0] = (uint8_t)(V4_ADV_COMPANY & 0xFF);
    mfg[1] = (uint8_t)((V4_ADV_COMPANY >> 8) & 0xFF);
    v4_build_adv((uint8_t)EDGE_NODE_ID, s_busy, mfg + 2);

    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&svc_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    fields.mfg_data = mfg;
    fields.mfg_data_len = sizeof(mfg);
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) { ESP_LOGE(TAG, "adv_set_fields rc=%d", rc); return; }

    struct ble_hs_adv_fields rsp = {0};
    rsp.name = (uint8_t *)DEVICE_NAME;
    rsp.name_len = strlen(DEVICE_NAME);
    rsp.name_is_complete = 1;
    ble_gap_adv_rsp_set_fields(&rsp);

    struct ble_gap_adv_params adv_params = {0};
    adv_params.conn_mode = s_busy ? BLE_GAP_CONN_MODE_NON : BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER,
                           &adv_params, gap_event, NULL);
    if (rc != 0) { ESP_LOGE(TAG, "adv_start rc=%d", rc); return; }
    if (s_busy) {
        ESP_LOGI(TAG, "Busy advertising (non-connectable) as '%s'", DEVICE_NAME);
    } else {
        ESP_LOGI(TAG, "Advertising as '%s' (node %u) — waiting for the Garmin",
                 DEVICE_NAME, (unsigned)EDGE_NODE_ID);
    }
}

// ---------------------------------------------------------------------------
// Pass-by simulation: alternates the "on" (THIS_EDGE_ON_S) and "off"
// (THIS_EDGE_OFF_S) phases. NimBLE callout: it runs in the stack task.
//
// While "off" the edge stops advertising and CLOSES the current connection:
// the watch sees an immediate disconnection. In the field it would instead see
// a supervision timeout a few seconds later: the simulation therefore slightly
// anticipates the moment the watch notices it has lost the edge. A packet
// half-sent, or confirmed but whose response has not left yet, is sent again
// to the next edge (or here, as a duplicate), as in reality.
// ---------------------------------------------------------------------------
static void sim_phase(struct ble_npl_event *ev) {
    (void)ev;
    s_sim_off = !s_sim_off;
    uint32_t dur_s = s_sim_off ? THIS_EDGE_OFF_S : THIS_EDGE_ON_S;

    if (s_sim_off) {
        ESP_LOGI(TAG, "SIM: edge OFF for %lu s (invisible)", (unsigned long)dur_s);
        mev(MEV_SIM_OFF, s_session, dur_s, 0);   // before the disconnection
        if (ble_gap_adv_active()) { ble_gap_adv_stop(); }
        if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE) {
            int rc = ble_gap_terminate(s_conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            if (rc != 0) { ESP_LOGW(TAG, "SIM: closing the connection rc=%d", rc); }
        }
    } else {
        ESP_LOGI(TAG, "SIM: edge ON for %lu s (visible)", (unsigned long)dur_s);
        mev(MEV_SIM_ON, s_session, dur_s, 0);
        advertise();
    }
    ble_npl_callout_reset(&s_sim_co, ble_npl_time_ms_to_ticks32(dur_s * 1000u));
}

// Starts the cycle: the first phase is "on", already running from on_sync().
static void sim_start(void) {
    static bool started = false;   // on_sync() repeats after a stack reset
    if (THIS_EDGE_OFF_S == 0 || started) { return; }
    started = true;
    ble_npl_callout_init(&s_sim_co, nimble_port_get_dflt_eventq(), sim_phase, NULL);
    ble_npl_callout_reset(&s_sim_co, ble_npl_time_ms_to_ticks32(THIS_EDGE_ON_S * 1000u));
}

// ---------------------------------------------------------------------------
// Simulated V5 alerts (THIS_EDGE_EVENT_S / THIS_EDGE_EVENT_ALERT).
//
// One alert as soon as the watch subscribes to ALERT, then one every
// THIS_EDGE_EVENT_S seconds while it stays subscribed. Every alert is sent
// once, without waiting for a confirmation and without retransmission: if the
// watch is not connected and subscribed, the alert is not even created.
// NimBLE callout like sim_phase(): it runs in the stack task.
// ---------------------------------------------------------------------------
static const char *alert_mode_name(uint8_t alert) {
    switch (alert & (V5_AL_VIBE | V5_AL_TONE)) {
        case 0:          return "message";
        case V5_AL_VIBE: return "vibration";
        case V5_AL_TONE: return "sound";
        default:         return "vibration+sound";
    }
}

// Builds the next alert and notifies it. With no subscribed watch (or while
// "off" in the pass-by simulation) it does nothing: the alert is not created.
static void alert_send(void) {
    if (!s_alert_sub || s_sim_off || s_conn_handle == BLE_HS_CONN_HANDLE_NONE) { return; }

    s_alert_seq = v5_next_ev_seq(s_alert_seq);
    // 0-3 are already the bits of the alert field. 4 = rotating by ev_seq:
    // from the alert number one knows how it should appear on the watch.
    uint8_t alert = (THIS_EDGE_EVENT_ALERT == 4) ? (uint8_t)((s_alert_seq - 1u) % 4u)
                                                 : (uint8_t)THIS_EDGE_EVENT_ALERT;
    char text[V5_TEXT_BYTES + 1];
    snprintf(text, sizeof(text), "E%u #%u", (unsigned)EDGE_NODE_ID, (unsigned)s_alert_seq);

    // ev_value = seconds waited since creation: without a queue the alert
    // leaves as soon as it is created, so 0.
    uint8_t out[V5_ALERT_BYTES];
    v5_build_alert((uint8_t)EDGE_NODE_ID, s_alert_seq, V5_EV_TEST, alert, 0, text, out);

    int rc = BLE_HS_ENOMEM;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(out, sizeof(out));
    if (om != NULL) {
        rc = ble_gatts_notify_custom(s_conn_handle, alert_val_handle, om);   // consumes om
    }
    if (rc == 0) {
        ESP_LOGI(TAG, "ALERT #%u (%s) '%s' sent", (unsigned)s_alert_seq,
                 alert_mode_name(alert), text);
    } else {
        ESP_LOGW(TAG, "ALERT #%u (%s) '%s' NOT sent: notify rc=%d", (unsigned)s_alert_seq,
                 alert_mode_name(alert), text, rc);
    }
}

static void alert_tick(struct ble_npl_event *ev) {
    (void)ev;
    if (!s_alert_sub) { return; }   // subscription closed meanwhile: the cycle stops
    alert_send();
    ble_npl_callout_reset(&s_alert_co, ble_npl_time_ms_to_ticks32(THIS_EDGE_EVENT_S * 1000u));
}

// ALERT subscription opened or closed (SUBSCRIBE), or connection closed
// (DISCONNECT, on = false). On subscription an alert is sent at once, then the
// cycle starts.
static void alert_set_sub(bool on) {
    bool was = s_alert_sub;
    s_alert_sub = on;
    if (THIS_EDGE_EVENT_S == 0) { return; }
    if (!on) {
        ble_npl_callout_stop(&s_alert_co);
    } else if (!was) {
        alert_send();
        ble_npl_callout_reset(&s_alert_co, ble_npl_time_ms_to_ticks32(THIS_EDGE_EVENT_S * 1000u));
    }
}

// Prepares the callout. Called by on_sync(), before advertising: no
// subscription (hence no alert_set_sub) can arrive earlier.
static void alert_init(void) {
    static bool ready = false;     // on_sync() repeats after a stack reset
    if (THIS_EDGE_EVENT_S == 0 || ready) { return; }
    ready = true;
    ble_npl_callout_init(&s_alert_co, nimble_port_get_dflt_eventq(), alert_tick, NULL);
}

// ---------------------------------------------------------------------------
// Host stack callbacks
// ---------------------------------------------------------------------------
static void on_sync(void) {
    ble_hs_id_infer_auto(0, &own_addr_type);
    alert_init();
    advertise();
    sim_start();
}
static void on_reset(int reason) {
    ESP_LOGW(TAG, "BLE stack reset; reason=%d", reason);
}
static void host_task(void *param) {
    nimble_port_run();
    nimble_port_freertos_deinit();
}

// ---------------------------------------------------------------------------
// Public API: complete initialisation of the BLE stack.
// ---------------------------------------------------------------------------
void ble_init(void) {
    // Initial state: all fields "missing".
    memset(&g_data, 0, sizeof(g_data));
    for (int i = 0; i < PROTO_NFIELDS; i++) { g_data.field[i] = PROTO_SENTINEL; }
    rx_reset();

    // Sample FIFO for the SD logger (created before the stack starts).
    s_sample_q = xQueueCreate(SAMPLE_QUEUE_LEN, sizeof(garmin_sample_t));
    s_multi_q  = xQueueCreate(MULTI_QUEUE_LEN, sizeof(multi_record_t));
    s_mon_q    = xQueueCreate(MONITOR_QUEUE_LEN, sizeof(monitor_record_t));
    s_mev_q    = xQueueCreate(MULTI_EVENT_QUEUE_LEN, sizeof(multi_event_t));
    // An edge restart must be visible in events.csv: it explains a gap in the
    // uptime and why the per-node continuity starts over (the state is not
    // persistent).
    mev(MEV_BOOT, 0, EDGE_NODE_ID, 0);

    ESP_ERROR_CHECK(nimble_port_init());

    ble_hs_cfg.sync_cb  = on_sync;
    ble_hs_cfg.reset_cb = on_reset;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    ESP_ERROR_CHECK(ble_gatts_count_cfg(gatt_svcs));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(gatt_svcs));

    ble_svc_gap_device_name_set(DEVICE_NAME);

    nimble_port_freertos_init(host_task);

    // The whole board configuration in ONE line, to check at boot.
    char sim[64];
    if (THIS_EDGE_OFF_S == 0) {
        snprintf(sim, sizeof(sim), "always on");
    } else {
        snprintf(sim, sizeof(sim), "SIMULATION on %u s / off %u s",
                 (unsigned)THIS_EDGE_ON_S, (unsigned)THIS_EDGE_OFF_S);
    }
    char alerts[64];
    if (THIS_EDGE_EVENT_S == 0) {
        snprintf(alerts, sizeof(alerts), "V5 alerts disabled");
    } else {
        snprintf(alerts, sizeof(alerts), "V5 alerts every %u s (%s)", (unsigned)THIS_EDGE_EVENT_S,
                 THIS_EDGE_EVENT_ALERT == 4 ? "rotating"
                                            : alert_mode_name((uint8_t)THIS_EDGE_EVENT_ALERT));
    }
    ESP_LOGI(TAG, "BLE peripheral started: edge node %u ('%s'), SD %s, %s, %s, protocols v3/v4/v5",
             (unsigned)EDGE_NODE_ID, DEVICE_NAME,
             EDGE_HAS_SD ? "present" : "ABSENT (data on the console only)", sim, alerts);
}
