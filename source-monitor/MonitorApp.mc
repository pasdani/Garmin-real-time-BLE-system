import Toybox.Application;
import Toybox.Attention;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

//
// MonitorApp.mc — Entry point of V5 (MONITOR), a DEVICE APP.
//
// It is not DataFieldApp, the data field entry point, which this build
// excludes (:datafield). The app state, read by the screens, lives here:
//
//   - the SESSION is the open app: it starts when the app opens (session_id =
//     epoch of that instant) and ends when it closes. There is no START/STOP;
//   - the 1 s Timer, which in a device app takes the place of compute(): it
//     reads the 4 values (MonitorSampler), advances the radio and every 5 s
//     queues a sample for the edges (MonitorManager);
//   - the alerts from the edges: vibration and sound according to the alert
//     field or the mode chosen with UP/DOWN (alertMode), alert screen until
//     the user confirms.
//
class MonitorApp extends Application.AppBase {

    public var mgr as MonitorManager?;
    public var alerts as AlertQueue;

    // --- Session ---
    public var startedAt as Number = 0;          // System.getTimer() at the app opening
    public var elapsedMs as Number = 0;          // session duration
    public var alertsRx  as Number = 0;          // new alerts in the session
    public var alertMode as Number = MonCfg.MODE_EDGE;   // UP/DOWN, MonCfg.MODE_*

    // --- Latest readings (main screen) ---
    public var values as Array = [null, null, null, null];   // MonitorSampler.V_* indices

    private var _sensor = null;                  // last Sensor.Info received
    private var _timer = null;
    private var _tick as Number = 0;
    private var _alertShown as Boolean = false;

    function initialize() {
        AppBase.initialize();
        alerts = new AlertQueue();
    }

    function onStart(state) {
        var m = Application.Storage.getValue(MonCfg.MODE_KEY);
        if (m instanceof Number && m >= 0 && m < MonCfg.MODE_COUNT) { alertMode = m; }

        startedAt = System.getTimer();
        mgr = new MonitorManager(method(:onAlertFrame), alerts, Time.now().value());
        mgr.start();

        // The heart rate sensor turns on only if the app asks for it; events
        // arrive about once per second with the latest Sensor.Info.
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensor));

        _timer = new Timer.Timer();
        _timer.start(method(:onTick), MonCfg.TICK_MS, true);
    }

    function onStop(state) {
        if (_timer != null) { _timer.stop(); }
        Sensor.enableSensorEvents(null);
        Sensor.setEnabledSensors([]);
        if (mgr != null) { mgr.stop(); }
    }

    function getInitialView() {
        return [ new MonitorView(self), new MonitorDelegate(self) ];
    }

    // =======================================================================
    // Time and sensors
    // =======================================================================

    function onSensor(info as Sensor.Info) as Void {
        _sensor = info;
    }

    function onTick() as Void {
        _tick++;
        var now = System.getTimer();

        values = MonitorSampler.read(_sensor);
        elapsedMs = now - startedAt;
        if (_tick % MonCfg.SAMPLE_EVERY == 0) {
            _sample();
        }
        mgr.tick(now);
        WatchUi.requestUpdate();
    }

    // A sample from the values just read, the same ones shown on screen:
    // encoded and serialised here (ProtoV5), then queued for the edges.
    private function _sample() as Void {
        var v = values;
        mgr.addSample(ProtoV5.packSample(Time.now().value(),
            ProtoV5.encHr(v[MonitorSampler.V_HR]),
            ProtoV5.encBatt(v[MonitorSampler.V_BATT]),
            ProtoV5.encSteps(v[MonitorSampler.V_STEPS]),
            ProtoV5.encAlt(v[MonitorSampler.V_ALT])));
    }

    // =======================================================================
    // Alerts
    // =======================================================================

    // Notification received on the ALERT characteristic (from MonitorManager).
    function onAlertFrame(value as ByteArray) as Void {
        var a = alerts.onFrame(value);
        if (a != null) {
            alertsRx++;
            _attention(effectiveAlert(a[ProtoV5.P_ALERT]));
            if (!_alertShown) {
                _alertShown = true;
                WatchUi.pushView(new AlertView(self), new AlertDelegate(self), WatchUi.SLIDE_UP);
            }
        }
        WatchUi.requestUpdate();
    }

    // UP/DOWN: previous or next mode, saved at once.
    function stepAlertMode(step as Number) as Void {
        alertMode = (alertMode + step + MonCfg.MODE_COUNT) % MonCfg.MODE_COUNT;
        Application.Storage.setValue(MonCfg.MODE_KEY, alertMode);
        WatchUi.requestUpdate();
    }

    // Vibration and sound bits to play for an alert whose alert field is
    // `alert`: those of the edge, or those imposed by the mode.
    function effectiveAlert(alert as Number) as Number {
        switch (alertMode) {
            case MonCfg.MODE_SILENT: return 0;
            case MonCfg.MODE_SOUND:  return ProtoV5.AL_TONE;
            case MonCfg.MODE_VIBE:   return ProtoV5.AL_VIBE;
            default:                 return alert;
        }
    }

    // The user confirms the alert shown; move to the next one, if any.
    function confirmAlert() as Void {
        alerts.confirm();
        if (alerts.count() == 0 && _alertShown) {
            _alertShown = false;
            WatchUi.popView(WatchUi.SLIDE_DOWN);
        }
        WatchUi.requestUpdate();
    }

    // Sound and vibration according to the bits of `alert`; the screen always
    // turns on. The watch settings prevail: with tones or vibration disabled
    // the system does not play them (the alert screen says so).
    //
    // The sound is a hand-built ToneProfile: the FR255 ignores the predefined
    // tones (TONE_*) requested by a device app, while it plays a ToneProfile
    // (verified on the watch; the same is known for the Forerunner 165 on the
    // Connect IQ forum, "playTone() oddities on FR165 device").
    private function _attention(alert as Number) as Void {
        if ((alert & ProtoV5.AL_TONE) != 0
            && (Attention has :playTone) && (Attention has :ToneProfile)) {
            Attention.playTone({ :toneProfile => [
                new Attention.ToneProfile(2500, 250),
                new Attention.ToneProfile(4000, 250),
                new Attention.ToneProfile(2500, 250)
            ] });
        }
        if ((alert & ProtoV5.AL_VIBE) != 0 && (Attention has :vibrate)) {
            Attention.vibrate([
                new Attention.VibeProfile(100, 400),
                new Attention.VibeProfile(0, 200),
                new Attention.VibeProfile(100, 400)
            ]);
        }
        if (Attention has :backlight) {
            try {
                Attention.backlight(true);
            } catch (e) {
                // Screen protection: do without the backlight.
            }
        }
    }
}
