import Toybox.Lang;

//
// MonCfg.mc — V5 (MONITOR) parameters. The radio parameters are the same as
// MULTI and stay in Cfg (source/Config.mc), read, not copied.
//
module MonCfg {

    const COLOR = 0xFF375F;      // pink: distinct from the colours of variants 1-5 (Colors.mc)

    // --- Time ---
    // A device app has no compute(): a Timer acts as the clock.
    const TICK_MS      = 1000;
    const SAMPLE_EVERY = 5;      // one sample every 5 ticks (5 s), as in MULTI

    // --- Alerts ---
    const ALERT_MAX       = 8;     // alerts to confirm kept on the watch
    const CCCD_TIMEOUT_MS = 6000;  // subscription without outcome: alerts not active

    // --- Alert mode on the watch (UP/DOWN on the main screen), remembered in
    // Application.Storage between one opening and the next.
    const MODE_EDGE   = 0;         // as the edge requests (alert field)
    const MODE_SILENT = 1;         // message only, whatever the edge requests
    const MODE_SOUND  = 2;         // sound only, likewise
    const MODE_VIBE   = 3;         // vibration only, likewise
    const MODE_COUNT  = 4;
    const MODE_KEY    = "alertMode";
}
