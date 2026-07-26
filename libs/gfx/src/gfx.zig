//! libs/gfx umbrella.
//! sprite / fixed_timestep / fps_counter / keyboard / atlas / animation / camera / action_map / tilemap
//! are re-exported as the kit.gfx public surface.
//!
//! atlas / animation / camera / action_map / tilemap use relative imports inside the same module (`@import("atlas.zig")`, etc.).
//! That lets `zig test` collect tests through the gfx root and wire them into test-gfx
//! without adding a dedicated runner.
//! Named-module sprite/helpers are received via `@import("sprite")`, etc.
//! (do not put the same .zig into two modules).

pub const sprite = @import("sprite");
pub const fixed_timestep = @import("fixed_timestep");
pub const fps_counter = @import("fps_counter");
pub const keyboard = @import("keyboard");
pub const atlas = @import("atlas.zig");
pub const animation = @import("animation.zig");
pub const camera = @import("camera.zig");
pub const screen_transform = @import("screen_transform.zig");
pub const action_map = @import("action_map.zig");
pub const tilemap = @import("tilemap.zig");

pub const ScreenTransform = screen_transform.ScreenTransform;

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

pub const ActionMap = action_map.ActionMap;
pub const ActionKind = action_map.ActionKind;
pub const ActionId = action_map.ActionId;
pub const Binding = action_map.Binding;
pub const StickSide = action_map.StickSide;
pub const StickAxis = action_map.StickAxis;
pub const GamepadButtonBinding = action_map.GamepadButtonBinding;
pub const GamepadStickBinding = action_map.GamepadStickBinding;
pub const KeyPairBinding = action_map.KeyPairBinding;

pub const TileMap = tilemap.TileMap;
pub const TileFlags = tilemap.TileFlags;
pub const TileContact = tilemap.TileContact;
pub const ResolveResult = tilemap.ResolveResult;
pub const EmptyTile = tilemap.EmptyTile;
pub const TileMapError = tilemap.TileMapError;
pub const QueryIterator = tilemap.QueryIterator;

pub const KeyCode = keyboard.KeyCode;
pub const KeyInfo = keyboard.KeyInfo;
pub const KeyboardState = keyboard.KeyboardState;
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

// For test-gfx: `pub const X = @import("f.zig")` alone does not collect f.zig's tests.
// Reference the whole namespace from a test block to collect them (same pattern as gui.zig).
// keyboard (including KeyboardState) runs via dedicated run_gfx_kb_test (avoid double collection).
test {
    _ = atlas;
    _ = animation;
    _ = camera;
    _ = screen_transform;
    _ = action_map;
    _ = tilemap;
}
