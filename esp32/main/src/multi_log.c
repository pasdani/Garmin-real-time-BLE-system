//
// multi_log.c — Writes the v4 data and events to microSD (see multi_log.h).
//
// Called ONLY by the SD task (core 1): the BLE stack hands records and events
// over through queues, so a slow FAT write never delays the radio.
//
#include <stdio.h>

#include "esp_log.h"

#include "multi_log.h"
#include "sd.h"
#include "config.h"

static const char *TAG = "MULTILOG";

static FILE    *s_data    = NULL;
static uint32_t s_session = 0;       // session of the open data file
static FILE    *s_events  = NULL;

static bool open_events(void) {
    if (s_events != NULL) { return true; }
    char path[64];
    snprintf(path, sizeof(path), SD_MOUNT_POINT "/edge_n%u_events.csv", (unsigned)EDGE_NODE_ID);
    s_events = sd_open_append(path, "uptime_ms,event,session,a,b\n");
    return s_events != NULL;
}

static bool open_data(uint32_t session) {
    if (s_data != NULL && s_session == session) { return true; }
    if (s_data != NULL) {
        sd_flush_file(s_data);
        fclose(s_data);
        s_data = NULL;
    }
    char path[64];
    snprintf(path, sizeof(path), SD_MOUNT_POINT "/multi_%lu_n%u.csv",
             (unsigned long)session, (unsigned)EDGE_NODE_ID);
    s_data = sd_open_append(path,
        "rx_ms,node,session,seq,conn_no,backlog,dup,realTime,elapsed,hr,cad,speed,dist,"
        "t_conn_s,t_scan_s,t_agg_s,tx_chunks,n_try,n_conn,n_ho,n_lost,n_fail,"
        "radio,scan_on,roam_ok,rssi,coda,timer,watchBatt\n");
    if (s_data == NULL) { return false; }
    s_session = session;
    ESP_LOGI(TAG, "v4 data file: %s", path);
    return true;
}

static const char *ev_name(uint8_t t) {
    switch (t) {
        case MEV_BOOT:          return "boot";
        case MEV_CONNECT:       return "connect";
        case MEV_DISCONNECT:    return "disconnect";
        case MEV_SESSION:       return "session";
        case MEV_JUMP:          return "jump";
        case MEV_DUP:           return "dup";
        case MEV_REJECT:        return "reject";
        case MEV_NODE_MISMATCH: return "node_mismatch";
        case MEV_QUEUE_FULL:    return "queue_full";
        case MEV_SIM_OFF:       return "sim_off";
        case MEV_SIM_ON:        return "sim_on";
        default:                return "?";
    }
}

bool multi_log_event(const multi_event_t *e) {
    if (!open_events()) { return false; }
    // disconnect: the HCI reason reads in hexadecimal (0x213, 0x208, ...).
    if (e->type == MEV_DISCONNECT) {
        fprintf(s_events, "%lu,%s,%lu,0x%03lX,%lu\n",
                (unsigned long)e->uptime_ms, ev_name(e->type), (unsigned long)e->session,
                (unsigned long)e->a, (unsigned long)e->b);
    } else {
        fprintf(s_events, "%lu,%s,%lu,%lu,%lu\n",
                (unsigned long)e->uptime_ms, ev_name(e->type), (unsigned long)e->session,
                (unsigned long)e->a, (unsigned long)e->b);
    }
    return true;
}

bool multi_log_record(const multi_record_t *r) {
    const multi_pkt_t *p = &r->p;
    if (!open_data(p->session_id)) { return false; }

    for (uint8_t s = 0; s < p->n_samples; s++) {
        const uint32_t *f = p->field[s];
        v4_telemetry_t t;
        v4_tel_decode(f, &t);
        int rc = fprintf(s_data,
            "%lu,%u,%lu,%lu,%u,%u,%u,%lu,%lu,%lu,%lu,%lu,%lu,"
            "%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%d,%u,%lu,%lu\n",
            (unsigned long)r->rx_ms, (unsigned)EDGE_NODE_ID,
            (unsigned long)p->session_id, (unsigned long)(p->seq_first + s),
            (unsigned)p->conn_no, (unsigned)p->backlog,
            (unsigned)(s < r->first_new ? 1 : 0),
            (unsigned long)f[F_REALTIME], (unsigned long)f[F_ELAPSED],
            (unsigned long)f[F_HR],       (unsigned long)f[F_CADENCE],
            (unsigned long)f[F_SPEED],    (unsigned long)f[F_DISTANCE],
            (unsigned)t.t_conn_s, (unsigned)t.t_scan_s, (unsigned)t.t_agg_s, (unsigned)t.tx_chunks,
            (unsigned)t.n_try,    (unsigned)t.n_conn,   (unsigned)t.n_ho,    (unsigned)t.n_lost,
            (unsigned)t.n_fail,   (unsigned)t.radio,    (unsigned)t.scan_on, (unsigned)t.roam_ok,
            (int)t.rssi,          (unsigned)t.coda,
            (unsigned long)f[F_TIMERTIME],(unsigned long)f[F_BATTERY]);
        if (rc < 0) {
            ESP_LOGW(TAG, "Write failed (SD card removed?)");
            return false;
        }
    }
    return true;
}

void multi_log_flush(void) {
    sd_flush_file(s_data);
    sd_flush_file(s_events);
}

void multi_log_close(void) {
    if (s_data != NULL)   { sd_flush_file(s_data);   fclose(s_data);   s_data = NULL; }
    if (s_events != NULL) { sd_flush_file(s_events); fclose(s_events); s_events = NULL; }
    s_session = 0;
}
