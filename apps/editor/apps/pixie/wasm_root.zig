//! pixie wasm root (wasm32-wasi)
//!
//! No `main` at root. Avoid std.start wiring for wasi command `_start` / reactor `_initialize`;
//! drive a reactor-equivalent via exports (kngn_init/kngn_frame).

const pixie = @import("pixie");

comptime {
    pixie.enableWasmRuntime();
}
