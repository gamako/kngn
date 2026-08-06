//! mic_demo wasm root (wasm32-wasi + shared memory; capture path scaffold)
//!
//! No `main` at the root. Avoid std.start wiring of wasi command `_start` / reactor `_initialize`,
//! and behave as a reactor driven by the exports (kngn_init / kngn_frame).

const mic_demo = @import("mic_demo_app");

comptime {
    mic_demo.enableWasmRuntime();
}
