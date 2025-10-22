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

    // これはモジュールを作成します。モジュールはコンパイルオプション(最適化モードと
    // リンクされたシステムライブラリなど)と共に、ソースファイルの集合を表します。
    // Zigモジュールは、コンシューマーがZigコードを利用できるようにするための
    // 推奨される方法です。addModuleは、コンシューマーにアクセス可能にすることを
    // 意図したモジュールを定義します。Zigパッケージが複数のモジュールを公開でき、
    // コンシューマーがどのモジュールにアクセスしたいのかを指定する必要があるため、
    // 名前を付ける必要があります。
    const mod = b.addModule("video_proto", .{
        // ルートソースファイルはこのモジュールの「エントリーポイント」です。
        // このモジュールのユーザーは、このファイルに含まれているパブリック宣言のみに
        // アクセスできます。つまり、このモジュールの一部である他のファイルで定義された、
        // コンシューマーに公開することを意図した宣言がある場合、
        // ルートファイルからそれらを再エクスポートしていることを確認する必要があります。
        .root_source_file = b.path("src/root.zig"),
        // 後でこのモジュールをテスト実行可能ファイルのルートモジュールとして
        // 使用するため、ターゲットを指定する必要があります。
        .target = target,
    });

    // ここで実行可能ファイルを定義します。実行可能ファイルには、
    // `main`関数を公開するルートモジュールが必要です。
    // 上記で定義したモジュールにmain関数を追加することもできますが、
    // ビジネスロジックとCLIを2つの別々のモジュールに分割することが
    // 推奨されることもあります。
    //
    // あなたの目標が他の人が使用するZigライブラリを作成することである場合、
    // CLIツールも公開することが有益かもしれないかどうかを検討してください。
    // データシリアル化形式のパーサーライブラリは、たとえば、
    // CLI構文チェッカーもバンドルできます。
    //
    // 代わりに、あなたの目標が実行可能ファイルを作成することである場合、
    // ユーザーが独自の実行可能ファイルにコア機能を埋め込むことに関心を持つかどうかを
    // 検討してください。サブプロセッシングCLIツールに関連するオーバーヘッドを回避するためです。
    //
    // どちらの場合にも該当しない場合は、不要な宣言を削除して、
    // すべてを1つのモジュールの下に置くことができます。

    // 外部clangコマンドで external.c を .o ファイルにコンパイル
    const compile_external_exe = b.addSystemCommand(&.{ "clang", "-c", "-o" });
    const external_obj_path_exe = compile_external_exe.addOutputFileArg("external_exe.o");
    compile_external_exe.addFileArg(b.path("src/external.c"));

    // 外部clangコマンドで external.m (Objective-C) を .o ファイルにコンパイル
    const compile_external_objc_exe = b.addSystemCommand(&.{ "clang", "-x", "objective-c", "-c", "-o" });
    const external_objc_obj_path_exe = compile_external_objc_exe.addOutputFileArg("external_objc_exe.o");
    compile_external_objc_exe.addFileArg(b.path("src/external.m"));

    // 外部swiftcコマンドで external.swift を .o ファイルにコンパイル
    const compile_external_swift_exe = b.addSystemCommand(&.{
        "swiftc",
        "-parse-as-library",
        "-Osize",
        "-disable-autolinking-runtime-compatibility",
        "-disable-autolinking-runtime-compatibility-concurrency",
        "-disable-autolinking-runtime-compatibility-dynamic-replacements",
        "-c",
        "-o"
    });
    const external_swift_obj_path_exe = compile_external_swift_exe.addOutputFileArg("external_swift_exe.o");
    compile_external_swift_exe.addFileArg(b.path("src/external.swift"));

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

    // C言語のmath.cをオブジェクトファイルとしてコンパイル
    const math_obj = b.addObject(.{
        .name = "math",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    // C言語ソースファイルをオブジェクトに追加
    math_obj.root_module.addCSourceFile(.{
        .file = b.path("src/math.c"),
    });
    math_obj.root_module.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "video_proto",
        .root_module = b.createModule(.{
            // b.createModuleはb.addModuleのようなモジュールを定義しますが、
            // b.addModuleとは異なり、このパッケージのコンシューマーにモジュールを
            // 公開しないため、この場合は名前を付ける必要があります。
            .root_source_file = b.path("src/main.zig"),
            // ルートモジュールで実行可能ファイルまたはライブラリを定義する場合、
            // ターゲットと最適化レベルは明示的に設定する必要があります。
            // また、実行可能ファイルまたはライブラリの定義に対して
            // 特定のターゲットをハードコーディングすることもできます
            // (例：組み込みデバイスのファームウェア)。
            .target = target,
            .optimize = optimize,
            // ルートモジュールに属するソースファイルでインポート可能なモジュールのリスト。
            .imports = &.{
                // ここで「video_proto」は、ソースコードでこのモジュールを
                // インポートする際に使用する名前です(例：`@import("video_proto")`)。
                // 異なるパッケージから複数のモジュールをインポートする場合に発生する可能性がある
                // 衝突の場合に非常に役立つため、インポート名を変更することが許可されています。
                .{ .name = "video_proto", .module = mod },
            },
        }),
    });

    // Swift版実行ファイル
    const exe_swift = b.addExecutable(.{
        .name = "video_proto_swift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "video_proto", .module = mod },
            },
        }),
    });

    // プラットフォーム層をclangコマンドで external.m (Objective-C) を .o ファイルにコンパイル
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

    // C言語オブジェクトファイルを実行可能ファイルにリンク
    exe.root_module.addObject(math_obj);
    // 外部生成した.oファイルをリンク
    exe.root_module.addObjectFile(external_obj_path_exe);
    // Objective-C外部生成した.oファイルをリンク
    exe.root_module.addObjectFile(external_objc_obj_path_exe);
    // Swift外部生成した.oファイルをリンク
    exe.root_module.addObjectFile(external_swift_obj_path_exe);
    // プラットフォーム層の.oファイルをリンク
    exe.root_module.addObjectFile(platform_objc_obj_path_exe);
    exe.root_module.link_libc = true;

    // macOSフレームワークをリンク
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("QuartzCore", .{});

    // @cImport用に、srcディレクトリとplatformディレクトリをインクルードパスに追加
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addIncludePath(b.path("platform"));

    // 実行可能ファイルを外部コンパイルステップに依存させる
    exe.step.dependOn(&compile_external_exe.step);
    exe.step.dependOn(&compile_external_objc_exe.step);
    exe.step.dependOn(&compile_external_swift_exe.step);
    exe.step.dependOn(&compile_platform_objc_exe.step);

    // ========================================
    // Swift版実行ファイルのリンク設定
    // ========================================
    // C言語オブジェクトファイルをSwift版実行可能ファイルにリンク
    exe_swift.root_module.addObject(math_obj);
    // 外部生成した.oファイルをリンク
    exe_swift.root_module.addObjectFile(external_obj_path_exe);
    // Objective-C外部生成した.oファイルをリンク
    exe_swift.root_module.addObjectFile(external_objc_obj_path_exe);
    // Swift外部生成した.oファイルをリンク
    exe_swift.root_module.addObjectFile(external_swift_obj_path_exe);
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

    // @cImport用に、srcディレクトリとplatformディレクトリをインクルードパスに追加
    exe_swift.root_module.addIncludePath(b.path("src"));
    exe_swift.root_module.addIncludePath(b.path("platform"));

    // Swift版実行可能ファイルを外部コンパイルステップに依存させる
    exe_swift.step.dependOn(&compile_external_exe.step);
    exe_swift.step.dependOn(&compile_external_objc_exe.step);
    exe_swift.step.dependOn(&compile_external_swift_exe.step);
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

    // 提供されたモジュールから`test`ブロックを実行する実行可能ファイルを作成します。
    // ここでは`mod`がターゲットを定義する必要があります。
    // これが前に相対フィールドを設定することを確認した理由です。
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // テスト実行可能ファイルを実行するRunステップ。
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // 実行可能ファイルのルートモジュールから`test`ブロックを実行する
    // 実行可能ファイルを作成します。テスト実行可能ファイルは一度に
    // 1つのモジュールのみをテストするため、2つの独立したものを
    // 作成する必要があることに注意してください。
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // 2番目のテスト実行可能ファイルを実行するRunステップ。
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // ========================================
    // 外部clangで生成した .o ファイルをリンクするテスト
    // ========================================

    // 外部clangコマンドで external.c を .o ファイルにコンパイル
    const compile_external = b.addSystemCommand(&.{ "clang", "-c", "-o" });
    const external_obj_path = compile_external.addOutputFileArg("external.o");
    compile_external.addFileArg(b.path("src/external.c"));

    // 外部.oファイルをリンクするテスト実行可能ファイルを作成
    const external_link_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_external_link.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 外部生成した.oファイルをテストにリンク
    external_link_tests.root_module.addObjectFile(external_obj_path);
    external_link_tests.root_module.link_libc = true;

    // テスト実行ステップを作成し、clangコンパイルステップに依存させる
    const run_external_link_tests = b.addRunArtifact(external_link_tests);
    run_external_link_tests.step.dependOn(&compile_external.step);

    // ========================================
    // Objective-C外部関数をリンクするテスト
    // ========================================

    // 外部clangコマンドで external.m (Objective-C) を .o ファイルにコンパイル
    const compile_external_objc = b.addSystemCommand(&.{ "clang", "-x", "objective-c", "-c", "-o" });
    const external_objc_obj_path = compile_external_objc.addOutputFileArg("external_objc.o");
    compile_external_objc.addFileArg(b.path("src/external.m"));

    // Objective-C .oファイルをリンクするテスト実行可能ファイルを作成
    const external_objc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_external_objc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 外部生成したObjective-C .oファイルをテストにリンク
    external_objc_tests.root_module.addObjectFile(external_objc_obj_path);
    external_objc_tests.root_module.link_libc = true;

    // テスト実行ステップを作成し、clangコンパイルステップに依存させる
    const run_external_objc_tests = b.addRunArtifact(external_objc_tests);
    run_external_objc_tests.step.dependOn(&compile_external_objc.step);

    // ========================================
    // Swift外部関数をリンクするテスト
    // ========================================

    // 外部swiftcコマンドで external.swift を .o ファイルにコンパイル
    // -parse-as-library: main 関数の自動生成を抑制
    // -Osize: 最適化を有効にしてSwiftランタイム依存を最小化
    // -disable-autolinking-runtime-compatibility*: ランタイム互換性ライブラリの自動リンクを無効化
    const compile_external_swift = b.addSystemCommand(&.{
        "swiftc",
        "-parse-as-library",
        "-Osize",
        "-disable-autolinking-runtime-compatibility",
        "-disable-autolinking-runtime-compatibility-concurrency",
        "-disable-autolinking-runtime-compatibility-dynamic-replacements",
        "-c",
        "-o"
    });
    const external_swift_obj_path = compile_external_swift.addOutputFileArg("external_swift.o");
    compile_external_swift.addFileArg(b.path("src/external.swift"));

    // Swift .oファイルをリンクするテスト実行可能ファイルを作成
    const external_swift_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_external_swift.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 外部生成したSwift .oファイルをテストにリンク
    external_swift_tests.root_module.addObjectFile(external_swift_obj_path);
    external_swift_tests.root_module.link_libc = true;

    // テスト実行ステップを作成し、swiftcコンパイルステップに依存させる
    const run_external_swift_tests = b.addRunArtifact(external_swift_tests);
    run_external_swift_tests.step.dependOn(&compile_external_swift.step);

    // すべてのテストを実行するためのトップレベルステップ。dependOnは複数回
    // 呼び出でき、複数のrunステップが互いに依存しないため、
    // これらが並列に実行されます。
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_external_link_tests.step);
    test_step.dependOn(&run_external_objc_tests.step);
    test_step.dependOn(&run_external_swift_tests.step);

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
