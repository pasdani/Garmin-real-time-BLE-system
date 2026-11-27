import Toybox.Lang;

//
// Chunker.mc — Splits a logical packet (payload) into BLE chunks.
//
//   chunk = HEADER (4 bytes) + PAYLOAD (1..16 bytes)
//
// cnt = ceil(len/16). The last chunk may be short: NO padding.
// The invariant "4 whole fields per full chunk, no field split" holds because
// CHUNK_PAYLOAD (16) = 4 * FIELD_BYTES.
//
module Chunker {

    // Returns an Array<ByteArray>: the chunks ready to be written to the DATA characteristic.
    function split(pktId as Number, flags as Number, bitmask as Number, payload as ByteArray) as Array {
        var len = payload.size();

        // Number of chunks (at least 1, even for a 12 B payload such as the keep-alive).
        var cnt = len / ProtoV3.CHUNK_PAYLOAD;
        if (len % ProtoV3.CHUNK_PAYLOAD != 0 || cnt == 0) { cnt += 1; }

        var chunks = [];
        for (var idx = 0; idx < cnt; idx++) {
            var start = idx * ProtoV3.CHUNK_PAYLOAD;
            var end   = start + ProtoV3.CHUNK_PAYLOAD;
            if (end > len) { end = len; }

            var chunk = new [4]b;                       // header
            var header = ProtoV3.packHeader(pktId, flags, idx, cnt, bitmask);
            ProtoV3.putBe32(chunk, 0, header);
            chunk.addAll(payload.slice(start, end));    // payload (the last one possibly short)

            chunks.add(chunk);
        }
        return chunks;
    }
}
