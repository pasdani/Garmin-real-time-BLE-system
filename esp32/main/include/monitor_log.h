//
// monitor_log.h — microSD logging of protocol v5 (MONITOR).
//
//   /monitor_<session>_n<node>.csv   one row per received sample
//
// Like the v4 data file (multi_log.h): name with session and node, append,
// duplicate rows written with dup=1. The edge events (connections,
// rejections, duplicates, jumps of v5 packets) go into the same
// edge_n<node>_events.csv as v4.
//
//   rx_ms,node,session,seq,conn_no,backlog,dup,realTime,hr,batt,steps,alt
//
//   rx_ms   ESP32 uptime at reception (NOT comparable between edges)
//   node    edge that received the sample (this one)
//   dup     1 = sample already received HERE (write response lost, resent)
//   hr      bpm
//   batt    % with two decimals
//   steps   steps of the day
//   alt     metres (offset removed)
//   N/A = value missing (0xFFFF on-air).
//
// A confirmations-only packet (n_samples = 0) writes no rows. ev_ack and
// ev_user go only to the console.
//
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "monitor.h"

// An accepted v5 packet, as handed to the SD logger.
typedef struct {
    uint32_t      rx_ms;      // uptime at reception
    uint8_t       first_new;  // samples [0, first_new) are duplicates
    monitor_pkt_t p;
} monitor_record_t;

// Writes the rows of a packet (opens/switches the session file if needed).
// Returns false if the SD card cannot be used.
bool monitor_log_record(const monitor_record_t *r);

// fflush + fsync of the open file. Called at the end of every SD task round.
void monitor_log_flush(void);

// Closes the file (e.g. after a write error, before unmounting the SD card).
void monitor_log_close(void);
