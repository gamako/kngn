//! libs/sound: メモリ再生音声ライブラリ（WAV デコード + SE ワンショット / BGM ループミキサー）。
//!
//! - `decodeWav` / `DecodedWav`: RIFF/WAVE（PCM8 / PCM16 / IEEE float32）→ f32 interleaved
//! - `Sound` / `SoundPlayer`: 固定 slot SE + 1 本 BGM、SPSC command + AtomicF32 バス gain
//!
//! 依存: `dsp`（equalPowerPan）/ `synth`（SpscRing / AtomicF32）。platform / core は import しない。
//! kit 公開: `kit.sound`。
//!
//! ホットパス宣言: デコードは初期化時のみ。`SoundPlayer.render` は RT（毎サンプル）で
//! alloc/lock/IO/panic/超越関数なし。

const wav = @import("wav.zig");
const player = @import("player.zig");

pub const decodeWav = wav.decodeWav;
pub const DecodedWav = wav.DecodedWav;
pub const WavError = wav.Error;

pub const Sound = player.Sound;
pub const SoundPlayer = player.SoundPlayer;
pub const PlayerError = player.Error;

test {
    _ = wav;
    _ = player;
}
