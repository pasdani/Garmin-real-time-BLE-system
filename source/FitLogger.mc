import Toybox.Lang;
import Toybox.FitContributor;

//
// FitLogger.mc — Developer fields in the FIT file (the same in the four data fields).
//
//   dev_battery (field ID 0, FLOAT, MESG_TYPE_RECORD, "%")  written at every compute()
//   dev_variant (field ID 1, UINT8, MESG_TYPE_SESSION)      written once (1, 2, 3 or 5)
//
// Field IDs and names are IDENTICAL in Full, Delta, Batch and Multi: only the
// value of dev_variant (Variant.ID) changes, so the analysis can tell the
// recordings apart.
//
// (:datafield): the Monitor build excludes this class, so it does not need
// the FitContributor permission (variants/monitor/monitor.jungle).
//
(:datafield)
class FitLogger {

    private var _batteryField;
    private var _variantField;

    // df = the DataField (which provides createField). variantId = Variant.ID.
    function initialize(df, variantId as Number) {
        _batteryField = df.createField(
            "battery", 0, FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" });

        _variantField = df.createField(
            "variant", 1, FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_SESSION });

        _variantField.setData(variantId);   // written once per session
    }

    // Watch battery (percent) — called at every compute().
    function recordBattery(pct as Float) as Void {
        if (_batteryField != null) {
            _batteryField.setData(pct);
        }
    }
}
