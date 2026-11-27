import Toybox.Lang;

//
// Encoders.mc — Builds the PAYLOAD of the three formats, plus the DELTA helpers.
//
// The payload is a sequence of big-endian uint32 fields WITHOUT prefixes: the
// bitmask is in the header. Every field takes 4 bytes; no field is ever split
// across two chunks (invariant guaranteed by the chunker, CHUNK_PAYLOAD=16=4*4).
//
(:datafield)
module Encoders {

    // true if the value means "missing" (sentinel).
    // Present values are always Numbers; the sentinel is a Long.
    function isSentinel(v) as Boolean {
        return (v instanceof Lang.Long);
    }

    // FULL: 12 fields in table order -> 48 bytes.
    function buildFull(values as Array) as ByteArray {
        var p = new [ProtoV3.FULL_BYTES]b;
        for (var i = 0; i < ProtoV3.NFIELDS; i++) {
            ProtoV3.putBe32(p, i * ProtoV3.FIELD_BYTES, values[i]);
        }
        return p;
    }

    // DELTA: only the fields whose bit is set, in increasing bit order.
    // The i-th present field is at offset 4*i of the payload.
    function buildDeltaPayload(values as Array, bitmask as Number) as ByteArray {
        var k = ProtoV3.popcount12(bitmask);
        var p = new [k * ProtoV3.FIELD_BYTES]b;
        var j = 0;
        for (var i = 0; i < ProtoV3.NFIELDS; i++) {
            if ((bitmask & (1 << i)) != 0) {
                ProtoV3.putBe32(p, j * ProtoV3.FIELD_BYTES, values[i]);
                j++;
            }
        }
        return p;
    }

    // Computes the DELTA bitmask by comparing the current values with the last
    // SENT value. The timestamp bits (8, 10, 11) are always forced to 1.
    // On the first packet after connecting all bits are 1.
    function computeDeltaMask(values as Array, lastSent as Array, first as Boolean) as Number {
        var mask = 0;
        for (var i = 0; i < ProtoV3.NFIELDS; i++) {
            if (first) {
                mask |= (1 << i);
                continue;
            }
            var th = Cfg.threshold(i);
            if (th < 0) {
                mask |= (1 << i);          // forced timestamps
            } else if (changed(values[i], lastSent[i], th)) {
                mask |= (1 << i);
            }
        }
        return mask;
    }

    // Updates lastSent ONLY for the fields actually sent (bit set).
    function updateLastSent(lastSent as Array, values as Array, bitmask as Number) as Void {
        for (var i = 0; i < ProtoV3.NFIELDS; i++) {
            if ((bitmask & (1 << i)) != 0) {
                lastSent[i] = values[i];
            }
        }
    }

    // BATCH: N consecutive samples, each with the FULL internal layout (48 B).
    // No block header: N = cnt/3 (alignment 48 = 3*16).
    function buildBatch(samples as Array) as ByteArray {
        var n = samples.size();
        var p = new [n * ProtoV3.FULL_BYTES]b;
        for (var s = 0; s < n; s++) {
            var base = s * ProtoV3.FULL_BYTES;
            var sv = samples[s] as Array;
            for (var i = 0; i < ProtoV3.NFIELDS; i++) {
                ProtoV3.putBe32(p, base + i * ProtoV3.FIELD_BYTES, sv[i]);
            }
        }
        return p;
    }

    // --- internal ---

    // true if the field counts as "changed" (hence present in the DELTA).
    function changed(cur, last, th as Number) as Boolean {
        var curS  = isSentinel(cur);
        var lastS = isSentinel(last);
        if (curS && lastS) { return false; }   // both missing: no change
        if (curS != lastS) { return true; }    // value appeared or disappeared
        var d = cur - last;
        if (d < 0) { d = -d; }
        return d >= th;
    }
}
