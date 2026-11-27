//
// monitor_log.c — Writes the v5 data to microSD (see monitor_log.h).
//
// Called ONLY by the SD task (core 1): the BLE stack hands the records over
// through a queue, so a slow FAT write never delays the radio.
//
#include <stdio.h>

#include "esp_log.h"

#include "monitor_log.h"
#include "sd.h"
#include "config.h"

static const char *TAG = "MONLOG";

static FILE    *s_data    = NULL;
static uint32_t s_session = 0;       // session of the open data file

static bool open_data(uint32_t session) {
    if (s_data != NULL && s_session == session) { return true; }
    if (s_data != NULL) {
        sd_flush_file(s_data);
        fclose(s_data);
        s_data = NULL;
    }
    char path[64];
    snprintf(path, sizeof(path), SD_MOUNT_POINT "/monitor_%lu_n%u.csv",
             (unsigned long)session, (unsigned)EDGE_NODE_ID);
    s_data = sd_open_append(path,
        "rx_ms,node,session,seq,conn_no,backlog,dup,realTime,hr,batt,steps,alt\n");
    if (s_data == NULL) { return false; }
    s_session = session;
    ESP_LOGI(TAG, "v5 data file: %s", path);
    return true;
}

bool monitor_log_record(const monitor_record_t *r) {
    const monitor_pkt_t *p = &r->p;
    if (p->n_samples == 0) { return true; }   // confirmations only: no rows
    if (!open_data(p->session_id)) { return false; }

    for (uint8_t s = 0; s < p->n_samples; s++) {
        const monitor_sample_t *x = &p->s[s];
        char hr[MONITOR_TXT_LEN], batt[MONITOR_TXT_LEN];
        char steps[MONITOR_TXT_LEN], alt[MONITOR_TXT_LEN];
        monitor_fmt_u16(x->hr, hr);
        monitor_fmt_batt(x->batt, batt);
        monitor_fmt_u16(x->steps, steps);
        monitor_fmt_alt(x->alt, alt);
        int rc = fprintf(s_data, "%lu,%u,%lu,%lu,%u,%u,%u,%lu,%s,%s,%s,%s\n",
            (unsigned long)r->rx_ms, (unsigned)EDGE_NODE_ID,
            (unsigned long)p->session_id, (unsigned long)(p->seq_first + s),
            (unsigned)p->conn_no, (unsigned)p->backlog,
            (unsigned)(s < r->first_new ? 1 : 0),
            (unsigned long)x->real_time, hr, batt, steps, alt);
        if (rc < 0) {
            ESP_LOGW(TAG, "Write failed (SD card removed?)");
            return false;
        }
    }
    return true;
}

void monitor_log_flush(void) {
    sd_flush_file(s_data);
}

void monitor_log_close(void) {
    if (s_data != NULL) { sd_flush_file(s_data); fclose(s_data); s_data = NULL; }
    s_session = 0;
}
