// video-proto AudioWorkletProcessor（TASK-73.2）
// main と同じ WebAssembly.Module + SharedArrayBuffer Memory で 2 つ目の Instance を同期生成し、
// process() から vp_audio_render を push 駆動する。
//
// stack: main が shared memory 内に確保した worklet 専用 stack の top を
//        exports.__stack_pointer にセット（PoC a で確認済み）。
// data: shared memory ビルドは passive data segment + DataCount（バイナリ解析確認済み）。
//       2nd instantiate は data を能動再適用しない。加えて sentinel 実行時検証。
//
// boot 時（g_state 未設定）の instantiate は安全: process は running ゲート内でしか g_state を読まない。

const SENTINEL_MAGIC = 0x56504153; // 'VPAS' — audio_web.zig と一致

class VpAudioProcessor extends AudioWorkletProcessor {
  /**
   * @param {{ processorOptions?: {
   *   module: WebAssembly.Module,
   *   memory: WebAssembly.Memory,
   *   stackTop: number,
   *   channels: number,
   *   sampleRate: number,
   * }}} options
   */
  constructor(options) {
    super();
    const opts = options.processorOptions || {};
    this._ready = false;
    this._channels = opts.channels || 2;
    this._sampleRate = opts.sampleRate || sampleRate;
    this._memory = opts.memory;
    this._render = null;
    this._outPtr = 0;
    this._errLogged = false;
    // RT GC 圧回避: Float32Array view をキャッシュ（buffer identity / ptr / len 変化時のみ再生成）
    this._f32View = null;
    this._f32Buf = null;
    this._f32Ptr = 0;
    this._f32Len = 0;

    try {
      if (!opts.module || !opts.memory) {
        throw new Error("vp-worklet: missing module/memory");
      }
      // worklet 側は audio 経路の env だけあればよい（present/log は呼ばない）。
      // wasi は stdlib が触る可能性があるので no-op 相当の最小面を渡す。
      const imports = {
        env: {
          memory: opts.memory,
          vp_now: () => currentTime,
          vp_present: () => {},
          vp_log: () => {},
          vp_set_cursor: () => {},
          vp_audio_open: () => 0,
          vp_audio_start: () => {},
          vp_audio_stop: () => {},
          vp_audio_close: () => {},
        },
        wasi_snapshot_preview1: makeWasiStub(),
      };

      const instance = new WebAssembly.Instance(opts.module, imports);
      const exp = instance.exports;

      // (a) stack pointer を main が確保した専用領域の top へ
      const stackTop = opts.stackTop | 0;
      if (stackTop > 0 && exp.__stack_pointer) {
        exp.__stack_pointer.value = stackTop;
      }

      // 実行時 sentinel: main が set した magic が 2nd Instance 後も共有 memory 上に残っているか
      if (typeof exp.vp_audio_check_sentinel !== "function") {
        throw new Error("vp-worklet: missing vp_audio_check_sentinel");
      }
      const got = exp.vp_audio_check_sentinel() >>> 0;
      if (got !== SENTINEL_MAGIC) {
        throw new Error(
          "vp-worklet: sentinel mismatch (got 0x" +
            got.toString(16) +
            ", want 0x" +
            SENTINEL_MAGIC.toString(16) +
            ") — 2nd instantiate may have clobbered shared state",
        );
      }

      this._render = exp.vp_audio_render;
      this._outPtr =
        typeof exp.vp_audio_render_buf === "function"
          ? exp.vp_audio_render_buf() >>> 0
          : 0;
      if (typeof this._render !== "function" || this._outPtr === 0) {
        throw new Error("vp-worklet: missing vp_audio_render / render buf");
      }
      this._ready = true;
      this.port.postMessage({ type: "ready", sentinel: got });
    } catch (e) {
      // process では throw しない（audio グラフ切断を避ける）。boot 側が await する。
      this.port.postMessage({
        type: "error",
        message: String(e && e.message ? e.message : e),
      });
    }
  }

  /**
   * @param {number} frames
   * @param {number} channels
   * @returns {Float32Array}
   */
  _getF32View(frames, channels) {
    const len = frames * channels;
    const buf = this._memory.buffer;
    if (
      this._f32View &&
      this._f32Buf === buf &&
      this._f32Ptr === this._outPtr &&
      this._f32Len === len
    ) {
      return this._f32View;
    }
    this._f32View = new Float32Array(buf, this._outPtr, len);
    this._f32Buf = buf;
    this._f32Ptr = this._outPtr;
    this._f32Len = len;
    return this._f32View;
  }

  /**
   * @param {Float32Array[][]} _inputs
   * @param {Float32Array[][]} outputs
   * @returns {boolean}
   */
  process(_inputs, outputs) {
    const output = outputs[0];
    if (!output || output.length === 0) return true;
    const frames = output[0].length;
    if (!this._ready || !this._render) {
      for (let c = 0; c < output.length; c++) output[c].fill(0);
      return true;
    }

    const channels = Math.min(this._channels, output.length, 2);
    try {
      // 戻り値 0 = skipped（start 前 / frames 過大等）→ 古い scratch を出さず無音
      const ok = this._render(this._outPtr, frames, channels, this._sampleRate | 0);
      if (!ok) {
        for (let c = 0; c < output.length; c++) output[c].fill(0);
        return true;
      }
      const f32 = this._getF32View(frames, channels);
      for (let i = 0; i < frames; i++) {
        for (let c = 0; c < channels; c++) {
          output[c][i] = f32[i * channels + c];
        }
      }
      for (let c = channels; c < output.length; c++) {
        output[c].fill(0);
      }
    } catch (e) {
      if (!this._errLogged) {
        this._errLogged = true;
        this.port.postMessage({
          type: "error",
          message: "vp_audio_render: " + String(e && e.message ? e.message : e),
        });
      }
      for (let c = 0; c < output.length; c++) output[c].fill(0);
    }
    return true;
  }
}

function makeWasiStub() {
  const ok = 0;
  const enosys = 52;
  const nop = () => enosys;
  return {
    args_get: () => ok,
    args_sizes_get: (c, s) => {
      void c;
      void s;
      return ok;
    },
    clock_res_get: () => enosys,
    clock_time_get: () => enosys,
    environ_get: () => ok,
    environ_sizes_get: () => ok,
    fd_close: () => ok,
    fd_fdstat_get: () => enosys,
    fd_filestat_get: nop,
    fd_filestat_set_size: nop,
    fd_filestat_set_times: nop,
    fd_pread: nop,
    fd_pwrite: nop,
    fd_read: () => enosys,
    fd_readdir: nop,
    fd_seek: () => enosys,
    fd_sync: () => ok,
    fd_write: () => enosys,
    path_create_directory: nop,
    path_filestat_get: nop,
    path_link: nop,
    path_open: nop,
    path_readlink: nop,
    path_remove_directory: nop,
    path_rename: nop,
    path_symlink: nop,
    path_unlink_file: nop,
    poll_oneoff: () => enosys,
    proc_exit: () => {},
    random_get: () => enosys,
  };
}

registerProcessor("vp-audio-processor", VpAudioProcessor);
