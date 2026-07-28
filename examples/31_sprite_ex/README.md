# Example 31: SpriteEx (`kit.gfx`)

Demo of `drawSpriteEx`. The same `usako.png` is drawn in fixed placements: plain / flip /
integer scale / RGB tint / source-rect crop.

## Run

```bash
zig build run-example_31
```

Headless check:

```bash
cat > /tmp/ex31.txt <<'EOF'
step 1
snapshot fb /tmp/ex31-fb.png
digest fb
expect fb crc=DF9AE909
quit
EOF
KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT=/tmp/ex31.txt KNGN_HARNESS_OUT=/tmp zig build run-example_31
```

Fixed CRC (640×360, Release default, deterministic layout): `DF9AE909`

Harness command language: [`docs/harness.md`](../../docs/harness.md).

## Controls

- **ESC / Q**: quit

## Dependencies

`@import("kit").gfx` (not the named `sprite` module — exercises the kit public surface directly).
