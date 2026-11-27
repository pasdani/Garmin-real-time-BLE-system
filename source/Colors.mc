import Toybox.Lang;

//
// Colors.mc — Colour of each variant on the data field screens (0xRRGGBB).
// The Monitor has its own, MonCfg.COLOR.
//
(:datafield)
module Colors {
    const FULL_C    = 0x25D366;   // green  — FULL variant
    const DELTA_C   = 0xFF8A1E;   // orange — DELTA variant
    const BATCH_C   = 0x45C4FF;   // light blue — BATCH variant
    const MULTI_C   = 0xFFD60A;   // yellow — MULTI variant (v4, several edges)
}
