// KNGN AudioWorkletProcessor
// Synchronously create a 2nd Instance from the same WebAssembly.Module + SharedArrayBuffer Memory as main,
// and push-drive kngn_audio_render from process().
//
// stack: take the top of the worklet-only stack that main reserved in shared memory
//        and set it on exports.__stack_pointer.
// data: shared-memory builds use passive data segments + DataCount (confirmed by binary analysis).
//       2nd instantiate does not actively re-apply data. Plus a runtime sentinel check.
//
// instantiate at boot (g_state unset) is safe: process only reads g_state inside the running gate.

const SENTINEL_MAGIC = 0x4B4E4153; // hex digits spell 'KNAS' — must match audio_web.zig

class KngnAudioProcessor extends AudioWorkletProcessor {
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
    // Avoid RT GC pressure: cache the Float32Array view (rebuild only when buffer identity / ptr / len change)
    this._f32View = null;
    this._f32Buf = null;
    this._f32Ptr = 0;
    this._f32Len = 0;

    try {
      if (!opts.module || !opts.memory) {
        throw new Error("kngn-worklet: missing module/memory");
      }
      // The worklet only needs the audio-path env (it never calls present/log).
      // wasi may be touched by stdlib, so pass a minimal no-op surface.
      const imports = {
        env: {
          memory: opts.memory,
          kngn_now: () => currentTime,
          kngn_present: () => {},
          kngn_log: () => {},
          kngn_set_cursor: () => {},
          kngn_audio_open: () => 0,
          kngn_audio_start: () => {},
          kngn_audio_stop: () => {},
          kngn_audio_close: () => {},
        },
        wasi_snapshot_preview1: makeWasiStub(),
      };

      const instance = new WebAssembly.Instance(opts.module, imports);
      const exp = instance.exports;

      // (a) point the stack pointer at the top of the region main reserved
      const stackTop = opts.stackTop | 0;
      if (stackTop > 0 && exp.__stack_pointer) {
        exp.__stack_pointer.value = stackTop;
      }

      // Runtime sentinel: confirm the magic main set is still on shared memory after the 2nd Instance
      if (typeof exp.kngn_audio_check_sentinel !== "function") {
        throw new Error("kngn-worklet: missing kngn_audio_check_sentinel");
      }
      const got = exp.kngn_audio_check_sentinel() >>> 0;
      if (got !== SENTINEL_MAGIC) {
        throw new Error(
          "kngn-worklet: sentinel mismatch (got 0x" +
            got.toString(16) +
            ", want 0x" +
            SENTINEL_MAGIC.toString(16) +
            ") — 2nd instantiate may have clobbered shared state",
        );
      }

      this._render = exp.kngn_audio_render;
      this._outPtr =
        typeof exp.kngn_audio_render_buf === "function"
          ? exp.kngn_audio_render_buf() >>> 0
          : 0;
      if (typeof this._render !== "function" || this._outPtr === 0) {
        throw new Error("kngn-worklet: missing kngn_audio_render / render buf");
      }
      this._ready = true;
      this.port.postMessage({ type: "ready", sentinel: got });
    } catch (e) {
      // Do not throw from process (avoids tearing down the audio graph). boot awaits the result.
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
      // Return 0 = skipped (before start / frames too large, etc.) → silence, do not emit stale scratch
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
          message: "kngn_audio_render: " + String(e && e.message ? e.message : e),
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

registerProcessor("kngn-audio-processor", KngnAudioProcessor);
