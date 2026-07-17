//! kit — 公開 umbrella モジュール（ADR-007 R4）
//!
//! apps/ と外部消費者が依存してよい**唯一の公開面**。個別モジュールの直 import ではなく
//! `@import("kit")` 経由で参照することで、内部リファクタが消費者を壊さない境界をここで引く。
//!
//! 収録は「安定 lib のみ」（ADR-007 未決#2 の段階化方針。kit に載る＝将来 semver で守る対象）:
//! - platform: core/platform.zig facade（window / event / 手動描画 / getTime）
//! - control:  core/control/harness.zig（制御＋観測プレーン: probe / replay / live / 仮想クロック）
//! - types:    core/platform_types.zig（KeyCode / Event 等の type-only 共有型）
//! - audio:    core/audio.zig facade（L1 オーディオ出力）
//! - gui / png / font / dsp / synth / sound / gmath / gfx / appshell: 安定 libs
//! - gamepad: src/gamepad.zig（ゲームパッド入力ヘルパー。TASK-80.1。platform_types のみに依存する
//!   headless lib として layer=.lib で扱う。keyboard 等の gfx ヘルパーは TASK-111.2 で libs/gfx へ
//!   移設し kit.gfx 経由でも公開する）
//! - recipe: libs/recipe（CommandRecord 列の save/replay。TASK-62.5.8。std + serde のみ）
//! - sound: libs/sound（WAV デコード + SE/BGM ミキサー。TASK-111.6。dsp + synth）
//! - gfx: libs/gfx（sprite / fixed_timestep / fps_counter / keyboard / atlas / animation。TASK-111.2/111.3）
//!
//! **流動中の lib（modular / paint / viz 等）は載せない**。apps はそれらを「内部・壊れうる」
//! 前提の直 import で使い、API が固まったら kit へ昇格する（成熟ゲート）。
//!
//! 注意: platform が backend 毎の module のため、kit も backend 毎に生成される
//! （build.zig の makeKitModule）。ここに import を足す場合は build.zig 側の配線も揃えること。

pub const platform = @import("platform");
pub const control = @import("harness");
pub const types = @import("platform_types");
pub const command_types = @import("command_types");
pub const audio = @import("audio");
pub const gui = @import("gui");
pub const png = @import("png");
pub const font = @import("font");
pub const dsp = @import("dsp");
pub const synth = @import("synth");
pub const gamepad = @import("gamepad");
pub const midi = @import("midi");
pub const recipe = @import("recipe");
pub const gmath = @import("gmath");
pub const gfx = @import("gfx");
pub const appshell = @import("appshell");
pub const app_runtime = @import("app_runtime");
pub const sound = @import("sound");
