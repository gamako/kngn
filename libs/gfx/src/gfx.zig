//! libs/gfx umbrella（TASK-111.2 / TASK-111.3 / TASK-111.4）。
//! sprite / fixed_timestep / fps_counter / keyboard / atlas / animation / camera を再エクスポートし、
//! kit.gfx の公開面とする。
//!
//! atlas / animation / camera は同一 module 内の相対 import（`@import("atlas.zig")` 等）。
//! こうすると `zig test` が gfx root 経由で test を収集し、専用 runner を
//! 増やさずに test-gfx へ接続できる（TASK-111.3/111.4 Claude 設計レビュー付記）。
//! named module の sprite/helpers は `@import("sprite")` 等で受け取る
//! （同一 .zig を 2 module に属させない）。

pub const sprite = @import("sprite");
pub const fixed_timestep = @import("fixed_timestep");
pub const fps_counter = @import("fps_counter");
pub const keyboard = @import("keyboard");
pub const atlas = @import("atlas.zig");
pub const animation = @import("animation.zig");
pub const camera = @import("camera.zig");

pub const Sprite = sprite.Sprite;
pub const drawSprite = sprite.drawSprite;
pub const drawSpriteEx = sprite.drawSpriteEx;
pub const SourceRect = sprite.SourceRect;
pub const RgbTint = sprite.RgbTint;
pub const SpriteDrawOptions = sprite.SpriteDrawOptions;
pub const PremultipliedImage = sprite.PremultipliedImage;

pub const FixedTimeStep = fixed_timestep.FixedTimeStep;
pub const FpsCounter = fps_counter.FpsCounter;

pub const Atlas = atlas.Atlas;
pub const FrameSpec = atlas.FrameSpec;
pub const AtlasError = atlas.AtlasError;

pub const AnimationClip = animation.AnimationClip;
pub const AnimationPlayer = animation.AnimationPlayer;

pub const Camera = camera.Camera;

pub const KeyCode = keyboard.KeyCode;
pub const KeyInfo = keyboard.KeyInfo;
pub const getKeyName = keyboard.getKeyName;
pub const getKeyInfo = keyboard.getKeyInfo;
pub const isLetterKey = keyboard.isLetterKey;
pub const isDigitKey = keyboard.isDigitKey;
pub const isFunctionKey = keyboard.isFunctionKey;
pub const isNumpadKey = keyboard.isNumpadKey;
pub const isModifierKey = keyboard.isModifierKey;
pub const isArrowKey = keyboard.isArrowKey;
pub const isNavigationKey = keyboard.isNavigationKey;
pub const getCharFromKey = keyboard.getCharFromKey;

// test-gfx 用: `pub const X = @import("f.zig")` だけでは f.zig の test は集まらない。
// namespace 全体を test ブロックで参照して収集する（gui.zig と同型）。
test {
    _ = atlas;
    _ = animation;
    _ = camera;
}
