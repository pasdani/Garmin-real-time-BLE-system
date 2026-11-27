import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.System;
import Toybox.Time;
import Toybox.Lang;

//
// MultiDfView.mc — Data field of the MULTI variant (Variant.ID = 5).
//
// Samples the SAME 12 values as v3 at the same cadence (5 s), only with the
// timer running, and hands them to MultiManager, which delivers them to the
// best edge. The radio is handled at EVERY compute(), even with the timer
// stopped: the connection is prepared before the start and survives pauses.
//
// The screen shows what is needed to check in the field that nothing is lost:
// current edge and its RSSI, queued samples, delivered samples, handoffs.
//
(:datafield)
class MultiDfView extends WatchUi.DataField {

    private var _mgr as MultiManager;
    private var _fit as FitLogger;

    private var _tick as Number = 0;
    private var _prevTimer as Number = Activity.TIMER_STATE_OFF;
    private var _computeMaxMs as Number = 0;   // worst case of compute() (watchdog)

    function initialize(mgr as MultiManager) {
        DataField.initialize();
        _mgr = mgr;
        _fit = new FitLogger(self, Variant.ID);
    }

    function compute(info as Activity.Info) as Void {
        var t0 = System.getTimer();
        computeInner(info);
        var dt = (System.getTimer() - t0) & 0x7FFFFFFF;
        if (dt > _computeMaxMs) { _computeMaxMs = dt; }
    }

    function computeInner(info as Activity.Info) as Void {
        _tick++;

        var stats = System.getSystemStats();
        if (stats != null && stats.battery != null) {
            _fit.recordBattery(stats.battery);
        }

        var ts = (info != null && (info has :timerState))
            ? info.timerState : Activity.TIMER_STATE_OFF;

        // "Fresh" START (from OFF/STOPPED, not resuming from pause): new session.
        // session_id = epoch of the start, the same on all edges: it is the key
        // used to merge their files.
        if (ts == Activity.TIMER_STATE_ON && _prevTimer != Activity.TIMER_STATE_ON
            && _prevTimer != Activity.TIMER_STATE_PAUSED) {
            _mgr.onSessionStart(Time.now().value());
        }
        _prevTimer = ts;

        if (ts == Activity.TIMER_STATE_ON && _tick % Cfg.MULTI_SAMPLE_EVERY == 0) {
            _mgr.addSample(Sampler.sample(info));
        }

        _mgr.tick(System.getTimer());
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var h = dc.getHeight();
        var cx = dc.getWidth() / 2;
        var full = h >= (System.getDeviceSettings().screenHeight * 0.7);
        var now = System.getTimer();
        var m = _mgr;

        // Full screen: text in "tiny" (Roboto 18 px on the FR255) and status on
        // two lines. At half screen there is not enough room: compact font
        // ("xtiny", 13 px) and status on a single line.
        var fText = full ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var fNum  = full ? Graphics.FONT_NUMBER_HOT : Graphics.FONT_NUMBER_MILD;
        var fPre  = full ? Graphics.FONT_LARGE : Graphics.FONT_SMALL;

        // Vertical positions, as fractions of the field height.
        var yTitle = full ? 0.05 : 0.02;
        var yLabel = 0.14;                       // full screen only
        var yBig   = full ? 0.19 : 0.14;
        var yInfo1 = full ? 0.50 : 0.48;
        var yInfo2 = full ? 0.59 : 0.63;
        // The status is 15 px below the "ok" line, as the "dBm" line is from
        // the big number: the central block stays evenly spaced (260 px
        // display).
        var yStat1 = full ? 0.72 : 0.82;
        var yStat2 = 0.81;                       // full screen only

        dc.setColor(Colors.MULTI_C, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * yTitle, fText, Variant.NAME, Graphics.TEXT_JUSTIFY_CENTER);

        if (full) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * yLabel, fText, "edge", Graphics.TEXT_JUSTIFY_CENTER);
        }

        // Current edge, big: it is the thing to look at while moving.
        var connected = (m.state == MultiState.CONNECTED);
        dc.setColor(connected ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY,
            Graphics.COLOR_TRANSPARENT);
        if (m.curNode > 0) {
            // The FONT_NUMBER_* fonts contain only digits and a few signs: an "E"
            // written with them comes out as an empty box. So the letter uses a
            // text font and the number the big one, on the SAME baseline: the
            // top of each is the common baseline minus the ascent of its own
            // font (the two fonts have different internal margins, so centring
            // them would leave them misaligned).
            var pre = "E";
            var num = m.curNode.format("%d");
            var wPre = dc.getTextWidthInPixels(pre, fPre);
            var x0 = cx - (wPre + 2 + dc.getTextWidthInPixels(num, fNum)) / 2;
            var yNum = h * yBig;
            var base = yNum + Graphics.getFontAscent(fNum);
            dc.drawText(x0, base - Graphics.getFontAscent(fPre), fPre, pre, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(x0 + wPre + 2, yNum, fNum, num, Graphics.TEXT_JUSTIFY_LEFT);
        } else {
            dc.drawText(cx, h * yBig, fNum, "--", Graphics.TEXT_JUSTIFY_CENTER);
        }

        // Filtered RSSI of the current edge, samples still queued and
        // successful connections in the session (connections to any edge,
        // including the current one). "--" while connected means that the
        // current edge is not seen by the roaming scan: without that
        // measurement the signal-based handoff cannot fire.
        var r = (m.curNode > 0) ? m.radar.rssi(m.curNode, now) : null;
        var rStr = (r == null) ? "--" : r.toNumber().format("%d");
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * yInfo1, fText,
            rStr + "dBm  queue " + m.ring.count.format("%d")
                + "  conn " + m.connNo.format("%d"),
            Graphics.TEXT_JUSTIFY_CENTER);

        // Delivered, intended handoffs / lost links, compute() peak.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * yInfo2, fText,
            "ok " + m.delivered.format("%d")
                + "  ho " + m.handoffs.format("%d") + "/" + m.linkLosses.format("%d")
                + "  " + _computeMaxMs.format("%d") + "ms",
            Graphics.TEXT_JUSTIFY_CENTER);

        // Radio status: first line the state (with the dot), second line the
        // detail. "seen" = registered edges received in the last
        // Cfg.MULTI_CAND_TTL_MS, including the current one (which also
        // advertises while connected, with the busy bit). While connected it is
        // shown only if the roaming scan works: with "roam off" (and while
        // pairing, with the scan off) the count would drop to zero although
        // nothing has changed.
        var st;
        var detail = "";
        var col;
        var filled = false;
        var seen = m.radar.visible(now).format("%d") + " seen";
        if (connected) {
            st = "Connected";
            detail = m.roamOk ? seen : "roam off";
            col = m.roamOk ? Graphics.COLOR_BLUE : Graphics.COLOR_ORANGE;
            filled = true;
        } else if (m.state == MultiState.CONNECTING) {
            st = "Connecting…";                  // the edge is already shown big
            col = Graphics.COLOR_ORANGE;
        } else {
            st = "Searching…";
            detail = seen;
            col = Graphics.COLOR_DK_GRAY;
        }

        if (full) {
            drawStatus(dc, cx, h * yStat1, fText, st, col, filled);
            if (detail.length() > 0) {
                dc.setColor(col, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, h * yStat2, fText, detail, Graphics.TEXT_JUSTIFY_CENTER);
            }
        } else {
            drawStatus(dc, cx, h * yStat1, fText,
                (detail.length() > 0) ? (st + ", " + detail) : st, col, filled);
        }
    }

    // Dot + text, centred together. The dot is DRAWN, not a character: the
    // FR255 fonts do not have the ● ○ ◌ symbols (in the simulator they come out
    // as "?"). Filled = connected, empty = searching or connecting.
    function drawStatus(dc as Graphics.Dc, cx as Number, y, f, text as String,
                        col as Number, filled as Boolean) as Void {
        var fh = dc.getFontHeight(f);
        var r = fh / 6;
        if (r < 3) { r = 3; }
        var gap = r + 2;
        var x0 = cx - (2 * r + gap + dc.getTextWidthInPixels(text, f)) / 2;
        var yc = y + fh / 2;

        dc.setColor(col, Graphics.COLOR_TRANSPARENT);
        if (filled) {
            dc.fillCircle(x0 + r, yc, r);
        } else {
            dc.setPenWidth(2);
            dc.drawCircle(x0 + r, yc, r);
            dc.setPenWidth(1);
        }
        dc.drawText(x0 + 2 * r + gap, y, f, text, Graphics.TEXT_JUSTIFY_LEFT);
    }
}
