import Toybox.Lang;

//
// VariantConfig.mc (MONITOR) — variant constants, included ONLY by this build.
//
// V5: a DEVICE APP started by hand (not a data field) that sends heart rate,
// battery, steps and altitude to the ESP32 edges with the v4 radio, and
// receives alerts from them to show (message, vibration, sound).
// Specification: docs/v5_monitoring.md.
//
// The app starts from MonitorApp: monitor.jungle excludes the parts of
// source/ that only the data fields need (:datafield). Variant.NAME is shown
// on screen.
//
module Variant {
    const ID   = 6;        // 6 = Monitor
    const NAME = "MONITOR";
}
