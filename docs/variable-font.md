# 可変フォント（OpenType Font Variations）API

`libs/font` の TrueType（glyf）可変フォント対応の使い方。軸 API は `OutlineFont` インスタンス局所で、
描画キャッシュと advance キャッシュは軸変更時に無効化・再構築される。

## 概要

| テーブル | 役割 |
|----------|------|
| `fvar` | 軸定義・named instance（必須で可変とみなす） |
| `avar` | 正規化座標の非線形マップ（任意） |
| `gvar` | glyf 点列 / composite offset の tuple 変分 |
| `HVAR` | advance 変分（優先。無ければ gvar phantom） |

- **CFF2 可変**は未対応（`FontFace.init` → `error.Unsupported`）。
- **pixelMetrics**（ascender 等）は MVAR 非対応のため **軸非依存の近似**（default インスタンス由来）。

## 基本的な使い方

```zig
const font = @import("font");

const face = try font.FontFace.init(ttf_bytes);
var of = font.OutlineFont.init(allocator, &face, 48);
defer of.deinit();

// 軸数・tag・範囲
const n = of.axisCount(); // 0 = 非可変
if (n > 0) {
    const tag = of.axisTag(0).?; // e.g. "wght"
    const range = of.axisRange(0).?; // .min / .def / .max
    _ = tag;
    _ = range;
}

// design space で 1 軸設定（範囲外は clamp。未知 tag / 非可変は Unsupported）
const wght = [4]u8{ 'w', 'g', 'h', 't' };
try of.setAxis(&wght, 700);

// 全軸一括
try of.setAxes(&.{700}); // len == axisCount

// named instance（fvar の index）
try of.selectNamedInstance(0);

// default に戻す
try of.resetAxes();

// 読み取り
_ = of.axisValue(0);
var norm: [16]f32 = undefined;
of.normalizedAxes(&norm); // avar 後の正規化座標
```

## キャッシュと advance

- **ラスタキャッシュ** / **sbix カラーキャッシュ**: `setAxis` / `setAxes` / `selectNamedInstance` / `resetAxes` で clear。
- **advance_cache**（`?[]f32`、numGlyphs 長）: 軸変更時に **eager 構築**。
  - `measure` / カラー描画の送りは構築済み cache を read-only 参照（毎フレーム gvar/HVAR を decode しない）。
  - 確保失敗は軸変更 API が `error.OutOfMemory` を返す。
- **advance 優先順位**:
  1. composite で `USE_MY_METRICS` が在る → **最後**に現れた component の advance（再帰で HVAR > phantom > hmtx）
  2. それ以外 → 当該 gid の HVAR > gvar phantom > hmtx

## composite と gvar

- gvar の点番号は **component index**（展開後の輪郭点ではない）。
- デルタは `ARGS_ARE_XY_VALUES` の **配置 offset のみ**に加算。scale / 2×2 は変分しない。
- offset の SCALED_COMPONENT_OFFSET 規則は **デルタ適用後**に既存どおり適用。
- composite では **IUP しない**（未参照 component のデルタは 0）。
- 点マッチ composite（非 XY）は低層 `Glyf` で `Unsupported`、`OutlineFont` 公開経路では `InvalidFont`。

## エラー方針

| 状況 | 結果 |
|------|------|
| 非可変で `setAxis` | `error.Unsupported` |
| 壊れた fvar/avar/gvar/HVAR | `FontFace.init` → `error.InvalidFont` |
| テーブル不在 | 非可変 / default 外形 / phantom fallback |
| 軸変更時 OOM | `error.OutOfMemory` |

## 関連

- 設計: トップ階層 `docs/plans/task-25.15-variable-font-design.md`
- 実装: `libs/font/src/{fvar,avar,gvar,hvar,glyf,outline_font,var_common}.zig`
- テスト: `zig build test-font`
