//! The macOS CoreMIDI backend (see ADR-010).
//!
//! ## Choosing the API (the legacy MIDIReadProc)
//!
//! Receiving uses `MIDIInputPortCreate` plus `MIDIReadProc`.
//! The SDK marks it deprecated in favour of `MIDIInputPortCreateWithProtocol` (`MIDIReceiveBlock` plus
//! `MIDIEventList`), but `MIDIReceiveBlock` uses the Objective-C block ABI and so does not suit this project's
//! approach of passing a C function pointer to an `extern fn` rather than using `@cImport`.
//! A hand-written extern does not pick up the SDK's deprecation attribute, and an unrelated API is not adopted
//! merely to hide a warning. The replacement point for a future MIDI 2 or block backend is isolated to this file.
//!
//! ## Hot path declaration
//!
//! In `midiReadProc` (CoreMIDI's high-priority receive thread, so near-real-time and once per event),
//! alloc, locking, IO, panic, CF operations and logging are all forbidden; it only pushes into a fixed-length SPSC
//! ring and parses MIDI 1.0 bytes. `MIDINotifyProc` only does an atomic store of the topology dirty flag.
//! Enumeration, connection changes and allocation happen only on the main thread's `pollMidi()` (when dirty), or in `open` and `close`.
//!
//! ## The thread model
//!
//! - the producer: CoreMIDI's receive thread (`midiReadProc`)
//! - the consumer: the main thread calling `Device.pollMidi()`
//! - the queue: `MidiEvent` with a capacity of 1024 (a power of two), head and tail on separate cache lines
//! - note-on reserves 128 slots and CC reserves 32 for note-off (when full it drops and bumps an atomic counter)

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");

pub const Error = error{ OpenFailed, OutOfMemory };

// ============================================================================
// the CoreMIDI and CoreFoundation C ABI (a minimal subset, no @cImport)
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

    /// A pack(4) variable-length list. There is no `packet` field (Zig's align 8 disagrees with
    /// C's pack(4) leading offset of 4, so `parsePacketListIntoRing` walks the body
    /// byte by byte instead).
    pub const MIDIPacketList = extern struct {
        numPackets: u32,
    };

    // the pack(4) MIDIPacket layout (from the SDK's CoreMIDI/MIDIServices.h):
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

/// The size MIDIPacket.data is declared with in the SDK. A length beyond it is taken as a driver fault and stops the walk.
const MIDI_PACKET_DATA_MAX: u16 = 256;

/// Reads the length field of a pack(4) MIDIPacket (the raw value, unclamped).
fn packetLengthRaw(pkt: [*]const u8) u16 {
    return std.mem.readInt(u16, pkt[8..10], .little);
}

/// On ARM64 the byte just past data[length] is 4-byte aligned; on Intel it stays unaligned.
/// The return value is the byte offset from the head of the current packet (to the head of the next).
/// `len` must already have been checked by the caller to be at most `MIDI_PACKET_DATA_MAX`.
fn midiPacketNextOffset(pkt: [*]const u8, len: u16) usize {
    _ = pkt;
    const data_end = c.packet_data_offset + len;
    if (builtin.cpu.arch.isAARCH64() or builtin.cpu.arch == .arm) {
        return (data_end + 3) & ~@as(usize, 3);
    }
    return data_end;
}

// ============================================================================
// an SPSC ring (a minimal copy, rather than importing libs/synth's SpscRing from core)
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
    // 1. Raise closing, so no later callback enqueues
    state.closing.store(true, .release);

    // 2. Disconnect every source
    for (state.sources) |src| {
        _ = c.MIDIPortDisconnectSource(state.port, src.endpoint);
    }

    // 3. port dispose
    if (state.port != 0) {
        _ = c.MIDIPortDispose(state.port);
        state.port = 0;
    }

    // 4. Dispose of the client (which also stops notify)
    if (state.client != 0) {
        _ = c.MIDIClientDispose(state.client);
        state.client = 0;
    }

    // 5. Wait until there are no in-flight callbacks
    while (state.callback_inflight.load(.acquire) != 0) {
        std.atomic.spinLoopHint();
        std.Thread.yield() catch {};
    }

    // 6. Free the source list and the State
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

/// Builds the list to put in state.sources from the physical endpoint list, the set of already-connected
/// endpoints, and whether each new connect succeeded (a testable core).
///
/// The contract: an already-connected endpoint stays as it is. An unconnected one goes in only when `new_connect_ok[i]==true`.
/// An endpoint that failed to connect is left out of out, so the next reconcile's difference detection retries it automatically.
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
        // failed to connect: leave it out (and try again on the next reconcile)
    }
    return count;
}

fn reconcileSources(state: *State) void {
    if (state.closing.load(.acquire)) return;

    const n = c.MIDIGetNumberOfSources();
    // free the previous list and empty it even when there are no physical sources
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

    // disconnect: an endpoint in the old list that the physical enumeration no longer has
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

    // connect: MIDIPortConnectSource only for those not yet connected. A failure gives connect_ok=false, so it is left out of sources.
    for (candidates, connect_ok) |cand, *ok| {
        if (findConnectedDeviceId(state.sources, cand.endpoint) != null) {
            ok.* = true; // already connected (the filter side uses previous)
            continue;
        }
        // The device_id is carried in the pointer as an integer value, and the callback turns it back into a u32 without dereferencing it.
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
            // on a failed realloc, allocate just the first count entries separately
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
// the CoreMIDI callbacks (under the real-time contract)
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

    // The device_id is the integer value put into the pointer at ConnectSource time. It is never dereferenced.
    const device_id: types.MidiDeviceId = @truncate(@intFromPtr(src_conn_ref_con));

    parsePacketListIntoRing(state, pktlist, device_id);
}

/// Pushes a packet list into the ring (shared by the callback and the unit tests).
/// It walks CoreMIDI's pack(4) variable-length layout byte by byte (rather than mapping it onto a Zig struct).
/// On seeing a packet whose length exceeds MIDI_PACKET_DATA_MAX(256) it discards the rest and stops (which prevents an out-of-bounds read).
fn parsePacketListIntoRing(state: *State, pktlist: *const c.MIDIPacketList, device_id: types.MidiDeviceId) void {
    const num = pktlist.numPackets;
    if (num == 0) return;

    const base: [*]const u8 = @ptrCast(pktlist);
    var offset: usize = c.packet_list_header_size;
    var pi: u32 = 0;
    while (pi < num) : (pi += 1) {
        const pkt = base + offset;
        const len = packetLengthRaw(pkt);
        // Exceeding the declared data[256] is a driver fault. It is not clamped and read on; the remaining packets are discarded wholesale.
        if (len > MIDI_PACKET_DATA_MAX) return;
        parsePacketData(state, pkt[c.packet_data_offset .. c.packet_data_offset + len], device_id);
        offset += midiPacketNextOffset(pkt, len);
    }
}

/// Converts the MIDI 1.0 byte sequence within one packet into events and puts them in the ring.
/// Running status is forbidden in a MIDIPacket. sysex, clock and system common are ignored.
fn parsePacketData(state: *State, data: []const u8, device_id: types.MidiDeviceId) void {
    var i: usize = 0;
    while (i < data.len) {
        const status = data[i];
        if (status < 0x80) {
            // Running status is assumed absent. Rubbish costs one discarded byte and it carries on (the callback never stops).
            i += 1;
            continue;
        }

        if (status == 0xF0) {
            // sysex: skip to EOX, or to the end of the packet
            i += 1;
            while (i < data.len and data[i] != 0xF7) : (i += 1) {}
            if (i < data.len) i += 1; // skip 0xF7 if present
            continue;
        }

        if (status >= 0xF8) {
            // system realtime (clock and the like): 0 data bytes
            i += 1;
            continue;
        }

        if (status >= 0xF0) {
            // system common
            const data_len: usize = switch (status) {
                0xF1, 0xF3 => 1,
                0xF2 => 2,
                else => 0, // F4/F5 undefined, F6 tune, F7 EOX alone
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
            else => {}, // A0 poly AT / C0 prog / D0 pressure / E0 pitch: ignored
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
// for the tests: building a synthetic MIDIPacketList
// ============================================================================

/// Writes a variable-length packet list into a buffer and returns its head as a `*const MIDIPacketList`.
/// The pack(4) layout (numPackets@0, packet0@4, timeStamp@+0, length@+8, data@+10).
fn buildPacketList(buf: []u8, packets: []const []const u8) *const c.MIDIPacketList {
    std.debug.assert(packets.len > 0);
    std.debug.assert(buf.len >= 4);

    std.mem.writeInt(u32, buf[0..4], @intCast(packets.len), .little);
    var offset: usize = c.packet_list_header_size;

    for (packets) |pdata| {
        std.debug.assert(pdata.len <= 256);
        // ARM: a packet starts 4-byte aligned (the 4 just past the header is already aligned)
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

test "midi_macos: converting a packet's note-on, note-off and CC" {
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

test "midi_macos: a note-on with velocity 0 is normalised to a note-off" {
    var state = testState();
    var buf: [256]u8 = undefined;
    const list = buildPacketList(&buf, &.{&[_]u8{ 0x90, 64, 0 }});
    parsePacketListIntoRing(&state, list, 1);
    try expectPop(&state, .{ .note_off = .{ .device_id = 1, .note = 64, .velocity = 0 } });
    try expectEmpty(&state);
}

test "midi_macos: deciding the status while ignoring the channel nibble" {
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

test "midi_macos: sysex, clock and system common are ignored" {
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

test "midi_macos: the device_id survives through srcConnRefCon" {
    var state = testState();
    var buf: [256]u8 = undefined;
    const list = buildPacketList(&buf, &.{&[_]u8{ 0x90, 1, 2 }});
    const device_id: types.MidiDeviceId = 0xA1B2_C3D4;
    const ref: ?*anyopaque = @ptrFromInt(@as(usize, device_id));

    parsePacketListIntoRing(&state, list, @truncate(@intFromPtr(ref)));
    try expectPop(&state, .{ .note_on = .{ .device_id = device_id, .note = 1, .velocity = 2 } });
    try expectEmpty(&state);
}

test "midi_macos: FIFO order" {
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

test "midi_macos: the note-on and CC reserves, and note-off taking priority" {
    var ring = MidiRing{};
    // note-on reserves 128, so used + 128 >= 1024 means it is refused from used >= 896
    var n: usize = 0;
    while (n < RING_CAP - NOTE_ON_RESERVE) : (n += 1) {
        try testing.expect(ring.pushReserve(.{ .note_on = .{ .device_id = 0, .note = 60, .velocity = 1 } }, NOTE_ON_RESERVE));
    }
    try testing.expect(!ring.pushReserve(.{ .note_on = .{ .device_id = 0, .note = 61, .velocity = 1 } }, NOTE_ON_RESERVE));
    // note-off has a reserve of 0 and goes in
    try testing.expect(ring.push(.{ .note_off = .{ .device_id = 0, .note = 60, .velocity = 0 } }));

    // CC reserves 32: with 32 or fewer free, CC is refused while note-off still goes in
    // used is now 896 + 1 = 897, so 127 are free
    // bring the free count down to 32 (used up to 992): 95 more note-offs
    n = 0;
    while (n < 95) : (n += 1) {
        try testing.expect(ring.push(.{ .note_off = .{ .device_id = 0, .note = 0, .velocity = 0 } }));
    }
    // used=992, free=32, so CC is refused (it needs free > 32, since used+32>=1024 means used>=992)
    try testing.expect(!ring.pushReserve(.{ .cc = .{ .device_id = 0, .controller = 1, .value = 1 } }, CC_RESERVE));
    try testing.expect(ring.push(.{ .note_off = .{ .device_id = 0, .note = 1, .velocity = 0 } }));
}

test "midi_macos: on overflow the callback does not stop and counts the drops" {
    var state = testState();
    // pack it with note-offs until it is full
    var n: usize = 0;
    while (n < RING_CAP) : (n += 1) {
        try testing.expect(state.ring.push(.{ .note_off = .{ .device_id = 0, .note = 0, .velocity = 0 } }));
    }
    const before = state.drop_count.load(.monotonic);
    enqueueEvent(&state, .{ .note_off = .{ .device_id = 0, .note = 1, .velocity = 0 } });
    enqueueEvent(&state, .{ .note_on = .{ .device_id = 0, .note = 2, .velocity = 10 } });
    enqueueEvent(&state, .{ .cc = .{ .device_id = 0, .controller = 3, .value = 4 } });
    try testing.expectEqual(before + 3, state.drop_count.load(.monotonic));
    // the ring can still be popped (the callback has not stopped)
    try testing.expect(state.ring.pop() != null);
}

test "midi_macos: head, tail, closing and the callback counter are on separate cache lines" {
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

    // on separate cache lines from each other
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

test "midi_macos: MIDINotifyProc updates the dirty flag alone" {
    var state = testState();
    try testing.expect(!state.topology_dirty.load(.monotonic));
    const msg = c.MIDINotification{ .messageID = 1, .messageSize = 8 };
    midiNotifyProc(&msg, @ptrCast(&state));
    try testing.expect(state.topology_dirty.load(.monotonic));
    // the ring stays empty (nothing is enumerated)
    try testing.expectEqual(@as(?types.MidiEvent, null), state.ring.pop());
}

test "midi_macos: a callback after shutdown enqueues no event" {
    var state = testState();
    state.closing.store(true, .release);

    var buf: [256]u8 = undefined;
    const list = buildPacketList(&buf, &.{&[_]u8{ 0x90, 60, 100 }});
    // through the midiReadProc path
    midiReadProc(list, @ptrCast(&state), @ptrFromInt(99));
    try testing.expectEqual(@as(?types.MidiEvent, null), state.ring.pop());
    try testing.expectEqual(@as(u32, 0), state.callback_inflight.load(.monotonic));
}

test "midi_macos: an endpoint that failed to connect is left out of sources and can be retried next time" {
    // previous has only endpoint=1 connected, and the physical candidates are 1, 2 and 3.
    // 2 fails to connect and 3 succeeds, so sources holds only 1 and 3.
    // 2 does not survive in previous, so the next reconcile retries it as unconnected.
    const previous = [_]SourceEntry{.{ .endpoint = 1, .device_id = 10 }};
    const candidates = [_]SourceEntry{
        .{ .endpoint = 1, .device_id = 10 },
        .{ .endpoint = 2, .device_id = 20 },
        .{ .endpoint = 3, .device_id = 30 },
    };
    const new_connect_ok = [_]bool{ true, false, true }; // index0 is already connected, so the filter ignores it
    var out: [3]SourceEntry = undefined;
    const n = filterConnectedSources(&candidates, &previous, &new_connect_ok, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(c.MIDIEndpointRef, 1), out[0].endpoint);
    try testing.expectEqual(@as(types.MidiDeviceId, 10), out[0].device_id);
    try testing.expectEqual(@as(c.MIDIEndpointRef, 3), out[1].endpoint);
    try testing.expectEqual(@as(types.MidiDeviceId, 30), out[1].device_id);

    // the failed 2 is not in out, so it is retried unless it is passed as previous
    const retry_ok = [_]bool{ true, true, true };
    var out2: [3]SourceEntry = undefined;
    const n2 = filterConnectedSources(&candidates, out[0..n], &retry_ok, &out2);
    try testing.expectEqual(@as(usize, 3), n2);
    try testing.expectEqual(@as(c.MIDIEndpointRef, 2), out2[1].endpoint);
}

test "midi_macos: a packet length over 256 stops the walk (which prevents an out-of-bounds read)" {
    var state = testState();
    // Assemble a packet list with a bad length by hand (numPackets=2, the first length=1000)
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], 2, .little); // numPackets
    // packet0 @4: timeStamp=0, length=1000 (>256), effectively no data
    std.mem.writeInt(u16, buf[4 + 8 ..][0..2], 1000, .little);
    // putting a note-on in the following packet does not get it read, the walk having stopped
    // (no offset is computed: nothing is touched after stopping, so the later content does not matter)

    const list: *const c.MIDIPacketList = @ptrCast(@alignCast(&buf));
    parsePacketListIntoRing(&state, list, 0);
    try expectEmpty(&state);
}

test "midi_macos: client open and close (succeeding even with no device)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var device = try open(testing.allocator);
    // null when there is no event (unless real hardware is sending at the same time)
    // the point here is to reach close
    _ = device.pollMidi();
    device.close();
}

test "midi_macos: pollMidi reconciles when dirty and drains the ring" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // Really open, raise dirty, and confirm that a reconcile running under poll does not panic
    var device = try open(testing.allocator);
    defer device.close();
    device.state.topology_dirty.store(true, .release);
    _ = device.pollMidi();
    try testing.expect(!device.state.topology_dirty.load(.monotonic));
}
