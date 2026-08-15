//! Fixed-framebuffer example wasm root (wasm32-wasi reactor).
//!
//! No `main` at the root. Avoid std.start wiring of wasi command `_start` / reactor `_initialize`,
//! and behave as a reactor driven by the exports (kngn_init / kngn_frame).

const fixed_fb = @import("fixed_fb_app");

comptime {
    fixed_fb.enableWasmRuntime();
}
