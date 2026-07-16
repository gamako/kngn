//! libs/gfx umbrella（TASK-111.2）。
//! sprite / fixed_timestep / fps_counter / keyboard を再エクスポートし、kit.gfx の公開面とする。
//! 実体ファイルは各 named module が所有し、ここは `@import("sprite")` 等で受け取る
//! （同一 .zig を 2 module に属させない）。

pub const sprite = @import("sprite");
pub const fixed_timestep = @import("fixed_timestep");
pub const fps_counter = @import("fps_counter");
pub const keyboard = @import("keyboard");

pub const Sprite = sprite.Sprite;
pub const drawSprite = sprite.drawSprite;
pub const drawSpriteEx = sprite.drawSpriteEx;
pub const SourceRect = sprite.SourceRect;
pub const RgbTint = sprite.RgbTint;
pub const SpriteDrawOptions = sprite.SpriteDrawOptions;

pub const FixedTimeStep = fixed_timestep.FixedTimeStep;
pub const FpsCounter = fps_counter.FpsCounter;

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
