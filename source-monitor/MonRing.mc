import Toybox.Lang;

//
// MonRing.mc — STORE-AND-FORWARD queue of the V5 (MONITOR) samples.
//
// Same rules as SampleRing (source/), with 12-byte samples instead of 48:
//   - One preallocated ByteArray: Cfg.MULTI_RING_CAP samples (720, one hour
//     at 5 s) = 8,640 B.
//   - The sample enters already serialised (ProtoV5.packSample): building a
//     packet is just copying bytes.
//   - The queued seqs are contiguous: samples are added at the tail and
//     removed only from the head (confirmation by an edge or overflow). The
//     head seq is enough.
//   - On overflow the oldest sample is dropped, counted in `dropped`.
//
class MonRing {

    private var _buf as ByteArray;
    private var _cap as Number;
    private var _head as Number = 0;     // slot of the oldest sample

    public var count   as Number = 0;    // samples waiting for confirmation
    public var headSeq as Number = 0;    // seq of the oldest sample
    public var dropped as Number = 0;    // samples dropped on overflow

    function initialize(capacity as Number) {
        _cap = capacity;
        _buf = new [capacity * ProtoV5.SAMPLE_BYTES]b;
    }

    // Queues an already serialised sample (ProtoV5.SAMPLE_BYTES bytes).
    function push(sample as ByteArray) as Void {
        if (count == _cap) {
            _head = (_head + 1) % _cap;
            count--;
            headSeq++;
            dropped++;
        }
        var off = ((_head + count) % _cap) * ProtoV5.SAMPLE_BYTES;
        for (var i = 0; i < ProtoV5.SAMPLE_BYTES; i++) {
            _buf[off + i] = sample[i];
        }
        count++;
    }

    // Bytes of the first n queued samples. At most two native slices: one up
    // to the end of the buffer, one from the start.
    function bytes(n as Number) as ByteArray {
        var first = n;
        if (_head + n > _cap) { first = _cap - _head; }
        var out = _buf.slice(_head * ProtoV5.SAMPLE_BYTES, (_head + first) * ProtoV5.SAMPLE_BYTES);
        if (first < n) {
            out.addAll(_buf.slice(0, (n - first) * ProtoV5.SAMPLE_BYTES));
        }
        return out;
    }

    // Removes from the head the samples with seq < seqEnd (confirmed
    // delivery). It reasons on seqs: if the queue overflowed in the meantime,
    // the head has already moved. Returns how many were removed.
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
