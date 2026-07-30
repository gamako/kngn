const std = @import("std");

// Vendored from kngn/build_helpers/. Keep byte-identical with upstream (parent gate checks).
const helpers = @import("build_helpers/consumer.zig");
const macos = @import("build_helpers/macos.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = helpers.resolveBackend(b, target);

    // Propagate target / optimize / platform so the exe and kit share one backend.
    const dep = b.dependency("kngn", .{
        .target = target,
        .optimize = optimize,
        .platform = backend,
    });

    // ----- native executable -----
    const exe = b.addExecutable(.{
        .name = "template",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("kit", dep.module("kit"));

    const sdk_paths: ?macos.MacOSSDKPaths = if (target.result.os.tag == .macos)
        macos.resolveMacOSSDKPaths(b, null, null)
    else
        null;
    helpers.setupConsumerExe(b, exe, dep, backend, sdk_paths, .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the template app (harness-compatible; uses -Dplatform)");
    run_step.dependOn(&run_cmd.step);

    const build_native_step = b.step("build-native", "Compile the native template executable only");
    build_native_step.dependOn(&exe.step);

    // ----- unit tests (no platform window init) -----
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("kit", dep.module("kit"));
    // Tests only exercise pure color parsing / state update; no native links needed.
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run template unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ----- compile-only diagnostics (the step editors look for on save) -----
    // Semantic analysis without linking or installing: it reports the same compile errors as a build
    // but skips the native link, so an editor can run it on every save. Nothing depends on this step,
    // so `gate` stays the thing that proves the app links and its tests pass.
    const check_exe = b.addExecutable(.{
        .name = "template-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    check_exe.root_module.addImport("kit", dep.module("kit"));
    // Dropping the binary output keeps this to semantic analysis: no codegen, no link, no native
    // objects or frameworks needed, which is why this step does not call setupConsumerExe.
    check_exe.generated_bin = null;
    const check_step = b.step("check", "Analyse only, for editor diagnostics (no binary is produced)");
    check_step.dependOn(&check_exe.step);

    // ----- native gate (no wasm) -----
    const gate_step = b.step("gate", "Native gate: compile the app and run its unit tests");
    gate_step.dependOn(build_native_step);
    gate_step.dependOn(test_step);

    // ----- wasm web package (existing WasmAppSpec / addWasmWebPackage) -----
    // Wasm packaging defaults to ReleaseSmall when neither -Doptimize nor --release is given.
    const wasm_optimize: std.builtin.OptimizeMode = if (b.user_input_options.contains("optimize") or b.release_mode != .off)
        optimize
    else
        .ReleaseSmall;

    const wasi_target_query = std.Target.Query{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    };
    const wasi_target = b.resolveTargetQuery(wasi_target_query);
    // Wasm branch of kngn does not register -Dplatform (early return before option).
    // Target alone selects the wasm kit/platform modules.
    const wasm_dep = b.dependency("kngn", .{
        .target = wasi_target,
        .optimize = wasm_optimize,
    });
    const kit_wasm = wasm_dep.module("kit");

    var specs = [_]helpers.WasmAppSpec{
        .{
            .name = "template",
            .target_query = wasi_target_query,
            .app_source = b.path("src/main.zig"),
            .wasm_root_source = b.path("src/wasm_root.zig"),
            .wasm_root_import_name = "template_app",
            .imports = &.{
                .{ .name = "kit", .module = kit_wasm },
            },
            .audio = .none,
            .shared_memory = false,
            .import_memory = false,
            .html_source = b.path("web/template.html"),
            .html_install_path = "web/template.html",
            .single_html = true,
            .single_html_basename = "template",
        },
    };

    // Shared web assets and packer come from the kngn package (dep.path), not local copies.
    _ = helpers.addWasmWebPackage(b, .{
        .apps = &specs,
        .assets = .{
            .js = dep.path("web/kngn.js"),
            .worklet = dep.path("web/kngn-worklet.js"),
            .headers = dep.path("web/deploy/_headers"),
            .netlify = dep.path("web/deploy/netlify.toml"),
            .serve_script = dep.path("web/deploy/serve-coop-coep.py"),
            .packer = dep.path("cli/pack-single-html.zig"),
        },
        .optimize = wasm_optimize,
        .linker = null,
        .default_install = false,
        .create_package_step = true,
        .package_step_name = "package-web",
        .package_step_description = "Package template wasm multi-file web bundle to zig-out/web/",
        .create_single_package_step = true,
        .single_package_step_name = "package-web-single",
        .single_package_step_description = "Package template single-file HTML to zig-out/web/",
    });

    // ----- web gate (package-web + package-web-single; shares one wasm compile) -----
    const gate_web_step = b.step("gate-web", "Web gate: package the multi-file and single-HTML wasm bundles");
    const package_web = b.top_level_steps.get("package-web") orelse @panic("package-web step missing");
    const package_web_single = b.top_level_steps.get("package-web-single") orelse @panic("package-web-single step missing");
    gate_web_step.dependOn(&package_web.step);
    gate_web_step.dependOn(&package_web_single.step);
}
