//! The minimal root module of the platform native object archive.
//!
//! The substance is added by `addPlatformNativeLib` in build.zig through `addObjectFile`:
//! the platform implementation (the .o compiled from the macOS Swift + Metal sources).
//! This stub carries no symbol of its own (it exists only as the root of the static lib).
