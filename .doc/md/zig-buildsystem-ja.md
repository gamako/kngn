# Zigビルドシステム

-   [Zigビルドシステムはいつ使うべき?](#build-system)
-   [はじめに](#getting-started)
    -   [シンプルな実行可能ファイル](#simple)
    -   [ビルド成果物のインストール](#installing-artifacts)
    -   [アプリケーションを実行するための便利なステップを追加する](#run-step)
-   [基本](#basics)
    -   [ユーザー提供のオプション](#user-options)
    -   [標準設定オプション](#standard-options)
    -   [条件付きコンパイルのためのオプション](#conditional-compilation)
    -   [静的ライブラリ](#static-library)
    -   [動的ライブラリ](#dynamic-library)
    -   [テスト](#testing)
    -   [システムライブラリへのリンク](#linking-to-system-libraries)
-   [ファイルの生成](#generating-files)
    -   [システムツールの実行](#system-tools)
    -   [プロジェクトのツールの実行](#project-tools)
    -   [`@embedFile`用のアセットの生成](#embed-file)
    -   [Zigソースコードの生成](#generating-zig)
    -   [1つ以上の生成されたファイルの処理](#write-files)
    -   [ソースファイルをインプレースで変更する](#mutating-source)
-   [便利な例](#examples)
    -   [複数のターゲットに対してビルドしてリリースを作成](#release)

# Zigビルドシステムはいつ使うべき?

基本的なコマンド `zig build-exe`、`zig build-lib`、`zig build-obj`、`zig test` はしばしば十分です。しかし、プロジェクトがソースからのビルドの複雑さを管理するために別の抽象化レイヤーが必要になることもあります。

例えば、以下の状況のいずれかが当てはまるかもしれません:

-   コマンドラインが長く扱いにくくなり、どこかに記述したいと思っている。
-   多くのものをビルドする必要があり、またはビルドプロセスに多くのステップが含まれている。
-   並行処理とキャッシングを活用してビルド時間を削減したい。
-   プロジェクトに設定オプションを公開したい。
-   ビルドプロセスがターゲットシステムと他のオプションに応じて異なる。
-   他のプロジェクトに依存する。
-   cmake、make、shell、msvc、python など への不要な依存を避けたく、プロジェクトをより多くの貢献者がアクセスできるようにしたい。
-   サードパーティに使用されるパッケージを提供したい。
-   IDEなどのツールがセマンティックにプロジェクトのビルド方法を理解できるような標準化された方法を提供したい。

これらのいずれかが当てはまる場合、プロジェクトはZigビルドシステムの使用から利益を得るでしょう。

# はじめに

## シンプルな実行可能ファイル

このビルドスクリプトは、パブリック `main` 関数定義を含むZigファイルから実行可能ファイルを作成します。

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello World!\n", .{});
}
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    });

    b.installArtifact(exe);
}
```

```bash
$ zig build --summary all

Build Summary: 3/3 steps succeeded
install success
└─ install hello success
   └─ compile exe hello Debug native success 1s MaxRSS:136M
```

## ビルド成果物のインストール

Zigビルドシステムは、ほとんどのビルドシステムと同様に、有向非環状グラフ(DAG)ステップのセットをモデル化することに基づいており、これらは独立して同時に実行されます。

デフォルトでは、グラフの主なステップは**インストール**ステップで、その目的はビルド成果物をその最終的な場所にコピーすることです。インストールステップは依存関係なしで開始するため、`zig build` を実行してもデフォルトでは何も起こりません。プロジェクトのビルドスクリプトはインストールするものの集合に追加する必要があり、これが上記の `installArtifact` 関数呼び出しが行うことです。

**出力**

    ├── build.zig
    ├── hello.zig
    ├── .zig-cache
    └── zig-out
        └── bin
            └── hello

この出力には2つの生成ディレクトリがあります: `.zig-cache` と `zig-out`。最初のものはその後のビルドをより速くするファイルを含みますが、これらのファイルはソース管理にチェックインされることを意図していません。このディレクトリはいつでも完全に削除できます。

2番目の `zig-out` は「インストールプレフィックス」です。これは標準的なファイルシステムの階層概念にマップされます。このディレクトリはプロジェクトによって選択されるのではなく、ユーザーが `zig build` の `--prefix` フラグ(`-p` の省略形)で選択します。

プロジェクト管理者として、このディレクトリに何を配置するかを選択しますが、ユーザーがシステムのどこにインストールするかを選択します。ビルドスクリプトがキャッシング、並行処理、構成可能性を破壊し、最終ユーザーを困らせるため、出力パスをハードコードすることはできません。

## アプリケーション実行のための便利なステップを追加する

ビルドコマンドから直接メインアプリケーションを実行する方法を提供するために、**実行**ステップを追加するのが一般的です。

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello World!\n", .{});
}
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
```

```bash
$ zig build run --summary all

Hello World!

Build Summary: 3/3 steps succeeded
run success
└─ run exe hello success 233us MaxRSS:1M
   └─ compile exe hello Debug native success 1s MaxRSS:118M
```

# 基本

## ユーザー提供のオプション

ビルドスクリプトをエンドユーザーだけでなく、プロジェクトの依存パッケージとして使用するプロジェクトにも設定可能にするために `b.option` を使用してください。

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
        }),
    });

    b.installArtifact(exe);
}
```

```bash
$ zig build --help

Usage: /home/ci/deps/zig-x86_64-linux-0.15.1/zig build [steps] [options]

Steps:
  install (default)            Copy build artifacts to prefix path
  uninstall                    Remove build artifacts from prefix path

General Options:
  -p, --prefix [path]          Where to install files (default: zig-out)
  --prefix-lib-dir [path]      Where to install libraries
  --prefix-exe-dir [path]      Where to install executables
  --prefix-include-dir [path]  Where to install C header files

  --release[=mode]             Request release mode, optionally specifying a
                               preferred optimization mode: fast, safe, small

  -fdarling,  -fno-darling     Integration with system-installed Darling to
                               execute macOS programs on Linux hosts
                               (default: no)
  -fqemu,     -fno-qemu        Integration with system-installed QEMU to execute
                               foreign-architecture programs on Linux hosts
                               (default: no)
  --libc-runtimes [path]       Enhances QEMU integration by providing dynamic libc
                               (e.g. glibc or musl) built for multiple foreign
                               architectures, allowing execution of non-native
                               programs that link with libc.
  -frosetta,  -fno-rosetta     Rely on Rosetta to execute x86_64 programs on
                               ARM64 macOS hosts. (default: no)
  -fwasmtime, -fno-wasmtime    Integration with system-installed wasmtime to
                               execute WASI binaries. (default: no)
  -fwine,     -fno-wine        Integration with system-installed Wine to execute
                               Windows programs on Linux hosts. (default: no)

  -h, --help                   Print this help and exit
  -l, --list-steps             Print available steps
  --verbose                    Print commands before executing them
  --color [auto|off|on]        Enable or disable colored error messages
  --prominent-compile-errors   Buffer compile errors and display at end
  --summary [mode]             Control the printing of the build summary
    all                        Print the build summary in its entirety
    new                        Omit cached steps
    failures                   (Default) Only print failed steps
    none                       Do not print the build summary
  -j<N>                        Limit concurrent jobs (default is to use all CPU cores)
  --maxrss <bytes>             Limit memory usage (default is to use available memory)
  --skip-oom-steps             Instead of failing, skip steps that would exceed --maxrss
  --fetch[=mode]               Fetch dependency tree (optionally choose laziness) and exit
    needed                     (Default) Lazy dependencies are fetched as needed
    all                        Lazy dependencies are always fetched
  --watch                      Continuously rebuild when source files are modified
  --debounce <ms>              Delay before rebuilding after changed file detected
  --webui[=ip]                 Enable the web interface on the given IP address
  --fuzz                       Continuously search for unit test failures (implies '--webui')
  --time-report                Force full rebuild and provide detailed information on
                               compilation time of Zig source code (implies '--webui')
     -fincremental             Enable incremental compilation
  -fno-incremental             Disable incremental compilation

Project-Specific Options:
  -Dwindows=[bool]             Target Microsoft Windows

System Integration Options:
  --search-prefix [path]       Add a path to look for binaries, libraries, headers
  --sysroot [path]             Set the system root directory (usually /)
  --libc [file]                Provide a file which specifies libc paths

  --system [pkgdir]            Disable package fetching; enable all integrations
  -fsys=[name]                 Enable a system integration
  -fno-sys=[name]              Disable a system integration

  Available System Integrations:                Enabled:
  (none)                                        -

Advanced Options:
  -freference-trace[=num]      How many lines of reference trace should be shown per compile error
  -fno-reference-trace         Disable reference trace
  -fallow-so-scripts           Allows .so files to be GNU ld scripts
  -fno-allow-so-scripts        (default) .so files must be ELF files
  --build-file [file]          Override path to build.zig
  --cache-dir [path]           Override path to local Zig cache directory
  --global-cache-dir [path]    Override path to global Zig cache directory
  --zig-lib-dir [arg]          Override path to Zig lib directory
  --build-runner [file]        Override path to build runner
  --seed [integer]             For shuffling dependency traversal order (default: random)
  --build-id[=style]           At a minor link-time expense, embeds a build ID in binaries
      fast                     8-byte non-cryptographic hash (COFF, ELF, WASM)
      sha1, tree               20-byte cryptographic hash (ELF, WASM)
      md5                      16-byte cryptographic hash (ELF)
      uuid                     16-byte random UUID (ELF, WASM)
      0x[hexstring]            Constant ID, maximum 32 bytes (ELF, WASM)
      none                     (default) No build ID
  --debug-log [scope]          Enable debugging the compiler
  --debug-pkg-config           Fail if unknown pkg-config flags encountered
  --debug-rt                   Debug compiler runtime libraries
  --verbose-link               Enable compiler debug output for linking
  --verbose-air                Enable compiler debug output for Zig AIR
  --verbose-llvm-ir[=file]     Enable compiler debug output for LLVM IR
  --verbose-llvm-bc=[file]     Enable compiler debug output for LLVM BC
  --verbose-cimport            Enable compiler debug output for C imports
  --verbose-cc                 Enable compiler debug output for C compilation
  --verbose-llvm-cpu-features  Enable compiler debug output for LLVM CPU features
```

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello World!\n", .{});
}
```

これらの行に特に注意してください:

    Project-Specific Options:
      -Dwindows=[bool]             Target Microsoft Windows

ヘルプメニューのこの部分は、`build.zig` ロジックを実行することに基づいて自動生成されます。ユーザーはこの方法でビルドスクリプトの設定オプションを発見できます。

## 標準設定オプション

以前は、Windowsをターゲットにしていることを示すためにブール値フラグを使用していました。ただし、より良くできます。

ほとんどのプロジェクトは、ターゲットと最適化設定を変更する能力を提供したいと考えています。標準的な命名規則にこれらのオプションを励ますために、Zigはヘルパー関数 `standardTargetOptions` と `standardOptimizeOption` を提供しています。

標準ターゲットオプションは、`zig build` を実行している人がビルドするターゲットを選択できます。デフォルトでは、どのターゲットも許可され、選択がないことはホストシステムをターゲットにすることを意味します。サポートされているターゲットセットを制限するための他のオプションが利用可能です。

標準最適化オプションは、`zig build` を実行している人が `Debug`、`ReleaseSafe`、`ReleaseFast`、`ReleaseSmall` の間で選択できます。デフォルトでは、リリースオプションのどれもビルドスクリプトによって望ましい選択肢ではなく、ユーザーがリリースビルドを作成するために決定を下さなければなりません。

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello World!\n", .{});
}
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) void);\n    const optimize = b.standardOptimizeOption(.);\n    const exe = b.addExecutable(.,\n    });\n\n    b.installArtifact(exe);\n}\n```

```bash
$ zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall --summary all

Build Summary: 3/3 steps succeeded
install success
└─ install hello success
   └─ compile exe hello ReleaseSmall x86_64-windows success 9s MaxRSS:155M
```

現在、`--help` メニューにはより多くのアイテムが含まれています:

    Project-Specific Options:
      -Dtarget=[string]            The CPU architecture, OS, and ABI to build for
      -Dcpu=[string]               Target CPU features to add or subtract
      -Doptimize=[enum]            Prioritize performance, safety, or binary size (-O flag)
                                     Supported Values:
                                       Debug
                                       ReleaseSafe
                                       ReleaseFast
                                       ReleaseSmall

これらのオプションを直接 `b.option` で作成することは完全に可能ですが、このAPIはこれらの頻繁に使用される設定に対する一般的に使用される命名規則を提供します。

ターミナル出力では、`-Dtarget=x86_64-windows -Doptimize=ReleaseSmall` を渡したことに注意してください。最初の例と比較して、インストールプレフィックスに異なるファイルが表示されるようになります:

    zig-out/
    └── bin
        └── hello.exe

## 条件付きコンパイルのためのオプション

ビルドスクリプトからプロジェクトのZigコードにオプションを渡すには、`Options` ステップを使用します。

```zig
const std = @import("std");
const config = @import("config");

const semver = std.SemanticVersion.parse(config.version) catch unreachable;

extern fn foo_bar() void;

pub fn main() !void
    std.debug.print("version:\n", .);

    if (config.have_libfoo)
}
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    });

    const version = b.option([]const u8, "version", "application version string") orelse "0.0.0";
    const enable_foo = detectWhetherToEnableLibFoo();

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "have_libfoo", enable_foo);

    exe.root_module.addOptions("config", options);

    b.installArtifact(exe);
}

fn detectWhetherToEnableLibFoo() bool
```

```bash
$ zig build -Dversion=1.2.3 --summary all

Build Summary: 4/4 steps succeeded
install success
└─ install app success
   └─ compile exe app Debug native success 1s MaxRSS:123M
      └─ options success
```

この例では、`@import("config")` によって提供されるデータはコンパイル時に既知であり、`@compileError` がトリガーされるのを防ぎます。`-Dversion=0.2.3` を渡していた場合、またはオプションを省略した場合、`app.zig` のコンパイルは「古すぎます」エラーで失敗していたでしょう。

## 静的ライブラリ

このビルドスクリプトはZigコードから静的ライブラリを作成し、それを使用する他のZigコードから実行可能ファイルも作成します。

```zig
export fn fizzbuzz(n: usize) ?[*:0]const u8 else
    } else if (n % 3 == 0)
    return null;
}
```

```zig
const std = @import("std");

extern fn fizzbuzz(n: usize) ?[*:0]const u8;

pub fn main() !void\n", .);
        } else\n", .);
        }
    }
    try bw.flush();
}
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) void);\n    const optimize = b.standardOptimizeOption(.);\n\n    const libfizzbuzz = b.addLibrary(.,\n    });\n\n    const exe = b.addExecutable(.,\n    });\n\n    exe.linkLibrary(libfizzbuzz);\n\n    b.installArtifact(libfizzbuzz);\n\n    if (b.option(bool, "enable-demo", "install the demo too") orelse false)\n}\n```

```bash
$ zig build --summary all

Build Summary: 3/3 steps succeeded
install success
└─ install fizzbuzz success
   └─ compile lib fizzbuzz Debug native success 142ms MaxRSS:86M
```

この場合、静的ライブラリだけがインストールされます:

    zig-out/
    └── lib
        └── libfizzbuzz.a

ただし、ビルドスクリプトにはデモもインストールするオプションが含まれています。さらに `-Denable-demo` を渡すと、インストールプレフィックスに以下が表示されます:

    zig-out/
    ├── bin
    │   └── demo
    └── lib
        └── libfizzbuzz.a

`addExecutable` への無条件呼び出しにもかかわらず、ビルドシステムは実際には、`demo` 実行可能ファイルを `-Denable-demo` でリクエストされない限りビルドするのに時間を無駄にしません。なぜなら、ビルドシステムは依存関係エッジを持つ有向非環状グラフに基づいているからです。

## 動的ライブラリ

ここで、[静的ライブラリ](#static-library)の例からすべてのファイルを同じにします。ただし、`build.zig` ファイルは変更されます。

```zig
const std = @import("std");

pub fn build(b: *std.Build) void);\n    const optimize = b.standardOptimizeOption(.);\n\n    const libfizzbuzz = b.addLibrary(.,\n        .root_module = b.createModule(.),\n    });\n\n    b.installArtifact(libfizzbuzz);\n}\n```

```bash
$ zig build --summary all

Build Summary: 3/3 steps succeeded
install success
└─ install fizzbuzz success
   └─ compile lib fizzbuzz Debug native success 10s MaxRSS:243M
```

**出力**

    zig-out
    └── lib
        ├── libfizzbuzz.so -> libfizzbuzz.so.1
        ├── libfizzbuzz.so.1 -> libfizzbuzz.so.1.2.3
        └── libfizzbuzz.so.1.2.3

静的ライブラリの例と同様に、実行可能ファイルをそれに対してリンクするには、次のようなコードを使用します:

``` zig
exe.linkLibrary(libfizzbuzz);
```

## テスト

個々のファイルは `zig test foo.zig` で直接テストできますが、より複雑な使用例はビルドスクリプト経由でテストの調整によって解決できます。

ビルドスクリプトを使用する場合、ユニットテストはビルドグラフの2つの異なるステップ、**コンパイル**ステップと**実行**ステップに分かれています。`addRunArtifact` への呼び出しがなく、これらの2つのステップ間に依存関係エッジを確立すると、ユニットテストは実行されません。

*コンパイル*ステップは、例えば[システムライブラリへのリンク](#linking-to-system-libraries)、ターゲットオプションの設定、または追加のコンパイル単位の追加によって、実行可能ファイル、ライブラリ、またはオブジェクトファイルと同じように設定できます。

*実行*ステップは、例えばホストがバイナリを実行できない場合に実行をスキップすることによって、任意の実行ステップと同じように設定できます。

ビルドシステムを使用してユニットテストを実行する場合、ビルドランナーとテストランナーは複数のユニットテストスイートを同時に実行し、出力を混ぜられることなく有意義な方法でテスト失敗を報告するために、*stdin* と *stdout* 経由で通信します。これは[ユニットテストで標準出力に書き込む](https://github.com/ziglang/zig/issues/15091)が問題である理由の1つです - この通信チャネルを妨害します。一方、このメカニズムは今後の機能を有効にします。これは[ユニットテストが*パニック*を期待できる](https://github.com/ziglang/zig/issues/1356)能力です。

```zig
const std = @import("std");

test "simple test"
```

```zig
const std = @import("std");

const test_targets = [_]std.Target.Query, // ネイティブ
    .,
    .,
};

pub fn build(b: *std.Build) !void {
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
}
```

```zig
$ zig build test --summary all
test
└─ run test
   └─ compile test Debug native 1 errors
/home/ci/actions-runner-website/_work/www.ziglang.org/www.ziglang.org/zig-code/build-system/unit-testing/main.zig:4:34: error: struct 'array_list.Aligned(i32,null)' has no member named 'init'
    var list = std.ArrayList(i32).init(std.testing.allocator);
               ~~~~~~~~~~~~~~~~~~^~~~~
/home/ci/deps/zig-x86_64-linux-0.15.1/lib/std/array_list.zig:606:12: note: struct declared here
    return struct);

         const run_unit_tests = b.addRunArtifact(unit_tests);
+        run_unit_tests.skip_foreign_checks = true;
         test_step.dependOn(&run_unit_tests.step);
     }
 }
```

<figure>
```const std = @import("std");

const test_targets = [_]std.Target.Query, // ネイティブ
    .,
    .,
};

pub fn build(b: *std.Build) !void {
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.skip_foreign_checks = true;
        test_step.dependOn(&run_unit_tests.step);
    }
}

// zig-doctest: build-system --collapseable -- test --summary all
```

```bash
$ zig build --summary all

Build Summary: 1/1 steps succeeded
install cached
```

## システムライブラリへのリンク

ライブラリ依存関係を満たすために、2つの選択肢があります:

1.  Zigビルドシステム経由でこれらのライブラリを提供します([パッケージ管理](#)と[静的ライブラリ](#static-library)を参照)。
2.  ホストシステムが提供するファイルを使用します。

アップストリームプロジェクト管理者の使用例については、Zigビルドシステム経由でこれらのライブラリを取得することで最小限の摩擦が提供され、設定力をこれらの管理者の手に置きます。この方法でビルドするすべての人は相互に再現可能で一貫した結果を得られ、あらゆるオペレーティングシステムで機能し、クロスコンパイルもサポートします。さらに、プロジェクトが完全な精度で、ビルドする依存関係ツリー全体の正確なバージョンを決定できます。これは一般的に好ましい外部ライブラリに依存する方法であると予想されています。

ただし、Debian、Homebrew、Nixなどのリポジトリにソフトウェアをパッケージングする使用例については、システムライブラリに対してリンクすることが必須です。したがって、ビルドスクリプトは[ビルドモードを検出](https://github.com/ziglang/zig/issues/14281)して、それに応じて設定する必要があります。

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    });

    exe.linkSystemLibrary("z");
    exe.linkLibC();

    b.installArtifact(exe);
}
```

```bash
$ zig build --summary all

Build Summary: 3/3 steps succeeded
install success
└─ install zip success
   └─ compile exe zip Debug native success 13s MaxRSS:220M
```

`zig build` のユーザーは `--search-prefix` を使用して、静的および動的ライブラリを見つけるために「システムディレクトリ」と見なされるディレクトリを提供できます。

# ファイルの生成

## システムツールの実行

このバージョンのhello worldは同じパスに `word.txt` ファイルを見つけることを期待し、JSONファイルから開始してシステムツールを使用してそれを生成したいと考えています。

システム依存はプロジェクトをユーザーがビルドするのを困難にします。例えば、このビルドスクリプトは `jq` に依存していますが、ほとんどのLinuxディストリビューションにはデフォルトでは存在せず、Windowsユーザーにとって不慣れなツールかもしれません。

次のセクションは `jq` をソースツリーに含まれるZigツールで置き換えます。これが推奨されるアプローチです。

**`words.json`**

``` json
```

```zig
const std = @import("std");

pub fn main() !void);
    defer self_exe_dir.close();

    const word = try self_exe_dir.readFileAlloc(arena, "word.txt", 1000);

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Hello\n", .);
    try stdout.flush();
}
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) void);\n    tool_run.addArgs(&.\"\n        , .),\n        \"-r\", // 選択された文字列の周りの引用符を省略するための生の出力\n    });\n    tool_run.addFileArg(b.path(\"words.json\"));\n\n    const output = tool_run.captureStdOut();\n\n    b.getInstallStep().dependOn(&b.addInstallFileWithDir(output, .prefix, \"word.txt\").step);\n\n    const target = b.standardTargetOptions(.);\n    const optimize = b.standardOptimizeOption(.);\n    const exe = b.addExecutable(.,\n    });\n\n    const install_artifact = b.addInstallArtifact(exe, .,\n    });\n    b.getInstallStep().dependOn(&install_artifact.step);\n}\n```

```bash
$ zig build -Dlanguage=ja --summary all

Build Summary: 5/5 steps succeeded
install success
├─ install generated to word.txt success
│  └─ run jq success 100ms MaxRSS:3M
└─ install hello success
   └─ compile exe hello Debug native success 1s MaxRSS:119M
```

**出力**

    zig-out
    ├── hello
    └── word.txt

`captureStdOut` がどのように `jq` 呼び出しの出力を含む一時ファイルを作成するかに注意してください。

## プロジェクトのツールの実行

このバージョンのhello worldは同じパスに `word.txt` ファイルを見つけることを期待し、JSONファイルをZigプログラムで呼び出すことにより、ビルド時にそれを生成したいと考えています。

**`tools/words.json`**

``` json
```

```zig
const std = @import("std");

pub fn main() !void);
    defer self_exe_dir.close();

    const word = try self_exe_dir.readFileAlloc(arena, "word.txt", 1000);

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Hello\n", .);
    try stdout.flush();
}
```

```zig
const std = @import("std");

const usage =
    \\Usage: ./word_select [options]
    \\
    \\Options:
    \\  --input-file INPUT_JSON_FILE
    \\  --output-file OUTPUT_TXT_FILE
    \\  --lang LANG
    \\
;

pub fn main() !void else if (std.mem.eql(u8, "--input-file", arg))'", .);
                if (opt_input_file_path != null) fatal("duplicated argument", .);
                opt_input_file_path = args[i];
            } else if (std.mem.eql(u8, "--output-file", arg))'", .);
                if (opt_output_file_path != null) fatal("duplicated argument", .);
                opt_output_file_path = args[i];
            } else if (std.mem.eql(u8, "--lang", arg))'", .);
                if (opt_lang != null) fatal("duplicated argument", .);
                opt_lang = args[i];
            } else'", .);
            }
        }
    }

    const input_file_path = opt_input_file_path orelse fatal("missing --input-file", .);
    const output_file_path = opt_output_file_path orelse fatal("missing --output-file", .);
    const lang = opt_lang orelse fatal("missing --lang", .);

    var input_file = std.fs.cwd().openFile(input_file_path, .) catch |err|':\", .);
    };
    defer input_file.close();
    var input_file_buffer: [1000]u8 = undefined;
    var input_file_reader = input_file.reader(&input_file_buffer);

    var output_file = std.fs.cwd().createFile(output_file_path, .) catch |err|':\", .);
    };
    defer output_file.close();

    var json_reader: std.json.Reader = .init(arena, &input_file_reader.interface);
    var words = try std.json.ArrayHashMap([]const u8).jsonParse(arena, &json_reader, .);

    const w = words.map.get(lang) orelse fatal("Lang not found in JSON file", .);

    try output_file.writeAll(w);
    return std.process.cleanExit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    });

    const tool_step = b.addRunArtifact(tool);
    tool_step.addArg("--input-file");
    tool_step.addFileArg(b.path("tools/words.json"));
    tool_step.addArg("--output-file");
    const output = tool_step.addOutputFileArg("word.txt");
    tool_step.addArgs(&.);

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(output, .prefix, "word.txt").step);

    const target = b.standardTargetOptions(.);
    const optimize = b.standardOptimizeOption(.);
    const exe = b.addExecutable(.,
    });

    const install_artifact = b.addInstallArtifact(exe, .,
    });
    b.getInstallStep().dependOn(&install_artifact.step);
}
```

```bash
$ zig build --summary all

Build Summary: 6/6 steps succeeded
install success
├─ install generated to word.txt success
│  └─ run exe word_select (word.txt) success 476us MaxRSS:1M
│     └─ compile exe word_select Debug native success 1s MaxRSS:123M
└─ install hello success
   └─ compile exe hello Debug native success 1s MaxRSS:142M
```

**出力**

    zig-out
    ├── hello
    └── word.txt

## `@embedFile`用のアセットの生成

このバージョンのhello worldは、ビルド時に生成されたアセットを `@embedFile` したいと考えており、Zigで書かれたツールを使用してそれを生成します。

**`tools/words.json`**

``` json
```

```zig
const std = @import("std");
const word = @embedFile("word");

pub fn main() !void\n", .);
}
```

```zig
const std = @import("std");

const usage =
    \\Usage: ./word_select [options]
    \\
    \\Options:
    \\  --input-file INPUT_JSON_FILE
    \\  --output-file OUTPUT_TXT_FILE
    \\  --lang LANG
    \\
;

pub fn main() !void else if (std.mem.eql(u8, "--input-file", arg))'", .);
                if (opt_input_file_path != null) fatal("duplicated argument", .);
                opt_input_file_path = args[i];
            } else if (std.mem.eql(u8, "--output-file", arg))'", .);
                if (opt_output_file_path != null) fatal("duplicated argument", .);
                opt_output_file_path = args[i];
            } else if (std.mem.eql(u8, "--lang", arg))'", .);
                if (opt_lang != null) fatal("duplicated argument", .);
                opt_lang = args[i];
            } else'", .);
            }
        }
    }

    const input_file_path = opt_input_file_path orelse fatal("missing --input-file", .);
    const output_file_path = opt_output_file_path orelse fatal("missing --output-file", .);
    const lang = opt_lang orelse fatal("missing --lang", .);

    var input_file = std.fs.cwd().openFile(input_file_path, .) catch |err|':\", .);
    };
    defer input_file.close();
    var input_file_buffer: [1000]u8 = undefined;
    var input_file_reader = input_file.reader(&input_file_buffer);

    var output_file = std.fs.cwd().createFile(output_file_path, .) catch |err|':\", .);
    };
    defer output_file.close();

    var json_reader: std.json.Reader = .init(arena, &input_file_reader.interface);
    var words = try std.json.ArrayHashMap([]const u8).jsonParse(arena, &json_reader, .);

    const w = words.map.get(lang) orelse fatal("Lang not found in JSON file", .);

    try output_file.writeAll(w);
    return std.process.cleanExit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    });

    const tool_step = b.addRunArtifact(tool);
    tool_step.addArg("--input-file");
    tool_step.addFileArg(b.path("tools/words.json"));
    tool_step.addArg("--output-file");
    const output = tool_step.addOutputFileArg("word.txt");
    tool_step.addArgs(&.);

    const target = b.standardTargetOptions(.);
    const optimize = b.standardOptimizeOption(.);
    const exe = b.addExecutable(.,
    });

    exe.root_module.addAnonymousImport("word", .);

    b.installArtifact(exe);
}
```

```bash
$ zig build --summary all

Build Summary: 5/5 steps succeeded
install success
└─ install hello success
   └─ compile exe hello Debug native success 1s MaxRSS:120M
      └─ run exe word_select (word.txt) success 11ms MaxRSS:1M
         └─ compile exe word_select Debug native success 1s MaxRSS:122M
```

**出力**

    zig-out/
    └── bin
        └── hello

## Zigソースコードの生成

このビルドファイルはZigプログラムを使用してZigファイルを生成し、それをメインプログラムにモジュール依存関係として公開します。

```zig
const std = @import("std");
const Person = @import("person").Person;

pub fn main() !void;
    std.log.info("Hello\n", .);
}
```

```zig
const std = @import("std");

pub fn main() !void);

    const output_file_path = args[1];

    var output_file = std.fs.cwd().createFile(output_file_path, .) catch |err|':\", .);
    };
    defer output_file.close();

    try output_file.writeAll(
        \\pub const Person = struct;
    );
    return std.process.cleanExit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    });

    const tool_step = b.addRunArtifact(tool);
    const output = tool_step.addOutputFileArg("person.zig");

    const target = b.standardTargetOptions(.);
    const optimize = b.standardOptimizeOption(.);
    const exe = b.addExecutable(.,
    });

    exe.root_module.addAnonymousImport("person", .);

    b.installArtifact(exe);
}
```

```bash
$ zig build --summary all

Build Summary: 5/5 steps succeeded
install success
└─ install hello success
   └─ compile exe hello Debug native success 1s MaxRSS:121M
      └─ run exe generate_struct (person.zig) success 358us MaxRSS:3M
         └─ compile exe generate_struct Debug native success 2s MaxRSS:121M
```

**出力**

    zig-out/
    └── bin
        └── hello

## 1つ以上の生成されたファイルの処理

**WriteFiles** ステップは、親ディレクトリを共有する1つ以上のファイルを生成する方法を提供します。生成されたディレクトリはローカル `.zig-cache` 内に存在し、各生成されたファイルは独立して `std.Build.LazyPath` として利用可能です。親ディレクトリ自体も `LazyPath` として利用可能です。

このAPIは任意の文字列を生成されたディレクトリに書き込むことと、それにファイルをコピーすることをサポートします。

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello World!\n", .{});
}
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) !void {
    });

    const version = b.option([]const u8, "version", "application version string") orelse "0.0.0";

    const wf = b.addWriteFiles();
    const app_exe_name = b.fmt("project/", .);
    _ = wf.addCopyFile(exe.getEmittedBin(), app_exe_name);
    _ = wf.add("project/version.txt", version);

    const tar = b.addSystemCommand(&.);
    tar.setCwd(wf.getDirectory());
    const out_file = tar.addOutputFileArg("project.tar.gz");
    tar.addArgs(&.);

    const install_tar = b.addInstallFileWithDir(out_file, .prefix, "project.tar.gz");
    b.getInstallStep().dependOn(&install_tar.step);
}
```

```bash
$ zig build --summary all

Build Summary: 5/5 steps succeeded
install success
└─ install generated to project.tar.gz success
   └─ run tar (project.tar.gz) success 981ms MaxRSS:2M
      └─ WriteFile project/app success
         └─ compile exe app Debug native success 1s MaxRSS:126M
```

**出力**

    zig-out/
    └── project.tar.gz

## ソースファイルをインプレースで変更する

稀ですが、プロジェクトがバージョン管理に生成されたファイルをコミットするという場合があります。これは、生成されたファイルがめったに更新されず、更新プロセスに多くのシステム依存を持っている場合に役立ちますが、*更新プロセス中のみ*に。

これについて、**WriteFiles** はこのタスクを実行する方法を提供します。これは[このの機能が将来のZigバージョンで独自のBuildステップに抽出される](https://github.com/ziglang/zig/issues/14944)機能です。

この機能を慎重に扱ってください。通常のビルドプロセス中には使用せず、ソースファイルを更新する意図でデベロッパーが実行するユーティリティとして使用してください。その後、バージョン管理にコミットされます。通常のビルドプロセス中に行われる場合、キャッシングと並行処理の バグが発生します。

```zig
const std = @import("std");

pub fn main() !void);

    const output_file_path = args[1];

    var output_file = std.fs.cwd().createFile(output_file_path, .) catch |err|':\", .);
    };
    defer output_file.close();

    try output_file.writeAll(
        \\pub const Header = extern struct;
    );
    return std.process.cleanExit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn
```

```zig
const std = @import("std");
const Protocol = @import("protocol.zig");

pub fn main() !void\n", .);
}
```

```zig
pub const Header = extern struct;
```

```zig
const std = @import("std");

pub fn build(b: *std.Build) void);\n    const exe = b.addExecutable(.);\n    b.installArtifact(exe);\n\n    const proto_gen = b.addExecutable(.);\n\n    const run = b.addRunArtifact(proto_gen);\n    const generated_protocol_file = run.addOutputFileArg(\"protocol.zig\");\n\n    const wf = b.addUpdateSourceFiles();\n    wf.addCopyFileToSource(generated_protocol_file, \"src/protocol.zig\");\n\n    const update_protocol_step = b.step(\"update-protocol\", \"update src/protocol.zig to latest\");\n    update_protocol_step.dependOn(&wf.step);\n}\n\nfn detectWhetherToEnableLibFoo() bool\n```

``` shell
$ zig build update-protocol --summary all
Build Summary: 4/4 steps succeeded
update-protocol success
└─ WriteFile success
   └─ run proto_gen (protocol.zig) success 401us MaxRSS:1M
      └─ zig build-exe proto_gen Debug native success 1s MaxRSS:183M
```

このコマンドを実行した後、`src/protocol.zig` がインプレースで更新されます。

# 便利な例

## 複数のターゲットに対してビルドしてリリースを作成

この例では、インストールパス内に各ターゲットのビルドを別のサブディレクトリに配置するために、`InstallArtifact` ステップを作成するときにいくつかのデフォルトを変更します。

```zig
const std = @import("std");

const targets: []const std.Target.Query = &.,
    .,
    .,
    .,
    .,
};

pub fn build(b: *std.Build) !void {
        });

        const target_output = b.addInstallArtifact(exe, .,
            },
        });

        b.getInstallStep().dependOn(&target_output.step);
    }
}
```

```bash
$ zig build --summary all

Build Summary: 11/11 steps succeeded
install success
├─ install hello success
│  └─ compile exe hello ReleaseSafe aarch64-macos success 39s MaxRSS:222M
├─ install hello success
│  └─ compile exe hello ReleaseSafe aarch64-linux success 39s MaxRSS:228M
├─ install hello success
│  └─ compile exe hello ReleaseSafe x86_64-linux-gnu success 38s MaxRSS:204M
├─ install hello success
│  └─ compile exe hello ReleaseSafe x86_64-linux-musl success 38s MaxRSS:203M
└─ install hello success
   └─ compile exe hello ReleaseSafe x86_64-windows success 37s MaxRSS:215M
```

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello World!\n", .{});
}
```

**出力**

    zig-out
    ├── aarch64-linux
    │   └── hello
    ├── aarch64-macos
    │   └── hello
    ├── x86_64-linux-gnu
    │   └── hello
    ├── x86_64-linux-musl
    │   └── hello
    └── x86_64-windows
        ├── hello.exe
        └── hello.pdb
