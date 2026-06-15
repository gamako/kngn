//! libs/synth: シンセサイザーの再利用ライブラリ（platform / GUI 非依存の純 Zig）。
//!
//! 現状（TASK-27.2）: GUI(メインスレッド) ⇔ Audio(RTスレッド) のロックフリー受け渡し機構。
//! - `NoteQueue` / `SpscRing`: GUI→Audio のノートイベント（note_off / パニックは落とさない）
//! - `AtomicF32` / `DoubleBuffer`: GUI→Audio の連続パラメータ / patch
//! - `SampleTap`: Audio→GUI の出力タップ（スペクトログラム用、drop 可）
//!
//! TASK-27.4: Voice / VoicePool / Patch / Synth.render（dsp に依存）。

const ring = @import("ring.zig");
const params = @import("params.zig");
const tap = @import("tap.zig");
const voice = @import("voice.zig");
const synth_engine = @import("synth_engine.zig");

pub const SpscRing = ring.SpscRing;
pub const NoteEvent = ring.NoteEvent;
pub const NoteQueue = ring.NoteQueue;

pub const AtomicF32 = params.AtomicF32;
pub const DoubleBuffer = params.DoubleBuffer;

pub const SampleTap = tap.SampleTap;

pub const Patch = voice.Patch;
pub const Voice = voice.Voice;
pub const VoicePool = voice.VoicePool;
pub const noteToFreq = voice.noteToFreq;
pub const Synth = synth_engine.Synth;

test {
    // 参照する全ファイルの test をまとめて回す。
    _ = ring;
    _ = params;
    _ = tap;
    _ = voice;
    _ = synth_engine;
}
