//! macOS CoreMIDI backend（TASK-115.2・ADR-010）。
//!
//! ## API 選定（legacy MIDIReadProc）
//!
//! 受信には `MIDIInputPortCreate` + `MIDIReadProc` を採用する。
//! SDK 上は deprecated で replacement は `MIDIInputPortCreateWithProtocol`（`MIDIReceiveBlock` +
//! `MIDIEventList`）だが、`MIDIReceiveBlock` は Objective-C block ABI のため、本プロジェクトの
//! 「`@cImport` せず `extern fn` に C 関数ポインタを渡す」方式には適さない。
//! 手書き extern は SDK の deprecation attribute を取り込まない。warning を隠すためだけの
//! 無関係 API は使わない。将来の MIDI 2 / block backend 置換点は本ファイルに隔離する。
//!
//! ## ホットパス宣言
//!
//! `midiReadProc`（CoreMIDI 管理の高優先度 receive thread・準 RT・毎イベント）では
//! alloc / lock / IO / panic / CF 操作 / ログを禁止し、固定長 SPSC ring への push と
//! MIDI 1.0 byte parsing のみ行う。`MIDINotifyProc` は topology dirty flag の atomic store のみ。
//! 列挙・接続変更・allocation は main thread の `pollMidi()`（dirty 時）または `open`/`close` のみ。
//!
//! ## スレッドモデル
//!
//! - producer: CoreMIDI receive thread（`midiReadProc`）
//! - consumer: `Device.pollMidi()` を呼ぶ main thread
//! - queue: `MidiEvent` 容量 1024（2 の冪）、head/tail は cache_line 分離
//! - note-on は 128 slot、CC は 32 slot を note-off 用に予約（満杯時は drop + atomic counter）

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");

pub const Error = error{ OpenFailed, OutOfMemory };

// ============================================================================
// CoreMIDI / CoreFoundation C ABI（最小サブセット。@cImport 不使用）
// ============================================================================
const c = struct {
    pub const OSStatus = i32;
    pub const ItemCount = usize; // MacTypes: unsigned long
    pub const MIDIObjectRef = u32;
    pub const MIDIClientRef = MIDIObjectRef;
    pub const MIDIPortRef = MIDIObjectRef;
    pub const MIDIEndpointRef = MIDIObjectRef;
    pub const MIDITimeStamp = u64;
    pub const MIDIUniqueID = i32;

    pub const CFTypeRef = ?*const anyopaque;
    pub const CFStringRef = ?*const opaque {};
    pub const CFAllocatorRef = ?*const anyopaque;
    pub const kCFStringEncodingUTF8: u32 = 0x0800_0100;

    /// pack(4) の可変長リスト。`packet` フィールドは置かない（Zig の align 8 が
    /// C の pack(4) 先頭 offset 4 と食い違うため、本文は `parsePacketListIntoRing` が
    /// バイト walk する）。
    pub const MIDIPacketList = extern struct {
        numPackets: u32,
    };

    // pack(4) MIDIPacket レイアウト（SDK CoreMIDI/MIDIServices.h）:
    //   timeStamp: u64 @0, length: u16 @8, data: [length] @10
    // MIDIPacketList: numPackets u32 @0, first packet @4
    pub const packet_list_header_size: usize = 4;
    pub const packet_data_offset: usize = 10; // within packet

    pub const MIDINotification = extern struct {
        messageID: i32,
        messageSize: u32,
    };

    pub const MIDIReadProc = *const fn (
        pktlist: *const MIDIPacketList,
        read_proc_ref_con: ?*anyopaque,
        src_conn_ref_con: ?*anyopaque,
    ) callconv(.c) void;

    pub const MIDINotifyProc = *const fn (
        message: *const MIDINotification,
        ref_con: ?*anyopaque,
    ) callconv(.c) void;

    pub extern "c" fn MIDIClientCreate(
        name: CFStringRef,
        notifyProc: ?MIDINotifyProc,
        notifyRefCon: ?*anyopaque,
        outClient: *MIDIClientRef,
    ) OSStatus;
    pub extern "c" fn MIDIClientDispose(client: MIDIClientRef) OSStatus;
    pub extern "c" fn MIDIInputPortCreate(
        client: MIDIClientRef,
        portName: CFStringRef,
        readProc: MIDIReadProc,
        refCon: ?*anyopaque,
        outPort: *MIDIPortRef,
    ) OSStatus;
    pub extern "c" fn MIDIPortDispose(port: MIDIPortRef) OSStatus;
    pub extern "c" fn MIDIPortConnectSource(
        port: MIDIPortRef,
        source: MIDIEndpointRef,
        connRefCon: ?*anyopaque,
    ) OSStatus;
    pub extern "c" fn MIDIPortDisconnectSource(port: MIDIPortRef, source: MIDIEndpointRef) OSStatus;
    pub extern "c" fn MIDIGetNumberOfSources() ItemCount;
    pub extern "c" fn MIDIGetSource(sourceIndex0: ItemCount) MIDIEndpointRef;
    pub extern "c" fn MIDIObjectGetIntegerProperty(
        obj: MIDIObjectRef,
        propertyID: CFStringRef,
        outValue: *i32,
    ) OSStatus;

    pub extern "c" const kMIDIPropertyUniqueID: CFStringRef;

    pub extern "c" fn CFStringCreateWithCString(
        alloc: CFAllocatorRef,
        cStr: [*:0]const u8,
        encoding: u32,
    ) CFStringRef;
    pub extern "c" fn CFRelease(cf: CFTypeRef) void;
};

/// MIDIPacket.data の SDK 宣言サイズ。length がこれを超える値は driver 異常とみなし walk 中断。
const MIDI_PACKET_DATA_MAX: u16 = 256;

/// pack(4) MIDIPacket の length フィールドを読む（クランプ無しの生値）。
fn packetLengthRaw(pkt: [*]const u8) u16 {
    return std.mem.readInt(u16, pkt[8..10], .little);
}

/// ARM64 では data[length] の直後を 4-byte align。Intel は unaligned のまま。
/// 戻り値は現 packet 先頭からのバイトオフセット（次 packet 先頭まで）。
/// `len` は呼び出し側で `MIDI_PACKET_DATA_MAX` 以下に検証済みであること。
fn midiPacketNextOffset(pkt: [*]const u8, len: u16) usize {
    _ = pkt;
    const data_end = c.packet_data_offset + len;
    if (builtin.cpu.arch.isAARCH64() or builtin.cpu.arch == .arm) {
        return (data_end + 3) & ~@as(usize, 3);
    }
    return data_end;
}

// ============================================================================
// SPSC ring（libs/synth の SpscRing を core から import せず最小複製）
// ============================================================================
const RING_CAP: usize = 1024;
const RING_MASK: usize = RING_CAP - 1;
const NOTE_ON_RESERVE: usize = 128;
const CC_RESERVE: usize = 32;

comptime {
    if (!std.math.isPowerOfTwo(RING_CAP)) @compileError("RING_CAP must be power of two");
}

const AtomicUsize = std.atomic.Value(usize);

const MidiRing = struct {
    buffer: [RING_CAP]types.MidiEvent = undefined,
    head: AtomicUsize align(std.atomic.cache_line) = AtomicUsize.init(0),
    tail: AtomicUsize align(std.atomic.cache_line) = AtomicUsize.init(0),

    fn pushReserve(self: *MidiRing, item: types.MidiEvent, reserve: usize) bool {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        const used = head -% tail;
        if (used + reserve >= RING_CAP) return false;
        self.buffer[head & RING_MASK] = item;
        self.head.store(head +% 1, .release);
        return true;
    }

    fn push(self: *MidiRing, item: types.MidiEvent) bool {
        return self.pushReserve(item, 0);
    }

    fn pop(self: *MidiRing) ?types.MidiEvent {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (head == tail) return null;
        const item = self.buffer[tail & RING_MASK];
        self.tail.store(tail +% 1, .release);
        return item;
    }

    fn usedCount(self: *const MidiRing) usize {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.monotonic);
        return head -% tail;
    }
};

const SourceEntry = struct {
    endpoint: c.MIDIEndpointRef,
    device_id: types.MidiDeviceId,
};

const State = struct {
    allocator: std.mem.Allocator,
    client: c.MIDIClientRef,
    port: c.MIDIPortRef,
    sources: []SourceEntry,
    ring: MidiRing = .{},

    topology_dirty: std.atomic.Value(bool) align(std.atomic.cache_line) = std.atomic.Value(bool).init(false),
    closing: std.atomic.Value(bool) align(std.atomic.cache_line) = std.atomic.Value(bool).init(false),
    callback_inflight: std.atomic.Value(u32) align(std.atomic.cache_line) = std.atomic.Value(u32).init(0),
    drop_count: std.atomic.Value(u64) align(std.atomic.cache_line) = std.atomic.Value(u64).init(0),
};

pub const Device = struct {
    state: *State,

    pub fn pollMidi(self: Device) ?types.MidiEvent {
        const state = self.state;
        if (state.topology_dirty.swap(false, .acq_rel)) {
            reconcileSources(state);
        }
        return state.ring.pop();
    }

    pub fn close(self: Device) void {
        destroyState(self.state);
    }
};

pub fn open(allocator: std.mem.Allocator) Error!Device {
    const state = allocator.create(State) catch return error.OutOfMemory;
    state.* = .{
        .allocator = allocator,
        .client = 0,
        .port = 0,
        .sources = &[_]SourceEntry{},
    };

    const client_name = c.CFStringCreateWithCString(null, "video-proto-midi", c.kCFStringEncodingUTF8);
    if (client_name == null) {
        allocator.destroy(state);
        return error.OpenFailed;
    }
    defer c.CFRelease(client_name);

    var client: c.MIDIClientRef = 0;
    if (c.MIDIClientCreate(client_name, midiNotifyProc, state, &client) != 0) {
        allocator.destroy(state);
        return error.OpenFailed;
    }
    state.client = client;

    const port_name = c.CFStringCreateWithCString(null, "video-proto-midi-in", c.kCFStringEncodingUTF8);
    if (port_name == null) {
        _ = c.MIDIClientDispose(client);
        allocator.destroy(state);
        return error.OpenFailed;
    }
    defer c.CFRelease(port_name);

    var port: c.MIDIPortRef = 0;
    if (c.MIDIInputPortCreate(client, port_name, midiReadProc, state, &port) != 0) {
        _ = c.MIDIClientDispose(client);
        allocator.destroy(state);
        return error.OpenFailed;
    }
    state.port = port;

    reconcileSources(state);
    return .{ .state = state };
}

fn destroyState(state: *State) void {
    // 1. closing を立て、以降の callback は enqueue しない
    state.closing.store(true, .release);

    // 2. 全 source を切断
    for (state.sources) |src| {
        _ = c.MIDIPortDisconnectSource(state.port, src.endpoint);
    }

    // 3. port dispose
    if (state.port != 0) {
        _ = c.MIDIPortDispose(state.port);
        state.port = 0;
    }

    // 4. client dispose（notify も止まる）
    if (state.client != 0) {
        _ = c.MIDIClientDispose(state.client);
        state.client = 0;
    }

    // 5. in-flight callback が 0 になるまで待つ
    while (state.callback_inflight.load(.acquire) != 0) {
        std.atomic.spinLoopHint();
        std.Thread.yield() catch {};
    }

    // 6. source list と State を解放
    if (state.sources.len != 0) {
        state.allocator.free(state.sources);
    }
    const allocator = state.allocator;
    allocator.destroy(state);
}

fn deviceIdForEndpoint(endpoint: c.MIDIEndpointRef) types.MidiDeviceId {
    var unique: c.MIDIUniqueID = 0;
    if (c.MIDIObjectGetIntegerProperty(endpoint, c.kMIDIPropertyUniqueID, &unique) == 0) {
        return @bitCast(unique);
    }
    return endpoint;
}

fn findConnectedDeviceId(sources: []const SourceEntry, endpoint: c.MIDIEndpointRef) ?types.MidiDeviceId {
    for (sources) |s| {
        if (s.endpoint == endpoint) return s.device_id;
    }
    return null;
}

/// 物理エンドポイント列と「既接続」集合と「新規 connect 成否」から、state.sources に載せる
/// リストを構築する（テスト可能コア）。
///
/// 契約: 既接続はそのまま残す。未接続は `new_connect_ok[i]==true` のときだけ載せる。
/// 接続失敗した endpoint は out に入れない → 次回 reconcile の差分検出で自動再試行される。
fn filterConnectedSources(
    candidates: []const SourceEntry,
    previous: []const SourceEntry,
    new_connect_ok: []const bool,
    out: []SourceEntry,
) usize {
    std.debug.assert(candidates.len == new_connect_ok.len);
    std.debug.assert(out.len >= candidates.len);
    var count: usize = 0;
    for (candidates, new_connect_ok) |cand, ok| {
        if (findConnectedDeviceId(previous, cand.endpoint)) |prev_id| {
            out[count] = .{ .endpoint = cand.endpoint, .device_id = prev_id };
            count += 1;
            continue;
        }
        if (ok) {
            out[count] = cand;
            count += 1;
        }
        // 接続失敗: 載せない（次回 reconcile で again）
    }
    return count;
}

fn reconcileSources(state: *State) void {
    if (state.closing.load(.acquire)) return;

    const n = c.MIDIGetNumberOfSources();
    // 物理ソース 0 件でも previous を解放して空にする
    if (n == 0) {
        for (state.sources) |old| {
            _ = c.MIDIPortDisconnectSource(state.port, old.endpoint);
        }
        if (state.sources.len != 0) {
            state.allocator.free(state.sources);
        }
        state.sources = &.{};
        return;
    }

    const candidates = state.allocator.alloc(SourceEntry, n) catch return;
    defer state.allocator.free(candidates);
    const connect_ok = state.allocator.alloc(bool, n) catch return;
    defer state.allocator.free(connect_ok);

    var i: c.ItemCount = 0;
    while (i < n) : (i += 1) {
        const endpoint = c.MIDIGetSource(i);
        candidates[i] = .{
            .endpoint = endpoint,
            .device_id = deviceIdForEndpoint(endpoint),
        };
    }

    // 切断: 旧にあって物理列挙に無い endpoint
    for (state.sources) |old| {
        var still = false;
        for (candidates) |cand| {
            if (cand.endpoint == old.endpoint) {
                still = true;
                break;
            }
        }
        if (!still) {
            _ = c.MIDIPortDisconnectSource(state.port, old.endpoint);
        }
    }

    // 接続: 未接続だけ MIDIPortConnectSource。失敗は connect_ok=false → sources に載せない。
    for (candidates, connect_ok) |cand, *ok| {
        if (findConnectedDeviceId(state.sources, cand.endpoint) != null) {
            ok.* = true; // 既接続（filter 側で previous を使う）
            continue;
        }
        // device_id を整数値としてポインタに載せ、callback は dereference せず u32 に戻す。
        const ref_con: ?*anyopaque = @ptrFromInt(@as(usize, cand.device_id));
        ok.* = c.MIDIPortConnectSource(state.port, cand.endpoint, ref_con) == 0;
    }

    const tmp = state.allocator.alloc(SourceEntry, n) catch return;
    const count = filterConnectedSources(candidates, state.sources, connect_ok, tmp);
    const new_sources: []SourceEntry = if (count == 0) blk: {
        state.allocator.free(tmp);
        break :blk &.{};
    } else if (count == n) tmp else blk: {
        const shrunk = state.allocator.realloc(tmp, count) catch {
            // realloc 失敗時は先頭 count 件だけを別確保
            const copy = state.allocator.alloc(SourceEntry, count) catch {
                state.allocator.free(tmp);
                return;
            };
            @memcpy(copy, tmp[0..count]);
            state.allocator.free(tmp);
            break :blk copy;
        };
        break :blk shrunk;
    };

    if (state.sources.len != 0) {
        state.allocator.free(state.sources);
    }
    state.sources = new_sources;
}

// ============================================================================
// CoreMIDI callbacks（RT 契約）
// ============================================================================

fn midiNotifyProc(message: *const c.MIDINotification, ref_con: ?*anyopaque) callconv(.c) void {
    _ = message;
    const state: *State = @ptrCast(@alignCast(ref_con orelse return));
    if (state.closing.load(.acquire)) return;
    state.topology_dirty.store(true, .release);
}

fn midiReadProc(
    pktlist: *const c.MIDIPacketList,
    read_proc_ref_con: ?*anyopaque,
    src_conn_ref_con: ?*anyopaque,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(read_proc_ref_con orelse return));
    _ = state.callback_inflight.fetchAdd(1, .acq_rel);
    defer _ = state.callback_inflight.fetchSub(1, .acq_rel);

    if (state.closing.load(.acquire)) return;

    // device_id は ConnectSource 時に整数値をポインタに載せたもの。dereference しない。
    const device_id: types.MidiDeviceId = @truncate(@intFromPtr(src_conn_ref_con));

    parsePacketListIntoRing(state, pktlist, device_id);
}

/// packet list を ring に積む（callback / 単体テスト共用）。
/// CoreMIDI の pack(4) 可変長レイアウトをバイト walk する（Zig struct に載せない）。
/// length > MIDI_PACKET_DATA_MAX(256) の packet を見たら以降を捨てて中断する（OOB 防止）。
fn parsePacketListIntoRing(state: *State, pktlist: *const c.MIDIPacketList, device_id: types.MidiDeviceId) void {
    const num = pktlist.numPackets;
    if (num == 0) return;

    const base: [*]const u8 = @ptrCast(pktlist);
    var offset: usize = c.packet_list_header_size;
    var pi: u32 = 0;
    while (pi < num) : (pi += 1) {
        const pkt = base + offset;
        const len = packetLengthRaw(pkt);
        // data[256] 宣言超過は driver 異常。クランプして読み進めず残り packet ごと破棄する。
        if (len > MIDI_PACKET_DATA_MAX) return;
        parsePacketData(state, pkt[c.packet_data_offset .. c.packet_data_offset + len], device_id);
        offset += midiPacketNextOffset(pkt, len);
    }
}

/// 1 packet 内の MIDI 1.0 バイト列を event に変換して ring へ。
/// running status は MIDIPacket では禁止。sysex / clock / system common は無視。
fn parsePacketData(state: *State, data: []const u8, device_id: types.MidiDeviceId) void {
    var i: usize = 0;
    while (i < data.len) {
        const status = data[i];
        if (status < 0x80) {
            // running status 無し前提。ゴミは 1 バイト捨てて継続（callback 停止しない）。
            i += 1;
            continue;
        }

        if (status == 0xF0) {
            // sysex: EOX または packet 末尾までスキップ
            i += 1;
            while (i < data.len and data[i] != 0xF7) : (i += 1) {}
            if (i < data.len) i += 1; // skip 0xF7 if present
            continue;
        }

        if (status >= 0xF8) {
            // system realtime（clock 等）: 0 data bytes
            i += 1;
            continue;
        }

        if (status >= 0xF0) {
            // system common
            const data_len: usize = switch (status) {
                0xF1, 0xF3 => 1,
                0xF2 => 2,
                else => 0, // F4/F5 未定義, F6 tune, F7 EOX alone
            };
            i += 1 + data_len;
            if (i > data.len) break;
            continue;
        }

        const kind = status & 0xF0;
        const data_len: usize = switch (kind) {
            0xC0, 0xD0 => 1,
            else => 2, // 80/90/A0/B0/E0
        };
        if (i + 1 + data_len > data.len) break;

        const d1 = data[i + 1];
        const d2: u8 = if (data_len == 2) data[i + 2] else 0;
        i += 1 + data_len;

        switch (kind) {
            0x80 => enqueueEvent(state, .{ .note_off = .{
                .device_id = device_id,
                .note = d1 & 0x7F,
                .velocity = d2 & 0x7F,
            } }),
            0x90 => {
                const note = d1 & 0x7F;
                const vel = d2 & 0x7F;
                if (vel == 0) {
                    enqueueEvent(state, .{ .note_off = .{
                        .device_id = device_id,
                        .note = note,
                        .velocity = 0,
                    } });
                } else {
                    enqueueEvent(state, .{ .note_on = .{
                        .device_id = device_id,
                        .note = note,
                        .velocity = vel,
                    } });
                }
            },
            0xB0 => enqueueEvent(state, .{ .cc = .{
                .device_id = device_id,
                .controller = d1 & 0x7F,
                .value = d2 & 0x7F,
            } }),
            else => {}, // A0 poly AT / C0 prog / D0 pressure / E0 pitch: 無視
        }
    }
}

fn enqueueEvent(state: *State, event: types.MidiEvent) void {
    const ok = switch (event) {
        .note_on => state.ring.pushReserve(event, NOTE_ON_RESERVE),
        .cc => state.ring.pushReserve(event, CC_RESERVE),
        .note_off => state.ring.push(event),
    };
    if (!ok) {
        _ = state.drop_count.fetchAdd(1, .monotonic);
    }
}

// ============================================================================
// テスト用: synthetic MIDIPacketList 構築
// ============================================================================

/// 可変長 packet list をバッファに書き、先頭を `*const MIDIPacketList` として返す。
/// pack(4) レイアウト（numPackets@0, packet0@4, timeStamp@+0, length@+8, data@+10）。
fn buildPacketList(buf: []u8, packets: []const []const u8) *const c.MIDIPacketList {
    std.debug.assert(packets.len > 0);
    std.debug.assert(buf.len >= 4);

    std.mem.writeInt(u32, buf[0..4], @intCast(packets.len), .little);
    var offset: usize = c.packet_list_header_size;

    for (packets) |pdata| {
        std.debug.assert(pdata.len <= 256);
        // ARM: packet 開始は 4-byte align（header 直後の 4 は既に align 済み）
        if (builtin.cpu.arch.isAARCH64() or builtin.cpu.arch == .arm) {
            offset = (offset + 3) & ~@as(usize, 3);
        }
        std.debug.assert(offset + c.packet_data_offset + pdata.len <= buf.len);

        @memset(buf[offset..][0..8], 0); // timeStamp
        std.mem.writeInt(u16, buf[offset + 8 ..][0..2], @intCast(pdata.len), .little);
        @memcpy(buf[offset + c.packet_data_offset ..][0..pdata.len], pdata);
        offset += c.packet_data_offset + pdata.len;
    }

    return @ptrCast(@alignCast(buf.ptr));
}

fn testState() State {
    return .{
        .allocator = std.testing.allocator,
        .client = 0,
        .port = 0,
        .sources = &[_]SourceEntry{},
    };
}

fn expectPop(state: *State, expected: types.MidiEvent) !void {
    const got = state.ring.pop() orelse return error.TooFewEvents;
    try testing.expectEqual(expected, got);
}

fn expectEmpty(state: *State) !void {
    try testing.expectEqual(@as(?types.MidiEvent, null), state.ring.pop());
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "midi_macos: packet note-on / note-off / CC 変換" {
    var state = testState();
    var buf: [512]u8 = undefined;
    const list = buildPacketList(&buf, &.{
        &[_]u8{ 0x90, 60, 100 }, // note on ch1
        &[_]u8{ 0x80, 60, 40 }, // note off
        &[_]u8{ 0xB0, 7, 96 }, // CC7
    });
    parsePacketListIntoRing(&state, list, 42);

    try expectPop(&state, .{ .note_on = .{ .device_id = 42, .note = 60, .velocity = 100 } });
    try expectPop(&state, .{ .note_off = .{ .device_id = 42, .note = 60, .velocity = 40 } });
    try expectPop(&state, .{ .cc = .{ .device_id = 42, .controller = 7, .value = 96 } });
    try expectEmpty(&state);
}

test "midi_macos: note-on velocity 0 は note-off に正規化" {
    var state = testState();
    var buf: [256]u8 = undefined;
    const list = buildPacketList(&buf, &.{&[_]u8{ 0x90, 64, 0 }});
    parsePacketListIntoRing(&state, list, 1);
    try expectPop(&state, .{ .note_off = .{ .device_id = 1, .note = 64, .velocity = 0 } });
    try expectEmpty(&state);
}

test "midi_macos: channel nibble を無視した status 判定" {
    var state = testState();
    var buf: [256]u8 = undefined;
    // ch 10 (0x9A), ch 16 (0xBF)
    const list = buildPacketList(&buf, &.{
        &[_]u8{ 0x9A, 12, 80 },
        &[_]u8{ 0xBF, 1, 2 },
    });
    parsePacketListIntoRing(&state, list, 7);
    try expectPop(&state, .{ .note_on = .{ .device_id = 7, .note = 12, .velocity = 80 } });
    try expectPop(&state, .{ .cc = .{ .device_id = 7, .controller = 1, .value = 2 } });
    try expectEmpty(&state);
}

test "midi_macos: sysex / clock / system common を無視" {
    var state = testState();
    var buf: [512]u8 = undefined;
    const list = buildPacketList(&buf, &.{
        &[_]u8{ 0xF0, 0x43, 0x12, 0x00, 0xF7 }, // sysex
        &[_]u8{0xF8}, // clock
        &[_]u8{ 0xF1, 0x00 }, // MTC
        &[_]u8{ 0xF2, 0x00, 0x00 }, // song position
        &[_]u8{ 0x90, 60, 10 }, // real event
    });
    parsePacketListIntoRing(&state, list, 0);
    try expectPop(&state, .{ .note_on = .{ .device_id = 0, .note = 60, .velocity = 10 } });
    try expectEmpty(&state);
}

test "midi_macos: srcConnRefCon から device_id が保持される" {
    var state = testState();
    var buf: [256]u8 = undefined;
    const list = buildPacketList(&buf, &.{&[_]u8{ 0x90, 1, 2 }});
    const device_id: types.MidiDeviceId = 0xA1B2_C3D4;
    const ref: ?*anyopaque = @ptrFromInt(@as(usize, device_id));

    parsePacketListIntoRing(&state, list, @truncate(@intFromPtr(ref)));
    try expectPop(&state, .{ .note_on = .{ .device_id = device_id, .note = 1, .velocity = 2 } });
    try expectEmpty(&state);
}

test "midi_macos: FIFO 順序" {
    var state = testState();
    var buf: [256]u8 = undefined;
    const list = buildPacketList(&buf, &.{&[_]u8{ 0x90, 1, 10, 0x90, 2, 20, 0x90, 3, 30 }});
    parsePacketListIntoRing(&state, list, 0);
    try expectPop(&state, .{ .note_on = .{ .device_id = 0, .note = 1, .velocity = 10 } });
    try expectPop(&state, .{ .note_on = .{ .device_id = 0, .note = 2, .velocity = 20 } });
    try expectPop(&state, .{ .note_on = .{ .device_id = 0, .note = 3, .velocity = 30 } });
    try expectEmpty(&state);
}

test "midi_macos: ring wrap-around" {
    var ring = MidiRing{};
    var i: u32 = 0;
    while (i < 3000) : (i += 1) {
        const ev: types.MidiEvent = .{ .cc = .{ .device_id = 0, .controller = 0, .value = @truncate(i) } };
        try testing.expect(ring.push(ev));
        const got = ring.pop().?;
        try testing.expectEqual(@as(u8, @truncate(i)), got.cc.value);
    }
}

test "midi_macos: note-on / CC reserve と note-off 優先" {
    var ring = MidiRing{};
    // note-on は reserve 128 なので used + 128 >= 1024 → used >= 896 で拒否
    var n: usize = 0;
    while (n < RING_CAP - NOTE_ON_RESERVE) : (n += 1) {
        try testing.expect(ring.pushReserve(.{ .note_on = .{ .device_id = 0, .note = 60, .velocity = 1 } }, NOTE_ON_RESERVE));
    }
    try testing.expect(!ring.pushReserve(.{ .note_on = .{ .device_id = 0, .note = 61, .velocity = 1 } }, NOTE_ON_RESERVE));
    // note-off は reserve 0 で入る
    try testing.expect(ring.push(.{ .note_off = .{ .device_id = 0, .note = 60, .velocity = 0 } }));

    // CC reserve 32: 空きが 32 以下なら CC 拒否、note-off は入る
    // 現 used = 896 + 1 = 897、空き = 127
    // 空きを 32 まで減らす（= used を 992 まで）: あと 95 個 note-off を入れる
    n = 0;
    while (n < 95) : (n += 1) {
        try testing.expect(ring.push(.{ .note_off = .{ .device_id = 0, .note = 0, .velocity = 0 } }));
    }
    // used=992, free=32 → CC は free > 32 が必要（used+32>=1024 → used>=992）で拒否
    try testing.expect(!ring.pushReserve(.{ .cc = .{ .device_id = 0, .controller = 1, .value = 1 } }, CC_RESERVE));
    try testing.expect(ring.push(.{ .note_off = .{ .device_id = 0, .note = 1, .velocity = 0 } }));
}

test "midi_macos: overflow 時も callback は停止せず drop を数える" {
    var state = testState();
    // 満杯まで note-off を詰める
    var n: usize = 0;
    while (n < RING_CAP) : (n += 1) {
        try testing.expect(state.ring.push(.{ .note_off = .{ .device_id = 0, .note = 0, .velocity = 0 } }));
    }
    const before = state.drop_count.load(.monotonic);
    enqueueEvent(&state, .{ .note_off = .{ .device_id = 0, .note = 1, .velocity = 0 } });
    enqueueEvent(&state, .{ .note_on = .{ .device_id = 0, .note = 2, .velocity = 10 } });
    enqueueEvent(&state, .{ .cc = .{ .device_id = 0, .controller = 3, .value = 4 } });
    try testing.expectEqual(before + 3, state.drop_count.load(.monotonic));
    // ring は依然として pop 可能（callback 停止していない）
    try testing.expect(state.ring.pop() != null);
}

test "midi_macos: head/tail・closing・callback counter の cache_line 分離" {
    const cl = std.atomic.cache_line;
    try testing.expect(@alignOf(MidiRing) >= cl);
    try testing.expect(@offsetOf(MidiRing, "head") % cl == 0);
    try testing.expect(@offsetOf(MidiRing, "tail") % cl == 0);
    const ring_dist = if (@offsetOf(MidiRing, "tail") > @offsetOf(MidiRing, "head"))
        @offsetOf(MidiRing, "tail") - @offsetOf(MidiRing, "head")
    else
        @offsetOf(MidiRing, "head") - @offsetOf(MidiRing, "tail");
    try testing.expect(ring_dist >= cl);

    try testing.expect(@offsetOf(State, "topology_dirty") % cl == 0);
    try testing.expect(@offsetOf(State, "closing") % cl == 0);
    try testing.expect(@offsetOf(State, "callback_inflight") % cl == 0);
    try testing.expect(@offsetOf(State, "drop_count") % cl == 0);

    // 互いに別 cache line
    const offs = [_]usize{
        @offsetOf(State, "topology_dirty"),
        @offsetOf(State, "closing"),
        @offsetOf(State, "callback_inflight"),
        @offsetOf(State, "drop_count"),
        @offsetOf(State, "ring") + @offsetOf(MidiRing, "head"),
        @offsetOf(State, "ring") + @offsetOf(MidiRing, "tail"),
    };
    for (offs, 0..) |a, i| {
        for (offs[i + 1 ..]) |b| {
            try testing.expect(a / cl != b / cl);
        }
    }
}

test "midi_macos: MIDINotifyProc は dirty flag のみ更新" {
    var state = testState();
    try testing.expect(!state.topology_dirty.load(.monotonic));
    const msg = c.MIDINotification{ .messageID = 1, .messageSize = 8 };
    midiNotifyProc(&msg, @ptrCast(&state));
    try testing.expect(state.topology_dirty.load(.monotonic));
    // ring は空のまま（列挙しない）
    try testing.expectEqual(@as(?types.MidiEvent, null), state.ring.pop());
}

test "midi_macos: shutdown 後の callback は event を enqueue しない" {
    var state = testState();
    state.closing.store(true, .release);

    var buf: [256]u8 = undefined;
    const list = buildPacketList(&buf, &.{&[_]u8{ 0x90, 60, 100 }});
    // midiReadProc 経路
    midiReadProc(list, @ptrCast(&state), @ptrFromInt(99));
    try testing.expectEqual(@as(?types.MidiEvent, null), state.ring.pop());
    try testing.expectEqual(@as(u32, 0), state.callback_inflight.load(.monotonic));
}

test "midi_macos: connect 失敗 endpoint は sources に入れず次回再試行可能" {
    // previous に endpoint=1 のみ接続済み。物理候補は 1,2,3。
    // 2 は新規 connect 失敗、3 は成功 → sources には 1 と 3 のみ。
    // 2 が previous に残らないので次回 reconcile では「未接続」として再試行される。
    const previous = [_]SourceEntry{.{ .endpoint = 1, .device_id = 10 }};
    const candidates = [_]SourceEntry{
        .{ .endpoint = 1, .device_id = 10 },
        .{ .endpoint = 2, .device_id = 20 },
        .{ .endpoint = 3, .device_id = 30 },
    };
    const new_connect_ok = [_]bool{ true, false, true }; // index0 は既接続なので filter は無視
    var out: [3]SourceEntry = undefined;
    const n = filterConnectedSources(&candidates, &previous, &new_connect_ok, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(c.MIDIEndpointRef, 1), out[0].endpoint);
    try testing.expectEqual(@as(types.MidiDeviceId, 10), out[0].device_id);
    try testing.expectEqual(@as(c.MIDIEndpointRef, 3), out[1].endpoint);
    try testing.expectEqual(@as(types.MidiDeviceId, 30), out[1].device_id);

    // 失敗した 2 は out に無い → previous として渡さなければ再試行対象
    const retry_ok = [_]bool{ true, true, true };
    var out2: [3]SourceEntry = undefined;
    const n2 = filterConnectedSources(&candidates, out[0..n], &retry_ok, &out2);
    try testing.expectEqual(@as(usize, 3), n2);
    try testing.expectEqual(@as(c.MIDIEndpointRef, 2), out2[1].endpoint);
}

test "midi_macos: packet length > 256 は walk 中断（OOB 防止）" {
    var state = testState();
    // 手動で異常 length の packet list を組み立てる（numPackets=2、先頭 length=1000）
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], 2, .little); // numPackets
    // packet0 @4: timeStamp=0, length=1000 (>256), data 無し相当
    std.mem.writeInt(u16, buf[4 + 8 ..][0..2], 1000, .little);
    // 後続 packet に note-on を置いても中断で読まれない
    // （offset 計算はしない＝中断後は触らないので後続内容は不要）

    const list: *const c.MIDIPacketList = @ptrCast(@alignCast(&buf));
    parsePacketListIntoRing(&state, list, 0);
    try expectEmpty(&state);
}

test "midi_macos: client open/close（デバイス無しでも成功）" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var device = try open(testing.allocator);
    // イベントが無ければ null（実機が同時に送っていなければ）
    // ここでは close まで到達することを主眼とする
    _ = device.pollMidi();
    device.close();
}

test "midi_macos: pollMidi が dirty 時に reconcile して ring を drain" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // 実 open して dirty を立て、poll で reconcile が走っても panic しないこと
    var device = try open(testing.allocator);
    defer device.close();
    device.state.topology_dirty.store(true, .release);
    _ = device.pollMidi();
    try testing.expect(!device.state.topology_dirty.load(.monotonic));
}
