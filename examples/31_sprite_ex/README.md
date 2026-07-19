# 31: SpriteEx（kit.gfx）

`drawSpriteEx` のデモ。同一 `usako.png` に対して plain / flip / 整数倍 scale / RGB tint / source rect 切り出しを固定配置で並べる。

## 実行

```bash
zig build run-example_31
```

ヘッドレス検証:

```bash
cat > /tmp/ex31.txt <<'EOF'
step 1
snapshot fb /tmp/ex31-fb.png
digest fb
expect fb crc=DF9AE909
quit
EOF
VP_HEADLESS=1 VP_HARNESS_SCRIPT=/tmp/ex31.txt VP_HARNESS_OUT=/tmp zig build run-example_31
```

固定 CRC（640×360・Release 既定・決定的配置）: `DF9AE909`

## 操作

- **ESC / Q**: 終了

## 依存

`@import("kit").gfx`（TASK-111.2）。named module `sprite` ではなく kit 公開面を直接検証する。
