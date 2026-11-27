import Toybox.Lang;

//
// EdgeRadar.mc — What the watch sees of the registered edges, and the edge
// selection and handoff POLICY of the MULTI variant.
//
// PURE logic: no BLE calls, time comes in as a parameter, so selection,
// hysteresis and minimum dwell time can be tested with synthetic times,
// without a radio. MultiManager just carries out what the radar decides.
//
// ===========================================================================
// MEASUREMENT
// ===========================================================================
// For every registered edge: advertising RSSI filtered with an exponential
// moving average (alpha = Cfg.MULTI_RSSI_ALPHA), time of the last sighting,
// busy bit, last ScanResult (needed by pairDevice). The raw RSSI of an
// advertisement swings by +/-5-10 dB even when standing still (body,
// orientation, multipath): without a filter the handoff would chase the
// noise. An edge not seen for Cfg.MULTI_CAND_TTL_MS is no longer a candidate,
// and its average restarts from scratch at the next sighting.
//
// ===========================================================================
// POLICY
// ===========================================================================
// Connection (while disconnected): among the fresh edges that are NOT busy and
// not cooling down, the one with the highest average. MultiManager waits a
// short window after the first sighting, so as not to simply take the first
// one that answers.
//
// Handoff (while connected), all of these together:
//   1. minimum dwell: connected for at least Cfg.MULTI_MIN_DWELL_MS;
//   2. the current edge has been seen AFTER the connection (busy advertising):
//      without it there is no term of comparison, and the RSSI of the
//      candidates alone says nothing. If the current edge does not advertise
//      while connected, or its advertising does not reach the watch, the
//      signal-based handoff never fires: only those caused by a lost link
//      remain;
//   3. a candidate beats the current edge by at least Cfg.MULTI_HYST_DB;
//   4. condition 3 holds for Cfg.MULTI_HANDOFF_VOTES consecutive evaluations
//      (one per second).
// If the current edge has not been seen for Cfg.MULTI_CUR_STALE_MS, its RSSI
// counts as Cfg.MULTI_RSSI_FLOOR: the watch is probably moving away and the
// link is about to drop, so it is better to act early.
//
class EdgeRadar {

    private var _nodes as Array<Number>;
    private var _ema   as Array;     // Float, or null if never seen
    private var _last  as Array<Number>;
    private var _seen  as Array<Boolean>;
    private var _busy  as Array<Boolean>;
    private var _res   as Array;     // last ScanResult (or null)
    private var _coolUntil as Array<Number>;
    private var _cooling as Array<Boolean>;

    private var _votes as Number = 0;

    function initialize(nodes as Array<Number>) {
        _nodes = nodes;
        var n = nodes.size();
        _ema  = new [n];
        _last = new [n];
        _seen = new [n];
        _busy = new [n];
        _res  = new [n];
        _coolUntil = new [n];
        _cooling = new [n];
        for (var i = 0; i < n; i++) {
            _last[i] = 0;
            _seen[i] = false;
            _busy[i] = false;
            _coolUntil[i] = 0;
            _cooling[i] = false;
        }
    }

    function slotOf(node as Number) as Number {
        for (var i = 0; i < _nodes.size(); i++) {
            if (_nodes[i] == node) { return i; }
        }
        return -1;
    }

    // Records an advertisement. Returns false if the node is not registered
    // (an ESP32 with the same firmware but an ID outside the list is ignored).
    function onAdv(node as Number, rssi as Number, busy as Boolean, result, now as Number) as Boolean {
        var s = slotOf(node);
        if (s < 0) { return false; }
        if (!_seen[s] || (now - _last[s]) > Cfg.MULTI_CAND_TTL_MS) {
            _ema[s] = rssi.toFloat();
        } else {
            _ema[s] = _ema[s] + (rssi - _ema[s]) * Cfg.MULTI_RSSI_ALPHA;
        }
        _last[s] = now;
        _seen[s] = true;
        _busy[s] = busy;
        _res[s]  = result;
        return true;
    }

    private function _fresh(s as Number, now as Number) as Boolean {
        return _seen[s] && (now - _last[s]) <= Cfg.MULTI_CAND_TTL_MS;
    }

    private function _isCooling(s as Number, now as Number) as Boolean {
        if (_cooling[s] && (now - _coolUntil[s]) >= 0) { _cooling[s] = false; }
        return _cooling[s];
    }

    // Filtered RSSI of an edge, or null if it is not fresh.
    function rssi(node as Number, now as Number) {
        var s = slotOf(node);
        if (s < 0 || !_fresh(s, now)) { return null; }
        return _ema[s];
    }

    function scanResult(node as Number) {
        var s = slotOf(node);
        return (s < 0) ? null : _res[s];
    }

    // Fresh edges (for the on-screen diagnostics).
    function visible(now as Number) as Number {
        var c = 0;
        for (var i = 0; i < _nodes.size(); i++) {
            if (_fresh(i, now)) { c++; }
        }
        return c;
    }

    // Best candidate for a NEW connection (excluding `exclude`), or -1.
    function best(now as Number, exclude as Number) as Number {
        var bestS = -1;
        for (var i = 0; i < _nodes.size(); i++) {
            if (_nodes[i] == exclude) { continue; }
            if (!_fresh(i, now) || _busy[i] || _isCooling(i, now)) { continue; }
            if (bestS < 0 || _ema[i] > _ema[bestS]) { bestS = i; }
        }
        return (bestS < 0) ? -1 : _nodes[bestS];
    }

    // Excludes an edge from the candidates for Cfg.MULTI_COOLDOWN_MS (failed
    // connection, too many failed writes): avoids retrying the same one at once.
    function cool(node as Number, now as Number) as Void {
        var s = slotOf(node);
        if (s < 0) { return; }
        _coolUntil[s] = now + Cfg.MULTI_COOLDOWN_MS;
        _cooling[s] = true;
    }

    function resetVotes() as Void { _votes = 0; }

    // Evaluates the handoff ONCE (called at 1 Hz). Returns the node to move
    // to, or -1. See the policy at the top of the file.
    function evalHandoff(cur as Number, now as Number, connectedAt as Number) as Number {
        if ((now - connectedAt) < Cfg.MULTI_MIN_DWELL_MS) { _votes = 0; return -1; }

        var s = slotOf(cur);
        if (s < 0 || !_seen[s] || (_last[s] - connectedAt) < 0) { _votes = 0; return -1; }

        var curV = ((now - _last[s]) <= Cfg.MULTI_CUR_STALE_MS)
            ? _ema[s] : Cfg.MULTI_RSSI_FLOOR.toFloat();

        var b = best(now, cur);
        if (b < 0) { _votes = 0; return -1; }

        if (_ema[slotOf(b)] >= curV + Cfg.MULTI_HYST_DB) {
            _votes++;
        } else {
            _votes = 0;
        }
        if (_votes >= Cfg.MULTI_HANDOFF_VOTES) {
            _votes = 0;
            return b;
        }
        return -1;
    }
}
