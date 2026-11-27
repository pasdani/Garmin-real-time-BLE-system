import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//
// MonitorView.mc — Main screen of V5 (MONITOR).
//
// English texts, four zones from the top:
//   1. name and session: RUNNING with the time since the app opened (the
//      session is the open app);
//   2. the 4 values and nothing else: HR and BAT, then ALT and STEPS;
//   3. radio on one line (searching, connecting or connected edge, with the
//      edges seen) and below it the alerts received in the session. The colour
//      of this line tells the state of the alert subscription: green active,
//      orange in progress or characteristic missing on the edge, red failed,
//      grey no edge;
//   4. the alert mode on the watch, changed with UP/DOWN (as edge / silent /
//      sound / vibrate). BACK exits, always after confirmation.
//
// Every line goes through MonDraw.text, which keeps it inside the circle.
//
class MonitorView extends WatchUi.View {

    private var _app as MonitorApp;

    function initialize(app as MonitorApp) {
        View.initialize();
        _app = app;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var app = _app;
        var m = app.mgr;
        var T = Graphics.COLOR_TRANSPARENT;

        // --- 1. Name and session ---
        dc.setColor(MonCfg.COLOR, T);
        MonDraw.text(dc, 0.07, Graphics.FONT_XTINY, Variant.NAME);

        dc.setColor(Graphics.COLOR_GREEN, T);
        MonDraw.text(dc, 0.14, Graphics.FONT_SMALL, "RUNNING " + _time(app.elapsedMs));

        // --- 2. The 4 values ---
        var v = app.values;
        dc.setColor(Graphics.COLOR_WHITE, T);
        MonDraw.text(dc, 0.29, Graphics.FONT_TINY,
            "HR " + _int(v[MonitorSampler.V_HR]) + "   BAT " + _int(v[MonitorSampler.V_BATT]) + "%");
        MonDraw.text(dc, 0.39, Graphics.FONT_TINY,
            "ALT " + _int(v[MonitorSampler.V_ALT]) + " m   STEPS " + _int(v[MonitorSampler.V_STEPS]));

        // --- 3. Radio and alerts ---
        if (m != null) {
            var now = System.getTimer();
            var seen = ", " + m.radar.visible(now).format("%d") + " seen";
            var radio;
            var col;
            if (m.state == MultiState.CONNECTED) {
                radio = "E" + m.curNode.format("%d") + " connected" + seen;
                col = Graphics.COLOR_BLUE;
            } else if (m.state == MultiState.CONNECTING) {
                radio = "Connecting E" + m.curNode.format("%d") + seen;
                col = Graphics.COLOR_ORANGE;
            } else {
                radio = "Searching" + seen;
                col = Graphics.COLOR_LT_GRAY;
            }
            dc.setColor(col, T);
            MonDraw.text(dc, 0.54, Graphics.FONT_TINY, radio);

            col = Graphics.COLOR_LT_GRAY;
            if (m.alertSub == MonSub.ON) {
                col = Graphics.COLOR_GREEN;
            } else if (m.alertSub == MonSub.PENDING || m.alertSub == MonSub.MISSING) {
                col = Graphics.COLOR_ORANGE;
            } else if (m.alertSub == MonSub.FAILED) {
                col = Graphics.COLOR_RED;
            }
            dc.setColor(col, T);
            MonDraw.text(dc, 0.65, Graphics.FONT_TINY, "Alerts received: " + app.alertsRx.format("%d"));
        }

        // --- 4. Alert mode (UP/DOWN) ---
        dc.setColor(Graphics.COLOR_LT_GRAY, T);
        MonDraw.text(dc, 0.82, Graphics.FONT_XTINY, "Alerts: " + AlertText.watchModeName(app.alertMode));
    }

    // Integer, or "--" if the sensor has no value.
    private function _int(x) as String {
        return (x == null) ? "--" : x.toNumber().format("%d");
    }

    // ms -> "m:ss" or "h:mm:ss".
    private function _time(ms as Number) as String {
        var s = ms / 1000;
        var hh = s / 3600;
        var mm = (s / 60) % 60;
        var ss = s % 60;
        if (hh > 0) {
            return hh.format("%d") + ":" + mm.format("%02d") + ":" + ss.format("%02d");
        }
        return mm.format("%d") + ":" + ss.format("%02d");
    }
}
