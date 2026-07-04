//! TASK-29.1: platform native object archive lib の最小 root module。
//!
//! 実体は build.zig の `addPlatformNativeLib` が `addObjectFile` で足す
//! platform 実装 (platform_macos.m / .swift をコンパイルした .o)。
//! この stub 自体は symbol を持たない（static lib の root としてのみ存在）。
