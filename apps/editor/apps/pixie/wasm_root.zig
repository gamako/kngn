//! pixie wasm root（TASK-73.1: wasm32-wasi）
//!
//! root に `main` が無いこと。wasi command `_start` / reactor `_initialize` の
//! std.start 配線を避け、export（vp_init/vp_frame）駆動の reactor 相当にする。

const pixie = @import("pixie");

comptime {
    pixie.enableWasmRuntime();
}
