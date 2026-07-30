// KNGN AudioWorkletProcessor
//
// Two transports (selected by processorOptions.transport):
//
//   "shared" (default): second wasm Instance on SharedArrayBuffer Memory; process()
//   calls kngn_audio_render on the worklet thread (low latency; needs COOP/COEP).
//
//   "postmessage": no wasm on the worklet. Main thread renders into transferable
//   ArrayBuffers and posts them here. process() only copies from a fixed ring.
//   Trade-off: main-thread stalls underrun audio; deeper queue raises latency.
//
// RT contract for process() (binding):
//   - no allocation (including TypedArray construction)
//   - no port.postMessage
//   - no Wasm instantiate
//   - no String()/object construction for diagnostics
// Underrun / quantum / render-error counters are polled by the main thread via
// a non-RT {type:"poll-stats"} message (handled in port.onmessage).
// Shared render buffer views are rebuilt only on the non-RT port.onmessage path
// after wasm memory growth detaches the prebuilt Float32Array (never in process).
//
// Quantum contract: only 128-frame process quanta are accepted. Other sizes
// silence the output, set quantum_mismatches, and do not advance the ring.

const SENTINEL_MAGIC = 0x4B4E4153; // hex digits spell 'KNAS' — must match audio_web.zig

// postMessage ring capacity: 24 blocks × 128 frames × 2 channels (matches
// cli/audio_pm_ring.zig). The producer keeps only as many blocks queued as it needs —
// see the adaptive target in kngn.js — so the capacity is the ceiling, not the depth.
const PM_BLOCKS = 24;
const PM_FRAMES = 128;
const PM_CHANNELS = 2;
const PM_SAMPLES = PM_FRAMES * PM_CHANNELS;
// Shared render path also locks to 128-frame quanta for a fixed prebuilt view.
const SHARED_FRAMES = 128;
const SHARED_CHANNELS = 2;
const SHARED_SAMPLES = SHARED_FRAMES * SHARED_CHANNELS;

class KngnAudioProcessor extends AudioWorkletProcessor {
  /**
   * @param {{ processorOptions?: {
   *   transport?: string,
   *   module?: WebAssembly.Module,
   *   memory?: WebAssembly.Memory,
   *   stackTop?: number,
   *   channels?: number,
   *   sampleRate?: number,
   * }}} options
   */
  constructor(options) {
    super();
    const opts = options.processorOptions || {};
    this._transport = opts.transport || "shared";
    this._ready = false;
    this._channels = opts.channels || 2;
    this._sampleRate = opts.sampleRate || sampleRate;
    // RT-safe counters (process only increments; main polls via poll-stats).
    this._underruns = 0;
    this._quantumMismatches = 0;
    this._renderErrors = 0;
    this._viewDetached = 0;
    this._drops = 0;

    if (this._transport === "postmessage") {
      this._initPostMessage();
      return;
    }
    this._initShared(opts);
  }

  _initPostMessage() {
    // Fixed ring allocated once (constructor only; process never allocates).
    this._ring = new Float32Array(PM_BLOCKS * PM_SAMPLES);
    this._write = 0;
    this._read = 0;
    this._count = 0;
    this.port.onmessage = (ev) => this._onMessagePostMessage(ev);
    this._ready = true;
    this.port.postMessage({ type: "ready", transport: "postmessage" });
  }

  /**
   * @param {MessageEvent} ev
   */
  _onMessagePostMessage(ev) {
    const data = ev.data || {};
    if (data.type === "poll-stats") {
      // Non-RT path: main requested a snapshot of counters.
      this.port.postMessage({
        type: "stats",
        underruns: this._underruns,
        quantumMismatches: this._quantumMismatches,
        renderErrors: this._renderErrors,
        drops: this._drops,
        queueDepth: this._count,
      });
      return;
    }
    if (data.type === "audio" && data.buffer) {
      if (this._count < PM_BLOCKS) {
        const src = new Float32Array(data.buffer);
        const base = this._write * PM_SAMPLES;
        const n = Math.min(src.length, PM_SAMPLES);
        for (let i = 0; i < n; i++) this._ring[base + i] = src[i];
        for (let i = n; i < PM_SAMPLES; i++) this._ring[base + i] = 0;
        this._write = (this._write + 1) % PM_BLOCKS;
        this._count += 1;
      } else {
        // The ring is the authority on how much audio is buffered. Dropping a block
        // discards rendered samples, which the listener hears as a mangled stream, so
        // it is counted and surfaced rather than absorbed.
        this._drops += 1;
      }
      // Return the transferable to the main-thread pool (event path, not process) and
      // report the depth the producer must pace against.
      this.port.postMessage(
        { type: "buffer-return", buffer: data.buffer, depth: this._count, drops: this._drops },
        [data.buffer],
      );
    }
  }

  /**
   * @param {{
   *   module?: WebAssembly.Module,
   *   memory?: WebAssembly.Memory,
   *   stackTop?: number,
   *   channels?: number,
   *   sampleRate?: number,
   * }} opts
   */
  _initShared(opts) {
    this._memory = opts.memory;
    this._render = null;
    this._outPtr = 0;
    /** @type {Float32Array|null} fixed view built once for SHARED_SAMPLES */
    this._f32View = null;

    try {
      if (!opts.module || !opts.memory) {
        throw new Error("kngn-worklet: missing module/memory");
      }
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

      const stackTop = opts.stackTop | 0;
      if (stackTop > 0 && exp.__stack_pointer) {
        exp.__stack_pointer.value = stackTop;
      }

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
      // Prebuild the only TypedArray process() will touch (fixed 128-frame quantum).
      this._f32View = new Float32Array(this._memory.buffer, this._outPtr, SHARED_SAMPLES);
      this.port.onmessage = (ev) => this._onMessageShared(ev);
      this._ready = true;
      this.port.postMessage({ type: "ready", transport: "shared", sentinel: got });
    } catch (e) {
      this.port.postMessage({
        type: "error",
        message: String(e && e.message ? e.message : e),
      });
    }
  }

  /**
   * Non-RT only: rebuild the fixed render view after SharedArrayBuffer growth.
   * process() must never allocate a new TypedArray.
   * @returns {boolean} true if a usable view is available
   */
  _rebuildSharedViewIfNeeded() {
    if (!this._memory || !this._outPtr) return false;
    if (this._f32View && this._f32View.buffer === this._memory.buffer) {
      this._viewDetached = 0;
      return true;
    }
    try {
      this._f32View = new Float32Array(this._memory.buffer, this._outPtr, SHARED_SAMPLES);
      this._viewDetached = 0;
      return true;
    } catch (_) {
      this._f32View = null;
      this._viewDetached = 1;
      return false;
    }
  }

  /**
   * @param {MessageEvent} ev
   */
  _onMessageShared(ev) {
    const data = ev.data || {};
    // Non-RT: recover from memory.grow that detaches the prebuilt view.
    if (data.type === "rebuild-view" || data.type === "poll-stats") {
      this._rebuildSharedViewIfNeeded();
    }
    if (data.type === "poll-stats") {
      this.port.postMessage({
        type: "stats",
        underruns: this._underruns,
        quantumMismatches: this._quantumMismatches,
        renderErrors: this._renderErrors,
        viewDetached: this._viewDetached,
      });
    }
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

    if (this._transport === "postmessage") {
      return this._processPostMessage(output, frames);
    }
    return this._processShared(output, frames);
  }

  /**
   * @param {Float32Array[]} output
   * @param {number} frames
   * @returns {boolean}
   */
  _processPostMessage(output, frames) {
    if (!this._ready) {
      silenceOutputs(output);
      return true;
    }
    // Fixed 128-frame contract (cli/audio_pm_ring.zig PullResult.bad_quantum).
    if (frames !== PM_FRAMES) {
      this._quantumMismatches += 1;
      silenceOutputs(output);
      return true;
    }
    if (this._count === 0) {
      this._underruns += 1;
      silenceOutputs(output);
      return true;
    }
    const base = this._read * PM_SAMPLES;
    const channels = Math.min(this._channels, output.length, PM_CHANNELS);
    for (let i = 0; i < PM_FRAMES; i++) {
      for (let c = 0; c < channels; c++) {
        output[c][i] = this._ring[base + i * PM_CHANNELS + c];
      }
    }
    for (let c = channels; c < output.length; c++) {
      output[c].fill(0);
    }
    this._read = (this._read + 1) % PM_BLOCKS;
    this._count -= 1;
    return true;
  }

  /**
   * @param {Float32Array[]} output
   * @param {number} frames
   * @returns {boolean}
   */
  _processShared(output, frames) {
    if (!this._ready || !this._render) {
      silenceOutputs(output);
      return true;
    }
    if (frames !== SHARED_FRAMES) {
      this._quantumMismatches += 1;
      silenceOutputs(output);
      return true;
    }
    // Detached buffer after memory growth: never allocate on the RT path.
    // Main thread poll-stats / rebuild-view rebuilds the view on port.onmessage.
    if (!this._f32View || this._f32View.buffer !== this._memory.buffer) {
      this._viewDetached = 1;
      silenceOutputs(output);
      return true;
    }

    const channels = Math.min(this._channels, output.length, SHARED_CHANNELS);
    let ok = 0;
    try {
      ok = this._render(this._outPtr, SHARED_FRAMES, channels, this._sampleRate | 0);
    } catch (_) {
      this._renderErrors += 1;
      silenceOutputs(output);
      return true;
    }
    if (!ok) {
      silenceOutputs(output);
      return true;
    }
    const f32 = this._f32View;
    for (let i = 0; i < SHARED_FRAMES; i++) {
      for (let c = 0; c < channels; c++) {
        output[c][i] = f32[i * SHARED_CHANNELS + c];
      }
    }
    for (let c = channels; c < output.length; c++) {
      output[c].fill(0);
    }
    return true;
  }
}

/**
 * @param {Float32Array[]} output
 */
function silenceOutputs(output) {
  for (let c = 0; c < output.length; c++) output[c].fill(0);
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
