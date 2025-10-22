const std = @import("std");

// この関数は命令形に見えますが、ビルドを直接実行せず、代わりに
// 外部ランナーによって実行されるビルドグラフ(`b`)を変更します。
// `std.Build`の関数はビルドステップを定義するDSLを実装し、
// ステップ間の依存関係を表現することで、ビルドランナーが
// ビルドを自動的に並列化でき、キャッシュシステムが
// ステップを再実行する必要があるかどうかを知ることができます。
pub fn build(b: *std.Build) void {
    // 標準ターゲットオプションを使用して、`zig build`を実行する人が
    // ビルド対象のターゲットを選択できます。ここではデフォルトをオーバーライドしないため、
    // すべてのターゲットが許可され、デフォルトはネイティブです。
    // サポートされるターゲットセットを制限するための他のオプションも利用可能です。
    const target = b.standardTargetOptions(.{});
    // 標準最適化オプションを使用して、`zig build`を実行する人は
    // Debug、ReleaseSafe、ReleaseFast、ReleaseSmallの中から選択できます。
    // ここではデフォルトの優先リリースモードを設定しないため、ユーザーは
    // 最適化方法を決定できます。
    const optimize = b.standardOptimizeOption(.{});
    // また、`b.option()`を使用してこのビルドスクリプトのオプション機能を
    // 切り替えるためのカスタムフラグを定義することも可能です。
    // 定義されたすべてのフラグ(ターゲットと最適化オプションを含む)は、
    // このディレクトリで`zig build --help`を実行する際に表示されます。

    // Swift版プラットフォーム層をswiftcで platform/macos-swift/platform_macos.swift をオブジェクトファイルにコンパイル
    const compile_platform_swift_exe = b.addSystemCommand(&.{
        "swiftc",
        "-parse-as-library",
        "-Osize",
        "-disable-autolinking-runtime-compatibility",
        "-disable-autolinking-runtime-compatibility-concurrency",
        "-disable-autolinking-runtime-compatibility-dynamic-replacements",
        "-framework", "Cocoa",
        "-framework", "QuartzCore",
        "-c",
        "-o"
    });
    const platform_swift_obj_path_exe = compile_platform_swift_exe.addOutputFileArg("platform_macos_swift_exe.o");
    compile_platform_swift_exe.addFileArg(b.path("platform/macos-swift/platform_macos.swift"));

    const exe = b.addExecutable(.{
        .name = "video_proto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Swift版実行ファイル
    const exe_swift = b.addExecutable(.{
        .name = "video_proto_swift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // プラットフォーム層（Objective-C版）をclangでコンパイル
    const compile_platform_objc_exe = b.addSystemCommand(&.{
        "clang",
        "-x", "objective-c",
        "-I", "platform",
        "-framework", "Cocoa",
        "-framework", "QuartzCore",
        "-c",
        "-o"
    });
    const platform_objc_obj_path_exe = compile_platform_objc_exe.addOutputFileArg("platform_macos_exe.o");
    compile_platform_objc_exe.addFileArg(b.path("platform/macos/platform_macos.m"));

    // プラットフォーム層の.oファイルをリンク
    exe.root_module.addObjectFile(platform_objc_obj_path_exe);
    exe.root_module.link_libc = true;

    // macOSフレームワークをリンク
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("QuartzCore", .{});

    // @cImport用に、platformディレクトリをインクルードパスに追加
    exe.root_module.addIncludePath(b.path("platform"));

    // 実行可能ファイルをプラットフォーム層のコンパイルステップに依存させる
    exe.step.dependOn(&compile_platform_objc_exe.step);

    // ========================================
    // Swift版実行ファイルのリンク設定
    // ========================================
    // Swift版プラットフォーム層の.oファイルをリンク
    exe_swift.root_module.addObjectFile(platform_swift_obj_path_exe);
    exe_swift.root_module.link_libc = true;

    // macOSフレームワークをリンク
    exe_swift.root_module.linkFramework("Cocoa", .{});
    exe_swift.root_module.linkFramework("QuartzCore", .{});

    // Swiftランタイムライブラリのサーチパスを追加
    exe_swift.root_module.addLibraryPath(.{
        .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx",
    });
    exe_swift.root_module.addLibraryPath(.{
        .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk/usr/lib/swift",
    });

    // Swiftランタイムライブラリをリンク
    exe_swift.root_module.linkSystemLibrary("swiftCore", .{});
    exe_swift.root_module.linkSystemLibrary("swiftCoreFoundation", .{});
    exe_swift.root_module.linkSystemLibrary("swiftDispatch", .{});
    exe_swift.root_module.linkSystemLibrary("swiftObjectiveC", .{});
    exe_swift.root_module.linkSystemLibrary("swiftQuartzCore", .{});
    exe_swift.root_module.linkSystemLibrary("swiftCoreImage", .{});
    exe_swift.root_module.linkSystemLibrary("swiftIOKit", .{});
    exe_swift.root_module.linkSystemLibrary("swiftMetal", .{});
    exe_swift.root_module.linkSystemLibrary("swiftOSLog", .{});
    exe_swift.root_module.linkSystemLibrary("swiftUniformTypeIdentifiers", .{});
    exe_swift.root_module.linkSystemLibrary("swiftXPC", .{});
    exe_swift.root_module.linkSystemLibrary("swift_Builtin_float", .{});
    exe_swift.root_module.linkSystemLibrary("swiftos", .{});
    exe_swift.root_module.linkSystemLibrary("swiftsimd", .{});

    // @cImport用に、platformディレクトリをインクルードパスに追加
    exe_swift.root_module.addIncludePath(b.path("platform"));

    // Swift版実行可能ファイルをプラットフォーム層のコンパイルステップに依存させる
    exe_swift.step.dependOn(&compile_platform_swift_exe.step);

    // これは`zig build`を実行する際(つまり、デフォルトステップを実行する際)に、
    // インストールプレフィックスに実行可能ファイルをインストールする意思を宣言します。
    // デフォルトではインストールプレフィックスは`zig-out/`ですが、
    // `--prefix`または`-p`を渡すことでオーバーライドできます。
    b.installArtifact(exe);
    b.installArtifact(exe_swift);

    // これはトップレベルステップを作成します。トップレベルステップには名前があり、
    // `zig build`を実行する際に名前で呼び出すことができます(例：`zig build run`)。
    // これは、デフォルトステップではなく、`run`ステップを評価します。
    // トップレベルステップが実際に何かをするためには、
    // 他のステップに依存する必要があります(例：Runステップ。すぐに確認します)。
    const run_step = b.step("run", "Run the app");

    // これはビルドグラフにRunArtifactステップを作成します。RunArtifactステップは、
    // Zigによってコンパイルされた実行可能ファイルを呼び出します。
    // ステップは、ユーザーによって直接呼び出された場合(トップレベルステップの場合)
    // または別のステップがそれに依存する場合にのみ、ランナーによって実行されます。
    // つまり、このRunステップをいつどのように実行するかを定義するのはあなた次第です。
    // この場合、ユーザーが`zig build run`を実行する際に実行したいため、
    // 依存関係リンクを作成します。
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // runステップをデフォルトステップに依存させることで、
    // キャッシュディレクトリ内から直接ではなく、
    // インストールディレクトリから実行されます。
    run_cmd.step.dependOn(b.getInstallStep());

    // これにより、ユーザーはビルドコマンド自体で
    // アプリケーションに引数を渡すことができます。
    // 例：`zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // フラグと同じように、トップレベルステップも`--help`メニューに表示されます。
    //
    // Zigビルドシステムはユーザーランドに完全に実装されています。
    // つまり、プライベートコンパイラAPIにフックできません。
    // ビルドシステムによってオーケストレーションされたすべてのコンパイルワークは、
    // 定義された正しいフラグを使用して、他のZigコンパイラサブコマンドを
    // 呼び出します。失敗したとき(またはフラグを渡して冗長性を増すとき)に
    // これらの呼び出しを観察して、仮定を検証し、問題を診断できます。
    //
    // 最後に、Zigビルドシステムは比較的シンプルで自己完結しており、
    // そのソースコードを読むことで、それをマスターできます。
}
