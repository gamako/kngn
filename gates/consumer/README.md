# The external-consumer gate

**This is not an example, and not a scaffold.** If you are starting an application against
`kit`, copy [`template/`](../../template/) instead and read
[`docs/app-authoring.md`](../../docs/app-authoring.md). Nothing here is meant to be a
starting point; it exists so a path with no other traffic keeps working.

## What it guards

`kit` re-exports facades that resolve against system libraries **on the executable side**:
`kit.audio` (AudioToolbox and CoreAudio, ALSA, ole32) and `kit.midi` (CoreMIDI). An external
package reaches them through `setupConsumerExe`, and if that helper stops attaching the
libraries the failure is an undefined symbol at link time — invisible to every check that
only asks whether the build succeeded, because until this directory existed **no build
anywhere reached those libraries through the external path**. The reference application
does not use audio, and the template makes no sound.

Two rules follow from how the failure appears, and both have to be kept:

- **Call the API for real.** Naming a type (`_ = kit.audio;`) emits no symbol reference, so
  it links cleanly whether or not the libraries are attached, and proves nothing. Each
  source here calls `open` and `close`.
- **One executable per capability.** `gate-audio` asks only for `.enable_audio`, `gate-midi`
  only for `.enable_midi`. A single mixed executable would stop at the first missing
  capability and hide the other, and it would blur the fact that MIDI resolves against a
  framework on macOS only — everywhere else `kit.midi` is the null backend, so building it
  there shows that the facade still compiles for a consumer, not that a framework was found.

`build_helpers/` is a real copy of `kngn/build_helpers/`, not a symlink: a symlink does not
survive a Windows checkout, which would make this gate unbuildable exactly where `ole32` is
the thing being guarded. The parent fails configuration if a copy drifts by one byte, so
staleness cannot happen quietly.

## Running it

```bash
zig build check-consumer   # from the repository root
cd gates/consumer && zig build gate
```

Both are also reached by `zig build test` and by `zig build -Dinstall-all=true`.

The gate covers the **host** target and the host's default backend. `-Dtarget` does not
reach a child build, and no backend is forced, so `ole32` and ALSA are only really linked
when the gate runs on Windows and Linux respectively.
