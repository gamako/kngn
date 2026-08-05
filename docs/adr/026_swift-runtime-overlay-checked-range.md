# ADR-026: Swift runtime overlays: a checked-range fixed list, not dynamic discovery

- Status: Accepted
- Date: 2026-08-04
- Scope: how `build_helpers/swift.zig` decides which macOS Swift runtime overlay
  libraries to link, and why a dynamically-discovered set was rejected in favor of a
  fixed list plus a build-time SDK version check. The contract this settles lives in the
  doc comments on `macos.checked_sdk_major_range` and `swift.zig`'s `optional_libs`.

## Context

swiftc marks every Swift overlay module (Foundation, Metal, Darwin, ...) it references
with an undefined `__swift_FORCE_LOAD_$_<name>` symbol in the compiled object — its own
mechanism for telling a linker "pull in lib\<name\>". Zig's own linker does not read this
metadata: linking with no `-l` flags at all produces hundreds of undefined symbol errors,
including ordinary swiftCore calls, so `build_helpers/swift.zig` has always had to supply
that list by hand.

The set of overlays swiftc force-loads is not fixed: it changes with the SDK and swiftc
version. A build on a Command Line Tools-only toolchain (SDK 15.2, swiftc 6.0.3) failed
with `undefined symbol: __swift_FORCE_LOAD_$_swiftDarwin` — a name this project's
hand-kept list did not have, because the SDK it was written against never force-loaded
it. The same compiled object also force-loaded seven more names (`swift_errno`,
`swift_math`, `swift_signal`, `swift_stdio`, `swift_time`, `swiftsys_time`,
`swiftunistd`) that were also missing.

## Decision

Keep linking Swift overlay libraries from an explicit list (`runtime_libs` always linked;
`optional_libs` linked only when its `.tbd` exists under the SDK or toolchain Swift
library path — the existing mechanism, unchanged), extended with the eight names above.

Declare the range of SDK major versions this list is checked against
(`macos.checked_sdk_major_range`, currently 15–26) and check the host's SDK version
against it in `resolveMacOSSDKPaths`. A host outside the range — or one whose SDK version
cannot be read (an overridden SDK path, or an unparseable version string) — gets an
explicit, non-fatal warning naming the range and pointing at `optional_libs` as the fix
site. This does not make the list automatically correct for every future SDK; it makes
the next occurrence of this exact bug shape diagnosable in seconds instead of requiring
an investigation from scratch.

## Rejected alternatives

1. **Discover the needed overlays from the compiled object at build time** (`nm -u`
   scanning a custom `std.Build.Step`, calling `Module.linkSystemLibrary` from its
   `make()`). This would make the fixed list unnecessary and adapt automatically to any
   SDK. Implemented and tested: a clean rebuild crashed with a `Bus error` inside
   `Build.zig`'s `b.fmt` (`std.fmt.allocPrint(b.allocator, ...)`), called from the custom
   step's `make()`. Wrapping the entire crash-prone section of that `make()` in a
   `std.Io.Mutex` did not fix it — the identical crash reproduced even with a single
   custom-step instance in the whole build graph, which rules out contention between the
   step's own concurrent invocations and points at some other, unrelated step
   concurrently touching the same build-graph arena (`Build.Graph.arena`, a plain
   `std.heap.ArenaAllocator`, not thread-safe). `Module.linkSystemLibrary` itself does
   `b.dupe(name)` and appends to `link_objects` using that same allocator, so there is no
   safe way to call it from a `Step`'s execution-time `make()` in this Zig version.
2. **Link every overlay `.tbd` found in the SDK and toolchain directories
   unconditionally, relying on the linker to drop the ones nothing references.** Linking
   all of them with the default `needed=false` did not trim anything — every one stayed
   in the final binary. Adding `exe.dead_strip_dylibs = true` did trim the list down to
   almost exactly the demand-driven result, except it also dropped `swiftFoundation`, a
   library the compiled object's own FORCE_LOAD symbol had asked for. `-dead_strip_dylibs`
   removes a dylib once nothing in the link references any of its symbols; whether a
   dylib whose *only* resolved reference is a FORCE_LOAD side-effect symbol reliably
   survives that pass could not be established without a synthetic linker fixture, so
   this was not adopted — the risk is a binary that links and runs on the common path but
   is silently missing an overlay whose static initializers or conformances some other
   path depends on.
3. **A configure-time synchronous compile-and-scan with a hand-rolled
   content-addressed cache**, reaching the same accuracy as alternative 1 without
   touching `Module` from `make()` and without recompiling on every invocation. Sound in
   principle — everything would run during the single-threaded configure phase — but it
   amounts to reimplementing a slice of Zig's own build cache (a cache key over compiler
   path/version, SDK/toolchain path, target, flags and source content; a contract for
   shipping the same manifest alongside the external-consumer's prebuilt archive). Scoped
   out as too large for the bug this list needed to fix; left as a future option if the
   checked-range list's limitations start to bite in practice.

## Consequences

- A future SDK that force-loads a name not yet in `optional_libs` still fails the build,
  but with a warning already printed identifying the SDK as unchecked and naming the file
  to edit, instead of a bare undefined-symbol error requiring investigation from scratch.
- The checked range is an SDK-major-only boundary, not a guarantee: a new `swiftc` on an
  SDK version already inside the range can still force-load a name this project has not
  seen. Extending `checked_sdk_major_range` requires evidence (a build, or at least an
  `nm -u` scan, on that SDK), not just raising the number.
- The external-consumer path (a prebuilt static archive; `gates/consumer` and `template`)
  keeps using the same fixed-list mechanism. Alternative 1's archive-scanning variant
  would have applied uniformly to both paths, so revisiting this decision should
  re-examine that path too, not only the in-repo compile.

## Reference

The investigation (both SDKs' `nm -u` output, the crash traces, the `dead_strip_dylibs`
and `LC_LINKER_OPTION` experiments) and the codex review rounds behind this decision are
recorded in the private task tracker.
