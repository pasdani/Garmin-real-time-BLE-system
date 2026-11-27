import Toybox.Lang;

//
// VariantConfig.mc (MULTI) — variant constants, included ONLY by this build.
//
// Protocol v4: the watch connects to the registered ESP32 edge with the best
// signal, moves to another one while on the move (handoff) and does not lose
// samples when the link drops (store-and-forward queue). It samples the same
// 12 values as v3 every 5 s, but does NOT take part in the battery
// experiment: it also scans while connected and sends 4 chunks per sample
// instead of 3. The value 5 of dev_variant keeps it distinguishable in the
// FIT files.
//
module Variant {
    const ID   = 5;        // 5 = Multi  (dev_variant value in the FIT file)
    const NAME = "MULTI";
}
