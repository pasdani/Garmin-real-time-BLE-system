import Toybox.BluetoothLowEnergy;
import Toybox.Lang;

//
// BleManager.mc — Radio side of the protocol v3 variants (Full, Delta, Batch).
//
// Scan by Service UUID, connection, and a CHUNK QUEUE with ONE ATT write in
// flight: sendPacket() queues the chunks of a logical packet and sends them
// one at a time, chunk N+1 only after the outcome of chunk N
// (onCharacteristicWrite).
//
// The profile registers the DATA characteristic only: the radio behaviour of
// the three variants is exactly that of the battery experiment.
//
(:datafield)
class BleManager {

    // State read by the views to draw the BLE status
    public var connected as Boolean = false;
    public var scanning  as Boolean = true;
    public var justConnected as Boolean = false;   // consumed by the view to reset the variant state

    public var devices as Array = [];
    public var connectedDevice = null;
    public var writeInProgress as Boolean = false;

    public var serviceUuid;                 // used by the delegate to recognise the peripheral
    public var lastChunkCount as Number = 0; // chunks of the last packet (on-screen diagnostics)
    public var totalChunks as Number = 0;    // total chunks written since start (on-screen diagnostics)

    private var _dataCharUuid;              // DATA characteristic (...DB5): all chunks
    private var _delegate;

    private var _chunkQueue as Array = [];  // chunks waiting to be sent (FIFO)
    private var _pktId as Number = 0;       // logical packet ID, incremented mod 256

    function initialize() {
        // SERVICE_UUID: A07498CA-AD5B-474E-940D-16F1F14E8972
        var svcHigh = (0xA07498CAl << 32) | 0xAD5B474El;
        var svcLow  = (0x940D16F1l << 32) | 0xF14E8972l;
        serviceUuid = BluetoothLowEnergy.longToUuid(svcHigh, svcLow);

        // DATA_CHAR_UUID: 51FF12BB-3ED8-46E5-B4F9-D64E25E01DB5
        var dataHigh = (0x51FF12BBl << 32) | 0x3ED846E5l;
        var dataLow  = (0xB4F9D64El << 32) | 0x25E01DB5l;
        _dataCharUuid = BluetoothLowEnergy.longToUuid(dataHigh, dataLow);
    }

    // Starts the BLE subsystem: delegate + profile + scan.
    function start() as Void {
        _delegate = new MyBleDelegate(self);
        BluetoothLowEnergy.setDelegate(_delegate);

        // registerProfile throws ProfileRegistrationException if the system has
        // already run out of profile slots. That happens when the app is
        // restarted several times in the same process without the previous
        // profiles being released (for example in the simulator).
        //
        // In that case the profile with THESE UUIDs is already registered and
        // still valid: carrying on is correct, while letting the exception
        // propagate would kill the data field (and with it the activity
        // recording) for a problem that does not prevent communication.
        try {
            BluetoothLowEnergy.registerProfile({
                :uuid => serviceUuid,
                :characteristics => [ { :uuid => _dataCharUuid, :descriptors => [] } ]
            });
        } catch (e instanceof BluetoothLowEnergy.ProfileRegistrationException) {
            // Profile already present: keep using it.
        }
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
    }

    function stop() as Void {
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
    }

    // Queues a logical packet (one of the three formats) and starts sending.
    // Assigns a new pktId (the same on all chunks of the packet).
    function sendPacket(flags as Number, bitmask as Number, payload as ByteArray) as Void {
        if (connectedDevice == null) { return; }

        var pktId = _pktId;
        _pktId = (_pktId + 1) & 0xFF;                       // mod 256

        var chunks = Chunker.split(pktId, flags, bitmask, payload);
        lastChunkCount = chunks.size();
        for (var i = 0; i < chunks.size(); i++) {
            _chunkQueue.add(chunks[i]);
        }
        _pump();
    }

    // Sends the next chunk if the bus is free. Also called by the delegate at
    // every outcome (onCharacteristicWrite) to advance the queue.
    function pump() as Void { _pump(); }

    private function _pump() as Void {
        if (writeInProgress) { return; }
        if (connectedDevice == null) { return; }
        if (_chunkQueue.size() == 0) { return; }

        var service = connectedDevice.getService(serviceUuid);
        if (service == null) { return; }
        var char = service.getCharacteristic(_dataCharUuid);
        if (char == null) { return; }

        var chunk = _chunkQueue[0];
        _chunkQueue.remove(chunk);        // removes the first element (FIFO)

        writeInProgress = true;
        char.requestWrite(chunk, {});     // default type, without response -> onCharacteristicWrite
        totalChunks++;                    // cumulative count for the diagnostics
    }

    // Called by the delegate when the device becomes CONNECTED.
    function onConnected(device) as Void {
        connectedDevice = device;
        connected = true;
        scanning  = false;
        justConnected = true;             // the view will reset the variant state
        _chunkQueue = [];                 // start clean
        writeInProgress = false;
    }

    // Called by the delegate on disconnection.
    function onDisconnected() as Void {
        connectedDevice = null;
        connected = false;
        scanning  = true;
        writeInProgress = false;
        _chunkQueue = [];                 // drop the pending chunks (interrupted packet)
    }
}
