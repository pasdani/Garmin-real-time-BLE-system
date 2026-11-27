import Toybox.BluetoothLowEnergy;
import Toybox.WatchUi;
import Toybox.Lang;

//
// MultiBleDelegate.mc — BLE callbacks of the MULTI variant.
//
// Separate from MyBleDelegate on purpose: the radio behaviour of variants 1-3
// does not depend on MULTI. Nothing is decided here, events are routed to
// MultiManager.
//
(:datafield)
class MultiBleDelegate extends BluetoothLowEnergy.BleDelegate {

    private var _mgr as MultiManager;

    function initialize(mgr as MultiManager) {
        BleDelegate.initialize();
        _mgr = mgr;
    }

    function onScanResults(scanResults as BluetoothLowEnergy.Iterator) as Void {
        var r = scanResults.next();
        while (r != null) {
            if (r instanceof BluetoothLowEnergy.ScanResult) {
                _mgr.onScanResult(r);
            }
            r = scanResults.next();
        }
    }

    function onConnectedStateChanged(device as BluetoothLowEnergy.Device,
                                     state as BluetoothLowEnergy.ConnectionState) as Void {
        if (state == BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
            _mgr.onConnected(device);
        } else {
            _mgr.onDisconnected(device);
        }
        WatchUi.requestUpdate();
    }

    // Outcome of a WITH RESPONSE write: for the last chunk it is the packet ACK.
    function onCharacteristicWrite(char as BluetoothLowEnergy.Characteristic,
                                   status as BluetoothLowEnergy.Status) as Void {
        _mgr.onWrite(status == BluetoothLowEnergy.STATUS_SUCCESS);
    }

    function onScanStateChange(scanState as BluetoothLowEnergy.ScanState,
                               status as BluetoothLowEnergy.Status) as Void {
        _mgr.onScanState(scanState, status);
    }
}
