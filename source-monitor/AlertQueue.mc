import Toybox.Lang;

//
// AlertQueue.mc — Alerts received from the edges, waiting for the user's
// confirmation (docs/v5_monitoring.md § Alerts).
//
// A notification enters only if it passes ProtoV5.parseAlert (length, magic,
// version, CRC-8). A duplicate (same ev_seq as the last one received from that
// node: the edge resends if the confirmation was lost) does not become a
// second alert. Alerts wait in order of arrival and are confirmed from the
// oldest, so the last confirmed one per node is cumulative (ev_user).
//
class AlertQueue {

    private var _pending  as Array = [];        // alerts to confirm, the oldest first
    private var _lastRx   as Dictionary = {};   // node -> last ev_seq received
    private var _lastUser as Dictionary = {};   // node -> last ev_seq confirmed

    function initialize() {
    }

    // A received notification. Returns the decoded alert (ProtoV5.P_* indices)
    // if it is new, otherwise null.
    function onFrame(v) as Array? {
        var a = ProtoV5.parseAlert(v);
        if (a == null) { return null; }            // invalid notification
        var node = a[ProtoV5.P_NODE];
        var seq = a[ProtoV5.P_SEQ];
        if (_lastRx.hasKey(node) && _lastRx[node] == seq) { return null; }   // duplicate
        _lastRx[node] = seq;
        if (_pending.size() >= MonCfg.ALERT_MAX) {
            _pending = _pending.slice(1, null);     // the oldest leaves without confirmation
        }
        _pending.add(a);
        return a;
    }

    function count() as Number {
        return _pending.size();
    }

    // ev_ack and ev_user of the packets to `node`: the last alert received and
    // the last one confirmed by the user for that edge, 0 = none.
    function evAck(node as Number) as Number {
        return _lastRx.hasKey(node) ? _lastRx[node] : 0;
    }

    function evUser(node as Number) as Number {
        return _lastUser.hasKey(node) ? _lastUser[node] : 0;
    }

    // The alert to show: the oldest one to confirm, or null.
    function head() as Array? {
        return (_pending.size() > 0) ? _pending[0] : null;
    }

    // The user confirmed the alert at the head. Returns the confirmed alert.
    function confirm() as Array? {
        var a = head();
        if (a == null) { return null; }
        _pending = _pending.slice(1, null);
        _lastUser[a[ProtoV5.P_NODE]] = a[ProtoV5.P_SEQ];
        return a;
    }
}
