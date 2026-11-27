import Toybox.BluetoothLowEnergy;
import Toybox.WatchUi;
import Toybox.Lang;

//
// MonitorBleDelegate.mc — BLE callbacks of V5 (MONITOR).
//
// Like MultiBleDelegate (source/), with two more callbacks: the outcome of the
// write to the ALERT CCCD and the arrival of notifications. It decides
// nothing: it routes to MonitorManager.
//
// onCharacteristicWrite and onDescriptorWrite are two separate callbacks: the
// first is the outcome of a data chunk (the ACK for the last one), the second
// that of the alert subscription.
//
class MonitorBleDelegate extends BluetoothLowEnergy.BleDelegate {

    private var _mgr as MonitorManager;

    function initialize(mgr as MonitorManager) {
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

    // Outcome of the write of a chunk on the DATA characteristic.
    function onCharacteristicWrite(char as BluetoothLowEnergy.Characteristic,
                                   status as BluetoothLowEnergy.Status) as Void {
        _mgr.onWrite(status == BluetoothLowEnergy.STATUS_SUCCESS);
    }

    // Outcome of the [0x01, 0x00] write to the ALERT CCCD (alert subscription).
    function onDescriptorWrite(desc as BluetoothLowEnergy.Descriptor,
                               status as BluetoothLowEnergy.Status) as Void {
        _mgr.onCccdWrite(status == BluetoothLowEnergy.STATUS_SUCCESS);
    }

    // Notification from the edge: an alert, if it arrives on the ALERT characteristic.
    function onCharacteristicChanged(char as BluetoothLowEnergy.Characteristic,
                                     value as ByteArray) as Void {
        if (char == null || value == null) { return; }
        _mgr.onNotify(char, value);
    }

    function onScanStateChange(scanState as BluetoothLowEnergy.ScanState,
                               status as BluetoothLowEnergy.Status) as Void {
        _mgr.onScanState(scanState, status);
    }
}
