//! apps/modular のオフライン WAV 書き出し（TASK-86）。
//!
//! ホットパス宣言: イベント時のみ（`action render` / 単体テスト）。main thread で offline
//! LofiPatch をチャンクループする。RT 再生経路（live patch の render / onAudioSamples）には
//! 一切関与しない。
//!
//! 設計: core/control/harness.zig の encodeWav（PCM16 RIFF/WAVE・44B ヘッダ・clamp*32767）を
//! 手本に移植したストリーミング版。ヘッダは total_frames から事前計算して先に書き、
//! `writeChunk` で f32 interleaved を i16 化して追記する。全バッファ確保（数百 MB）はしない。
//! std のみ・kit/platform/modular 非依存。

const std = @import("std");

pub const Error = error{
    /// `finish` 時に書き込みフレーム数が `total_frames` と一致しない。
    /// または `writeChunk` が total を超えようとしたとき（finish 前検出）。
    FrameCountMismatch,
    /// data_size / byte_rate が RIFF u32 制約を超える（u64 計算後に検出。panic 回避）。
    TooLong,
    WriteFailed,
};

/// PCM16 little-endian RIFF/WAVE を `*std.Io.Writer` へストリーミング書き込みする。
pub const WavWriter = struct {
    writer: *std.Io.Writer,
    channels: u32,
    sample_rate: u32,
    total_frames: u32,
    frames_written: u32 = 0,

    /// ヘッダを先に書き、残りは `writeChunk` で埋める。
    /// サイズは u64 で計算し、`36 + data_size > maxInt(u32)` なら `error.TooLong`。
    pub fn init(writer: *std.Io.Writer, channels: u32, sample_rate: u32, total_frames: u32) Error!WavWriter {
        const data_size_u64: u64 = @as(u64, total_frames) * @as(u64, channels) * 2;
        if (36 + data_size_u64 > std.math.maxInt(u32)) return error.TooLong;
        const data_size: u32 = @intCast(data_size_u64);

        const byte_rate_u64: u64 = @as(u64, sample_rate) * @as(u64, channels) * 2;
        if (byte_rate_u64 > std.math.maxInt(u32)) return error.TooLong;
        const byte_rate: u32 = @intCast(byte_rate_u64);

        var hdr: [44]u8 = undefined;
        @memcpy(hdr[0..4], "RIFF");
        std.mem.writeInt(u32, hdr[4..8], 36 + data_size, .little);
        @memcpy(hdr[8..12], "WAVE");
        @memcpy(hdr[12..16], "fmt ");
        std.mem.writeInt(u32, hdr[16..20], 16, .little); // subchunk1 size (PCM)
        std.mem.writeInt(u16, hdr[20..22], 1, .little); // audio format = PCM
        std.mem.writeInt(u16, hdr[22..24], @intCast(channels), .little);
        std.mem.writeInt(u32, hdr[24..28], sample_rate, .little);
        std.mem.writeInt(u32, hdr[28..32], byte_rate, .little);
        std.mem.writeInt(u16, hdr[32..34], @intCast(channels * 2), .little); // block_align
        std.mem.writeInt(u16, hdr[34..36], 16, .little); // bits_per_sample
        @memcpy(hdr[36..40], "data");
        std.mem.writeInt(u32, hdr[40..44], data_size, .little);
        writer.writeAll(&hdr) catch return error.WriteFailed;
        return .{
            .writer = writer,
            .channels = channels,
            .sample_rate = sample_rate,
            .total_frames = total_frames,
        };
    }

    /// interleaved f32（-1..1）を PCM16 に変換して追記する。
    /// `interleaved.len` は `channels` の倍数でなければならない。
    /// total 超過は即 `error.FrameCountMismatch`（書き込まずに返す）。
    pub fn writeChunk(self: *WavWriter, interleaved: []const f32) Error!void {
        std.debug.assert(self.channels > 0);
        std.debug.assert(interleaved.len % self.channels == 0);
        const frames: u32 = @intCast(interleaved.len / self.channels);
        if (@as(u64, self.frames_written) + @as(u64, frames) > @as(u64, self.total_frames)) {
            return error.FrameCountMismatch;
        }
        for (interleaved) |s| {
            const clamped = std.math.clamp(s, -1.0, 1.0);
            const v: i16 = @intFromFloat(clamped * 32767.0);
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(i16, &bytes, v, .little);
            self.writer.writeAll(&bytes) catch return error.WriteFailed;
        }
        self.frames_written += frames;
    }

    /// 書き込みフレーム数と total の一致を検証し、writer を flush する。
    pub fn finish(self: *WavWriter) Error!void {
        if (self.frames_written != self.total_frames) return error.FrameCountMismatch;
        self.writer.flush() catch return error.WriteFailed;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "WavWriter: PCM16 RIFF/WAVE ヘッダの byte offset を絶対値 assert" {
    // 4 samples, 2ch → 2 frames（harness encodeWav テストと同型）
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var ww = try WavWriter.init(&aw.writer, 2, 48000, 2);
    try ww.writeChunk(&[_]f32{ 0, 0, 0, 0 });
    try ww.finish();
    const bytes = aw.written();

    try testing.expectEqual(@as(usize, 44 + 8), bytes.len);
    try testing.expectEqualStrings("RIFF", bytes[0..4]);
    try testing.expectEqual(@as(u32, 36 + 8), std.mem.readInt(u32, bytes[4..8], .little));
    try testing.expectEqualStrings("WAVE", bytes[8..12]);
    try testing.expectEqualStrings("fmt ", bytes[12..16]);
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, bytes[16..20], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[20..22], .little)); // PCM
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[22..24], .little)); // channels
    try testing.expectEqual(@as(u32, 48000), std.mem.readInt(u32, bytes[24..28], .little)); // sample_rate
    try testing.expectEqual(@as(u32, 48000 * 2 * 2), std.mem.readInt(u32, bytes[28..32], .little)); // byte_rate
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, bytes[32..34], .little)); // block_align
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[34..36], .little)); // bits
    try testing.expectEqualStrings("data", bytes[36..40]);
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, bytes[40..44], .little)); // data_size
}

test "WavWriter: 既知サンプルの i16 変換（clamp * 32767）" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // mono 3 samples: 1.0 / -1.0 / 0.5
    var ww = try WavWriter.init(&aw.writer, 1, 48000, 3);
    try ww.writeChunk(&[_]f32{ 1.0, -1.0, 0.5 });
    try ww.finish();
    const bytes = aw.written();
    try testing.expectEqual(@as(usize, 44 + 6), bytes.len);
    try testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, bytes[44..46], .little));
    try testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, bytes[46..48], .little));
    try testing.expectEqual(@as(i16, 16383), std.mem.readInt(i16, bytes[48..50], .little)); // 0.5*32767
}

test "WavWriter: total_frames 不一致で FrameCountMismatch" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var ww = try WavWriter.init(&aw.writer, 2, 48000, 4);
    // 2 frames only（total は 4）
    try ww.writeChunk(&[_]f32{ 0, 0, 0, 0 });
    try testing.expectError(error.FrameCountMismatch, ww.finish());
}

test "WavWriter: writeChunk が total 超過なら即 FrameCountMismatch" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var ww = try WavWriter.init(&aw.writer, 2, 48000, 2);
    try ww.writeChunk(&[_]f32{ 0, 0, 0, 0 }); // 2 frames = total
    // これ以上書けない
    try testing.expectError(error.FrameCountMismatch, ww.writeChunk(&[_]f32{ 0, 0, 0, 0 }));
    try ww.finish(); // frames_written == total のまま finish 可
}

test "WavWriter: data_size が RIFF u32 上限超過なら TooLong" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // stereo: data_size = total_frames * 2 * 2。maxInt(u32) frames は 36+data が u32 超過。
    try testing.expectError(error.TooLong, WavWriter.init(&aw.writer, 2, 48000, std.math.maxInt(u32)));
}
