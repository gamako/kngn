// video-proto wasm JS glue（TASK-73.1 + TASK-73.2 audio）
// import table:
//   env: vp_now / vp_present / vp_log / vp_set_cursor
//        + vp_audio_open / vp_audio_start / vp_audio_stop / vp_audio_close（audio app）
//   wasi_snapshot_preview1: 生成 wasm の import 実測に基づく手書き shim（外部依存なし）
//
// boot オプション（script type=module から、または data-*）:
//   wasm: "pixie.wasm" | "synth.wasm"（既定 pixie.wasm）
//   sharedMemory: true のとき import shared memory（synth audio 必須）
//   audio: true のとき AudioWorklet 経路を有効化（sharedMemory 必須）
//
// 時刻契約（M2）:
//   - アプリのフレーム時刻は常に env.vp_now（performance.now 基準・秒）
//   - WASI clock_time_get は stdlib 内部専用。monotonic も performance.now 基準で揃える
// DOM → vp_push_*（KeyCode 変換は Zig 側 table。JS は code 文字列の識別と export 呼び出しのみ）

const canvas = document.getElementById("vp-canvas");
const ctx2d = canvas.getContext("2d", { alpha: false });

/** @type {WebAssembly.Memory} */
let memory;
/** @type {WebAssembly.Instance} */
let instance;
/** @type {WebAssembly.Module | null} */
let wasmModule = null;

// ImageData は再利用（サイズ変化・memory growth 時のみ再生成。codex Medium#3）
let imageData = null;
let imageW = 0;
let imageH = 0;

const CURSOR_CSS = ["default", "crosshair", "none"];

// ---- audio state（TASK-73.2）----
/** @type {AudioContext | null} */
let audioCtx = null;
/** @type {AudioWorkletNode | null} */
let audioNode = null;
let audioChannels = 2;
/** start 意図フラグ。stop 後の gesture で意図せず resume しない（修正4） */
let audioWantRunning = false;
let audioGestureBound = false;
/**
 * boot で worklet Node 構築 + 2nd Instance + sentinel 検証が成功したとき true。
 * envAudioOpen はこれが false なら 0 を返す → Zig open が error.OpenFailed（修正2）。
 */
let audioReady = false;
const WORKLET_READY_TIMEOUT_MS = 5000;
const SENTINEL_MAGIC = 0x56504153;

// ---- WASI preview1 errno / clockid（実測 import 用最小面）----
const WASI_ESUCCESS = 0;
const WASI_EBADF = 8;
const WASI_EINVAL = 28;
const WASI_ENOSYS = 52;
const WASI_ENOTCAPABLE = 76;
const WASI_CLOCK_REALTIME = 0;
const WASI_CLOCK_MONOTONIC = 1;
const WASI_FILETYPE_CHARACTER_DEVICE = 2;

/** @type {Record<number, string>} */
const lineBuf = { 1: "", 2: "" };

function u32(ptr) {
  return new DataView(memory.buffer).getUint32(ptr, true);
}
function setU32(ptr, v) {
  new DataView(memory.buffer).setUint32(ptr, v >>> 0, true);
}
function setU64(ptr, v) {
  // BigInt で little-endian u64 を書く（Timestamp = ns）
  const dv = new DataView(memory.buffer);
  const bi = typeof v === "bigint" ? v : BigInt(Math.trunc(v));
  dv.setBigUint64(ptr, bi, true);
}
function bytesAt(ptr, len) {
  return new Uint8Array(memory.buffer, ptr, len);
}

function flushFd(fd) {
  const s = lineBuf[fd];
  if (s == null || s.length === 0) return;
  if (fd === 2) console.error(s);
  else console.log(s);
  lineBuf[fd] = "";
}

function appendFd(fd, text) {
  if (fd !== 1 && fd !== 2) return;
  let rest = text;
  while (rest.length > 0) {
    const nl = rest.indexOf("\n");
    if (nl < 0) {
      lineBuf[fd] += rest;
      return;
    }
    lineBuf[fd] += rest.slice(0, nl);
    flushFd(fd);
    rest = rest.slice(nl + 1);
  }
}

/** ciovec[] を連結して文字列化。戻り値は書込バイト数。 */
function concatIovecs(iovsPtr, iovsLen) {
  const parts = [];
  let total = 0;
  for (let i = 0; i < iovsLen; i++) {
    const base = iovsPtr + i * 8;
    const buf = u32(base);
    const len = u32(base + 4);
    if (len > 0) {
      parts.push(bytesAt(buf, len));
      total += len;
    }
  }
  if (parts.length === 0) return { text: "", total: 0 };
  const merged = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    merged.set(p, off);
    off += p.length;
  }
  return { text: new TextDecoder().decode(merged), total };
}

function writeFdstat(statPtr, filetype) {
  const dv = new DataView(memory.buffer);
  dv.setUint8(statPtr + 0, filetype);
  dv.setUint8(statPtr + 1, 0);
  dv.setUint16(statPtr + 2, 0, true); // fdflags
  dv.setUint32(statPtr + 4, 0, true); // pad to align rights
  dv.setBigUint64(statPtr + 8, 0n, true); // rights_base
  dv.setBigUint64(statPtr + 16, 0n, true); // rights_inheriting
}

/**
 * wasi_snapshot_preview1 — pixie.wasm の import 実測一覧に一致する手書き shim。
 * FS 系は NOTCAPABLE（永続 I/O は 73.3）。proc_exit は本ビルドでは未 import
 * （要求された場合は flush してから返す想定で helpers を用意）。
 */
const wasi = {
  clock_res_get(clockId, resolutionPtr) {
    if (clockId !== WASI_CLOCK_REALTIME && clockId !== WASI_CLOCK_MONOTONIC) {
      return WASI_EINVAL;
    }
    // 1ms 相当（ブラウザ timer 精度の目安）
    setU64(resolutionPtr, 1_000_000n);
    return WASI_ESUCCESS;
  },
  clock_time_get(clockId, _precision, timePtr) {
    // M2: monotonic = performance.now 基準。realtime は Date.now。
    // アプリ時刻は vp_now を使う（本関数は stdlib 内部専用）。
    let ns;
    if (clockId === WASI_CLOCK_MONOTONIC) {
      ns = BigInt(Math.trunc(performance.now() * 1e6));
    } else if (clockId === WASI_CLOCK_REALTIME) {
      ns = BigInt(Date.now()) * 1_000_000n;
    } else {
      return WASI_EINVAL;
    }
    setU64(timePtr, ns);
    return WASI_ESUCCESS;
  },
  environ_get(_environ, _environBuf) {
    return WASI_ESUCCESS;
  },
  environ_sizes_get(countPtr, bufSizePtr) {
    setU32(countPtr, 0);
    setU32(bufSizePtr, 0);
    return WASI_ESUCCESS;
  },
  fd_close(fd) {
    if (fd === 0 || fd === 1 || fd === 2) return WASI_ESUCCESS;
    return WASI_EBADF;
  },
  fd_fdstat_get(fd, statPtr) {
    if (fd === 0 || fd === 1 || fd === 2) {
      writeFdstat(statPtr, WASI_FILETYPE_CHARACTER_DEVICE);
      return WASI_ESUCCESS;
    }
    return WASI_EBADF;
  },
  fd_filestat_get() {
    return WASI_ENOTCAPABLE;
  },
  fd_filestat_set_size() {
    return WASI_ENOTCAPABLE;
  },
  fd_filestat_set_times() {
    return WASI_ENOTCAPABLE;
  },
  fd_pread() {
    return WASI_ENOTCAPABLE;
  },
  fd_pwrite(fd, iovsPtr, iovsLen, _offset, nwrittenPtr) {
    // offset 付きだが stdout/stderr は通常 seek 不可 → fd_write と同じ扱いでよい
    return wasi.fd_write(fd, iovsPtr, iovsLen, nwrittenPtr);
  },
  fd_read(fd, _iovsPtr, _iovsLen, nreadPtr) {
    if (fd === 0) {
      setU32(nreadPtr, 0); // EOF
      return WASI_ESUCCESS;
    }
    return WASI_EBADF;
  },
  fd_readdir() {
    return WASI_ENOTCAPABLE;
  },
  fd_seek(fd, _offset, _whence, newOffsetPtr) {
    if (fd === 0 || fd === 1 || fd === 2) {
      setU64(newOffsetPtr, 0n);
      return WASI_ESUCCESS;
    }
    return WASI_EBADF;
  },
  fd_sync(fd) {
    if (fd === 1 || fd === 2) {
      flushFd(fd);
      return WASI_ESUCCESS;
    }
    if (fd === 0) return WASI_ESUCCESS;
    return WASI_EBADF;
  },
  // M3: per-fd 行バッファ → newline で console.log/error。複数 iovec 連結。
  fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
    if (fd !== 1 && fd !== 2) return WASI_EBADF;
    const { text, total } = concatIovecs(iovsPtr, iovsLen);
    appendFd(fd, text);
    setU32(nwrittenPtr, total);
    return WASI_ESUCCESS;
  },
  path_create_directory() {
    return WASI_ENOTCAPABLE;
  },
  path_filestat_get() {
    return WASI_ENOTCAPABLE;
  },
  path_link() {
    return WASI_ENOTCAPABLE;
  },
  path_open() {
    return WASI_ENOTCAPABLE;
  },
  path_readlink() {
    return WASI_ENOTCAPABLE;
  },
  path_remove_directory() {
    return WASI_ENOTCAPABLE;
  },
  path_rename() {
    return WASI_ENOTCAPABLE;
  },
  path_symlink() {
    return WASI_ENOTCAPABLE;
  },
  path_unlink_file() {
    return WASI_ENOTCAPABLE;
  },
  poll_oneoff() {
    return WASI_ENOSYS;
  },
  random_get(bufPtr, bufLen) {
    const view = bytesAt(bufPtr, bufLen);
    if (typeof crypto !== "undefined" && crypto.getRandomValues) {
      crypto.getRandomValues(view);
    } else {
      for (let i = 0; i < bufLen; i++) view[i] = (Math.random() * 256) | 0;
    }
    return WASI_ESUCCESS;
  },
};

function modsFromEvent(e) {
  let m = 0;
  if (e.shiftKey) m |= 0x01;
  if (e.ctrlKey) m |= 0x02;
  if (e.altKey) m |= 0x04;
  if (e.metaKey) m |= 0x08;
  return m;
}

function buttonsFromEvent(e) {
  // MouseEvent.buttons: 1=left, 2=right, 4=middle → our packed: left/right/middle
  let b = 0;
  if (e.buttons & 1) b |= 0x01;
  if (e.buttons & 2) b |= 0x02;
  if (e.buttons & 4) b |= 0x04;
  return b;
}

function buttonIndex(e) {
  // DOM MouseEvent.button をそのまま渡す（0=left, 1=middle, 2=right）。
  // Zig 側 buttonFromDom が MouseButton（left=0,right=1,middle=2）へ変換する。
  // ※ 共有 enum の discriminant とは middle/right が入れ替わる点に注意。
  if (e.button === 0) return 0;
  if (e.button === 1) return 1;
  if (e.button === 2) return 2;
  return -1;
}

/** clientX/Y → canvas logical px（HiDPI / CSS scale 対応） */
function canvasLogicalXY(e) {
  const rect = canvas.getBoundingClientRect();
  const scaleX = canvas.width / rect.width;
  const scaleY = canvas.height / rect.height;
  const x = Math.round((e.clientX - rect.left) * scaleX);
  const y = Math.round((e.clientY - rect.top) * scaleY);
  return { x, y };
}

function writeDomCode(code) {
  const enc = new TextEncoder();
  const bytes = enc.encode(code);
  const scratch = instance.exports.vp_dom_code_scratch();
  const view = new Uint8Array(memory.buffer, scratch, 32);
  const n = Math.min(bytes.length, 32);
  view.set(bytes.subarray(0, n));
  return instance.exports.vp_dom_code_to_keycode(n);
}

function pushKey(e, down) {
  const code = writeDomCode(e.code);
  instance.exports.vp_push_key(down, code, modsFromEvent(e), !!e.repeat);
}

function shouldPreventKey(e) {
  // pixie / synth が使うキーのページデフォルトを抑止
  const c = e.code;
  return (
    c === "Space" ||
    c === "Tab" ||
    c.startsWith("Arrow") ||
    c === "Backspace" ||
    c === "Delete" ||
    ((e.metaKey || e.ctrlKey) && (c === "KeyZ" || c === "KeyS" || c === "KeyO" || c === "KeyQ")) ||
    // synth 鍵盤 A..K 周辺
    (c.startsWith("Key") && c.length === 4)
  );
}

/** コンテナの論理 px（DPR 非適用）を wasm へ通知。pending 方式でフレーム境界適用。 */
function reportCanvasSize() {
  if (!instance) return;
  const w = Math.round(canvas.clientWidth);
  const h = Math.round(canvas.clientHeight);
  if (w > 0 && h > 0) {
    instance.exports.vp_resize(w, h);
  }
}

function bindResize() {
  const ro = new ResizeObserver(() => reportCanvasSize());
  ro.observe(canvas);
  reportCanvasSize();
}

// ---- audio env imports ----

function showAudioError(msg) {
  console.error(msg);
  const el = document.getElementById("vp-error");
  if (el) {
    el.textContent = String(msg);
    el.style.display = "block";
  }
}

function ensureAudioGestureResume() {
  if (audioGestureBound) return;
  audioGestureBound = true;
  const hint = document.getElementById("vp-audio-hint");
  const tryResume = async () => {
    // stop 後の gesture で意図せず再開しない（修正4）
    if (!audioWantRunning) return;
    if (!audioCtx) return;
    if (audioCtx.state === "suspended") {
      try {
        await audioCtx.resume();
      } catch (e) {
        console.warn("AudioContext.resume failed:", e);
      }
    }
    if (audioCtx.state === "running" && hint) {
      hint.style.display = "none";
    }
  };
  // クリック / キーで resume（autoplay policy）
  const onGesture = () => {
    void tryResume();
  };
  canvas.addEventListener("pointerdown", onGesture, { capture: true });
  window.addEventListener("keydown", onGesture, { capture: true });
  if (hint) {
    hint.style.display = "block";
    hint.addEventListener("click", onGesture);
  }
}

/**
 * boot: main Instance 生成後・vp_init 前に AudioWorkletNode を構築し、
 * worklet 側 2nd Instance + sentinel 検証の ready を await する（修正1/2）。
 * g_state は未設定だが worklet は running ゲート内でしか読まないので安全。
 * @param {number} channels
 * @returns {Promise<void>}
 */
function prepareAudioWorkletNode(channels) {
  return new Promise((resolve, reject) => {
    if (!audioCtx || !wasmModule || !memory || !instance) {
      reject(new Error("prepareAudioWorkletNode: ctx/module/memory/instance missing"));
      return;
    }
    if (typeof instance.exports.vp_audio_set_sentinel !== "function") {
      reject(new Error("prepareAudioWorkletNode: missing vp_audio_set_sentinel"));
      return;
    }
    // main が shared memory 上に magic を書く（worklet instantiate 前）
    instance.exports.vp_audio_set_sentinel();

    const stackTop =
      typeof instance.exports.vp_audio_worklet_stack_top === "function"
        ? instance.exports.vp_audio_worklet_stack_top() >>> 0
        : 0;
    if (!stackTop) {
      reject(new Error("prepareAudioWorkletNode: missing stack top"));
      return;
    }

    audioChannels = channels || 2;
    const actualSr = audioCtx.sampleRate | 0;
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error("vp-worklet: ready timeout (" + WORKLET_READY_TIMEOUT_MS + "ms)"));
    }, WORKLET_READY_TIMEOUT_MS);

    try {
      if (audioNode) {
        try {
          audioNode.disconnect();
        } catch (_) {}
        audioNode = null;
      }
      audioNode = new AudioWorkletNode(audioCtx, "vp-audio-processor", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [audioChannels],
        processorOptions: {
          module: wasmModule,
          memory: memory,
          stackTop: stackTop,
          channels: audioChannels,
          sampleRate: actualSr,
        },
      });
      audioNode.port.onmessage = (ev) => {
        const data = ev.data || {};
        if (data.type === "ready") {
          if (settled) return;
          if ((data.sentinel >>> 0) !== SENTINEL_MAGIC) {
            settled = true;
            clearTimeout(timer);
            reject(new Error("vp-worklet: ready with bad sentinel 0x" + (data.sentinel >>> 0).toString(16)));
            return;
          }
          settled = true;
          clearTimeout(timer);
          resolve();
          return;
        }
        if (data.type === "error") {
          if (settled) {
            console.error("vp-worklet:", data.message);
            return;
          }
          settled = true;
          clearTimeout(timer);
          reject(new Error("vp-worklet: " + data.message));
        }
      };
      audioNode.connect(audioCtx.destination);
    } catch (e) {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(e);
      }
    }
  });
}

/**
 * Zig `vp_audio_open` → boot 済み worklet を確認して実 sample rate を返す。
 * Node 生成は boot に前倒し済み。audioReady でなければ 0（修正2）。
 * @returns {number} actual sample rate, or 0 on failure
 */
function envAudioOpen(sampleRate, channels, bufferFrames) {
  void sampleRate;
  void bufferFrames;
  void channels;
  try {
    if (typeof SharedArrayBuffer === "undefined") {
      console.error("vp_audio_open: SharedArrayBuffer unavailable (need COOP/COEP)");
      return 0;
    }
    if (!globalThis.crossOriginIsolated) {
      console.error(
        "vp_audio_open: crossOriginIsolated=false (serve with COOP/COEP; scripts/serve-web.py)",
      );
      return 0;
    }
    if (!audioReady || !audioCtx || !audioNode) {
      console.error("vp_audio_open: worklet not ready (boot failed or not audio app)");
      return 0;
    }
    ensureAudioGestureResume();
    return audioCtx.sampleRate | 0;
  } catch (e) {
    console.error("vp_audio_open failed:", e);
    return 0;
  }
}

function envAudioStart() {
  audioWantRunning = true;
  if (!audioCtx) return;
  if (audioCtx.state === "suspended") {
    ensureAudioGestureResume();
    void audioCtx.resume().catch((e) => console.warn("resume:", e));
  }
}

function envAudioStop() {
  audioWantRunning = false;
  if (audioCtx && audioCtx.state === "running") {
    void audioCtx.suspend().catch(() => {});
  }
}

function envAudioClose() {
  audioWantRunning = false;
  audioReady = false;
  if (audioNode) {
    try {
      audioNode.disconnect();
    } catch (_) {}
    audioNode = null;
  }
  if (audioCtx) {
    void audioCtx.close().catch(() => {});
    audioCtx = null;
  }
}

function makeImportObject() {
  return {
    env: {
      // アプリ時刻の正（フレーム・getTime）。WASI clock は使わない。
      vp_now() {
        return performance.now() / 1000;
      },
      vp_present(ptr, w, h) {
        // memory growth で旧 ArrayBuffer が detach するため、毎回 buffer から view を作り直す
        const nbytes = (w * h * 4) >>> 0;
        const wasmView = new Uint8ClampedArray(memory.buffer, ptr, nbytes);
        if (!imageData || imageW !== w || imageH !== h || imageData.data.length !== nbytes) {
          imageData = ctx2d.createImageData(w, h);
          imageW = w;
          imageH = h;
          if (canvas.width !== w || canvas.height !== h) {
            canvas.width = w;
            canvas.height = h;
          }
        }
        imageData.data.set(wasmView);
        ctx2d.putImageData(imageData, 0, 0);
      },
      vp_log(ptr, len) {
        const bytes = new Uint8Array(memory.buffer, ptr, len);
        console.log(new TextDecoder().decode(bytes));
      },
      vp_set_cursor(shape) {
        canvas.style.cursor = CURSOR_CSS[shape] || "default";
      },
      vp_audio_open: envAudioOpen,
      vp_audio_start: envAudioStart,
      vp_audio_stop: envAudioStop,
      vp_audio_close: envAudioClose,
    },
    wasi_snapshot_preview1: wasi,
  };
}

function bindInput() {
  canvas.addEventListener("keydown", (e) => {
    if (shouldPreventKey(e)) e.preventDefault();
    pushKey(e, true);
  });
  canvas.addEventListener("keyup", (e) => {
    if (shouldPreventKey(e)) e.preventDefault();
    pushKey(e, false);
  });
  // 確定文字（char_input）。制御キーは Zig 側でも弾く
  canvas.addEventListener("keypress", (e) => {
    if (e.charCode && e.charCode >= 0x20) {
      instance.exports.vp_push_char(e.charCode, modsFromEvent(e));
    }
  });

  canvas.addEventListener("mousemove", (e) => {
    const { x, y } = canvasLogicalXY(e);
    instance.exports.vp_push_mouse(0, x, y, -1, buttonsFromEvent(e), modsFromEvent(e));
  });
  canvas.addEventListener("mousedown", (e) => {
    canvas.focus();
    const { x, y } = canvasLogicalXY(e);
    instance.exports.vp_push_mouse(1, x, y, buttonIndex(e), buttonsFromEvent(e), modsFromEvent(e));
  });
  canvas.addEventListener("mouseup", (e) => {
    const { x, y } = canvasLogicalXY(e);
    instance.exports.vp_push_mouse(2, x, y, buttonIndex(e), buttonsFromEvent(e), modsFromEvent(e));
  });
  canvas.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault(); // ページスクロール抑止
      const { x, y } = canvasLogicalXY(e);
      // DOM wheel は下方向が正 → pixie/gui 慣習に合わせ dy を反転
      instance.exports.vp_push_scroll(x, y, -e.deltaX, -e.deltaY, modsFromEvent(e));
    },
    { passive: false },
  );
  canvas.addEventListener("contextmenu", (e) => e.preventDefault());
}

/**
 * @param {{
 *   wasm?: string,
 *   sharedMemory?: boolean,
 *   audio?: boolean,
 *   initialPages?: number,
 *   maxPages?: number,
 * }} [opts]
 */
export async function boot(opts = {}) {
  const wasmUrl = opts.wasm || "pixie.wasm";
  const useShared = !!(opts.sharedMemory || opts.audio);
  const useAudio = !!opts.audio;
  const initialPages = opts.initialPages || 256; // 16 MiB
  const maxPages = opts.maxPages || 1024; // 64 MiB

  canvas.focus();
  audioReady = false;

  if (useAudio) {
    // addModule は「node を作る同一 AudioContext」に対して必須。
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) throw new Error("AudioContext not available");
    if (typeof SharedArrayBuffer === "undefined" || !globalThis.crossOriginIsolated) {
      throw new Error(
        "audio requires cross-origin isolation (COOP/COEP). Use: python3 scripts/serve-web.py zig-out/web",
      );
    }
    audioCtx = new AC({ sampleRate: 48000 });
    await audioCtx.audioWorklet.addModule(new URL("./vp-worklet.js", import.meta.url).href);
  }

  const resp = await fetch(new URL("./" + wasmUrl, import.meta.url).href);
  const bytes = await resp.arrayBuffer();
  wasmModule = await WebAssembly.compile(bytes);

  const importObject = makeImportObject();

  if (useShared) {
    if (typeof SharedArrayBuffer === "undefined" || !globalThis.crossOriginIsolated) {
      throw new Error(
        "shared memory requires cross-origin isolation (COOP/COEP). Use: python3 scripts/serve-web.py",
      );
    }
    memory = new WebAssembly.Memory({
      initial: initialPages,
      maximum: maxPages,
      shared: true,
    });
    importObject.env.memory = memory;
    instance = await WebAssembly.instantiate(wasmModule, importObject);
  } else {
    instance = await WebAssembly.instantiate(wasmModule, importObject);
    memory = /** @type {WebAssembly.Memory} */ (instance.exports.memory);
  }

  // audio: vp_init 前に 2nd Instance + sentinel 検証を完了（失敗 → open も失敗）（修正2）
  if (useAudio) {
    try {
      await prepareAudioWorkletNode(2);
      audioReady = true;
      ensureAudioGestureResume();
    } catch (e) {
      audioReady = false;
      showAudioError(e && e.message ? e.message : e);
      // グラフィックスは続行。audio.open は OpenFailed になる。
      console.warn("audio disabled:", e);
    }
  }

  bindInput();
  bindResize();
  instance.exports.vp_init();

  function loop(ts) {
    instance.exports.vp_frame(ts); // rAF ms。Zig 側で /1000
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
}

// 既定: index.html は data 属性 or クエリ無しで pixie
function defaultOptsFromPage() {
  const params = new URLSearchParams(location.search);
  const body = document.body;
  const wasm =
    params.get("wasm") || body?.dataset?.wasm || (location.pathname.includes("synth") ? "synth.wasm" : "pixie.wasm");
  const audio =
    params.get("audio") === "1" ||
    body?.dataset?.audio === "1" ||
    wasm.includes("synth");
  const sharedMemory =
    params.get("shared") === "1" ||
    body?.dataset?.shared === "1" ||
    audio;
  return { wasm, audio, sharedMemory };
}

// type=module のトップレベル自動起動（import { boot } でも可）
if (!globalThis.__vpManualBoot) {
  boot(defaultOptsFromPage()).catch((err) => {
    console.error(err);
    const el = document.getElementById("vp-error");
    if (el) {
      el.textContent = String(err && err.message ? err.message : err);
      el.style.display = "block";
    }
  });
}
