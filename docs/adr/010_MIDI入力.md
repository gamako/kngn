# ADR-010: MIDI 入力 facade

- Status: Accepted
- Date: 2026-07-17
- Scope: TASK-115.1 の OS 非依存骨格

## 目的と非スコープ

MIDI 実機 backend に先行して、OS 非依存の型、ポーリング facade、null backend、harness
synthetic input、MIDI monitor example の契約を固定する。115.1 では MIDI 出力、sysex、clock、
modular への結線、CoreMIDI/ALSA の実機実装は扱わない。

## 公開型と facade

`core/platform_types.zig` を共有型の単一ソースとし、次を定義する。

- `MidiDeviceId = u32`
- `MidiEvent = note_on | note_off | cc` の exhaustive union
- note/controller/value は MIDI 標準の `0..127` を `u8` で保持
- すべての payload に `device_id` を保持
- `note_off` の `velocity` は release velocity

`core/midi.zig` は型を再エクスポートし、`midi.open(allocator)` で `midi.Device` を返す。
`Device.pollMidi()` は1件ずつイベントを返し、空なら `null`、`Device.close()` は終了処理を行う。
115.1 の全対象 OS は `core/midi_null.zig` を選択し、open は成功、poll は常に `null`、close は
no-op とする。harness が有効な場合は native backend を開かず、harness FIFO を main thread
から読む。

## `platform.Event` に追加しない理由

MIDI は Window イベントと異なる受信頻度・所有モデルを持ち、受信をポーリングとして独立させ
られる。`platform.Event` に variant を加えると既存 consumer の exhaustive switch に cross-cutting
な修正が必要になるため、既存 union は変更しない。

## 所有モデルと将来の境界

`midi.Device` と `pollMidi()` は main thread が所有する。`MidiEvent` は値コピーで consumer に渡す。
115.1 の null backend と harness 注入は単一 thread で動作し、atomic/ring は追加しない。

115.2/115.4 では、OS callback を single producer、`pollMidi()` を single consumer とする
SPSC queue を backend 側に置く。callback 内では alloc、lock、IO、panic を行わない。既存の
`libs/synth/src/ring.zig` を後続実装の再利用候補とし、core から libs への新しい依存例外は
115.1 では増やさない。

## Harness 契約

注入文法は次のとおりで、synthetic device id は常に `0` とする。

```text
inject midi note_on <note> <vel>
inject midi note_off <note> <release_vel>
inject midi cc <num> <val>
```

範囲外、未知 event、引数不足/過多は fail-fast で拒否し、queue/state を変更しない。`note_on`
の velocity `0` は `note_off` に正規化する。live command は既存の record 機構で raw command
のまま記録し、replay でも同じ parser を通す。

組み込み probe 名は `midi`、snapshot は持たず digest 専用とする。digest の wire format は
次で固定する。

```text
midi device=0 note_count=.. notes=<32hex> cc_count=.. cc=<256hex>
```

`notes` は note 0..127 の押下 bitset を昇順の16 bytesで表す。`cc` は controller 0..127 を
昇順に2桁 hex で連結し、未設定値は `--` とする。出力は常に固定順で、custom probe と同じ
`buf[1024]` 契約を守る。harness state は注入時点で更新するため、app がまだ drain していなくても
最後に注入された論理状態を digest できる。

## 後続タスクへの引き継ぎ

115.2/115.4 は実機 OS callback、device enumeration/open、callback→SPSC→main-thread poll drain
を追加する。backend はこの型値域、所有モデル、FIFO の順序、callback の no-alloc/no-lock/no-IO
契約を維持し、`platform.Event` を拡張しない。

## ホットパス宣言

115.1 の MIDI 受信処理はイベント時のみ。null backend/harness の queue/state 更新と digest は
command/event 処理時だけで、thread、atomic、SPSC、RT 毎サンプル経路はない。monitor の描画は
フレーム毎だが固定サイズの既存 framebuffer 矩形描画であり、RT 経路ではない。
