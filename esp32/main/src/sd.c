//
// sd.c — Saves the BLE data to the SD card (CSV files).
//
// On the ESP32-CAM (AI-Thinker) the SD slot is wired to SDMMC host slot 1.
// 1-bit mode is used: the only pins needed are fixed in hardware
//   CLK = GPIO14, CMD = GPIO15, D0 = GPIO2.
// 4-bit mode must be AVOIDED because D1=GPIO4 is also the flash LED and
// D2/D3 (GPIO12/13) are strapping pins: in 1-bit mode the SD card coexists
// with the camera.
//
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_log.h"
#include "esp_timer.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "driver/sdmmc_host.h"

#include "sd.h"
#include "ble.h"
#include "config.h"

static const char *TAG = "SD";
static sdmmc_card_t *sd_card = NULL;    // != NULL => SD card mounted and present
static bool sd_mounted = false;

// Path of the v3 CSV file of the current activity.
static char session_path[64];

// Tries to mount the SD card. Returns true if present and mounted.
// It is also the "presence check": if there is no card (or it is faulty) the
// mount fails and false is returned WITHOUT blocking the rest of the firmware.
//
// On a board configured without a slot (EDGE_HAS_SD = 0, see ble.c) nothing
// is attempted: the SDMMC pins stay untouched, and the callers, which receive
// false, still take the data out of the queues and discard them.
static bool sd_try_mount(void) {
    if (!EDGE_HAS_SD) { return false; }
    if (sd_mounted) { return true; }

    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.flags = SDMMC_HOST_FLAG_1BIT;          // force 1-bit
    host.max_freq_khz = SDMMC_FREQ_DEFAULT;     // 20 MHz (safe on the cam)

    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = 1;                              // 1-bit: uses only CLK/CMD/D0
    slot.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP; // internal pull-ups as well

    esp_vfs_fat_sdmmc_mount_config_t mount_cfg = {
        .format_if_mount_failed = false,         // never format: presence check only
        // In the worst case 4 files are open at the same time: the two v4
        // files (data + events) and the v5 data file, kept open between
        // rounds, and the v3 CSV during the round. The value is the one tested
        // in the field, which leaves a margin: one file too many would fail
        // silently in the middle of a session.
        .max_files = 8,
        .allocation_unit_size = 16 * 1024,
    };

    esp_err_t err = esp_vfs_fat_sdmmc_mount(SD_MOUNT_POINT, &host, &slot,
                                            &mount_cfg, &sd_card);
    if (err != ESP_OK) {
        if (err == ESP_FAIL) {
            ESP_LOGW(TAG, "No valid FAT filesystem (card needs formatting?)");
        } else {
            ESP_LOGW(TAG, "SD card not detected (err=%s) — logging disabled",
                     esp_err_to_name(err));
        }
        sd_card = NULL;
        return false;
    }

    sd_mounted = true;
    ESP_LOGI(TAG, "SD card mounted on %s", SD_MOUNT_POINT);
    sdmmc_card_print_info(stdout, sd_card);
    return true;
}

// Unmounts the SD card after a write error (card removed while running): the
// next round will retry the mount. The v4 and v5 FILE* stay open between
// rounds, so they must be closed FIRST: after unmounting they would be
// invalid.
static void sd_unmount(void) {
    multi_log_close();
    monitor_log_close();
    esp_vfs_fat_sdcard_unmount(SD_MOUNT_POINT, sd_card);
    sd_card = NULL;
    sd_mounted = false;
}

FILE *sd_open_append(const char *path, const char *header) {
    struct stat st;
    bool exists = (stat(path, &st) == 0);
    FILE *f = fopen(path, "a");
    if (f == NULL) {
        ESP_LOGW(TAG, "Cannot open %s", path);
        return NULL;
    }
    if (!exists) { fputs(header, f); }
    return f;
}

void sd_flush_file(FILE *f) {
    if (f == NULL) { return; }
    fflush(f);
    fsync(fileno(f));
}

// Chooses the file name for the new session: first FREE index in the form
// SD_LOG_PREFIX + N + ".csv" ("activity_1.csv", "activity_2.csv", ...), so a
// restart does not overwrite the logs of previous sessions (there is no RTC to
// use a timestamp).
// Returns true if a free name was found and creates the file with the header.
static bool sd_open_new_session(void) {
    for (unsigned i = 1; i <= 9999; i++) {
        snprintf(session_path, sizeof(session_path), SD_LOG_PREFIX "%u.csv", i);
        struct stat st;
        if (stat(session_path, &st) == 0) { continue; }   // already exists: try the next one

        FILE *f = fopen(session_path, "w");
        if (!f) {
            ESP_LOGW(TAG, "Cannot create %s", session_path);
            return false;
        }
        // Columns = uptime + the 12 fields of protocol v3 + packet format.
        // Value 4294967295 (0xFFFFFFFF) = value missing (sentinel).
        fprintf(f, "uptime_s,realTime,elapsed,hr,cad,speed,dist,alt,ascent,"
                   "kcal,heading,timer,watchBatt,fmt\n");
        fclose(f);
        ESP_LOGI(TAG, "New session: %s", session_path);
        return true;
    }
    ESP_LOGW(TAG, "No free file name (activity_1..activity_9999)");
    return false;
}

// ---------------------------------------------------------------------------
// Draining of the v4 (MULTI) queues: first the edge events (v5 ones too), then
// the data, so that in events.csv a connection appears before the samples it
// carried.
//
// No "session by inactivity" as for v3: the data file is chosen by the
// session_id written in the packet by the watch, which is the same on all the
// edges. That is what makes the files of the various cards mergeable.
// Without an SD card the records are still taken out of the queue (and lost):
// the edge must not reject packets because of a missing card, otherwise the
// watch would spin on it. See docs/protocol.md, v4, "Known limitations".
// ---------------------------------------------------------------------------
static void drain_multi_queues(void) {
    multi_event_t  e;
    multi_record_t r;
    uint32_t rows = 0;
    bool wrote = false;

    while (ble_pop_multi_event(&e)) {
        if (!sd_mounted && !sd_try_mount()) { continue; }
        wrote |= multi_log_event(&e);
    }
    while (ble_pop_multi(&r)) {
        if (!sd_mounted && !sd_try_mount()) { continue; }
        if (multi_log_record(&r)) {
            rows += r.p.n_samples;
            wrote = true;
        } else {
            ESP_LOGW(TAG, "v4 write failed: SD card removed? Unmounting and retrying");
            sd_unmount();
            wrote = false;
        }
    }
    if (wrote) {
        multi_log_flush();
    }
    if (rows > 0) {
        ESP_LOGI(TAG, "%lu v4 samples saved", (unsigned long)rows);
    }
}

// ---------------------------------------------------------------------------
// Draining of the v5 (MONITOR) queue: like the v4 data, file chosen by the
// session_id of the packet. The v5 events go through the event queue, already
// drained by drain_multi_queues(). Without an SD card the records are taken
// out of the queue and lost, for the same reason as v4.
// ---------------------------------------------------------------------------
static void drain_monitor_queue(void) {
    monitor_record_t r;
    uint32_t rows = 0;
    bool wrote = false;

    while (ble_pop_monitor(&r)) {
        if (!sd_mounted && !sd_try_mount()) { continue; }
        if (monitor_log_record(&r)) {
            rows += r.p.n_samples;
            wrote = true;
        } else {
            ESP_LOGW(TAG, "v5 write failed: SD card removed? Unmounting and retrying");
            sd_unmount();
            wrote = false;
        }
    }
    if (wrote) {
        monitor_log_flush();
    }
    if (rows > 0) {
        ESP_LOGI(TAG, "%lu v5 samples saved", (unsigned long)rows);
    }
}

// FreeRTOS task: every SD_LOG_PERIOD_MS it drains the queues of the BLE
// module, in the order v4 (events, then data), v5 and v3. For v3 it appends ONE
// CSV row per sample. The watch sends only with the timer running (start
// pressed): empty queue = nothing to write (before the start, paused, after
// the stop).
//
// v3, ONE FILE PER ACTIVITY: the activity is delimited by the ARRIVAL OF DATA,
// not by the BLE link. The first sample opens "activity_N.csv"; the file stays
// the same as long as samples keep arriving — a BLE disconnection/reconnection
// during the activity does NOT create a new file. After SD_ACTIVITY_TIMEOUT_MS
// without samples the activity is closed and the next sample opens a new file.
static void sd_logger_task(void *arg) {
    // Initial mount attempt (presence check only: the session file is created
    // at the FIRST sample received, not at connection time).
    // Without an SD card the task runs anyway: it must empty the queues,
    // otherwise they would fill up.
    if (EDGE_HAS_SD) {
        sd_try_mount();
    } else {
        ESP_LOGW(TAG, "Board without SD (THIS_EDGE_HAS_SD = 0): received data stay on the console only");
    }

    bool     session_open = false;   // true = a session file is in progress
    uint32_t last_rows_ms = 0;       // ms of the last sample written (end of activity)

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(SD_LOG_PERIOD_MS));

        // --- Protocol v4 (MULTI variant): file per session and per node ---
        // Independent of v3: the two protocols have different layouts on disk
        // and share nothing but the mount of the card.
        drain_multi_queues();

        // --- Protocol v5 (Monitor): file per session and per node ---
        // After the events, which drain_multi_queues() has already written.
        drain_monitor_queue();

        // --- Protocol v3 (Full / Delta / Batch): one file per activity ---

        // Drains all queued samples (FULL/DELTA: ~1 every 5 s;
        // BATCH: burst of 6 every 30 s → 6 rows at once).
        garmin_sample_t s;
        FILE *f = NULL;
        uint32_t rows = 0;
        while (ble_pop_sample(&s)) {
            // If the SD card is missing, retry the mount (hot-plug); if it is
            // still missing, the sample is discarded (non-blocking behaviour).
            if (!sd_mounted && !sd_try_mount()) { continue; }

            // First sample of the session: open a new file with the header.
            if (!session_open) {
                if (!sd_open_new_session()) { continue; }
                session_open = true;
            }

            if (f == NULL) {
                f = fopen(session_path, "a");
                if (!f) {
                    ESP_LOGW(TAG, "Write failed: SD card removed? Unmounting and retrying");
                    sd_unmount();
                    break;   // the remaining samples of this round are lost
                }
            }

            uint32_t uptime_s = (uint32_t)(esp_timer_get_time() / 1000000ULL);
            fprintf(f, "%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%s\n",
                    (unsigned long)uptime_s,
                    (unsigned long)s.field[F_REALTIME], (unsigned long)s.field[F_ELAPSED],
                    (unsigned long)s.field[F_HR],       (unsigned long)s.field[F_CADENCE],
                    (unsigned long)s.field[F_SPEED],    (unsigned long)s.field[F_DISTANCE],
                    (unsigned long)s.field[F_ALTITUDE], (unsigned long)s.field[F_ASCENT],
                    (unsigned long)s.field[F_CALORIES], (unsigned long)s.field[F_HEADING],
                    (unsigned long)s.field[F_TIMERTIME],(unsigned long)s.field[F_BATTERY],
                    v3_fmt_name(s.fmt));
            rows++;
        }
        if (f != NULL) {
            fclose(f);   // fclose => flushed to the card (safe against power loss)
            ESP_LOGI(TAG, "%lu row(s) saved to %s", (unsigned long)rows, session_path);
        }

        // The activity is delimited by data INACTIVITY (not by the BLE link):
        // while samples keep arriving the session stays open; after
        // SD_ACTIVITY_TIMEOUT_MS without samples the activity is over and the
        // file is closed — the next sample will open "activity_(N+1).csv".
        uint32_t now_ms = (uint32_t)(esp_timer_get_time() / 1000ULL);
        if (rows > 0) {
            last_rows_ms = now_ms;                 // activity still alive
        } else if (session_open &&
                   (now_ms - last_rows_ms) >= SD_ACTIVITY_TIMEOUT_MS) {
            ESP_LOGI(TAG, "Activity finished (no data for %lu s): closing %s",
                     (unsigned long)(SD_ACTIVITY_TIMEOUT_MS / 1000), session_path);
            session_open = false;
        }
    }
}

// ---------------------------------------------------------------------------
// Public API: starts the logging task.
// ---------------------------------------------------------------------------
void sd_logger_start(void) {
    // Pinned to core 1: the NimBLE stack runs on core 0, and a slow FAT write
    // (or a remount after a hot-plug) must not steal time from the radio.
    xTaskCreatePinnedToCore(sd_logger_task, "sd_logger", 4096, NULL, 5, NULL,
                            SD_TASK_CORE);
}
