import Toybox.Lang;

//
// SampleRing.mc — STORE-AND-FORWARD queue of the MULTI variant samples.
//
// Every sample enters with a consecutive seq and leaves only when an edge has
// CONFIRMED its reception. If the link drops (the watch moves, the edge is far
// away, a handoff is half done) the samples stay here and go to the next edge:
// no sample is lost until the queue overflows.
//
// ===========================================================================
// DESIGN CHOICES
// ===========================================================================
// - ONE preallocated ByteArray (capacity x 48 bytes), not an array of
//   objects: the memory is fixed and known at start-up (720 samples = 34,560 B,
//   one hour at 5 s, out of the 256 KB available to a data field) and the
//   sampling loop allocates nothing.
// - Samples are serialised WHEN SAMPLED (12 putBe32), not when sent: the cost
//   per compute() is flat, and building a packet is just copying bytes that are
//   already prepared.
// - The queued seqs are ALWAYS contiguous: samples are added at the tail and
//   removed only from the head (confirmation or overflow). The head seq is
//   therefore enough to know the seq of every element, without storing it.
// - On overflow the OLDEST sample is dropped: after an hour without edges the
//   recent data are more useful. The gap shows up when the files are merged
//   (tools/merge_multi.py) and is counted in `dropped`.
//
(:datafield)
class SampleRing {

    private var _buf as ByteArray;
    private var _cap as Number;
    private var _head as Number = 0;     // slot of the oldest sample

    public var count   as Number = 0;    // samples waiting for confirmation
    public var headSeq as Number = 0;    // seq of the oldest sample
    public var nextSeq as Number = 0;    // seq the next sample will get
    public var dropped as Number = 0;    // samples dropped on overflow

    function initialize(capacity as Number) {
        _cap = capacity;
        _buf = new [capacity * ProtoV3.FULL_BYTES]b;
    }

    function capacity() as Number { return _cap; }

    // New session: numbering restarts from 0. The buffer is not reallocated.
    function reset() as Void {
        _head = 0;
        count = 0;
        headSeq = 0;
        nextSeq = 0;
        dropped = 0;
    }

    // Queues a sample (Array<12> from Sampler.sample).
    function push(values as Array) as Void {
        if (count == _cap) {
            _head = (_head + 1) % _cap;
            count--;
            headSeq++;
            dropped++;
        }
        var off = ((_head + count) % _cap) * ProtoV3.FULL_BYTES;
        for (var i = 0; i < ProtoV3.NFIELDS; i++) {
            ProtoV3.putBe32(_buf, off + i * ProtoV3.FIELD_BYTES, values[i]);
        }
        count++;
        nextSeq++;
    }

    // Bytes of samples [headSeq + k, headSeq + k + n), in the FULL layout.
    // At most two native slices: one up to the end of the buffer, one from the start.
    function bytes(k as Number, n as Number) as ByteArray {
        var s0 = (_head + k) % _cap;
        var first = n;
        if (s0 + n > _cap) { first = _cap - s0; }
        var out = _buf.slice(s0 * ProtoV3.FULL_BYTES, (s0 + first) * ProtoV3.FULL_BYTES);
        if (first < n) {
            out.addAll(_buf.slice(0, (n - first) * ProtoV3.FULL_BYTES));
        }
        return out;
    }

    // Removes from the head all samples with seq < seqEnd (confirmed
    // delivery). It reasons on seqs, not on a count: if the queue overflowed
    // during the transmission, the head has already moved and a count would
    // remove samples never sent. Returns how many were removed.
    function confirmUpTo(seqEnd as Number) as Number {
        var k = seqEnd - headSeq;
        if (k <= 0) { return 0; }
        if (k > count) { k = count; }
        _head = (_head + k) % _cap;
        count -= k;
        headSeq += k;
        return k;
    }
}
