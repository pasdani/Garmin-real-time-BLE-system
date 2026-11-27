//
// multi_log.h — microSD logging of protocol v4 (MULTI).
//
// ===========================================================================
// LAYOUT ON SD — designed to be MERGED with the cards of the other edges
// ===========================================================================
//
//   /multi_<session>_n<node>.csv   one row per received sample
//   /edge_n<node>_events.csv       edge events, appended across boots
//
// The name carries session AND node: when the cards of the edges are copied
// into the same folder on the PC no file overwrites another, and
// tools/merge_multi.py merges them by `seq`.
//
// Data:
//   rx_ms,node,session,seq,conn_no,backlog,dup,realTime,elapsed,hr,cad,speed,
//   dist,t_conn_s,t_scan_s,t_agg_s,tx_chunks,n_try,n_conn,n_ho,n_lost,n_fail,
//   radio,scan_on,roam_ok,rssi,coda,timer,watchBatt
//
//   rx_ms   ESP32 uptime at reception (NOT comparable between edges: every
//           edge has its own clock; the common time is the watch realTime)
//   node    edge that received the sample (this one)
//   dup     1 = sample already received HERE (write response lost, resent).
//           Duplicate rows are written anyway: they are the direct measure of
//           the retransmissions.
//   hr..dist, timer, watchBatt: v3 encodings (4294967295 = value missing).
//   t_conn_s..coda: radio telemetry of fields 4-7 (proto_ver 0x05), already
//           unpacked by v4_tel_decode (protocol_v4.h). The counters are
//           cumulative since the start and wrap around (mod 65536 / mod 256):
//           the difference between any two rows is the work of the radio in
//           between. radio = the state only (bit0-1), scan_on and roam_ok =
//           bits 2 and 3, signed rssi (-128 = not measured), coda = samples
//           queued on the watch.
//
// Events:
//   uptime_ms,event,session,a,b
//
// The event file belongs to the edge, not to v4 only: it also receives the
// session, jump, dup, reject, node_mismatch and queue_full events of v5
// (Monitor) packets, with the same meaning. Connections carry the session of
// the last accepted packet, v4 or v5.
//
//   boot           a=node_id
//   connect        a=conn_handle
//   disconnect     a=HCI reason (0x213 = closed by the watch, e.g. handoff;
//                  0x208 = supervision timeout, i.e. link lost;
//                  0x216 = closed by this edge, pass-by simulation)
//   session        a=seq_first of the first packet seen
//   jump           a=expected seq, b=received seq (the samples in between
//                  went to another edge, or were lost)
//   dup            a=seq_first, b=duplicate samples in the packet
//   reject         a=reason (1 len, 2 magic, 3 n_samples, 4 crc), b=length
//   node_mismatch  a=node_id in the packet, b=node_id of this edge
//   queue_full     a=seq_first (packet rejected: the watch sends it again)
//   sim_off        a=duration in s of the "off" phase (pass-by simulation:
//                  the edge becomes invisible and closes the connection)
//   sim_on         a=duration in s of the "on" phase (visible again)
//
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "multi.h"

// An accepted v4 packet, as handed to the SD logger.
typedef struct {
    uint32_t    rx_ms;      // uptime at reception
    uint8_t     first_new;  // samples [0, first_new) are duplicates
    multi_pkt_t p;
} multi_record_t;

typedef enum {
    MEV_BOOT = 0,
    MEV_CONNECT,
    MEV_DISCONNECT,
    MEV_SESSION,
    MEV_JUMP,
    MEV_DUP,
    MEV_REJECT,
    MEV_NODE_MISMATCH,
    MEV_QUEUE_FULL,
    MEV_SIM_OFF,
    MEV_SIM_ON,
} multi_ev_type_t;

typedef struct {
    uint32_t uptime_ms;
    uint8_t  type;          // multi_ev_type_t
    uint32_t session;
    uint32_t a;
    uint32_t b;
} multi_event_t;

// Writes the rows of a packet (opens/switches the session file if needed).
// Returns false if the SD card cannot be used.
bool multi_log_record(const multi_record_t *r);

// Appends an event to edge_n<node>_events.csv.
bool multi_log_event(const multi_event_t *e);

// fflush + fsync of the open files. Called at the end of every SD task round.
void multi_log_flush(void);

// Closes the files (e.g. after a write error, before unmounting the SD card).
void multi_log_close(void);
