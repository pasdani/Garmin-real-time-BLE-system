import Toybox.BluetoothLowEnergy;
import Toybox.WatchUi;
import Toybox.Lang;

//
// MyBleDelegate.mc — BLE callbacks (scan / connect / write outcome) of the
// protocol v3 variants (Full, Delta, Batch).
//
// Recognises the peripheral by its SERVICE UUID. After every write outcome
// (onCharacteristicWrite) it advances the CHUNK QUEUE of the BleManager
// (pump), so chunk N+1 starts only when chunk N has been written.
//
(:datafield)
class MyBleDelegate extends BluetoothLowEnergy.BleDelegate {

    private var _mgr;

    function initialize(mgr) {
        BleDelegate.initialize();
        _mgr = mgr;
    }

    function onScanResults(scanResults as BluetoothLowEnergy.Iterator) as Void {
        var result = scanResults.next();
        while (result != null) {
            if (result instanceof BluetoothLowEnergy.ScanResult) {
                if (_advertisesService(result)) {
                    var name = result.getDeviceName();
                    if (name == null) { name = "Peripheral"; }

                    if (_mgr.devices.indexOf(name) == -1) {
                        _mgr.devices.add(name);
                        WatchUi.requestUpdate();
                    }

                    BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
                    BluetoothLowEnergy.pairDevice(result);
                }
            }
            result = scanResults.next();
        }
    }

    function onConnectedStateChanged(device as BluetoothLowEnergy.Device, state as BluetoothLowEnergy.ConnectionState) as Void {
        if (state == BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
            _mgr.onConnected(device);
            WatchUi.requestUpdate();
        } else {
            _mgr.onDisconnected();
            BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
            WatchUi.requestUpdate();
        }
    }

    // Write outcome (whatever it is): frees the bus and sends the next chunk.
    function onCharacteristicWrite(char as BluetoothLowEnergy.Characteristic, status as BluetoothLowEnergy.Status) as Void {
        _mgr.writeInProgress = false;
        _mgr.pump();
    }

    private function _advertisesService(result as BluetoothLowEnergy.ScanResult) as Boolean {
        var uuids = result.getServiceUuids();
        var uuid = uuids.next();
        while (uuid != null) {
            if (uuid.equals(_mgr.serviceUuid)) { return true; }
            uuid = uuids.next();
        }
        return false;
    }
}
