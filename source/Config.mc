import Toybox.Lang;

//
// Config.mc — Tunable parameters shared by the variants.
//
// The single place to change cadences and thresholds. The three v3 variants
// sample the SAME data at the SAME cadence (5 s): only the radio strategy
// changes, so the battery comparison is made on equal data.
//
module Cfg {

    // --- Cadences (in number of compute() calls; compute runs at ~1 Hz) ---
    const SAMPLE_EVERY   = 5;   // sample every 5 compute calls -> ~5 s
    const BATCH_SAMPLES  = 6;   // BATCH: 6 samples -> one send every ~30 s

    // =======================================================================
    // MULTI variant (Variant.ID = 5) — protocol v4, several ESP32 edges
    // =======================================================================
    // The watch connects to the REGISTERED edge with the best signal, moves to
    // another one when that becomes clearly better (handoff) and does not lose
    // samples when the link drops: they stay queued and go to the next edge.
    // See EdgeRadar.mc (policy) and MultiManager.mc (radio).

    // Edges the watch accepts to connect to: IDs from MULTI_NODE_MIN to
    // MULTI_NODE_MAX, fixed when the ESP32 is built (THIS_EDGE_NODE_ID in
    // esp32/main/src/ble.c). An ESP32 with the same firmware but an ID out of
    // range is ignored.
    //
    // The range is wider than the edges that actually exist, on purpose: a new
    // edge (up to 10) is added by flashing an ESP32 with its ID, without
    // rebuilding the watch app. An ID without a board costs nothing: it sends
    // no advertising, so it is never a candidate. The price is one more row in
    // the EdgeRadar table per ID (10 in total).
    const MULTI_NODE_MIN = 1;
    const MULTI_NODE_MAX = 10;

    function multiNodes() as Array<Number> {
        var n = MULTI_NODE_MAX - MULTI_NODE_MIN + 1;
        var a = new [n];
        for (var i = 0; i < n; i++) { a[i] = MULTI_NODE_MIN + i; }
        return a;
    }

    // --- Data ---
    const MULTI_SAMPLE_EVERY = 5;    // same cadence (5 s) and same 12 values as v3
    const MULTI_MAX_PER_PKT  = 4;    // samples per packet while draining the queue (13 chunks)
    // Store-and-forward queue: 720 samples = 1 h without any edge at 5 s,
    // 34,560 B out of 256 KB. Beyond that, the oldest sample is dropped.
    const MULTI_RING_CAP     = 720;

    // --- Edge selection (while disconnected) ---
    // After the first sighting, wait this long before choosing, to compare the
    // edges instead of taking the first one that answers.
    const MULTI_SELECT_WINDOW_MS = 1500;
    // pairDevice() has no synchronous outcome: if CONNECTED does not arrive
    // within this time the attempt is abandoned and the edge cools down.
    const MULTI_CONNECT_TIMEOUT_MS = 10000;
    const MULTI_COOLDOWN_MS        = 10000;

    // --- RSSI measurement (see EdgeRadar.mc) ---
    const MULTI_RSSI_ALPHA   = 0.3;     // weight of the new sample in the moving average
    const MULTI_CAND_TTL_MS  = 5000;    // beyond this, the edge is no longer a candidate
    const MULTI_CUR_STALE_MS = 8000;    // beyond this, the current edge counts as RSSI_FLOOR
    const MULTI_RSSI_FLOOR   = -100;    // dBm

    // --- Handoff ---
    // Hysteresis: the candidate must beat the current edge by at least 8 dB.
    // The RSSI of an advertisement swings by +/-5 dB even when standing still:
    // below this threshold the watch would bounce between two equidistant edges.
    const MULTI_HYST_DB       = 8;
    const MULTI_HANDOFF_VOTES = 3;      // consecutive evaluations (1 per second)
    const MULTI_MIN_DWELL_MS  = 15000;  // minimum time on an edge

    // Roaming scan while connected: on for ROAM_SCAN_ON ticks every
    // ROAM_SCAN_PERIOD. Equal values = always on (default: handoff matters
    // more than power, and this variant is not part of the battery
    // experiment). To save power, e.g. ON = 3, PERIOD = 6.
    const MULTI_ROAM_SCAN_ON     = 6;
    const MULTI_ROAM_SCAN_PERIOD = 6;

    // --- Transmission robustness ---
    // A write without outcome for longer than this = dead link, even if the
    // system has not reported it yet (the supervision timeout can be late).
    const MULTI_WRITE_TIMEOUT_MS = 6000;
    // Failed packets in a row before abandoning the edge.
    const MULTI_MAX_WRITE_FAILS  = 3;

    // --- Diagnostics ---
    // How often MultiManager writes the window summary to the app log
    // (advertisements received, RSSI of the current edge, confirmed chunks).
    // On the watch the log is enabled by creating GARMIN/APPS/LOGS/<.prg name>.TXT.
    const MULTI_LOG_EVERY_MS = 10000;

    // --- DELTA thresholds: bit set if |value - last_SENT| >= threshold ---
    // Expressed in the RAW unit already encoded in the payload (see Sampler).
    //   speed   is m/s*100  -> 0.1 m/s = 10
    //   battery is %*100    -> 0.5%    = 50
    //   heading is rad*1000 -> 0.1 rad = 100
    const TH_HR       = 2;     // +/- 2 bpm
    const TH_CADENCE  = 2;     // +/- 2 spm/rpm
    const TH_SPEED    = 10;    // +/- 0.1 m/s  (m/s*100)
    const TH_DISTANCE = 10;    // +/- 10 m
    const TH_ALTITUDE = 1;     // +/- 1 m
    const TH_ASCENT   = 1;     // +/- 1 m
    const TH_CALORIES = 1;     // +/- 1 kcal
    const TH_HEADING  = 100;   // +/- 0.1 rad  (rad*1000)
    const TH_BATTERY  = 50;    // +/- 0.5%     (%*100)

    // Threshold per field index. For the timestamp fields (8, 10, 11) the
    // threshold is not used: those bits are ALWAYS forced to 1 (see
    // DELTA_FORCED_MASK). -1 = field without threshold comparison.
    function threshold(fieldIdx as Number) as Number {
        switch (fieldIdx) {
            case ProtoV3.F_HR:       return TH_HR;
            case ProtoV3.F_CADENCE:  return TH_CADENCE;
            case ProtoV3.F_SPEED:    return TH_SPEED;
            case ProtoV3.F_DISTANCE: return TH_DISTANCE;
            case ProtoV3.F_ALTITUDE: return TH_ALTITUDE;
            case ProtoV3.F_ASCENT:   return TH_ASCENT;
            case ProtoV3.F_CALORIES: return TH_CALORIES;
            case ProtoV3.F_HEADING:  return TH_HEADING;
            case ProtoV3.F_BATTERY:  return TH_BATTERY;
            default:                  return -1; // timestamps: forced
        }
    }
}
