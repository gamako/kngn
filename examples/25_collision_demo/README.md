# Example 25: Collision demo

Uses `kit.gmath` AABB / circle tests to bounce a ball off the four walls and two side AABB
paddles at a fixed 60 Hz. On a collision tick the ball turns red.

**Hot-path declaration**: simulation advances one tick per `pollEvents()` iteration; drawing is a
per-frame full-framebuffer loop. gmath is inline, allocation-free, and O(1).

## Controls

- **ESC**: quit

(Paddles are fixed; there is no player input beyond quit.)

## Run

```bash
zig build run-example_25
```
