//
// ble.h — Interface of the BLE GATT peripheral module (NimBLE stack),
// protocols v3, v4 and v5.
//
// Receives the chunks on the DATA characteristic, reassembles the logical
// packets, applies the integrity checks and routes them by protocol. What goes
// to the SD card passes through four FIFOs, drained by the SD module on core 1
// (the radio never touches the card):
//   - reconstructed v3 samples (12 fields): ONE row per received sample, no
//     "stale" rows when the watch is not sending (before the start, paused);
//   - accepted v4 packets, and edge events (v4 and v5);
//   - accepted v5 packets with at least one sample.
//
#pragma once
#include <stdint.h>
#include <stdbool.h>

#include "protocol_v3.h"
#include "multi_log.h"
#include "monitor_log.h"

// A reconstructed sample (raw on-air values, or SENTINEL) + source format.
typedef struct {
    uint32_t field[PROTO_NFIELDS]; // values by field index
    uint8_t  fmt;                  // packet format (PROTO_FMT_*)
} garmin_sample_t;

// Initialises NimBLE, registers the GATT service and starts advertising.
void ble_init(void);

// Pops the oldest received sample (FIFO), non-blocking.
// Returns false if no sample is queued.
bool ble_pop_sample(garmin_sample_t *out);

// Pops the oldest accepted v4 packet (FIFO), non-blocking.
bool ble_pop_multi(multi_record_t *out);

// Pops the oldest edge event (FIFO), non-blocking.
bool ble_pop_multi_event(multi_event_t *out);

// Pops the oldest accepted v5 packet (FIFO), non-blocking.
bool ble_pop_monitor(monitor_record_t *out);
