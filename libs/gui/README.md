# libs/gui

video-proto 用の immediate-mode GUI ライブラリ。platform 非依存の standalone で、
`cd libs/gui && zig build test` で単体テストが回る。

## 構成

| ファイル | 内容 |
|---|---|
| `src/gui.zig` | 公開 API root |
| `src/geom.zig` | Rect / Vec2 / RenderTarget |
| `src/color.zig` | Color（straight alpha、canonical BGRA 0xAARRGGBB） |
| `src/draw.zig` | DrawList（clip 焼き込み式 draw cmd） |
| `src/font.zig` | BitmapFont（ASCII 固定幅、comptime BDF パーサ） |
| `src/render.zig` | DrawList → ピクセルバッファのソフトウェアレンダラ |
| `src/input.zig` | 入力集約（platform 非依存の InputEvent） |
| `src/id.zig` | widget ID（FNV-1a）+ IdStack |
| `src/state.zig` | hot / active / focused |
| `src/context.zig` | Context（フレームライフサイクル + ツリー構築 + hit-test） |
| `src/layout.zig` | Flex レイアウトエンジン（measure / place） |
| `src/style.zig` | ウィジェット共通スタイル定義（色 / 寸法 / パディング等） |
| `src/widgets.zig` | 基本ウィジェット実装（Button / Label / ColorSwatch / Slider / HSV ピッカー / ScrollArea / checkbox / toggle / radio） |

## フレームの流れ

```zig
ctx.beginFrame(fb.width, fb.height);
// pushEvent → widget（前フレーム rect で同期 hit-test）→ beginBox/label/endBox でツリー構築
ctx.endFrame(); // layout 確定 + draw cmd 発行 + rect キャッシュ更新
gui.render(target, &ctx.draw_list, ctx.font);
```

## ウィジェット（`src/widgets.zig`。`ctx.<name>(...)` で呼ぶ）

Button / Label / ColorSwatch / Slider(i32,f32) / HSV ピッカー(svSquare,hueBar) / imageBox /
Splitter / ScrollArea に加え、bool トグル系（TASK-48）:

- `ctx.checkbox(label, *bool) bool` — □/■。クリックで反転し、変化したら true。
- `ctx.toggle(label, *bool) bool` — トグルスイッチ（ノブが左右に動く）。戻り値は checkbox と同じ。
- `ctx.radio(label, selected: bool) bool` — ○/◉。`selected` は表示専用、クリックされたら true（activated）。

いずれも自動 ID（label hash + id_stack）。glyph + label の**箱全体がクリック域**（button と同じ）。
radio group は選択状態を caller が管理する（IM 流。gui はグループ状態を持たない）:

```zig
if (ctx.radio("Pen", tool == .pen)) tool = .pen;
if (ctx.radio("Eraser", tool == .eraser)) tool = .eraser;
```

同一スコープに同ラベルを並べると ID が衝突するので、`~Id` 版か `id_stack.push(i)` スコープで回避する。

## レイアウトエンジンの制限事項

- wrap 非対応
- absolute positioning 非対応
- 主軸の整列（justify_content）は start のみ。右寄せ等は grow の箱を挟んで表現する
- shrink 非対応。子の合計が親を超える場合は overflow する（見た目は `clip_children` で抑制）
- fit の親の中の grow / percent 子は measure 段階で 0 扱い（fit 親はその分縮む）
- percent は親の content box（padding 控除後、gap 控除前）基準。floor で切り捨て、
  切り捨てで浮いた px は grow 子が吸収する
- `clip_children` は描画時のみ有効で、レイアウト計算には影響しない
