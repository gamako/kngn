# Text input and IME

Everything a single-line text field needs that is not the widget call itself: switching the
platform's input method on, placing its candidate window, receiving text that is still being
composed, and connecting the clipboard. `libs/gui` owns the editing model and the application
owns the window, so these are the seams between them.

`examples/28_text_input` is the worked example and exercises all of it.

## The published names

| Name | What it is for | Source |
|---|---|---|
| `gui.Context.textInputId(id, buffer, opts)` | The field itself: caret, selection, scrolling, editing keys | [`libs/gui/src/widgets.zig`](../libs/gui/src/widgets.zig) |
| `gui.Context.wantsTextInput()` | Whether the focus is on a text field — the value the input method is switched with | [`libs/gui/src/context.zig`](../libs/gui/src/context.zig) |
| `gui.Context.setComposition(state)` | Hand the text being composed to the field, once per frame | [`libs/gui/src/context.zig`](../libs/gui/src/context.zig) |
| `TextInputOpts.paste_text` | The string to paste on this frame, or null | [`libs/gui/src/widgets.zig`](../libs/gui/src/widgets.zig) |
| `TextInputResult.copy_request` | What the field wants put on the clipboard | [`libs/gui/src/widgets.zig`](../libs/gui/src/widgets.zig) |
| `TextInputResult.caret_rect` | Where the caret is, for placing the candidate window | [`libs/gui/src/widgets.zig`](../libs/gui/src/widgets.zig) |
| `platform.Window.setTextInputActive(active)` | Turn the platform input method on and off | [`core/platform.zig`](../core/platform.zig) |
| `platform.Window.setCompositionRect(x, y, w, h)` | Where the candidate window should appear | [`core/platform.zig`](../core/platform.zig) |
| `platform.Window.getCompositionSnapshot(buf)` | The text currently being composed | [`core/platform.zig`](../core/platform.zig) |
| `platform.setClipboardText` / `getClipboardText` | The system clipboard | [`core/platform.zig`](../core/platform.zig) |
| `kit.toGuiEvent(ev)` | Platform event to interface event, typed characters included | [`kit/kit.zig`](../kit/kit.zig) |

The editing model behind the widget — `TextBuffer`, `TextLayout`, `SelectionState`, `hitTest`,
`wordRange` — is [`libs/gui/src/text_edit.zig`](../libs/gui/src/text_edit.zig), and its doc
comment is the contract.

## The order within a frame

1. Drain events. `kit.toGuiEvent` covers all of them the interface reacts to; on a
   `composition_changed` also read `getCompositionSnapshot` into a buffer you own.
2. `beginFrame`.
3. `setComposition` with what the snapshot last reported, before building the field.
4. Build the field with `textInputId`, passing `paste_text` if this frame is a paste.
5. `endFrame`. **The focus settles here**, so nothing before this point knows where it ended up.
6. Act on the result: put `copy_request` on the clipboard, and turn `caret_rect` into a window
   rectangle for `setCompositionRect`.
7. `setTextInputActive(ctx.wantsTextInput())`, **before the next `pollEvents`**.

## What to know before writing it

**`wantsKeyboard` is not the predicate for an input method.** It is true whenever *any* widget
holds the focus — a button, a checkbox, a slider — because keyboard focus is not specific to
text. Driving an IME from it switches the input method on while the user is tabbing through
buttons. `wantsTextInput` is the one that answers about text fields.

**`wantsTextInput` answers yes or no; it does not name the field.** With several fields, ask
`focusedId()` which one. The two are separate questions and only the first one is what an input
method is switched with.

**Read it after `endFrame`.** The focus is resolved inside `endFrame` — an outside click clears
it there, and Tab moves it there — so during a frame it still reports what the previous frame
finished with.

**`caret_rect` is local to the field, and two conversions away from what the platform wants.**
Its origin is the field's top-left, so compose it with `getNodeRect(id)` after `endFrame` — and
that gives *logical* coordinates, while `setCompositionRect` takes **framebuffer pixels**. Under
`.logical` the two are the same; under `.physical` with a content scale above 1 they are not, and
handing over the logical rectangle puts the candidate window in the wrong place. Scale by the
frame's `content_scale`, the same factor `gui.render` is given (§10 of
[`docs/app-authoring.md`](app-authoring.md) has the split). `caret_rect` is null while the field
is unfocused; send an empty rectangle to release the candidate window, and skip the call on a
frame where the rectangle has not moved.

**Text being composed does not arrive as an interface event.** `composition_changed` is a
platform event with no `gui.InputEvent` form: `kit.toGuiEvent` returns null for it. It is the
signal to read `getCompositionSnapshot` and pass the result to `setComposition`. The snapshot is
latest-wins, and after a commit or a cancel it reports the newest revision with **empty** text —
so decide from the phase, not from the text being non-empty.

**The clipboard is three separate connections, and none of them is automatic.** The field never
touches the system clipboard itself: it reports what it wants (`copy_request`) and accepts what
it is given (`paste_text`).

- **Paste**: on the paste key, read `getClipboardText` into a buffer **you own** and pass that
  slice as `paste_text` when you build the field. It is consumed **synchronously, in that same
  call** — there is nothing to keep alive afterwards, and nothing to carry to a later frame.
- **Copy and cut**: `copy_request.text` comes back from the field on the frame the key was
  pressed and lives on **the frame arena**, so hand it to `setClipboardText` before the next
  `beginFrame` rather than storing the slice.

## What is out of scope

`textInputId` and `text_edit.zig` are **single-line only**. Newlines and control characters are
never inserted, and there is no multi-line layout, no soft wrapping and no vertical caret
movement. [ADR-024](adr/024_gui-scope-boundary-large-widget-subsystems.md) records why, and what
would have to be decided before that changes. Keyboard focus traversal, which a field takes part
in like any other control, is [ADR-021](adr/021_gui-keyboard-focus-traversal.md).

## Trying it without a display

The verification harness injects settled characters and drives a composition without a keyboard:
`inject char`, `inject commit` and `inject composition` are described in
[docs/harness.md](harness.md). What it cannot reproduce is the platform's own presentation — the
candidate window and where it lands — so `setCompositionRect` is checked on a real session by eye.

## Runnable references

- [`examples/28_text_input`](../examples/28_text_input) — several fields, IME and clipboard: the
  complete example.
- [`examples/21_char_input`](../examples/21_char_input) — `char_input` and `composition_changed`
  handled directly, without a widget.
- [`examples/27_selectable_label`](../examples/27_selectable_label) — selection and copy on text
  that cannot be edited.
