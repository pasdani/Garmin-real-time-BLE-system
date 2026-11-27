import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//
// AlertView.mc — V5 alert screen and its delegate.
//
// Shows the oldest alert to confirm (AlertQueue.head). START or BACK confirm
// it: the next one is shown, or the app goes back to the main screen. The mode
// shown is the one played by the watch, i.e. the edge request filtered by the
// mode chosen with UP/DOWN (MonitorApp.effectiveAlert). If vibration or sound
// are disabled in the watch settings, the screen says so: otherwise a "mute"
// alert would look like a fault.
//

// Texts (in English, like the whole screen) and colours of the alerts.
module AlertText {

    function typeName(t as Number) as String {
        switch (t) {
            case ProtoV5.EV_TEST:   return "Test alert";
            case ProtoV5.EV_INFO:   return "Info";
            case ProtoV5.EV_WARN:   return "Warning";
            case ProtoV5.EV_DANGER: return "Danger";
            default:                return "Alert";
        }
    }

    function typeColor(t as Number) as Number {
        switch (t) {
            case ProtoV5.EV_INFO:   return Graphics.COLOR_BLUE;
            case ProtoV5.EV_WARN:   return Graphics.COLOR_ORANGE;
            case ProtoV5.EV_DANGER: return Graphics.COLOR_RED;
            default:                return Graphics.COLOR_WHITE;
        }
    }

    // Mode chosen on the watch (MonCfg.MODE_*), for the main screen.
    function watchModeName(mode as Number) as String {
        switch (mode) {
            case MonCfg.MODE_SILENT: return "silent";
            case MonCfg.MODE_SOUND:  return "sound";
            case MonCfg.MODE_VIBE:   return "vibrate";
            default:                 return "as edge";
        }
    }

    function modeName(alert as Number) as String {
        var vibe = (alert & ProtoV5.AL_VIBE) != 0;
        var tone = (alert & ProtoV5.AL_TONE) != 0;
        if (vibe && tone) { return "vibrate+tone"; }
        if (vibe) { return "vibrate"; }
        if (tone) { return "tone"; }
        return "message";
    }
}

class AlertView extends WatchUi.View {

    private var _app as MonitorApp;

    function initialize(app as MonitorApp) {
        View.initialize();
        _app = app;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var a = _app.alerts.head();
        if (a == null) { return; }

        var T = Graphics.COLOR_TRANSPARENT;
        var t = a[ProtoV5.P_TYPE];
        var al = _app.effectiveAlert(a[ProtoV5.P_ALERT]);   // what the watch played

        dc.setColor(AlertText.typeColor(t), T);
        MonDraw.text(dc, 0.14, Graphics.FONT_SMALL, AlertText.typeName(t));

        // Text from the edge; if missing, the type is already the message.
        var text = a[ProtoV5.P_TEXT];
        dc.setColor(Graphics.COLOR_WHITE, T);
        MonDraw.text(dc, 0.32, Graphics.FONT_MEDIUM, (text.length() > 0) ? text : AlertText.typeName(t));

        var val = a[ProtoV5.P_VALUE];
        if (val != ProtoV5.VALUE_NONE) {
            dc.setColor(Graphics.COLOR_LT_GRAY, T);
            MonDraw.text(dc, 0.48, Graphics.FONT_SMALL, "value " + val.format("%d"));
        }

        dc.setColor(Graphics.COLOR_LT_GRAY, T);
        MonDraw.text(dc, 0.60, Graphics.FONT_XTINY,
            "from E" + a[ProtoV5.P_NODE].format("%d") + ", alert #" + a[ProtoV5.P_SEQ].format("%d")
                + ", " + AlertText.modeName(al));

        // Watch settings that silenced the alert.
        var ds = System.getDeviceSettings();
        var muted = "";
        if ((al & ProtoV5.AL_VIBE) != 0 && !ds.vibrateOn) { muted = "vibration off"; }
        if ((al & ProtoV5.AL_TONE) != 0 && !ds.tonesOn) {
            muted = (muted.length() > 0) ? "vibration and tones off" : "tones off";
        }
        if (muted.length() > 0) {
            dc.setColor(Graphics.COLOR_ORANGE, T);
            MonDraw.text(dc, 0.68, Graphics.FONT_XTINY, muted + " (settings)");
        }

        var more = _app.alerts.count() - 1;
        if (more > 0) {
            dc.setColor(Graphics.COLOR_WHITE, T);
            MonDraw.text(dc, 0.76, Graphics.FONT_XTINY, more.format("%d") + " more to confirm");
        }

        dc.setColor(Graphics.COLOR_DK_GRAY, T);
        MonDraw.text(dc, 0.85, Graphics.FONT_XTINY, "START: OK");
    }
}

class AlertDelegate extends WatchUi.BehaviorDelegate {

    private var _app as MonitorApp;

    function initialize(app as MonitorApp) {
        BehaviorDelegate.initialize();
        _app = app;
    }

    function onSelect() as Boolean {
        _app.confirmAlert();
        return true;
    }

    // BACK confirms too: the alert cannot be dismissed without having been seen.
    function onBack() as Boolean {
        _app.confirmAlert();
        return true;
    }
}
