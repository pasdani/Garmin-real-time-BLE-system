//
// sd.h — Interface of the SD card logging module.
//
// On the ESP32-CAM the SD slot is wired to SDMMC host slot 1: 1-bit mode is
// used (CLK=GPIO14, CMD=GPIO15, D0=GPIO2), the only one compatible with the
// camera.
//
#pragma once
#include <stdio.h>

// Starts the FreeRTOS task (pinned to core SD_TASK_CORE) that:
//   1. checks that the card is present (mount), retried at every value to
//      write if the card is missing (hot-plug);
//   2. every SD_LOG_PERIOD_MS drains the queues of the BLE module, in order:
//      - v4 events and data -> edge_n<node>_events.csv and
//        multi_<session>_n<node>.csv (multi_log.c);
//      - v5 data -> monitor_<session>_n<node>.csv (monitor_log.c);
//      - v3 samples -> ONE CSV row per sample in activity_N.csv, opened at
//        the first sample and closed after SD_ACTIVITY_TIMEOUT_MS without
//        samples.
// It never blocks the firmware if the SD card is missing.
void sd_logger_start(void);

// For the log modules (multi_log.c, monitor_log.c), from the SD task only.
// Opens `path` in append mode; if the file did not exist it writes the header.
// Append and not "w": if the edge restarts in the middle of a session, the
// rows already written are not lost.
FILE *sd_open_append(const char *path, const char *header);

// fflush() empties the libc buffer, fsync() forces FATFS to write to the card:
// an edge on a power bank can switch off at any moment. f = NULL does nothing.
void sd_flush_file(FILE *f);
