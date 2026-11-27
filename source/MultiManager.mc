import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

//
// MultiManager.mc — Radio side of the MULTI variant (protocol v4).
//
// One watch, several ESP32 edges. At any time it is connected to ONE only: the
// registered one with the best signal. It carries out the decisions of
// EdgeRadar (which edge to choose, when to change) and guarantees the delivery
// of the SampleRing samples (store-and-forward).
//
// ===========================================================================
// STATES
// ===========================================================================
//   SCAN        scan on; at the first registered edge seen, wait
//               Cfg.MULTI_SELECT_WINDOW_MS, then pairDevice() on the best one.
//   CONNECTING  pairDevice() called; if CONNECTED does not arrive within
//               Cfg.MULTI_CONNECT_TIMEOUT_MS the attempt is abandoned (edge
//               cooling down).
//   CONNECTED   transmitting; the scan stays on (roaming) to measure the RSSI
//               of all edges, including the current one, which keeps
//               advertising with the busy bit.
//
// ONE connection at a time, and one paired device at a time: before pairing
// another one, unpairDevice() is called on the previous one. This matters
// twice: it frees the connection slot, and it stops the system from
// reconnecting by itself to an edge that was left (paired devices are searched
// for automatically until they are unpaired).
//
// ===========================================================================
// DELIVERY
// ===========================================================================
// A packet is the head of the queue (1..4 samples) and is delivered only when
// ALL the writes of its chunks have a positive outcome. The writes are
// explicitly WITH RESPONSE: with the requestWrite default (WRITE_TYPE_DEFAULT,
// which the Connect IQ docs describe as "without response") the outcome would
// only report the sending, not the reception. The ESP32 answers the last chunk
// after validating the whole packet: its write response IS the ACK.
//
// Whatever goes wrong (failed write, write without outcome past the timeout,
// disconnection, handoff) leaves the samples in the queue: the next packet
// starts again from the first unconfirmed one, to the same edge or another.
// If the ESP32 had received the packet but its response was lost, a duplicate
// arrives: the edge recognises it (same session_id + seq) and the files are
// merged with deduplication. Better a duplicate than a gap.
//
// MultiState is also used by the Monitor; the MultiManager class is not
// (:datafield).
module MultiState {
    const SCAN       = 0;
    const CONNECTING = 1;
    const CONNECTED  = 2;
}

(:datafield)
class MultiManager {

    // --- State read by the view ---
    public var state      as Number = MultiState.SCAN;
    public var curNode    as Number = -1;     // edge connected or being connected
    public var ring       as SampleRing;
    public var radar      as EdgeRadar;
    public var sessionId  as Number = 0;      // UTC epoch of the start (0 = not yet)
    public var connNo     as Number = 0;      // connections in the session
    public var delivered  as Number = 0;      // samples confirmed by an edge
    public var handoffs   as Number = 0;      // INTENDED edge changes (better signal)
    public var linkLosses as Number = 0;      // links lost or abandoned because of errors
    public var roamOk     as Boolean = true;  // false if the stack refuses to scan while connected

    public var serviceUuid;
    private var _dataCharUuid;
    private var _delegate;

    // --- Connection ---
    private var _dev     = null;              // connected Device
    private var _pairDev = null;              // Device returned by pairDevice
    private var _pairAt      as Number = 0;
    private var _connectedAt as Number = 0;
    private var _selecting   as Boolean = false;
    private var _selectAt    as Number = 0;
    private var _scanOn      as Boolean = false;
    private var _roamTick    as Number = 0;
    private var _handoffTo   as Number = -1;  // decided handoff, executed at the end of the packet

    // --- Transmission ---
    private var _queue     as Array = [];     // chunks of the packet in flight
    private var _writeBusy as Boolean = false;
    private var _writeAt   as Number = 0;
    private var _pktSeq    as Number = 0;     // seq of the 1st sample in flight
    private var _pktN      as Number = 0;     // samples in flight (0 = no packet)
    private var _pktId     as Number = 0;
    private var _fails     as Number = 0;     // failed packets in a row

    // --- Field diagnostics (see _logWindow) ---
    private var _dAt      as Number = 0;      // start of the current log window
    private var _dAdv     as Number = 0;      // advertisements received from registered edges
    private var _dAdvCur  as Number = 0;      // ... of which from the current edge
    private var _dRssiCur = null;             // last raw RSSI of the current edge
    private var _dChunks  as Number = 0;      // confirmed chunks (write with positive outcome)
    private var _dSamples as Number = 0;      // confirmed samples

    // --- Radio telemetry (fields 4-7 of every sample, see ProtocolV4.mc) ---
    // Cumulative since the session start: the difference between any two
    // samples received by an edge tells what the radio did in between.
    private var _telAt    as Number = 0;      // time of the last accumulation
    private var _tConnMs  as Number = 0;      // ms connected
    private var _tScanMs  as Number = 0;      // ms with the scan on
    private var _tAggMs   as Number = 0;      // ms pairing
    private var _txTotal  as Number = 0;      // chunks written with a positive outcome
    private var _tryTotal as Number = 0;      // calls to pairDevice
    private var _failTotal as Number = 0;     // failed packets

    function initialize() {
        ring  = new SampleRing(Cfg.MULTI_RING_CAP);
        radar = new EdgeRadar(Cfg.multiNodes());

        // Same service and same DATA characteristic as the other variants.
        // SERVICE_UUID: A07498CA-AD5B-474E-940D-16F1F14E8972
        serviceUuid = BluetoothLowEnergy.longToUuid(
            (0xA07498CAl << 32) | 0xAD5B474El, (0x940D16F1l << 32) | 0xF14E8972l);
        // DATA_CHAR_UUID: 51FF12BB-3ED8-46E5-B4F9-D64E25E01DB5
        _dataCharUuid = BluetoothLowEnergy.longToUuid(
            (0x51FF12BBl << 32) | 0x3ED846E5l, (0xB4F9D64El << 32) | 0x25E01DB5l);
    }

    function start() as Void {
        _delegate = new MultiBleDelegate(self);
        BluetoothLowEnergy.setDelegate(_delegate);
        try {
            BluetoothLowEnergy.registerProfile({
                :uuid => serviceUuid,
                :characteristics => [ { :uuid => _dataCharUuid, :descriptors => [] } ]
            });
        } catch (e instanceof BluetoothLowEnergy.ProfileRegistrationException) {
            // Profile already registered (restart in the same process): still valid.
        }
        _unpairAll();
        _setScan(true);
    }

    function stop() as Void {
        _setScan(false);
        if (_dev != null)     { _unpair(_dev); }
        if (_pairDev != null) { _unpair(_pairDev); }
    }

    // =======================================================================
    // Data (called by the view)
    // =======================================================================

    // "Fresh" START of the activity: new session, numbering restarts. Samples
    // of a previous session still in the queue are dropped: they belong to
    // another activity and to another session_id.
    function onSessionStart(epoch as Number) as Void {
        sessionId = epoch;
        ring.reset();
        delivered = 0;
        handoffs = 0;
        linkLosses = 0;
        connNo = (state == MultiState.CONNECTED) ? 1 : 0;
        _tConnMs = 0;
        _tScanMs = 0;
        _tAggMs = 0;
        _telAt = System.getTimer();         // time before the start does not count
        _txTotal = 0;
        _tryTotal = 0;
        _failTotal = 0;
        // A packet in flight belonged to the previous session: its possible
        // confirmation will be ignored (_pktN = 0). _writeBusy stays as it is:
        // the response to that write has yet to arrive.
        _queue = [];
        _pktN = 0;
    }

    function addSample(values as Array) as Void {
        if (sessionId == 0) { sessionId = Time.now().value(); }
        _fillTelemetry(values, System.getTimer());
        ring.push(values);
        _sendNext();
    }

    // Replaces fields 4-7 (altitude, ascent, kcal, heading) with the radio
    // telemetry read NOW, at the same instant as the battery of the sample.
    // The time elapsed since the last tick is accumulated first, so the seconds
    // are up to date at the time of the sample and not at the previous tick.
    private function _fillTelemetry(values as Array, now as Number) as Void {
        _accumulate(now);
        var r = (curNode > 0) ? radar.rssi(curNode, now) : null;
        var t = ProtoV4.packTelemetry(
            _tConnMs / 1000, _tScanMs / 1000, _tAggMs / 1000, _txTotal,
            _tryTotal, connNo, handoffs, linkLosses, _failTotal,
            state, _scanOn, roamOk,
            (r == null) ? ProtoV4.RSSI_ABSENT : r.toNumber(),
            ring.count);
        values[ProtoV4.T_TIME]  = t[0];
        values[ProtoV4.T_LINK]  = t[1];
        values[ProtoV4.T_COUNT] = t[2];
        values[ProtoV4.T_STATE] = t[3];
    }

    // Adds the stretch since the last accumulation to the time counters,
    // according to the state the radio was in during that stretch.
    private function _accumulate(now as Number) as Void {
        var dt = now - _telAt;
        if (_telAt != 0 && dt > 0) {
            if (_scanOn) { _tScanMs += dt; }
            if (state == MultiState.CONNECTED) {
                _tConnMs += dt;
            } else if (state == MultiState.CONNECTING) {
                _tAggMs += dt;
            }
        }
        _telAt = now;
    }

    // Called at every compute() (~1 Hz), even with the timer stopped: the
    // connection is prepared before the start and survives pauses.
    function tick(now as Number) as Void {
        _accumulate(now);
        if ((now - _dAt) >= Cfg.MULTI_LOG_EVERY_MS) { _logWindow(now); }

        if (state == MultiState.SCAN) {
            if (!_scanOn) { _setScan(true); }
            _maybeSelect(now);
            return;
        }

        if (state == MultiState.CONNECTING) {
            if ((now - _pairAt) > Cfg.MULTI_CONNECT_TIMEOUT_MS) {
                _dropLink(now, true, "connection not established within the timeout");
            }
            return;
        }

        // --- CONNECTED ---
        // Safety net for missed callbacks: the device is no longer connected,
        // or a write has had no outcome for too long (the system supervision
        // timeout may come much later).
        if (_dev != null && !_dev.isConnected()) {
            linkLosses++;
            _dropLink(now, false, "device no longer connected");
            return;
        }
        if (_writeBusy && (now - _writeAt) > Cfg.MULTI_WRITE_TIMEOUT_MS) {
            linkLosses++;
            _dropLink(now, true, "write without outcome past the timeout");
            return;
        }

        if (roamOk) {
            _roamTick++;
            _setScan((_roamTick % Cfg.MULTI_ROAM_SCAN_PERIOD) < Cfg.MULTI_ROAM_SCAN_ON);
            var t = radar.evalHandoff(curNode, now, _connectedAt);
            if (t >= 0) { _handoffTo = t; }
        }
        _sendNext();
    }

    // =======================================================================
    // Callbacks (from the delegate)
    // =======================================================================

    function onScanResult(result as BluetoothLowEnergy.ScanResult) as Void {
        var md = null;
        try {
            md = result.getManufacturerSpecificData(ProtoV4.ADV_COMPANY);
        } catch (e) {
            return;
        }
        var adv = ProtoV4.parseAdv(md);
        if (adv == null) { return; }

        var now = System.getTimer();
        var busy = (adv[1] & ProtoV4.ADV_F_BUSY) != 0;
        var rssi = result.getRssi();
        if (!radar.onAdv(adv[0], rssi, busy, result, now)) { return; }
        _dAdv++;
        if (adv[0] == curNode) {
            _dAdvCur++;
            _dRssiCur = rssi;
        }
        if (state == MultiState.SCAN) { _maybeSelect(now); }
    }

    function onConnected(device) as Void {
        var now = System.getTimer();
        if (state != MultiState.CONNECTING) {
            // Connection not requested: the system found by itself a device we
            // no longer want. Unpair it and free the slot.
            _unpair(device);
            return;
        }
        _accumulate(now);                   // the stretch so far was pairing
        _dev = device;
        state = MultiState.CONNECTED;
        _connectedAt = now;
        connNo++;
        _log("connected to E" + curNode.format("%d") + " (conn " + connNo.format("%d") + ")");
        _fails = 0;
        _roamTick = 0;
        _handoffTo = -1;
        radar.resetVotes();
        _queue = [];
        _pktN = 0;
        _writeBusy = false;
        _sendNext();
    }

    function onDisconnected(device) as Void {
        // Ignored while CONNECTING: it may be the late closing of the edge just
        // left (handoff). An attempt that does not succeed is ended by the
        // connection timeout.
        if (state != MultiState.CONNECTED) { return; }
        // Likewise while connected: if the current device is still connected,
        // the event is about another device.
        if (_dev != null && _dev.isConnected()) { return; }
        linkLosses++;
        _dropLink(System.getTimer(), false, "disconnection reported by the system");
    }

    function onWrite(ok as Boolean) as Void {
        _writeBusy = false;
        if (_pktN == 0) { return; }        // response to a packet already abandoned
        if (!ok) {
            _failPacket();
            return;
        }
        _dChunks++;
        _txTotal++;
        if (_queue.size() > 0) {
            _pumpChunk();
            return;
        }
        // Last chunk confirmed: the packet is delivered.
        var k = ring.confirmUpTo(_pktSeq + _pktN);
        delivered += k;
        _dSamples += k;
        _pktN = 0;
        _fails = 0;
        _sendNext();                       // drains the queue without waiting for the tick
    }

    function onScanState(scanState, status) as Void {
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            _accumulate(System.getTimer());
            _scanOn = false;
            // While connected: the stack does not allow scanning during a
            // connection. Roaming is given up (handoff remains possible only
            // on a lost link) and this is shown on screen.
            if (state == MultiState.CONNECTED) { roamOk = false; }
            _log("scan refused (status " + status.toString() + ")");
        }
    }

    // =======================================================================
    // Internals
    // =======================================================================

    private function _setScan(on as Boolean) as Void {
        if (on == _scanOn) { return; }
        _accumulate(System.getTimer());     // the stretch so far goes to the old state
        _scanOn = on;
        BluetoothLowEnergy.setScanState(on
            ? BluetoothLowEnergy.SCAN_STATE_SCANNING
            : BluetoothLowEnergy.SCAN_STATE_OFF);
    }

    private function _maybeSelect(now as Number) as Void {
        var b = radar.best(now, -1);
        if (b < 0) {
            _selecting = false;
            return;
        }
        if (!_selecting) {
            _selecting = true;
            _selectAt = now + Cfg.MULTI_SELECT_WINDOW_MS;
            return;
        }
        if ((now - _selectAt) >= 0) {
            _connectTo(b, now);
        }
    }

    private function _connectTo(node as Number, now as Number) as Void {
        var res = radar.scanResult(node);
        if (res == null) { return; }
        _selecting = false;
        _setScan(false);

        var dev = null;
        try {
            _tryTotal++;
            dev = BluetoothLowEnergy.pairDevice(res);
        } catch (e) {
            // Typically: paired device slots exhausted. Clean up and try again
            // at the next round.
            _unpairAll();
        }
        if (dev == null) {
            _log("pairDevice to E" + node.format("%d") + " failed");
            radar.cool(node, now);
            _setScan(true);
            return;
        }
        _accumulate(now);                   // the stretch so far was searching
        _pairDev = dev;
        curNode = node;
        _pairAt = now;
        state = MultiState.CONNECTING;
        WatchUi.requestUpdate();
    }

    // Leaves the current edge (or the attempt in progress) and goes back to
    // searching. The samples of the packet in flight stay queued: no loss.
    private function _dropLink(now as Number, coolIt as Boolean, why as String) as Void {
        _log("leaving E" + curNode.format("%d") + ": " + why);
        _accumulate(now);                   // the stretch so far was connected/pairing
        var d = (_dev != null) ? _dev : _pairDev;
        if (d != null) { _unpair(d); }
        if (coolIt && curNode >= 0) { radar.cool(curNode, now); }

        _dev = null;
        _pairDev = null;
        curNode = -1;
        state = MultiState.SCAN;
        _selecting = false;
        _handoffTo = -1;
        _queue = [];
        _pktN = 0;
        _writeBusy = false;
        _fails = 0;
        radar.resetVotes();
        _setScan(true);
        WatchUi.requestUpdate();
    }

    private function _failPacket() as Void {
        _queue = [];
        _pktN = 0;                          // the samples stay queued
        _fails++;
        _failTotal++;
        if (_fails >= Cfg.MULTI_MAX_WRITE_FAILS) {
            linkLosses++;
            _dropLink(System.getTimer(), true, "packets rejected in a row");
        }
        // Otherwise retry at the next tick, not immediately: an edge that has
        // just rejected (e.g. SD queue full) should not be hammered.
    }

    // Starts the next packet if the link is free. Run at the end of every
    // packet and at every tick: it is also the point where an already decided
    // handoff is carried out, so a packet is never interrupted half-way.
    private function _sendNext() as Void {
        if (state != MultiState.CONNECTED || _writeBusy || _pktN > 0) { return; }

        if (_handoffTo >= 0) {
            var t = _handoffTo;
            var now = System.getTimer();
            handoffs++;
            _dropLink(now, false, "handoff to E" + t.format("%d"));
            _connectTo(t, now);
            return;
        }

        if (ring.count == 0 || sessionId == 0) { return; }

        var n = ring.count;
        if (n > Cfg.MULTI_MAX_PER_PKT) { n = Cfg.MULTI_MAX_PER_PKT; }
        var pkt = ProtoV4.buildPacket(curNode, sessionId, ring.headSeq,
                                      ring.count - n, connNo, ring.bytes(0, n));
        _pktSeq = ring.headSeq;
        _pktN = n;
        _queue = Chunker.split(_pktId, ProtoV3.FMT_APP, 0, pkt);
        _pktId = (_pktId + 1) & 0xFF;
        _pumpChunk();
    }

    private function _pumpChunk() as Void {
        if (_writeBusy || _queue.size() == 0 || _dev == null) { return; }

        var ch = null;
        var svc = _dev.getService(serviceUuid);
        if (svc != null) { ch = svc.getCharacteristic(_dataCharUuid); }
        if (ch == null) {
            _failPacket();
            return;
        }

        var chunk = _queue[0];
        _queue = _queue.slice(1, null);
        _writeBusy = true;
        _writeAt = System.getTimer();
        try {
            ch.requestWrite(chunk, { :writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE });
        } catch (e) {
            _writeBusy = false;
            _failPacket();
        }
    }

    // One line in the app log. On the watch System.println writes only if the
    // file GARMIN/APPS/LOGS/<.prg name>.TXT exists (otherwise it does nothing);
    // in the simulator it goes to the console.
    private function _log(msg as String) as Void {
        System.println("MULTI " + (System.getTimer() / 1000).format("%d") + "s " + msg);
    }

    // Summary of the window just closed, every Cfg.MULTI_LOG_EVERY_MS.
    // It answers two questions of the field tests:
    //   - does the watch receive the advertising of the edge it is connected
    //     to? (advE, rssiE) If advE stays 0 while connected, the dBm on screen
    //     cannot update and the signal-based handoff cannot fire;
    //   - how much does the link deliver? (chunks and samples confirmed in the
    //     window: while draining the queue they give the real throughput).
    private function _logWindow(now as Number) as Void {
        var st = (state == MultiState.CONNECTED) ? "CONN"
               : ((state == MultiState.CONNECTING) ? "PAIR" : "SCAN");
        var ema = (curNode > 0) ? radar.rssi(curNode, now) : null;
        _log(st + " E" + curNode.format("%d")
            + " scan=" + (_scanOn ? "1" : "0") + " roam=" + (roamOk ? "1" : "0")
            + " adv=" + _dAdv.format("%d") + " advE=" + _dAdvCur.format("%d")
            + " rssiE=" + ((_dRssiCur == null) ? "--" : _dRssiCur.format("%d"))
            + " ema=" + ((ema == null) ? "--" : ema.toNumber().format("%d"))
            + " vis=" + radar.visible(now).format("%d")
            + " chunks=" + _dChunks.format("%d") + " samples=" + _dSamples.format("%d")
            + " queue=" + ring.count.format("%d") + " conn=" + connNo.format("%d"));
        _dAt = now;
        _dAdv = 0;
        _dAdvCur = 0;
        _dRssiCur = null;
        _dChunks = 0;
        _dSamples = 0;
    }

    private function _unpair(d) as Void {
        try {
            BluetoothLowEnergy.unpairDevice(d);
        } catch (e) {
            // Already unpaired: nothing to do.
        }
    }

    // Unpairs everything the app has paired (at start-up and when pairDevice()
    // reports that the slots are exhausted).
    private function _unpairAll() as Void {
        var list = [];
        try {
            var it = BluetoothLowEnergy.getPairedDevices();
            var d = it.next();
            while (d != null) {
                list.add(d);
                d = it.next();
            }
        } catch (e) {
            return;
        }
        for (var i = 0; i < list.size(); i++) { _unpair(list[i]); }
    }
}
