import Toybox.ActivityMonitor;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.System;

//
// MonitorSampler.mc — Reads the 4 V5 values from the watch sensors.
//
// Returns PHYSICAL values, as the sensors give them (null = missing): the
// uint16 encoding is done by ProtoV5 (encHr, encBatt, encSteps, encAlt), so the
// screen shows the same numbers that end up in the packet. None comes from
// Activity.Info: V5 does not record an activity.
//
module MonitorSampler {

    // Indices of the Array returned by read().
    const V_HR    = 0;     // bpm (Sensor.Info.heartRate)
    const V_BATT  = 1;     // % (System.getSystemStats().battery)
    const V_STEPS = 2;     // steps since midnight (ActivityMonitor.Info.steps)
    const V_ALT   = 3;     // metres above sea level (Sensor.Info.altitude)

    // `info` is the last Sensor.Info received (Sensor.enableSensorEvents), or null.
    function read(info as Sensor.Info?) as Array {
        var hr = null;
        var alt = null;
        if (info != null) {
            hr = info.heartRate;
            alt = info.altitude;
        }
        var stats = System.getSystemStats();
        var am = ActivityMonitor.getInfo();
        return [hr,
                (stats != null) ? stats.battery : null,
                (am != null) ? am.steps : null,
                alt];
    }
}
