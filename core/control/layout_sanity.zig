const std = @import("std");
const harness = @import("harness");

pub const env_var = "KNGN_LAYOUT_SANITY";

/// Selects the GUI layout sanity probe.
///
/// `1` enables the probe, `0` disables it, and any other value follows the harness state.
/// A normal application therefore pays no scan cost unless it is running under the harness.
pub fn isEnabled() bool {
    return if (harness.readEnv(env_var)) |value| blk: {
        if (std.mem.eql(u8, value, "1")) break :blk true;
        if (std.mem.eql(u8, value, "0")) break :blk false;
        break :blk harness.isEnabled();
    } else harness.isEnabled();
}
