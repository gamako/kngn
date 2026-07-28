//! synth wasm root (wasm32-wasi + shared memory audio)
//!
//! No `main` at the root. Avoid std.start wiring of wasi command `_start` / reactor `_initialize`,
//! and behave as a reactor driven by the exports (kngn_init/kngn_frame/kngn_audio_*).

const synth = @import("synth_app");

comptime {
    synth.enableWasmRuntime();
}
