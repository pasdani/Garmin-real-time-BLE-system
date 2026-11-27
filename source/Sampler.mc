import Toybox.Lang;
import Toybox.Activity;
import Toybox.System;
import Toybox.Time;

//
// Sampler.mc — Reads the 12 values from the sensors and encodes them as the
// RAW on-air values (big-endian uint32). Any Activity.Info field may be null:
// in that case the sentinel ProtoV3.SENTINEL (0xFFFFFFFF = "missing") is used.
//
// Returns an Array<12> where every element is a Number (value present) or
// ProtoV3.SENTINEL (Long) if the value is missing. The order is that of the
// field table (index i is bit i of the DELTA bitmask).
//
(:datafield)
module Sampler {

    // Samples the 12 values. `info` may be null (outside an activity).
    function sample(info as Activity.Info?) as Array {
        var v = new [ProtoV3.NFIELDS];

        // Fields from Activity.Info (individual null check on EVERY access).
        if (info != null) {
            v[ProtoV3.F_HR]        = num(info.currentHeartRate);
            v[ProtoV3.F_CADENCE]   = num(info.currentCadence);
            v[ProtoV3.F_SPEED]     = fixed(info.currentSpeed, 100);           // m/s * 100
            v[ProtoV3.F_DISTANCE]  = trunc(info.elapsedDistance);             // metres
            v[ProtoV3.F_ALTITUDE]  = offset(info.altitude, 1, ProtoV3.ALT_OFFSET);      // m + 10000
            v[ProtoV3.F_ASCENT]    = trunc(info.totalAscent);                 // metres
            v[ProtoV3.F_CALORIES]  = num(info.calories);                      // kcal
            v[ProtoV3.F_HEADING]   = offset(info.currentHeading, 1000, ProtoV3.HEADING_OFFSET); // rad*1000 + 10000
            v[ProtoV3.F_TIMERTIME] = num(info.timerTime);                     // ms
            v[ProtoV3.F_ELAPSED]   = num(info.elapsedTime);                   // ms
        } else {
            v[ProtoV3.F_HR]        = ProtoV3.SENTINEL;
            v[ProtoV3.F_CADENCE]   = ProtoV3.SENTINEL;
            v[ProtoV3.F_SPEED]     = ProtoV3.SENTINEL;
            v[ProtoV3.F_DISTANCE]  = ProtoV3.SENTINEL;
            v[ProtoV3.F_ALTITUDE]  = ProtoV3.SENTINEL;
            v[ProtoV3.F_ASCENT]    = ProtoV3.SENTINEL;
            v[ProtoV3.F_CALORIES]  = ProtoV3.SENTINEL;
            v[ProtoV3.F_HEADING]   = ProtoV3.SENTINEL;
            v[ProtoV3.F_TIMERTIME] = ProtoV3.SENTINEL;
            v[ProtoV3.F_ELAPSED]   = ProtoV3.SENTINEL;
        }

        // Watch battery: always available from System (percent * 100).
        var stats = System.getSystemStats();
        v[ProtoV3.F_BATTERY] = (stats != null && stats.battery != null)
            ? (stats.battery * 100).toNumber()
            : ProtoV3.SENTINEL;

        // UTC real time (epoch seconds): always available.
        v[ProtoV3.F_REALTIME] = Time.now().value();

        return v;
    }

    // --- Encoding helpers (null -> SENTINEL) ---

    // Plain integer (Number). null -> sentinel.
    function num(x) {
        if (x == null) { return ProtoV3.SENTINEL; }
        return x.toNumber();
    }

    // Truncation to integer of a Float in metres. null -> sentinel.
    function trunc(x) {
        if (x == null) { return ProtoV3.SENTINEL; }
        return x.toNumber();
    }

    // Fixed-point: x * scale, truncated. null -> sentinel.
    function fixed(x, scale as Number) {
        if (x == null) { return ProtoV3.SENTINEL; }
        return (x * scale).toNumber();
    }

    // Fixed-point with an additive offset (for values that may be negative):
    // (x * scale) + off. null -> sentinel.
    function offset(x, scale as Number, off as Number) {
        if (x == null) { return ProtoV3.SENTINEL; }
        return ((x * scale) + off).toNumber();
    }
}
