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
//! - gui / png / font / dsp / synth: 安定 libs
//! - gamepad: src/gamepad.zig（ゲームパッド入力ヘルパー。TASK-80.1。platform_types のみに依存する
//!   headless lib として layer=.lib で扱う。keyboard.zig 等の他 src/ ヘルパーは examples 専用で
//!   kit 非収録だが、gamepad は将来 apps からの直接利用も想定するため kit に載せる）
//! - recipe: libs/recipe（CommandRecord 列の save/replay。TASK-62.5.8。std + serde のみ）
//!
//! **流動中の lib（modular / paint / viz 等）は載せない**。apps はそれらを「内部・壊れうる」
//! 前提の直 import で使い、API が固まったら kit へ昇格する（成熟ゲート）。
//!
//! 注意: platform が backend 毎の module のため、kit も backend 毎に生成される
//! （build.zig の makeKitModule）。ここに import を足す場合は build.zig 側の配線も揃えること。

pub const platform = @import("platform");
pub const control = @import("harness");
pub const types = @import("platform_types");
pub const audio = @import("audio");
pub const gui = @import("gui");
pub const png = @import("png");
pub const font = @import("font");
pub const dsp = @import("dsp");
pub const synth = @import("synth");
pub const gamepad = @import("gamepad");
pub const recipe = @import("recipe");
