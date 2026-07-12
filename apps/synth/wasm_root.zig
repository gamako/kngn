//! synth wasm root（TASK-73.2: wasm32-wasi + shared memory audio）
//!
//! root に `main` が無いこと。wasi command `_start` / reactor `_initialize` の
//! std.start 配線を避け、export（vp_init/vp_frame/vp_audio_*）駆動の reactor 相当にする。

const synth = @import("synth_app");

comptime {
    synth.enableWasmRuntime();
}
