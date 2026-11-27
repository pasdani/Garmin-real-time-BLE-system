import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.System;
import Toybox.Lang;

//
// V3DfView.mc — Data field of the protocol v3 variants. The radio strategy is
// chosen by Variant.ID (1=Full, 2=Delta, 3=Batch).
//
// The system calls compute(info) at ~1 Hz: ticks are counted and every
// Cfg.SAMPLE_EVERY (=5) a sample is taken and sent according to the strategy.
// The sampled data are IDENTICAL in the three variants, only HOW they travel
// changes.
//
(:datafield)
class V3DfView extends WatchUi.DataField {

    private var _ble as BleManager;
    private var _fit as FitLogger;

    private var _tick as Number = 0;

    // DELTA state: last SENT value per field (initially: sentinel).
    private var _lastSent as Array;
    private var _firstDelta as Boolean = true;

    // BATCH state: accumulated samples (each = Array<12>).
    private var _batch as Array = [];

    // Last sample (for drawing).
    private var _lastValues as Array;

    // Timer state at the previous call (to detect the activity START).
    private var _prevTimer as Number = Activity.TIMER_STATE_OFF;

    function initialize(ble) {
        DataField.initialize();
        _ble = ble;
        _fit = new FitLogger(self, Variant.ID);
        _lastSent = freshSentinels();
        _lastValues = freshSentinels();
    }

    function freshSentinels() as Array {
        var a = new [ProtoV3.NFIELDS];
        for (var i = 0; i < ProtoV3.NFIELDS; i++) { a[i] = ProtoV3.SENTINEL; }
        return a;
    }

    // Called by the system ~1/s during the activity.
    function compute(info as Activity.Info) as Void {
        _tick++;

        // dev_battery written to the FIT file at EVERY compute.
        var stats = System.getSystemStats();
        if (stats != null && stats.battery != null) {
            _fit.recordBattery(stats.battery);
        }

        // On (re)connection: reset the variant state.
        if (_ble.justConnected) {
            _ble.justConnected = false;
            _firstDelta = true;
            // BATCH: on reconnection, send the accumulated partial block at once.
            if (Variant.ID == 3 && _batch.size() > 0) {
                flushBatch();
            }
        }

        // Data are sent ONLY with the timer running (start pressed, not paused or
        // stopped): before the start, while paused and after the stop nothing is
        // sampled or sent, so the peripheral receives (and logs) no data outside
        // the activity.
        var ts = (info != null && (info has :timerState))
            ? info.timerState : Activity.TIMER_STATE_OFF;

        // "Fresh" START (from OFF/STOPPED, not resuming from pause): reset the
        // chunk total, so at the end of the activity `total` = radio cost of the
        // recording.
        if (ts == Activity.TIMER_STATE_ON && _prevTimer != Activity.TIMER_STATE_ON
            && _prevTimer != Activity.TIMER_STATE_PAUSED) {
            _ble.totalChunks = 0;
        }
        _prevTimer = ts;

        if (ts != Activity.TIMER_STATE_ON) { return; }

        // Sample every SAMPLE_EVERY ticks (~5 s).
        if (_tick % Cfg.SAMPLE_EVERY != 0) { return; }

        var values = Sampler.sample(info);
        _lastValues = values;

        switch (Variant.ID) {
            case 1: sendFull(values);  break;
            case 2: sendDelta(values); break;
            case 3: accumulateBatch(values); break;
        }
    }

    // --- Variant 1: FULL ---
    function sendFull(values as Array) as Void {
        if (!_ble.connected) { return; }
        var payload = Encoders.buildFull(values);
        _ble.sendPacket(ProtoV3.FMT_FULL, 0, payload);
    }

    // --- Variant 2: DELTA ---
    function sendDelta(values as Array) as Void {
        if (!_ble.connected) { return; }
        var mask = Encoders.computeDeltaMask(values, _lastSent, _firstDelta);
        var payload = Encoders.buildDeltaPayload(values, mask);
        _ble.sendPacket(ProtoV3.FMT_DELTA, mask, payload);
        Encoders.updateLastSent(_lastSent, values, mask);
        _firstDelta = false;
    }

    // --- Variant 3: BATCH ---
    function accumulateBatch(values as Array) as Void {
        _batch.add(values);
        // Never accumulate more than 6 samples (during long disconnections the
        // last 6 are kept: cnt at most 18 chunks).
        while (_batch.size() > Cfg.BATCH_SAMPLES) {
            _batch.remove(_batch[0]);
        }
        if (_ble.connected && _batch.size() >= Cfg.BATCH_SAMPLES) {
            flushBatch();
        }
    }

    // Sends the current BATCH block (even partial) and starts over.
    function flushBatch() as Void {
        if (_batch.size() == 0 || !_ble.connected) { return; }
        var payload = Encoders.buildBatch(_batch);
        _ble.sendPacket(ProtoV3.FMT_BATCH, 0, payload);
        _batch = [];
    }

    // --- Drawing: variant name, HR, chunks (last packet + total), BLE status ---
    // ADAPTIVE layout in fractions of the field height, two modes:
    //   full    = full-screen field (1 field)
    //   compact = half-screen field (top) or smaller
    // The chunk total sits RIGHT BELOW the count of the last packet.
    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        // Full screen if the field takes at least ~70% of the display height.
        var full = h >= (System.getDeviceSettings().screenHeight * 0.7);

        var hr = _lastValues[ProtoV3.F_HR];
        var hrStr    = Encoders.isSentinel(hr) ? "--" : hr.format("%d");
        var chunkStr = "chunk: " + _ble.lastChunkCount.format("%d");
        var totStr   = "total: " + _ble.totalChunks.format("%d");

        // Variant name at the top, coloured.
        dc.setColor(variantColor(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * (full ? 0.06 : 0.02), Graphics.FONT_XTINY,
            Variant.NAME, Graphics.TEXT_JUSTIFY_CENTER);

        // HR in the middle (BPM label only at full screen; smaller font at half screen).
        if (full) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.20, Graphics.FONT_XTINY, "BPM", Graphics.TEXT_JUSTIFY_CENTER);
        }
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * (full ? 0.30 : 0.14),
            full ? Graphics.FONT_NUMBER_MEDIUM : Graphics.FONT_NUMBER_MILD,
            hrStr, Graphics.TEXT_JUSTIFY_CENTER);

        // Chunks of the last packet and, right below, the cumulative total.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * (full ? 0.56 : 0.48), Graphics.FONT_XTINY,
            chunkStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * (full ? 0.66 : 0.63), Graphics.FONT_XTINY,
            totStr, Graphics.TEXT_JUSTIFY_CENTER);

        // BLE status at the bottom.
        if (_ble.connected) {
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.82, Graphics.FONT_XTINY, "● connected", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.82, Graphics.FONT_XTINY, "○ searching…", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    function variantColor() as Number {
        switch (Variant.ID) {
            case 1:  return Colors.FULL_C;
            case 2:  return Colors.DELTA_C;
            default: return Colors.BATCH_C;
        }
    }
}
