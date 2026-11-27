import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//
// MonitorManager.mc — Radio side of V5 (MONITOR).
//
// Same structure as MultiManager (source/): same states, edge selection,
// handoff and delivery; EdgeRadar, MultiState and Cfg.MULTI_* are used as they
// are.
//
// ===========================================================================
// WHAT IS NEW COMPARED WITH MULTI
// ===========================================================================
// - ALERTS: the profile also registers the ALERT characteristic (...DBB) with
//   its CCCD, and [0x01, 0x00] is written to the CCCD at every connection.
//   Received notifications are passed, as they are, to the method given to
//   the constructor (MonitorApp.onAlertFrame). With an edge that has no ALERT
//   characteristic the watch connects anyway and the subscription stays
//   MonSub.MISSING.
// - v5 DATA: packets from ProtoV5.buildPacket with up to ProtoV5.MAX_SAMPLES
//   12 B samples taken from MonRing. The header also carries ev_ack and
//   ev_user of the destination edge (AlertQueue).
// - ATT allows a single operation in flight: no chunk starts until the CCCD
//   write has an outcome (or MonCfg.CCCD_TIMEOUT_MS expires).
//
// ===========================================================================
// DELIVERY (as in MULTI)
// ===========================================================================
// Write WITH RESPONSE. The ESP32 answers the last chunk after validating the
// packet: that response is the ACK, and only then do the samples leave the
// queue. A failed write or one without outcome, a disconnection or a handoff
// leave the samples in the queue: the next packet starts again from the first
// unconfirmed one, to the same edge or another. A decided handoff is carried
// out at the end of a packet, never half-way.
//
module MonSub {
    const NONE    = 0;     // not connected
    const PENDING = 1;     // CCCD write in progress
    const ON      = 2;     // subscribed: alerts arrive
    const FAILED  = 3;     // CCCD write rejected or without outcome
    const MISSING = 4;     // the edge has no ALERT characteristic
}

class MonitorManager {

    // --- State read by the view ---
    public var state      as Number = MultiState.SCAN;
    public var curNode    as Number = -1;     // edge connected or being connected
    public var radar      as EdgeRadar;
    public var ring       as MonRing;
    public var sessionId  as Number;          // epoch of the app opening
    public var connNo     as Number = 0;      // connections in the session
    public var handoffs   as Number = 0;      // INTENDED edge changes (better signal)
    public var linkLosses as Number = 0;      // links lost or abandoned
    public var roamOk     as Boolean = true;  // false if the stack refuses to scan while connected
    public var alertSub   as Number = MonSub.NONE;

    public var serviceUuid;
    private var _dataCharUuid;
    private var _alertCharUuid;
    private var _delegate;
    private var _onFrame as Method;
    private var _alerts as AlertQueue;

    // --- Connection ---
    private var _dev     = null;              // connected Device
    private var _pairDev = null;              // Device returned by pairDevice
    private var _pairAt      as Number = 0;
    private var _connectedAt as Number = 0;
    private var _selecting   as Boolean = false;
    private var _selectAt    as Number = 0;
    private var _scanOn      as Boolean = false;
    private var _roamTick    as Number = 0;
    private var _cccdAt      as Number = 0;   // time of the CCCD write
    private var _handoffTo   as Number = -1;  // decided handoff, executed at the end of the packet

    // --- Transmission ---
    private var _queue     as Array = [];     // chunks of the packet in flight
    private var _writeBusy as Boolean = false;
    private var _writeAt   as Number = 0;
    private var _pktSeq    as Number = 0;     // seq of the 1st sample in flight
    private var _pktN      as Number = 0;     // samples in flight (0 = no packet)
    private var _pktId     as Number = 0;
    private var _fails     as Number = 0;     // failed packets in a row

    // --- Log (see _logWindow) ---
    private var _dAt      as Number = 0;
    private var _dChunks  as Number = 0;      // chunks confirmed in the window
    private var _dSamples as Number = 0;      // samples confirmed in the window

    // onFrame: Method(value as ByteArray) as Void, called for every
    // notification received on the ALERT characteristic. alerts: source of
    // ev_ack and ev_user. session: session_id of the packets.
    function initialize(onFrame as Method, alerts as AlertQueue, session as Number) {
        _onFrame = onFrame;
        _alerts = alerts;
        sessionId = session;
        radar = new EdgeRadar(Cfg.multiNodes());
        ring = new MonRing(Cfg.MULTI_RING_CAP);

        // Same service and same DATA characteristic as the other variants.
        // SERVICE_UUID: A07498CA-AD5B-474E-940D-16F1F14E8972
        serviceUuid = BluetoothLowEnergy.longToUuid(
            (0xA07498CAl << 32) | 0xAD5B474El, (0x940D16F1l << 32) | 0xF14E8972l);
        // DATA_CHAR_UUID: 51FF12BB-3ED8-46E5-B4F9-D64E25E01DB5
        _dataCharUuid = BluetoothLowEnergy.longToUuid(
            (0x51FF12BBl << 32) | 0x3ED846E5l, (0xB4F9D64El << 32) | 0x25E01DB5l);
        // ALERT_CHAR_UUID: 51FF12BB-3ED8-46E5-B4F9-D64E25E01DBB (NOTIFY, V5 only)
        _alertCharUuid = BluetoothLowEnergy.longToUuid(
            (0x51FF12BBl << 32) | 0x3ED846E5l, (0xB4F9D64El << 32) | 0x25E01DBBl);
    }

    function start() as Void {
        _delegate = new MonitorBleDelegate(self);
        BluetoothLowEnergy.setDelegate(_delegate);
        try {
            BluetoothLowEnergy.registerProfile({
                :uuid => serviceUuid,
                :characteristics => [
                    { :uuid => _dataCharUuid, :descriptors => [] },
                    { :uuid => _alertCharUuid, :descriptors => [ BluetoothLowEnergy.cccdUuid() ] }
                ]
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

    // A sample already serialised (ProtoV5.packSample), from the app Timer.
    function addSample(sample as ByteArray) as Void {
        ring.push(sample);
        _sendNext();
    }

    // Called by the app Timer every MonCfg.TICK_MS.
    function tick(now as Number) as Void {
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
        // Safety nets for missed callbacks, as in MULTI.
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
        if (alertSub == MonSub.PENDING && (now - _cccdAt) > MonCfg.CCCD_TIMEOUT_MS) {
            alertSub = MonSub.FAILED;
            _log("alert subscription timed out");
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
        if (!radar.onAdv(adv[0], result.getRssi(), busy, result, now)) { return; }
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
        _subscribe(now);
        _sendNext();                        // starts only if the subscription is not in progress
    }

    function onDisconnected(device) as Void {
        // As in MULTI: ignored while CONNECTING (it may be the late closing of
        // the edge just left), and while connected it counts only if the
        // current device is no longer connected.
        if (state != MultiState.CONNECTED) { return; }
        if (_dev != null && _dev.isConnected()) { return; }
        linkLosses++;
        _dropLink(System.getTimer(), false, "disconnection reported by the system");
    }

    // Outcome of the CCCD write of ALERT: from here the data can start.
    function onCccdWrite(ok as Boolean) as Void {
        if (alertSub != MonSub.PENDING) { return; }
        alertSub = ok ? MonSub.ON : MonSub.FAILED;
        _log(ok ? "alerts enabled" : "alert subscription rejected");
        _sendNext();
        WatchUi.requestUpdate();
    }

    // Outcome of the write of a chunk on the DATA characteristic.
    function onWrite(ok as Boolean) as Void {
        _writeBusy = false;
        if (_pktN == 0) { return; }        // response to a packet already abandoned
        if (!ok) {
            _failPacket();
            return;
        }
        _dChunks++;
        if (_queue.size() > 0) {
            _pumpChunk();
            return;
        }
        // Last chunk confirmed: the packet is delivered.
        _dSamples += ring.confirmUpTo(_pktSeq + _pktN);
        _pktN = 0;
        _fails = 0;
        _sendNext();                       // drains the queue without waiting for the tick
    }

    // Notification from the edge: only the ALERT characteristic is forwarded.
    function onNotify(ch as BluetoothLowEnergy.Characteristic, value as ByteArray) as Void {
        if (ch.getUuid().equals(_alertCharUuid)) {
            _onFrame.invoke(value);
        }
    }

    function onScanState(scanState, status) as Void {
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            _scanOn = false;
            if (state == MultiState.CONNECTED) { roamOk = false; }
            _log("scan refused (status " + status.toString() + ")");
        }
    }

    // =======================================================================
    // Internals
    // =======================================================================

    // Alert subscription: [0x01, 0x00] in the CCCD of ALERT. The outcome
    // arrives in onCccdWrite; until then _sendNext starts no chunk.
    private function _subscribe(now as Number) as Void {
        alertSub = MonSub.MISSING;
        var svc = (_dev != null) ? _dev.getService(serviceUuid) : null;
        var ch = (svc != null) ? svc.getCharacteristic(_alertCharUuid) : null;
        var cccd = (ch != null) ? ch.getDescriptor(BluetoothLowEnergy.cccdUuid()) : null;
        if (cccd == null) {
            _log("E" + curNode.format("%d") + " has no ALERT characteristic: no alerts");
            return;
        }
        try {
            cccd.requestWrite([0x01, 0x00]b);
            alertSub = MonSub.PENDING;
            _cccdAt = now;
        } catch (e) {
            alertSub = MonSub.FAILED;
            _log("CCCD write failed");
        }
    }

    // Starts the next packet if the link is free. Run at the end of every
    // packet, at every tick and at every sample: it is also the point where an
    // already decided handoff is carried out, never with a packet in flight.
    private function _sendNext() as Void {
        if (state != MultiState.CONNECTED || _writeBusy || _pktN > 0) { return; }
        if (alertSub == MonSub.PENDING) { return; }

        if (_handoffTo >= 0) {
            var t = _handoffTo;
            var now = System.getTimer();
            handoffs++;
            _dropLink(now, false, "handoff to E" + t.format("%d"));
            _connectTo(t, now);
            return;
        }

        if (ring.count == 0) { return; }

        var n = ring.count;
        if (n > ProtoV5.MAX_SAMPLES) { n = ProtoV5.MAX_SAMPLES; }
        var pkt = ProtoV5.buildPacket(curNode, sessionId, ring.headSeq, ring.count - n, connNo,
                                      _alerts.evAck(curNode), _alerts.evUser(curNode), ring.bytes(n));
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

    private function _failPacket() as Void {
        _queue = [];
        _pktN = 0;                          // the samples stay queued
        _fails++;
        if (_fails >= Cfg.MULTI_MAX_WRITE_FAILS) {
            linkLosses++;
            _dropLink(System.getTimer(), true, "packets rejected in a row");
        }
        // Otherwise retry at the next tick, not immediately: an edge that has
        // just rejected should not be hammered.
    }

    private function _setScan(on as Boolean) as Void {
        if (on == _scanOn) { return; }
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
            dev = BluetoothLowEnergy.pairDevice(res);
        } catch (e) {
            // Typically: paired device slots exhausted.
            _unpairAll();
        }
        if (dev == null) {
            _log("pairDevice to E" + node.format("%d") + " failed");
            radar.cool(node, now);
            _setScan(true);
            return;
        }
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
        var d = (_dev != null) ? _dev : _pairDev;
        if (d != null) { _unpair(d); }
        if (coolIt && curNode >= 0) { radar.cool(curNode, now); }

        _dev = null;
        _pairDev = null;
        curNode = -1;
        state = MultiState.SCAN;
        alertSub = MonSub.NONE;
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

    // One line in the app log: on the watch System.println writes only if the
    // file GARMIN/APPS/LOGS/<.prg name>.TXT exists.
    private function _log(msg as String) as Void {
        System.println("MONITOR " + (System.getTimer() / 1000).format("%d") + "s " + msg);
    }

    // Summary every Cfg.MULTI_LOG_EVERY_MS: state, alert subscription, chunks
    // and samples confirmed in the window, queue and samples dropped on
    // overflow, connections and edge changes (ho = intended / lost links, as
    // on the MULTI screen). Useful to compare the watch with the SD card.
    private function _logWindow(now as Number) as Void {
        var st = (state == MultiState.CONNECTED) ? "CONN"
               : ((state == MultiState.CONNECTING) ? "PAIR" : "SCAN");
        var sub = ["no", "pending", "on", "failed", "missing"][alertSub];
        _log(st + " E" + curNode.format("%d") + " alerts=" + sub
            + " chunks=" + _dChunks.format("%d") + " samples=" + _dSamples.format("%d")
            + " queue=" + ring.count.format("%d") + " dropped=" + ring.dropped.format("%d")
            + " seq=" + (ring.headSeq + ring.count).format("%d") + " conn=" + connNo.format("%d")
            + " ho=" + handoffs.format("%d") + "/" + linkLosses.format("%d"));
        _dAt = now;
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
