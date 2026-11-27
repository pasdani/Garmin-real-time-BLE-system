import Toybox.Application;
import Toybox.Lang;

//
// DataFieldApp.mc — Entry point of the DATA FIELDS (variants 1, 2, 3 and 5).
//
// All these builds use this same class: they differ only in the manifest (app
// UUID and name) and in the Variant.ID constant included from the variant
// folder. The Monitor (6) is a device app with its own entry point, MonitorApp.
//
// The MULTI variant (5) has its own radio manager and its own view: variants
// 1-3 do not even instantiate those classes.
//
// (:datafield): the parts of source/ needed only by the data fields. The
// Monitor build excludes them (excludeAnnotations): this class, V3DfView,
// MultiDfView, FitLogger, the v3 radio (BleManager, MyBleDelegate) and the v4
// radio (MultiManager, MultiBleDelegate), Sampler, Encoders, SampleRing and
// Colors. From source/ the Monitor uses only Chunker, ProtoV3, ProtoV4,
// EdgeRadar, MultiState and Cfg.
//
(:datafield)
class DataFieldApp extends Application.AppBase {

    public var ble as BleManager?;
    public var multi as MultiManager?;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        if (Variant.ID == 5) {
            multi = new MultiManager();
            multi.start();
        } else {
            ble = new BleManager();
            ble.start();
        }
    }

    function getInitialView() {
        if (Variant.ID == 5) {
            return [ new MultiDfView(multi) ];
        }
        return [ new V3DfView(ble) ];
    }

    function onStop(state) {
        if (ble != null) { ble.stop(); }
        if (multi != null) { multi.stop(); }
    }
}
