//
// config.h — Firmware configuration constants.
//
// The single place to change the "tunable" parameters of the firmware: SD
// paths and write period, SD task core and size of the v4 and v5 queues to the
// SD task. The configuration of the SINGLE board (node ID, SD presence, pass-by
// simulation, V5 alerts) lives instead in src/ble.c.
//
#pragma once

#include <stdbool.h>
#include <stdint.h>

// ===========================================================================
// Board configuration (v4 edge node ID, SD presence)
// ===========================================================================
// NOT set here: these are the THIS_EDGE_NODE_ID and THIS_EDGE_HAS_SD lines in
// src/ble.c, which change from one ESP32 to another (that is also where the
// BLE name derived from the ID is, together with THIS_EDGE_ON_S /
// THIS_EDGE_OFF_S of the pass-by simulation and THIS_EDGE_EVENT_S /
// THIS_EDGE_EVENT_ALERT of the V5 alerts, used only in ble.c). Here their
// values are exposed to the other modules: the ID for the file names
// (multi_log.c, monitor_log.c) and the boot log (main.c), the SD flag for the
// logging task (sd.c).
extern const uint8_t g_edge_node_id;
extern const bool    g_edge_has_sd;
#define EDGE_NODE_ID g_edge_node_id
#define EDGE_HAS_SD  g_edge_has_sd

// ===========================================================================
// SD card
// ===========================================================================
#define SD_MOUNT_POINT   "/sdcard"                  // VFS mount point
// v3: one file per activity (see SD_ACTIVITY_TIMEOUT_MS): SD_LOG_PREFIX + N + ".csv"
// -> "activity_1.csv", "activity_2.csv", ... (requires FATFS LFN enabled).
#define SD_LOG_PREFIX    SD_MOUNT_POINT "/activity_"
#define SD_LOG_PERIOD_MS 5000                       // write every 5 s

// An activity is considered FINISHED after this time WITHOUT new samples; the
// next sample opens a new file. It must exceed the BATCH send interval (~30 s)
// plus a margin for BLE reconnections, so a link flap DURING the activity does
// not split the log into several files.
#define SD_ACTIVITY_TIMEOUT_MS 60000                // 60 s

// FreeRTOS core the logging task runs on. The NimBLE stack runs on core 0
// (default configuration of the BT controller): keeping the SD on core 1
// prevents a slow FAT write from delaying the radio.
#define SD_TASK_CORE 1

// ===========================================================================
// Protocol v4 (MULTI variant) — queues to the SD task
// ===========================================================================
// Accepted v4 packets waiting to be written. The SD task drains every
// SD_LOG_PERIOD_MS; while the watch drains its queue about one packet (4
// samples) per second arrives: 16 slots cover 3 missed rounds. With the queue
// FULL the packet is REJECTED with an ATT error: the watch keeps it and sends
// it again, instead of seeing it confirmed and then lost here. Only on boards
// with an SD card: without one (EDGE_HAS_SD = 0) the queue is not used.
#define MULTI_QUEUE_LEN        16

// Edge events (boot, connections, jumps, duplicates, rejections, also for v5
// packets) for edge_n<node>_events.csv. With the queue full the event is lost
// with a warning on the console: the data are not affected, and the packet is
// NOT rejected because of it.
#define MULTI_EVENT_QUEUE_LEN  24

// ===========================================================================
// Protocol v5 (Monitor) — queue to the SD task
// ===========================================================================
// Accepted v5 packets with at least one sample (confirmations-only packets
// write no rows and do not go through here). Same rule as v4: with the queue
// FULL the packet is REJECTED with an ATT error, and only on boards with an SD
// card. A v5 packet carries up to 8 samples in 8 chunks, against 4 in 13 for
// v4: at the same chunk rate more samples arrive, and 16 slots cover about two
// rounds of the SD task while the watch drains its queue.
#define MONITOR_QUEUE_LEN      16
