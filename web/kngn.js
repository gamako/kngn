// KNGN wasm JS glue (audio + file/clipboard)
// import table:
//   env: kngn_now / kngn_present / kngn_log / kngn_set_cursor / kngn_device_pixel_ratio
//        + kngn_audio_open / kngn_audio_start / kngn_audio_stop / kngn_audio_close (audio app)
//        + kngn_request_open / kngn_clipboard_write / kngn_request_paste (file dialog / clipboard)
//   wasi_snapshot_preview1: hand-written shim + in-memory FS (path_open/fd_read/write/seek/close)
//
// boot options (from a script type=module import, data-* attrs, or __kngnEmbedded):
//   wasm: filename (default pixie.wasm)
//   audioTransport: "none" | "worklet_shared" | "worklet_postmessage"
//   sharedMemory: true only with worklet_shared (COOP/COEP required)
//   embedded + wasmBase64: single-HTML package (no fetch of .wasm)
//   workletSource: embedded worklet text for postMessage single-HTML
//
// Time contract:
//   - App frame time is always env.kngn_now (performance.now based, seconds)
//   - WASI clock_time_get is for stdlib internals only. monotonic is also performance.now based
// DOM → kngn_push_* (KeyCode conversion is a Zig-side table. JS only identifies code strings and calls exports)
//
// DPR (ADR-011 R1/R2):
//   - kngn_resize(w, h, dpr) carries the canvas's CSS box and devicePixelRatio together. Both
//     bindResize()'s ResizeObserver and bindDprWatcher()'s matchMedia watcher call it, each
//     re-reading the other quantity too, so it never applies half of a stale combination.
//   - Mouse/wheel coordinates are raw physical (CSS × devicePixelRatio) regardless of fb_mode; the
//     Zig facade divides by the frame-latched content_scale to recover logical points.
//
// File I/O:
//   - open: <input type=file> → register bytes at virtual path `pick/<name>` → kngn_file_picked
//   - save: Zig writes a path via WASI write → Blob download on fd_close
//   - OPFS is not used (download/pick round-trip is enough for .pix)

const canvas = document.getElementById("kngn-canvas");
const ctx2d = canvas.getContext("2d", { alpha: false });

/** @type {WebAssembly.Memory} */
let memory;
/** @type {WebAssembly.Instance} */
let instance;
/** @type {WebAssembly.Module | null} */
let wasmModule = null;

// The copy path's own ImageData is reused, and rebuilt when the frame size or its byte
// length changes. It does not view wasm memory, so growing memory does not invalidate it.
let imageData = null;
let imageW = 0;
let imageH = 0;
// Whether present may hand putImageData an ImageData that views wasm memory directly
// instead of copying into one. Latched when memory is created: an ImageData cannot be
// built over a SharedArrayBuffer, and whether memory is shared is fixed for the run.
let presentCanAlias = false;
// Set if constructing that ImageData ever throws for a reason the shared check did not
// predict, so the copy path takes over for good and the warning is printed once.
let presentAliasFailed = false;

const CURSOR_CSS = ["default", "crosshair", "none"];

// ---- audio state ----
/** @type {AudioContext | null} */
let audioCtx = null;
/** @type {AudioWorkletNode | null} */
let audioNode = null;
let audioChannels = 2;
/** Intent-to-start flag. After stop, a later gesture must not resume unintentionally. */
let audioWantRunning = false;
let audioGestureBound = false;
/**
 * true when boot built the worklet Node, 2nd Instance, and sentinel checks successfully.
 * When false, envAudioOpen returns 0 so Zig open fails with error.OpenFailed.
 */
let audioReady = false;
const WORKLET_READY_TIMEOUT_MS = 5000;
const SENTINEL_MAGIC = 0x4B4E4153;

// ---- WASI preview1 errno / clockid (minimal surface for the measured imports) ----
const WASI_ESUCCESS = 0;
const WASI_EBADF = 8;
const WASI_EEXIST = 20;
const WASI_EFBIG = 22;
const WASI_EINVAL = 28;
const WASI_ENOENT = 44;
const WASI_ENOSYS = 52;
const WASI_ENOTCAPABLE = 76;
/** memFS size/offset/growth cap (64 MiB). Over that: EFBIG/EINVAL. */
const MEMFS_MAX_BYTES = 64 * 1024 * 1024;
const WASI_CLOCK_REALTIME = 0;
const WASI_CLOCK_MONOTONIC = 1;
const WASI_FILETYPE_CHARACTER_DEVICE = 2;
const WASI_FILETYPE_DIRECTORY = 3;
const WASI_FILETYPE_REGULAR_FILE = 4;
/** Zig wasi cwd = fd 3 (first preopen) */
const WASI_PREOPEN_FD = 3;
/** oflags bits (wasi oflags_t packed) */
const WASI_O_CREAT = 1;
const WASI_O_DIRECTORY = 2;
const WASI_O_EXCL = 4;
const WASI_O_TRUNC = 8;
/** whence */
const WASI_WHENCE_SET = 0;
const WASI_WHENCE_CUR = 1;
const WASI_WHENCE_END = 2;

// ---- harness host bridge ----
// Present only when the module was built with the real harness (`-Dwasm-harness=true`); a normal
// build exports none of `kngn_harness_*` and pays nothing here but one feature test at boot.
// The page submits one command batch, the wasm side runs it across as many frames as `step` and
// `await` ask for, and the response is picked up in the frame loop the moment it is ready.
/** @type {{resolve: (s: string) => void, reject: (e: Error) => void} | null} */
let harnessPending = null;
/** Serialises exec(): the bridge accepts one request at a time. */
let harnessChain = Promise.resolve();
let harnessEnabled = false;

function harnessAvailable() {
  return (
    !!instance &&
    typeof instance.exports.kngn_harness_submit === "function" &&
    typeof instance.exports.kngn_harness_enable === "function"
  );
}

/**
 * Reads and clears the response the wasm side just published, together with the snapshots the
 * batch took. A snapshot is binary and travels beside the text, on its own channel: a blob of
 * concatenated bytes plus a manifest naming and locating each one. Both are read before the clear,
 * and every view over `memory.buffer` is made fresh, since a growing memory detaches the old one.
 * @returns {{response: string, snapshots: Array<{name: string, bytes: Uint8Array}>}}
 */
function harnessTakeResponse() {
  const ptr = instance.exports.kngn_harness_response_ptr() >>> 0;
  const len = instance.exports.kngn_harness_response_len() >>> 0;
  const copy = new Uint8Array(len);
  copy.set(new Uint8Array(memory.buffer, ptr, len));
  const snapshots = harnessTakeSnapshots();
  instance.exports.kngn_harness_response_clear();
  return { response: new TextDecoder().decode(copy), snapshots };
}

/** The snapshot half of `harnessTakeResponse`. Empty unless the batch took one. */
function harnessTakeSnapshots() {
  const mptr = instance.exports.kngn_harness_attachments_manifest_ptr() >>> 0;
  const mlen = instance.exports.kngn_harness_attachments_manifest_len() >>> 0;
  if (mlen === 0) return [];
  const manifest = new TextDecoder().decode(new Uint8Array(memory.buffer, mptr, mlen).slice());
  const entries = JSON.parse(manifest);
  if (entries.length === 0) return [];
  const bptr = instance.exports.kngn_harness_attachments_ptr() >>> 0;
  return entries.map((e) => ({
    name: e.name,
    bytes: new Uint8Array(memory.buffer, bptr + e.off, e.len).slice(),
  }));
}

/** Called once per frame, right after kngn_frame, which is where a response becomes ready. */
function harnessPump() {
  if (!harnessPending) return;
  if (!instance.exports.kngn_harness_response_ready()) return;
  const p = harnessPending;
  harnessPending = null;
  p.resolve(harnessTakeResponse());
}

function harnessSubmit(text) {
  return new Promise((resolve, reject) => {
    if (!harnessEnabled) {
      reject(new Error("harness bridge is not enabled in this build"));
      return;
    }
    const bytes = new TextEncoder().encode(text.endsWith("\n") ? text : text + "\n");
    const cap = instance.exports.kngn_harness_request_cap() >>> 0;
    if (bytes.length > cap) {
      reject(new Error("harness request is " + bytes.length + " bytes, over the " + cap + " limit"));
      return;
    }
    const ptr = instance.exports.kngn_harness_request_ptr() >>> 0;
    new Uint8Array(memory.buffer, ptr, cap).set(bytes);
    if (!instance.exports.kngn_harness_submit(bytes.length)) {
      reject(new Error("harness bridge refused the request (not started, or one is in flight)"));
      return;
    }
    harnessPending = { resolve, reject };
  });
}

/** Queues one batch behind the ones already in flight: the bridge accepts a single request at a time. */
function harnessExec(text) {
  const run = harnessChain.then(
    () => harnessSubmit(text),
    () => harnessSubmit(text),
  );
  harnessChain = run.catch(() => {});
  return run;
}

/**
 * Installs `globalThis.__kngnHarness`. `exec(text)` sends one command batch and resolves with the
 * response, the same text the TCP transport would return. Calls are serialised, so an external
 * driver may fire them without tracking whether the previous one has landed.
 */
function installHarnessBridge(captureFrames) {
  instance.exports.kngn_harness_enable(captureFrames ? 0 : 1);
  harnessEnabled = true;
  globalThis.__kngnHarness = {
    exec(text) {
      return harnessExec(text).then((r) => r.response);
    },
    /**
     * The same batch as `exec`, resolving with the snapshots as well: `{response, snapshots}`,
     * where each snapshot is `{name, bytes}`. A `snapshot` command has no file to write to here,
     * so its bytes come back this way and the caller decides where they go; `exec` drops them.
     */
    execWithSnapshots(text) {
      return harnessExec(text);
    },
    /**
     * Drives the platform resize seam directly — the same call bindResize and bindDprWatcher make.
     * It exercises how the backend commits a size or ratio change (and therefore scale_epoch). It
     * does **not** change the browser's own devicePixelRatio, which is fixed for the page's life:
     * a driver that wants a real ratio must launch the browser with one.
     */
    resize(w, h, dpr) {
      instance.exports.kngn_resize(w >>> 0, h >>> 0, +dpr);
    },
    /** What the browser reports right now, so a driver can record the environment it measured in. */
    devicePixelRatio() {
      return window.devicePixelRatio;
    },
  };
}

/** @type {Record<number, string>} */
const lineBuf = { 1: "", 2: "" };

function u32(ptr) {
  return new DataView(memory.buffer).getUint32(ptr, true);
}
function setU32(ptr, v) {
  new DataView(memory.buffer).setUint32(ptr, v >>> 0, true);
}
function setU64(ptr, v) {
  // Write a little-endian u64 via BigInt (Timestamp = ns)
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

/** Concatenate ciovec[] into a string. Returns bytes written. */
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

/** filestat_t (64B): dev/ino u64, filetype u8 + pad, nlink u64, size u64, atim/mtim/ctim u64 */
function writeFilestat(statPtr, filetype, size) {
  const dv = new DataView(memory.buffer);
  dv.setBigUint64(statPtr + 0, 0n, true); // dev
  dv.setBigUint64(statPtr + 8, 1n, true); // ino
  dv.setUint8(statPtr + 16, filetype);
  // pad 17..23
  for (let i = 17; i < 24; i++) dv.setUint8(statPtr + i, 0);
  dv.setBigUint64(statPtr + 24, 1n, true); // nlink
  dv.setBigUint64(statPtr + 32, BigInt(size >>> 0), true);
  const nowNs = BigInt(Date.now()) * 1_000_000n;
  dv.setBigUint64(statPtr + 40, nowNs, true); // atim
  dv.setBigUint64(statPtr + 48, nowNs, true); // mtim
  dv.setBigUint64(statPtr + 56, nowNs, true); // ctim
}

// ---- in-memory FS ----
/** @type {Map<string, Uint8Array>} path → file bytes */
const memFiles = new Map();
/**
 * @typedef {{ path: string, data: Uint8Array, pos: number, writable: boolean, dirty: boolean }} MemFd
 * @type {Map<number, MemFd>}
 */
const memFds = new Map();
let nextMemFd = 4;

/** open picker in progress (prevent double-fire) */
let openPickerBusy = false;
/** @type {HTMLInputElement | null} */
let hiddenFileInput = null;

function normalizePath(p) {
  let s = String(p || "");
  // strip leading ./ and /
  s = s.replace(/^\.\/+/, "").replace(/^\/+/, "");
  // collapse //
  s = s.replace(/\/+/g, "/");
  if (s === "" || s === ".") return "";
  return s;
}

function pathBasename(p) {
  const s = normalizePath(p);
  const i = s.lastIndexOf("/");
  const base = i >= 0 ? s.slice(i + 1) : s;
  if (!base || base === "." || base === "..") return "download";
  return base;
}

function makePickPath(filename) {
  let base = pathBasename(filename);
  // Strip path traversal (basename already applied; belt-and-suspenders)
  base = base.replace(/[\\/]/g, "_");
  if (!base || base === "." || base === "..") base = "file";
  return "pick/" + base;
}

/**
 * Truncate by code point so the UTF-8 byte length stays <= maxBytes.
 * Avoids breaking UTF-8 with a raw byte cut, and keeps the memFS key and wasm delivery path identical.
 * @param {string} s
 * @param {number} maxBytes
 * @returns {string}
 */
function clampUtf8(s, maxBytes) {
  const enc = new TextEncoder();
  if (enc.encode(s).length <= maxBytes) return s;
  const cps = Array.from(s);
  while (cps.length && enc.encode(cps.join("")).length > maxBytes) cps.pop();
  return cps.join("");
}

/**
 * BigInt/number → non-negative SafeInteger. Returns null if invalid.
 * @param {number|bigint} v
 * @returns {number|null}
 */
function asSafeNonNegInt(v) {
  let n;
  try {
    if (typeof v === "bigint") {
      if (v < 0n || v > BigInt(Number.MAX_SAFE_INTEGER)) return null;
      n = Number(v);
    } else {
      n = Number(v);
    }
  } catch (_) {
    return null;
  }
  if (!Number.isSafeInteger(n) || n < 0) return null;
  return n;
}

/**
 * BigInt/number → signed SafeInteger (for fd_seek delta). Returns null if invalid.
 * @param {number|bigint} v
 * @returns {number|null}
 */
function asSafeInt(v) {
  let n;
  try {
    if (typeof v === "bigint") {
      if (v < BigInt(Number.MIN_SAFE_INTEGER) || v > BigInt(Number.MAX_SAFE_INTEGER)) return null;
      n = Number(v);
    } else {
      n = Number(v);
    }
  } catch (_) {
    return null;
  }
  if (!Number.isSafeInteger(n)) return null;
  return n;
}

function registerMemFile(path, bytes) {
  const key = normalizePath(path);
  memFiles.set(key, bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
  return key;
}

function triggerDownload(filename, data) {
  try {
    const blob = new Blob([data], { type: "application/octet-stream" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename || "download";
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    a.remove();
    // Delay revoke (some browsers fail download if revoke is immediate)
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  } catch (e) {
    console.error("download failed:", e);
  }
}

function ensureFileInput() {
  if (hiddenFileInput) return hiddenFileInput;
  const input = document.createElement("input");
  input.type = "file";
  input.style.display = "none";
  input.addEventListener("change", () => {
    const file = input.files && input.files[0];
    input.value = ""; // Allow re-selecting the same file
    if (!file) {
      openPickerBusy = false;
      if (instance && typeof instance.exports.kngn_file_cancelled === "function") {
        instance.exports.kngn_file_cancelled();
      }
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      openPickerBusy = false;
      try {
        const buf = new Uint8Array(reader.result);
        // Keep the registered key and the wasm delivery path as the same string (UTF-8-safe clamp; scratch 256B contract)
        const vpath = clampUtf8(makePickPath(file.name), 256);
        registerMemFile(vpath, buf);
        deliverPickedPath(vpath);
      } catch (e) {
        console.error("file pick deliver failed:", e);
        if (instance && typeof instance.exports.kngn_file_cancelled === "function") {
          instance.exports.kngn_file_cancelled();
        }
      }
    };
    reader.onerror = () => {
      openPickerBusy = false;
      console.error("FileReader error");
      if (instance && typeof instance.exports.kngn_file_cancelled === "function") {
        instance.exports.kngn_file_cancelled();
      }
    };
    reader.readAsArrayBuffer(file);
  });
  // cancel: some browsers expose a cancel event
  input.addEventListener("cancel", () => {
    openPickerBusy = false;
    if (instance && typeof instance.exports.kngn_file_cancelled === "function") {
      instance.exports.kngn_file_cancelled();
    }
  });
  document.body.appendChild(input);
  hiddenFileInput = input;
  return input;
}

function deliverPickedPath(vpath) {
  // Caller already clampUtf8(..., 256) on vpath. Do not re-truncate here (avoids key mismatch).
  if (!instance || typeof instance.exports.kngn_file_path_scratch !== "function") return;
  const enc = new TextEncoder();
  const bytes = enc.encode(vpath);
  const scratch = instance.exports.kngn_file_path_scratch();
  const view = new Uint8Array(memory.buffer, scratch, 256);
  view.set(bytes);
  instance.exports.kngn_file_picked(bytes.length);
}

/**
 * Zig `kngn_request_open` — fire <input type=file>.
 * @param {number} extPtr
 * @param {number} extLen
 */
function envRequestOpen(extPtr, extLen) {
  if (openPickerBusy) return; // Prevent double-fire
  openPickerBusy = true;
  const input = ensureFileInput();
  let accept = "";
  if (extLen > 0) {
    try {
      const ext = new TextDecoder().decode(bytesAt(extPtr, extLen));
      // Hint like "png" → ".png,image/png"
      if (ext && !ext.includes("/") && !ext.startsWith(".")) {
        accept = "." + ext;
      } else {
        accept = ext;
      }
    } catch (_) {
      accept = "";
    }
  }
  input.accept = accept;
  // click often works even outside a user gesture (via a button-origin frame)
  try {
    input.click();
  } catch (e) {
    openPickerBusy = false;
    console.error("file input click failed:", e);
    if (instance && typeof instance.exports.kngn_file_cancelled === "function") {
      instance.exports.kngn_file_cancelled();
    }
  }
}

/**
 * @param {number} ptr
 * @param {number} len
 */
function envClipboardWrite(ptr, len) {
  if (len <= 0) return;
  try {
    const text = new TextDecoder().decode(bytesAt(ptr, len));
    if (navigator.clipboard && navigator.clipboard.writeText) {
      void navigator.clipboard.writeText(text).catch((e) => console.warn("clipboard write:", e));
    }
  } catch (e) {
    console.warn("clipboard write failed:", e);
  }
}

function envRequestPaste() {
  const deliver = (text) => {
    if (!instance || typeof instance.exports.kngn_clipboard_text_scratch !== "function") return;
    const enc = new TextEncoder();
    const bytes = enc.encode(String(text || ""));
    const scratch = instance.exports.kngn_clipboard_text_scratch();
    const view = new Uint8Array(memory.buffer, scratch, 64);
    const n = Math.min(bytes.length, 64);
    view.set(bytes.subarray(0, n));
    instance.exports.kngn_clipboard_text(n);
  };
  if (!navigator.clipboard || !navigator.clipboard.readText) {
    deliver("");
    return;
  }
  void navigator.clipboard
    .readText()
    .then((t) => deliver(t))
    .catch((e) => {
      console.warn("clipboard read:", e);
      deliver("");
    });
}

/**
 * wasi_snapshot_preview1 — hand-written shim + in-memory FS.
 * stdin/stdout/stderr go to console. Regular files use memFiles/memFds. cwd preopen = fd 3.
 */
const wasi = {
  clock_res_get(clockId, resolutionPtr) {
    if (clockId !== WASI_CLOCK_REALTIME && clockId !== WASI_CLOCK_MONOTONIC) {
      return WASI_EINVAL;
    }
    // About 1ms (rough browser timer resolution)
    setU64(resolutionPtr, 1_000_000n);
    return WASI_ESUCCESS;
  },
  clock_time_get(clockId, _precision, timePtr) {
    // monotonic = performance.now based. realtime = Date.now.
    // App time uses kngn_now (this function is stdlib-internal only).
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
    if (fd === 0 || fd === 1 || fd === 2 || fd === WASI_PREOPEN_FD) return WASI_ESUCCESS;
    const ent = memFds.get(fd);
    if (!ent) return WASI_EBADF;
    memFds.delete(fd);
    // If written, commit into memFiles and fire download
    if (ent.writable && ent.dirty) {
      memFiles.set(ent.path, ent.data);
      triggerDownload(pathBasename(ent.path), ent.data);
    } else if (ent.writable) {
      // Even an empty write registers the path (create-only)
      memFiles.set(ent.path, ent.data);
    }
    return WASI_ESUCCESS;
  },
  fd_fdstat_get(fd, statPtr) {
    if (fd === 0 || fd === 1 || fd === 2) {
      writeFdstat(statPtr, WASI_FILETYPE_CHARACTER_DEVICE);
      return WASI_ESUCCESS;
    }
    if (fd === WASI_PREOPEN_FD) {
      writeFdstat(statPtr, WASI_FILETYPE_DIRECTORY);
      return WASI_ESUCCESS;
    }
    if (memFds.has(fd)) {
      writeFdstat(statPtr, WASI_FILETYPE_REGULAR_FILE);
      return WASI_ESUCCESS;
    }
    return WASI_EBADF;
  },
  fd_filestat_get(fd, statPtr) {
    if (fd === WASI_PREOPEN_FD) {
      writeFilestat(statPtr, WASI_FILETYPE_DIRECTORY, 0);
      return WASI_ESUCCESS;
    }
    const ent = memFds.get(fd);
    if (!ent) return WASI_EBADF;
    writeFilestat(statPtr, WASI_FILETYPE_REGULAR_FILE, ent.data.length);
    return WASI_ESUCCESS;
  },
  fd_filestat_set_size(fd, size) {
    const ent = memFds.get(fd);
    if (!ent) return WASI_EBADF;
    if (!ent.writable) return WASI_ENOTCAPABLE;
    const n = asSafeNonNegInt(typeof size === "bigint" ? size : BigInt(size));
    if (n === null) return WASI_EINVAL;
    if (n > MEMFS_MAX_BYTES) return WASI_EFBIG;
    if (n === ent.data.length) return WASI_ESUCCESS;
    const next = new Uint8Array(n);
    next.set(ent.data.subarray(0, Math.min(ent.data.length, n)));
    ent.data = next;
    ent.dirty = true;
    if (ent.pos > n) ent.pos = n;
    return WASI_ESUCCESS;
  },
  fd_filestat_set_times() {
    return WASI_ESUCCESS; // no-op accept
  },
  fd_pread(fd, iovsPtr, iovsLen, offset, nreadPtr) {
    const ent = memFds.get(fd);
    if (!ent) {
      if (fd === 0) {
        setU32(nreadPtr, 0);
        return WASI_ESUCCESS;
      }
      return WASI_EBADF;
    }
    const off = asSafeNonNegInt(typeof offset === "bigint" ? offset : BigInt(offset));
    if (off === null) return WASI_EINVAL;
    if (off > MEMFS_MAX_BYTES) return WASI_EFBIG;
    return memFdReadAt(ent, iovsPtr, iovsLen, off, nreadPtr, false);
  },
  fd_pwrite(fd, iovsPtr, iovsLen, offset, nwrittenPtr) {
    if (fd === 1 || fd === 2) {
      return wasi.fd_write(fd, iovsPtr, iovsLen, nwrittenPtr);
    }
    const ent = memFds.get(fd);
    if (!ent || !ent.writable) return WASI_EBADF;
    const off = asSafeNonNegInt(typeof offset === "bigint" ? offset : BigInt(offset));
    if (off === null) return WASI_EINVAL;
    if (off > MEMFS_MAX_BYTES) return WASI_EFBIG;
    return memFdWriteAt(ent, iovsPtr, iovsLen, off, nwrittenPtr, false);
  },
  fd_read(fd, iovsPtr, iovsLen, nreadPtr) {
    if (fd === 0) {
      setU32(nreadPtr, 0); // EOF
      return WASI_ESUCCESS;
    }
    const ent = memFds.get(fd);
    if (!ent) return WASI_EBADF;
    return memFdReadAt(ent, iovsPtr, iovsLen, ent.pos, nreadPtr, true);
  },
  fd_readdir() {
    return WASI_ENOTCAPABLE;
  },
  fd_seek(fd, offset, whence, newOffsetPtr) {
    if (fd === 0 || fd === 1 || fd === 2) {
      setU64(newOffsetPtr, 0n);
      return WASI_ESUCCESS;
    }
    if (fd === WASI_PREOPEN_FD) {
      setU64(newOffsetPtr, 0n);
      return WASI_ESUCCESS;
    }
    const ent = memFds.get(fd);
    if (!ent) return WASI_EBADF;
    const off = asSafeInt(typeof offset === "bigint" ? offset : BigInt(offset));
    if (off === null) return WASI_EINVAL;
    let base = 0;
    if (whence === WASI_WHENCE_SET) base = 0;
    else if (whence === WASI_WHENCE_CUR) base = ent.pos;
    else if (whence === WASI_WHENCE_END) base = ent.data.length;
    else return WASI_EINVAL;
    const next = base + off;
    if (!Number.isSafeInteger(next) || next < 0) return WASI_EINVAL;
    if (next > MEMFS_MAX_BYTES) return WASI_EFBIG;
    ent.pos = next;
    setU64(newOffsetPtr, BigInt(ent.pos));
    return WASI_ESUCCESS;
  },
  fd_sync(fd) {
    if (fd === 1 || fd === 2) {
      flushFd(fd);
      return WASI_ESUCCESS;
    }
    if (fd === 0 || fd === WASI_PREOPEN_FD) return WASI_ESUCCESS;
    if (memFds.has(fd)) return WASI_ESUCCESS;
    return WASI_EBADF;
  },
  // per-fd line buffer → console.log/error on newline. Concatenate multiple iovec.
  fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
    if (fd === 1 || fd === 2) {
      const { text, total } = concatIovecs(iovsPtr, iovsLen);
      appendFd(fd, text);
      setU32(nwrittenPtr, total);
      return WASI_ESUCCESS;
    }
    const ent = memFds.get(fd);
    if (!ent || !ent.writable) return WASI_EBADF;
    return memFdWriteAt(ent, iovsPtr, iovsLen, ent.pos, nwrittenPtr, true);
  },
  path_create_directory() {
    return WASI_ENOTCAPABLE;
  },
  path_filestat_get(dirfd, _flags, pathPtr, pathLen, statPtr) {
    if (dirfd !== WASI_PREOPEN_FD && dirfd !== 3) {
      // Relative open supports cwd only
      if (!memFds.has(dirfd)) return WASI_EBADF;
    }
    const path = normalizePath(new TextDecoder().decode(bytesAt(pathPtr, pathLen)));
    const data = memFiles.get(path);
    if (!data) return WASI_ENOENT;
    writeFilestat(statPtr, WASI_FILETYPE_REGULAR_FILE, data.length);
    return WASI_ESUCCESS;
  },
  path_link() {
    return WASI_ENOTCAPABLE;
  },
  path_open(dirfd, _dirflags, pathPtr, pathLen, oflags, _fsRightsBase, _fsRightsInheriting, _fsFlags, fdPtr) {
    // cwd preopen only (Zig Dir.cwd handle=3)
    if (dirfd !== WASI_PREOPEN_FD) return WASI_EBADF;
    if ((oflags & WASI_O_DIRECTORY) !== 0) return WASI_ENOTCAPABLE;
    const path = normalizePath(new TextDecoder().decode(bytesAt(pathPtr, pathLen)));
    if (!path) return WASI_EINVAL;
    const creat = (oflags & WASI_O_CREAT) !== 0;
    const excl = (oflags & WASI_O_EXCL) !== 0;
    const trunc = (oflags & WASI_O_TRUNC) !== 0;
    let data = memFiles.get(path);
    if (data) {
      if (creat && excl) return WASI_EEXIST;
      if (trunc) data = new Uint8Array(0);
      else data = new Uint8Array(data); // copy for mutable fd buffer
    } else {
      if (!creat) return WASI_ENOENT;
      data = new Uint8Array(0);
    }
    // rights are ignored. writeFile uses CREAT|TRUNC; read uses oflags=0.
    const writable = creat || trunc;
    const fd = nextMemFd++;
    memFds.set(fd, {
      path,
      data,
      pos: 0,
      writable,
      dirty: writable,
    });
    setU32(fdPtr, fd);
    return WASI_ESUCCESS;
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
  path_unlink_file(dirfd, pathPtr, pathLen) {
    if (dirfd !== WASI_PREOPEN_FD) return WASI_EBADF;
    const path = normalizePath(new TextDecoder().decode(bytesAt(pathPtr, pathLen)));
    memFiles.delete(path);
    return WASI_ESUCCESS;
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

/**
 * @param {MemFd} ent
 * @param {number} iovsPtr
 * @param {number} iovsLen
 * @param {number} offset
 * @param {number} nreadPtr
 * @param {boolean} advancePos
 */
function memFdReadAt(ent, iovsPtr, iovsLen, offset, nreadPtr, advancePos) {
  let pos = offset;
  let total = 0;
  for (let i = 0; i < iovsLen; i++) {
    const base = iovsPtr + i * 8;
    const buf = u32(base);
    const len = u32(base + 4);
    if (len === 0) continue;
    if (pos >= ent.data.length) break;
    const n = Math.min(len, ent.data.length - pos);
    bytesAt(buf, n).set(ent.data.subarray(pos, pos + n));
    pos += n;
    total += n;
  }
  if (advancePos) ent.pos = pos;
  setU32(nreadPtr, total);
  return WASI_ESUCCESS;
}

/**
 * @param {MemFd} ent
 * @param {number} iovsPtr
 * @param {number} iovsLen
 * @param {number} offset
 * @param {number} nwrittenPtr
 * @param {boolean} advancePos
 */
function memFdWriteAt(ent, iovsPtr, iovsLen, offset, nwrittenPtr, advancePos) {
  if (!Number.isSafeInteger(offset) || offset < 0) return WASI_EINVAL;
  if (offset > MEMFS_MAX_BYTES) return WASI_EFBIG;
  // First the total byte count
  let need = 0;
  for (let i = 0; i < iovsLen; i++) {
    need += u32(iovsPtr + i * 8 + 4);
  }
  const end = offset + need;
  if (!Number.isSafeInteger(end) || end < 0) return WASI_EINVAL;
  if (end > MEMFS_MAX_BYTES) return WASI_EFBIG;
  if (end > ent.data.length) {
    const next = new Uint8Array(end);
    next.set(ent.data);
    ent.data = next;
  }
  let pos = offset;
  let total = 0;
  for (let i = 0; i < iovsLen; i++) {
    const base = iovsPtr + i * 8;
    const buf = u32(base);
    const len = u32(base + 4);
    if (len === 0) continue;
    ent.data.set(bytesAt(buf, len), pos);
    pos += len;
    total += len;
  }
  if (advancePos) ent.pos = pos;
  ent.dirty = true;
  setU32(nwrittenPtr, total);
  return WASI_ESUCCESS;
}

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
  // Pass DOM MouseEvent.button through as-is (0=left, 1=middle, 2=right).
  // Zig-side buttonFromDom maps to MouseButton (left=0,right=1,middle=2).
  // Note: middle/right swap relative to the shared enum discriminant.
  if (e.button === 0) return 0;
  if (e.button === 1) return 1;
  if (e.button === 2) return 2;
  return -1;
}

/**
 * clientX/Y (CSS px) → raw physical event coordinates: CSS × devicePixelRatio, independent of
 * fb_mode. The Zig facade (core/platform.zig) divides this by the frame-latched content_scale to
 * recover logical points, mirroring every native backend's "the backend enqueues raw physical, the
 * facade normalises" contract (docs/adr/011_high-dpi-coordinates-and-fb-modes.md R2).
 *
 * Deriving the ratio from the canvas bitmap instead (`canvas.width / rect.width`) would silently
 * halve `.logical` coordinates whenever the real ratio is not 1: a `.logical` canvas's bitmap stays
 * at the CSS size (content_scale still reports the real ratio, only the framebuffer does not scale
 * with it), so that ratio would read as 1 while the facade still divides by the real one.
 */
function canvasRawPhysicalXY(e) {
  const rect = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const x = Math.round((e.clientX - rect.left) * dpr);
  const y = Math.round((e.clientY - rect.top) * dpr);
  return { x, y };
}

function writeDomCode(code) {
  const enc = new TextEncoder();
  const bytes = enc.encode(code);
  const scratch = instance.exports.kngn_dom_code_scratch();
  const view = new Uint8Array(memory.buffer, scratch, 32);
  const n = Math.min(bytes.length, 32);
  view.set(bytes.subarray(0, n));
  return instance.exports.kngn_dom_code_to_keycode(n);
}

function pushKey(e, down) {
  const code = writeDomCode(e.code);
  instance.exports.kngn_push_key(down, code, modsFromEvent(e), !!e.repeat);
}

function shouldPreventKey(e) {
  // Suppress page defaults for keys used by pixie / synth
  const c = e.code;
  return (
    c === "Space" ||
    c === "Tab" ||
    c.startsWith("Arrow") ||
    c === "Backspace" ||
    c === "Delete" ||
    ((e.metaKey || e.ctrlKey) &&
      (c === "KeyZ" || c === "KeyS" || c === "KeyO" || c === "KeyQ" || c === "KeyC" || c === "KeyV" || c === "KeyX")) ||
    // Around the synth keyboard A..K
    (c.startsWith("Key") && c.length === 4)
  );
}

/**
 * Seed the canvas's intrinsic width/height from the app's declared `App.window` size, so the
 * initial framebuffer matches it instead of the UA's default 300x150 canvas box.
 *
 * Only applies when the host page left both attributes unset (`hasAttribute`, not the IDL
 * getter, which always returns a number) — an author's explicit markup is never overridden.
 *
 * This is not a one-frame default: a canvas with no CSS box renders at its intrinsic attribute
 * size, so absent a CSS override this stays the canvas's box (and therefore the framebuffer's
 * size, via `bindResize()`'s `ResizeObserver`) for as long as the app runs. The moment the
 * page's CSS gives the canvas an explicit box, that box wins instead, immediately and
 * continuously, from the next resize report on. `template/web/template.html` relies on the
 * first behaviour (no CSS box, so it stays at `App.window`'s size); a page that wants the
 * canvas to track the viewport instead opts into the second by giving it one.
 */
function primeDeclaredWindowSize() {
  if (canvas.hasAttribute("width") || canvas.hasAttribute("height")) return;
  const declW = instance.exports.kngn_declared_window_w;
  const declH = instance.exports.kngn_declared_window_h;
  if (!declW || !declH) return; // older wasm without these exports
  const w = declW();
  const h = declH();
  if (w > 0 && h > 0) {
    canvas.width = w;
    canvas.height = h;
  }
}

/**
 * Notify wasm of the container's logical (CSS) px and the current devicePixelRatio together.
 * Applied at the frame boundary via pending (kngn_resize never swaps the buffer mid-frame). Both
 * bindResize()'s ResizeObserver and bindDprWatcher()'s matchMedia watcher call this same function,
 * so a size-only or a ratio-only change always carries the other quantity's current value too.
 */
function reportCanvasSize() {
  if (!instance) return;
  const w = Math.round(canvas.clientWidth);
  const h = Math.round(canvas.clientHeight);
  const dpr = window.devicePixelRatio || 1;
  if (w > 0 && h > 0) {
    instance.exports.kngn_resize(w, h, dpr);
  }
}

function bindResize() {
  const ro = new ResizeObserver(() => reportCanvasSize());
  ro.observe(canvas);
  reportCanvasSize();
}

/**
 * Watch for a devicePixelRatio change (moving the window to a display with a different scale
 * factor, or a browser zoom) with the standard self-resubscribing matchMedia idiom: a
 * `(resolution: Xdppx)` query only ever fires once it stops matching X exactly, so each firing
 * rebuilds the query around the new ratio before listening again.
 */
function bindDprWatcher() {
  let mql = null;
  function onChange() {
    reportCanvasSize(); // re-reads the CSS box too, so size and ratio never apply half-stale
    subscribe();
  }
  function subscribe() {
    const dpr = window.devicePixelRatio || 1;
    mql = window.matchMedia(`(resolution: ${dpr}dppx)`);
    mql.addEventListener("change", onChange, { once: true });
  }
  subscribe();
}

// ---- audio env imports ----

/** @type {"none"|"worklet_shared"|"worklet_postmessage"} */
let audioTransport = "none";

// postMessage queue: blocks of 128 frames × 2 ch (~2.67 ms per block at 48 kHz).
// Contract: the render shares the thread that draws, so a frame that runs long starves
// playback. Queue depth is therefore adaptive: it starts at the lowest useful latency
// and grows only after an underrun proves this machine needs more headroom, up to the
// ring capacity the worklet allocates. It never shrinks within a session — a machine
// that stuttered once will stutter again, and silence is worse than latency here.
const PM_BLOCK_FRAMES = 128;
const PM_CHANNELS = 2;
const PM_MIN_QUEUE_BLOCKS = 8; // ~21 ms
const PM_MAX_QUEUE_BLOCKS = 24; // ~64 ms; must not exceed PM_BLOCKS in kngn-worklet.js
const PM_QUEUE_GROW_BLOCKS = 4;
const PM_POOL_SIZE = PM_MAX_QUEUE_BLOCKS + 2;
let pmTargetBlocks = PM_MIN_QUEUE_BLOCKS;
/** @type {ArrayBuffer[]} */
let pmPool = [];
/** Blocks posted to the worklet whose transferable has not come back yet. */
let pmInFlight = 0;
/**
 * Ring depth the worklet last reported. The producer paces against
 * `depth + in-flight`, not against in-flight alone: a transferable comes back as soon
 * as the worklet has copied it, which says nothing about how much audio is still
 * queued, so pacing on it renders far faster than real time and the ring drops the
 * excess.
 */
let pmDepth = 0;
/** AudioContext time at which `pmDepth` was last carried forward (seconds). */
let pmLastPumpTime = 0;
let pmLastDrops = 0;
let pmSchedulerBound = false;

function showAudioError(msg) {
  console.error(msg);
  const el = document.getElementById("kngn-error");
  if (el) {
    el.textContent = String(msg);
    el.style.display = "block";
  }
}

function ensureAudioGestureResume() {
  if (audioGestureBound) return;
  audioGestureBound = true;
  const hint = document.getElementById("kngn-audio-hint");
  const tryResume = async () => {
    // After stop, a later gesture must not resume unintentionally
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
    // Start / top-up the postMessage queue after the context is running.
    if (audioTransport === "worklet_postmessage") {
      pmEnsureQueue();
    }
  };
  // Resume on click / key (autoplay policy)
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

function pmAllocBlock() {
  if (pmPool.length > 0) return /** @type {ArrayBuffer} */ (pmPool.pop());
  return new ArrayBuffer(PM_BLOCK_FRAMES * PM_CHANNELS * 4);
}

/** Render `n` blocks on the main thread and post them to the worklet (transferable). */
function pmRenderAndSend(n) {
  if (!instance || !audioNode || !memory) return;
  const outPtr =
    typeof instance.exports.kngn_audio_render_buf === "function"
      ? instance.exports.kngn_audio_render_buf() >>> 0
      : 0;
  if (!outPtr || typeof instance.exports.kngn_audio_render !== "function") return;
  const sr = (audioCtx && audioCtx.sampleRate) || 48000;
  for (let b = 0; b < n; b++) {
    const ab = pmAllocBlock();
    const f32 = new Float32Array(ab);
    const ok = instance.exports.kngn_audio_render(outPtr, PM_BLOCK_FRAMES, PM_CHANNELS, sr | 0);
    if (ok) {
      const wasmView = new Float32Array(memory.buffer, outPtr, PM_BLOCK_FRAMES * PM_CHANNELS);
      f32.set(wasmView);
    } else {
      f32.fill(0);
    }
    audioNode.port.postMessage(
      { type: "audio", buffer: ab, frames: PM_BLOCK_FRAMES, channels: PM_CHANNELS },
      [ab],
    );
    pmInFlight += 1;
  }
}

/**
 * Top the worklet ring back up to `PM_QUEUE_BLOCKS`. Called from the frame loop, so the
 * pump rate follows the display while the amount follows playback.
 *
 * The worklet cannot announce consumption (`process` is real time and may not post), so
 * the depth is carried forward on a clock: playback drains one block every
 * `frames / sampleRate` seconds. Every `buffer-return` and every stats poll replaces the
 * estimate with the ring's real count, which bounds the drift. Pacing on the returned
 * transfer buffers instead would render far ahead of playback and the ring would drop
 * the surplus; pacing on a stale depth would stall and starve it.
 */
function pmEnsureQueue() {
  if (audioTransport !== "worklet_postmessage" || !audioReady || !audioNode) return;
  const sr = (audioCtx && audioCtx.sampleRate) || 48000;
  const now = (audioCtx && audioCtx.currentTime) || 0;
  if (pmLastPumpTime > 0) {
    const consumed = Math.floor(((now - pmLastPumpTime) * sr) / PM_BLOCK_FRAMES);
    if (consumed > 0) {
      pmDepth = Math.max(0, pmDepth - consumed);
      pmLastPumpTime += (consumed * PM_BLOCK_FRAMES) / sr;
    }
  } else {
    pmLastPumpTime = now;
  }
  const queued = pmDepth + pmInFlight;
  if (queued < pmTargetBlocks) {
    pmRenderAndSend(pmTargetBlocks - queued);
  }
}

/** Last underrun count observed via poll-stats (main thread only). */
let pmLastUnderruns = 0;
let pmStatsPollBound = false;

function pmOnWorkletMessage(data) {
  if (data.type === "buffer-return" && data.buffer) {
    if (pmPool.length < PM_POOL_SIZE) pmPool.push(data.buffer);
    pmInFlight = Math.max(0, pmInFlight - 1);
    if (typeof data.depth === "number") {
      pmDepth = data.depth;
      pmLastPumpTime = (audioCtx && audioCtx.currentTime) || 0;
    }
    if (typeof data.drops === "number" && data.drops > pmLastDrops) {
      pmLastDrops = data.drops;
      showAudioError(
        "audio transport dropped a rendered block (ring full; count=" +
          data.drops +
          "). The producer is running ahead of playback.",
      );
    }
    pmEnsureQueue();
    return;
  }
  if (data.type === "stats") {
    // Worklet process() only increments counters; main observes them here (non-RT).
    // The depth snapshot also re-syncs the producer if a buffer-return was missed.
    if (typeof data.queueDepth === "number") {
      pmDepth = data.queueDepth;
      pmLastPumpTime = (audioCtx && audioCtx.currentTime) || 0;
    }
    if (typeof data.drops === "number" && data.drops > pmLastDrops) {
      pmLastDrops = data.drops;
      showAudioError(
        "audio transport dropped a rendered block (ring full; count=" +
          data.drops +
          "). The producer is running ahead of playback.",
      );
    }
    if (typeof data.underruns === "number" && data.underruns > pmLastUnderruns) {
      pmLastUnderruns = data.underruns;
      if (pmTargetBlocks < PM_MAX_QUEUE_BLOCKS) {
        // Buy headroom with latency: the drop-outs a listener hears cost more than the
        // extra milliseconds, and the growth is reported rather than applied silently.
        pmTargetBlocks = Math.min(PM_MAX_QUEUE_BLOCKS, pmTargetBlocks + PM_QUEUE_GROW_BLOCKS);
        console.warn(
          "kngn audio: underrun (count=" +
            data.underruns +
            "); queue depth raised to " +
            pmTargetBlocks +
            " blocks (~" +
            Math.round((pmTargetBlocks * PM_BLOCK_FRAMES * 1000) / ((audioCtx && audioCtx.sampleRate) || 48000)) +
            " ms)",
        );
        pmEnsureQueue();
      } else {
        showAudioError(
          "audio transport underrun at maximum queue depth (count=" +
            data.underruns +
            "). This machine cannot keep the main thread free enough for main-thread audio.",
        );
      }
    }
    if (data.quantumMismatches > 0) {
      showAudioError(
        "audio worklet quantum mismatch (only 128-frame quanta are supported; count=" +
          data.quantumMismatches +
          ")",
      );
    }
    if (data.viewDetached) {
      // Worklet rebuilds the view on this non-RT poll; a sticky flag means rebuild failed.
      showAudioError(
        "audio worklet lost its render buffer view (wasm memory grew and rebuild failed); reload the page",
      );
    }
    if (data.renderErrors > 0) {
      showAudioError("audio worklet render errors: " + data.renderErrors);
    }
    return;
  }
}

/** Ask the worklet for RT counters (non-RT request/response; process() never posts). */
function pollWorkletStats() {
  if (!audioNode) return;
  try {
    audioNode.port.postMessage({ type: "poll-stats" });
  } catch (_) {}
}

/**
 * After main-thread memory.grow (e.g. kngn_init), tell the shared worklet to rebuild
 * its prebuilt Float32Array view on the non-RT message path (process never allocates).
 */
function requestSharedViewRebuild() {
  if (audioTransport !== "worklet_shared" || !audioNode) return;
  try {
    audioNode.port.postMessage({ type: "rebuild-view" });
  } catch (_) {}
}

function ensureWorkletStatsPoll() {
  if (pmStatsPollBound) return;
  pmStatsPollBound = true;
  // 100 ms: fast enough that the queue grows within a few drop-outs, cheap enough that
  // the request/response pair is noise next to the audio traffic itself.
  const POLL_MS = 100;
  const tick = () => {
    if (audioReady && audioNode) {
      pollWorkletStats();
      // A timer pump as well as the frame loop: a frame that runs long is exactly when
      // the queue needs topping up, and that is when rAF is not running.
      pmEnsureQueue();
    }
    setTimeout(tick, POLL_MS);
  };
  setTimeout(tick, POLL_MS);
}

/**
 * Load the worklet module from an embedded source string or from kngn-worklet.js.
 * @param {string|undefined} workletSource
 * @returns {Promise<void>}
 */
async function loadWorkletModule(workletSource) {
  if (!audioCtx) throw new Error("AudioContext missing");
  if (workletSource) {
    // data: URLs work under file://. blob: URLs are blocked there as "local resource".
    const url = "data:text/javascript;charset=utf-8," + encodeURIComponent(workletSource);
    await audioCtx.audioWorklet.addModule(url);
  } else {
    await audioCtx.audioWorklet.addModule(new URL("./kngn-worklet.js", import.meta.url).href);
  }
}

/**
 * Shared-memory path: second Instance + sentinel on the worklet.
 * @param {number} channels
 * @returns {Promise<void>}
 */
function prepareSharedWorkletNode(channels) {
  return new Promise((resolve, reject) => {
    if (!audioCtx || !wasmModule || !memory || !instance) {
      reject(new Error("prepareSharedWorkletNode: ctx/module/memory/instance missing"));
      return;
    }
    if (typeof instance.exports.kngn_audio_set_sentinel !== "function") {
      reject(new Error("prepareSharedWorkletNode: missing kngn_audio_set_sentinel"));
      return;
    }
    instance.exports.kngn_audio_set_sentinel();

    const stackTop =
      typeof instance.exports.kngn_audio_worklet_stack_top === "function"
        ? instance.exports.kngn_audio_worklet_stack_top() >>> 0
        : 0;
    if (!stackTop) {
      reject(new Error("prepareSharedWorkletNode: missing stack top"));
      return;
    }

    audioChannels = channels || 2;
    const actualSr = audioCtx.sampleRate | 0;
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error("kngn-worklet: ready timeout (" + WORKLET_READY_TIMEOUT_MS + "ms)"));
    }, WORKLET_READY_TIMEOUT_MS);

    try {
      if (audioNode) {
        try {
          audioNode.disconnect();
        } catch (_) {}
        audioNode = null;
      }
      audioNode = new AudioWorkletNode(audioCtx, "kngn-audio-processor", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [audioChannels],
        processorOptions: {
          transport: "shared",
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
            reject(new Error("kngn-worklet: ready with bad sentinel 0x" + (data.sentinel >>> 0).toString(16)));
            return;
          }
          settled = true;
          clearTimeout(timer);
          resolve();
          return;
        }
        if (data.type === "error") {
          if (settled) {
            console.error("kngn-worklet:", data.message);
            return;
          }
          settled = true;
          clearTimeout(timer);
          reject(new Error("kngn-worklet: " + data.message));
          return;
        }
        // stats / other non-RT diagnostics from the worklet.
        pmOnWorkletMessage(data);
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
 * postMessage path: worklet is a ring only; main thread owns kngn_audio_render.
 * @param {number} channels
 * @returns {Promise<void>}
 */
function preparePostMessageWorkletNode(channels) {
  return new Promise((resolve, reject) => {
    if (!audioCtx || !instance) {
      reject(new Error("preparePostMessageWorkletNode: ctx/instance missing"));
      return;
    }
    audioChannels = channels || 2;
    const actualSr = audioCtx.sampleRate | 0;
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error("kngn-worklet: postmessage ready timeout (" + WORKLET_READY_TIMEOUT_MS + "ms)"));
    }, WORKLET_READY_TIMEOUT_MS);

    try {
      if (audioNode) {
        try {
          audioNode.disconnect();
        } catch (_) {}
        audioNode = null;
      }
      // Seed the transferable pool once (not on the RT path).
      pmPool = [];
      for (let i = 0; i < PM_POOL_SIZE; i++) {
        pmPool.push(new ArrayBuffer(PM_BLOCK_FRAMES * PM_CHANNELS * 4));
      }
      pmInFlight = 0;
      pmDepth = 0;
      pmLastPumpTime = 0;
      pmLastDrops = 0;
      pmLastUnderruns = 0;
      pmTargetBlocks = PM_MIN_QUEUE_BLOCKS;

      audioNode = new AudioWorkletNode(audioCtx, "kngn-audio-processor", {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [audioChannels],
        processorOptions: {
          transport: "postmessage",
          channels: audioChannels,
          sampleRate: actualSr,
        },
      });
      audioNode.port.onmessage = (ev) => {
        const data = ev.data || {};
        if (data.type === "ready") {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          // Prefill 8 blocks (silence until Zig start() sets running=1).
          pmEnsureQueue();
          if (!pmSchedulerBound) {
            pmSchedulerBound = true;
            // Top up on animation frames when the context is running (event-time, not RT).
            const tick = () => {
              if (audioTransport === "worklet_postmessage" && audioReady) {
                if (audioCtx && audioCtx.state === "running") pmEnsureQueue();
              }
              requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          }
          resolve();
          return;
        }
        if (data.type === "error") {
          if (settled) {
            console.error("kngn-worklet:", data.message);
            return;
          }
          settled = true;
          clearTimeout(timer);
          reject(new Error("kngn-worklet: " + data.message));
          return;
        }
        pmOnWorkletMessage(data);
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
 * Diagnostic-only audio probe (query `audio_probe=1`).
 *
 * Contract (does not run when the query is absent — normal mode is unchanged):
 * 1. Attach an AnalyserNode after the worklet for output-side measurement.
 * 2. Resume the AudioContext if needed (headless may use --autoplay-policy).
 * 3. Inject one note-on through the **same** exports as the DOM keyboard path:
 *    writeDomCode("KeyA") → kngn_push_key(true, code, 0, false) (synth maps A → C4).
 * 4. Wait hundreds of ms while rAF keeps calling kngn_frame so the app processes the event.
 * 5. Sample silent / rms / peak; report via fetch("/report?d=...") for the static server log.
 * 6. Note-off via the same kngn_push_key path.
 *
 * Not a product feature. Never enable from normal UI chrome.
 */
function maybeStartAudioProbe() {
  const params = new URLSearchParams(location.search);
  if (params.get("audio_probe") !== "1") return;
  if (!audioCtx || !audioNode || !instance) return;
  try {
    const analyser = audioCtx.createAnalyser();
    analyser.fftSize = 4096;
    audioNode.connect(analyser);
    const buf = new Float32Array(analyser.fftSize);

    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    const sampleOnce = () => {
      analyser.getFloatTimeDomainData(buf);
      let peak = 0;
      let sumSq = 0;
      for (let i = 0; i < buf.length; i++) {
        const v = buf[i];
        const a = v < 0 ? -v : v;
        if (a > peak) peak = a;
        sumSq += v * v;
      }
      const rms = Math.sqrt(sumSq / buf.length);
      const silent = peak < 1e-5 && rms < 1e-5 ? 1 : 0;
      return {
        silent,
        rms,
        peak,
        report:
          "transport=" +
          audioTransport +
          "&silent=" +
          silent +
          "&rms=" +
          rms.toFixed(6) +
          "&peak=" +
          peak.toFixed(6) +
          "&sr=" +
          (audioCtx.sampleRate | 0) +
          "&n=" +
          buf.length +
          "&probe_note=KeyA",
      };
    };

    const postReport = (report) => {
      void fetch("/report?d=" + encodeURIComponent(report)).catch(() => {});
      console.log("audio_probe", report);
    };

    void (async () => {
      // Diagnostic path only: force intent-to-run so postMessage refill continues.
      audioWantRunning = true;
      if (audioCtx.state === "suspended") {
        try {
          await audioCtx.resume();
        } catch (e) {
          console.warn("audio_probe: resume failed", e);
        }
      }
      // Let the app finish open/start after kngn_init.
      await sleep(800);
      if (audioTransport === "worklet_postmessage") pmEnsureQueue();

      // Same keyboard entry as pushKey(e, true) for KeyboardEvent.code === "KeyA".
      const code = writeDomCode("KeyA");
      instance.exports.kngn_push_key(true, code, 0, false);

      // Hold the note while frames run (rAF → kngn_frame drains the event queue).
      await sleep(700);
      if (audioTransport === "worklet_postmessage") pmEnsureQueue();
      await sleep(200);

      let best = sampleOnce();
      // A few samples; keep the loudest (in case of brief underrun at the edges).
      for (let i = 0; i < 4; i++) {
        await sleep(150);
        const s = sampleOnce();
        if (s.rms > best.rms || s.peak > best.peak) best = s;
        postReport(s.report);
      }
      postReport(best.report);

      instance.exports.kngn_push_key(false, code, 0, false);
    })();
  } catch (e) {
    console.warn("audio_probe setup failed:", e);
  }
}

/**
 * Zig `kngn_audio_open` → confirm the boot-time worklet and return the real sample rate.
 * Node creation already ran at boot. Returns 0 unless audioReady.
 * @returns {number} actual sample rate, or 0 on failure
 */
function envAudioOpen(sampleRate, channels, bufferFrames) {
  void sampleRate;
  void bufferFrames;
  void channels;
  try {
    if (audioTransport === "worklet_shared") {
      if (typeof SharedArrayBuffer === "undefined") {
        console.error("kngn_audio_open: SharedArrayBuffer unavailable (need COOP/COEP)");
        return 0;
      }
      if (!globalThis.crossOriginIsolated) {
        console.error(
          "kngn_audio_open: crossOriginIsolated=false (serve with COOP/COEP; scripts/serve-web.py)",
        );
        return 0;
      }
    }
    if (!audioReady || !audioCtx || !audioNode) {
      console.error("kngn_audio_open: worklet not ready (boot failed or not audio app)");
      return 0;
    }
    ensureAudioGestureResume();
    return audioCtx.sampleRate | 0;
  } catch (e) {
    console.error("kngn_audio_open failed:", e);
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
      // Canonical app time (frame / getTime). Do not use the WASI clock.
      kngn_now() {
        return performance.now() / 1000;
      },
      kngn_present(ptr, w, h) {
        // memory growth detaches the old ArrayBuffer, so rebuild the view from buffer every time
        const nbytes = (w * h * 4) >>> 0;
        let wasmView = new Uint8ClampedArray(memory.buffer, ptr, nbytes);
        if (canvas.width !== w || canvas.height !== h) {
          canvas.width = w;
          canvas.height = h;
        }
        if (presentCanAlias && !presentAliasFailed) {
          // An ImageData built from a Uint8ClampedArray keeps that array rather than copying
          // it, so this uploads straight out of wasm memory and the frame-sized copy below
          // does not happen. It is rebuilt every frame on purpose: growing memory detaches
          // the buffer, and a retained ImageData would then throw InvalidStateError on
          // upload, so not retaining one removes that failure mode instead of guarding it.
          let aliased = null;
          try {
            aliased = new ImageData(wasmView, w, h);
          } catch (e) {
            // Only the construction is guarded. An upload that fails is a different fault
            // and must not be recorded as "this engine cannot alias".
            presentAliasFailed = true;
            console.warn(
              "kngn_present: cannot upload from wasm memory directly, copying instead (" +
                String((e && e.message) || e) + ")",
            );
            // The throw may have been a detached buffer, so do not copy from the old view.
            wasmView = new Uint8ClampedArray(memory.buffer, ptr, nbytes);
          }
          if (aliased) {
            ctx2d.putImageData(aliased, 0, 0);
            return;
          }
        }
        if (!imageData || imageW !== w || imageH !== h || imageData.data.length !== nbytes) {
          imageData = ctx2d.createImageData(w, h);
          imageW = w;
          imageH = h;
        }
        imageData.data.set(wasmView);
        ctx2d.putImageData(imageData, 0, 0);
      },
      kngn_log(ptr, len) {
        const bytes = new Uint8Array(memory.buffer, ptr, len);
        console.log(new TextDecoder().decode(bytes));
      },
      kngn_set_cursor(shape) {
        canvas.style.cursor = CURSOR_CSS[shape] || "default";
      },
      kngn_device_pixel_ratio() {
        return window.devicePixelRatio || 1;
      },
      kngn_audio_open: envAudioOpen,
      kngn_audio_start: envAudioStart,
      kngn_audio_stop: envAudioStop,
      kngn_audio_close: envAudioClose,
      // file dialog / clipboard
      kngn_request_open: envRequestOpen,
      kngn_clipboard_write: envClipboardWrite,
      kngn_request_paste: envRequestPaste,
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
  // Committed characters (char_input). Control keys are also filtered on the Zig side
  canvas.addEventListener("keypress", (e) => {
    if (e.charCode && e.charCode >= 0x20) {
      instance.exports.kngn_push_char(e.charCode, modsFromEvent(e));
    }
  });

  canvas.addEventListener("mousemove", (e) => {
    const { x, y } = canvasRawPhysicalXY(e);
    instance.exports.kngn_push_mouse(0, x, y, -1, buttonsFromEvent(e), modsFromEvent(e));
  });
  canvas.addEventListener("mousedown", (e) => {
    canvas.focus();
    const { x, y } = canvasRawPhysicalXY(e);
    instance.exports.kngn_push_mouse(1, x, y, buttonIndex(e), buttonsFromEvent(e), modsFromEvent(e));
  });
  canvas.addEventListener("mouseup", (e) => {
    const { x, y } = canvasRawPhysicalXY(e);
    instance.exports.kngn_push_mouse(2, x, y, buttonIndex(e), buttonsFromEvent(e), modsFromEvent(e));
  });
  canvas.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault(); // Suppress page scroll
      const { x, y } = canvasRawPhysicalXY(e);
      const dpr = window.devicePixelRatio || 1;
      // DOM wheel is positive downward → flip dy to match the pixie/gui convention. The delta is
      // scaled into raw physical units too, for the same reason the position is (the facade divides
      // both x/y and dx/dy by the frame-latched content_scale).
      instance.exports.kngn_push_scroll(x, y, -e.deltaX * dpr, -e.deltaY * dpr, modsFromEvent(e));
    },
    { passive: false },
  );
  canvas.addEventListener("contextmenu", (e) => e.preventDefault());
}

/**
 * Decode a standard base64 string to an ArrayBuffer (embedded single-HTML package).
 * @param {string} b64
 * @returns {ArrayBuffer}
 */
function base64ToArrayBuffer(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
}

/**
 * @param {{
 *   wasm?: string,
 *   sharedMemory?: boolean,
 *   audio?: boolean,
 *   audioTransport?: string,
 *   embedded?: boolean,
 *   wasmBase64?: string,
 *   workletSource?: string,
 *   initialPages?: number,
 *   maxPages?: number,
 * }} [opts]
 */
export async function boot(opts = {}) {
  const wasmUrl = opts.wasm || "pixie.wasm";
  // Transport is the sole mode selector. sharedMemory must not enable shared audio when
  // transport is none or postmessage (contradictory options → hard error).
  const transport = opts.audioTransport || (opts.audio ? "worklet_shared" : "none");
  audioTransport = transport;
  if (opts.sharedMemory && transport !== "worklet_shared") {
    throw new Error(
      "invalid boot options: sharedMemory=true requires audioTransport=worklet_shared (got " +
        transport +
        ")",
    );
  }
  const useShared = transport === "worklet_shared";
  const usePostMessage = transport === "worklet_postmessage";
  const useAudio = useShared || usePostMessage;
  const initialPages = opts.initialPages || 256; // 16 MiB
  const maxPages = opts.maxPages || 1024; // 64 MiB
  const embedded = !!(opts.embedded && opts.wasmBase64);

  canvas.focus();
  audioReady = false;

  if (useShared) {
    // Hard fail: do not start the app without isolation (no silent fallback).
    if (typeof SharedArrayBuffer === "undefined" || !globalThis.crossOriginIsolated) {
      throw new Error(
        "This application requires cross-origin isolation for shared audio.\n" +
          "Serve it with COOP/COEP headers, or use a postmessage audio build.",
      );
    }
  }

  if (useAudio) {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) throw new Error("AudioContext not available");
    if (typeof AudioWorkletNode === "undefined") {
      throw new Error("AudioWorklet is not available in this browser");
    }
    audioCtx = new AC({ sampleRate: 48000 });
    try {
      await loadWorkletModule(opts.workletSource);
    } catch (e) {
      throw new Error(
        "audioWorklet.addModule failed: " + String(e && e.message ? e.message : e),
      );
    }
  }

  /** @type {ArrayBuffer} */
  let bytes;
  if (embedded) {
    bytes = base64ToArrayBuffer(opts.wasmBase64);
  } else {
    // Multi-file package: fetch wasm next to this module (or next to the page for inline modules).
    const resp = await fetch(new URL("./" + wasmUrl, import.meta.url).href);
    bytes = await resp.arrayBuffer();
  }
  wasmModule = await WebAssembly.compile(bytes);

  const importObject = makeImportObject();

  if (useShared) {
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
  // Decided once, because it cannot change afterwards: the ImageData constructor rejects a
  // view over a SharedArrayBuffer, which is what shared audio builds get.
  presentCanAlias =
    typeof SharedArrayBuffer === "undefined" ||
    !(memory.buffer instanceof SharedArrayBuffer);
  presentAliasFailed = false;

  // Audio worklet setup before kngn_init. Failures stop boot (no half-started audio).
  if (useShared) {
    await prepareSharedWorkletNode(2);
    audioReady = true;
    ensureAudioGestureResume();
    ensureWorkletStatsPoll();
    maybeStartAudioProbe();
  } else if (usePostMessage) {
    await preparePostMessageWorkletNode(2);
    audioReady = true;
    ensureAudioGestureResume();
    ensureWorkletStatsPoll();
    maybeStartAudioProbe();
  }

  primeDeclaredWindowSize();
  bindInput();
  bindResize();
  bindDprWatcher();
  // Before kngn_init: platform.init() settles the transport decision, and after that enabling has
  // no effect. A build without the harness has no export to call, so the option is simply inert.
  if (opts.harness && harnessAvailable()) installHarnessBridge(!!opts.harnessCaptureFrames);
  instance.exports.kngn_init();
  // kngn_init may grow SharedArrayBuffer memory and detach the worklet's prebuilt view.
  requestSharedViewRebuild();

  function loop(ts) {
    instance.exports.kngn_frame(ts); // rAF ms. Zig divides by 1000
    if (harnessEnabled) harnessPump();
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
}

/**
 * Resolve boot options from an embedded single-HTML prelude or from page
 * data- attributes or the query string.
 * Explicit data-audio-transport / embedded audioTransport win; the app name is not guessed.
 */
function defaultOptsFromPage() {
  const emb = globalThis.__kngnEmbedded;
  if (emb && emb.embedded) {
    const transport = emb.audioTransport || "none";
    return {
      wasm: emb.wasm || "pixie.wasm",
      audioTransport: transport,
      audio: transport === "worklet_shared" || transport === "worklet_postmessage",
      sharedMemory: !!emb.sharedMemory,
      embedded: true,
      wasmBase64: emb.wasmBase64,
      workletSource: emb.workletSource,
    };
  }

  const params = new URLSearchParams(location.search);
  const body = document.body;
  const wasm = params.get("wasm") || body?.dataset?.wasm || "pixie.wasm";
  // Prefer explicit transport; fall back to legacy data-audio / data-shared for older HTML.
  const transport =
    params.get("audio-transport") ||
    body?.dataset?.audioTransport ||
    (params.get("audio") === "1" || body?.dataset?.audio === "1" ? "worklet_shared" : "none");
  const sharedMemory =
    params.get("shared") === "1" ||
    body?.dataset?.shared === "1" ||
    transport === "worklet_shared";
  return {
    wasm,
    audioTransport: transport,
    audio: transport === "worklet_shared" || transport === "worklet_postmessage",
    sharedMemory,
  };
}

// Auto-start at the top level of a type=module script (import { boot } also works)
if (!globalThis.__kngnManualBoot) {
  boot(defaultOptsFromPage()).catch((err) => {
    console.error(err);
    const el = document.getElementById("kngn-error");
    if (el) {
      el.textContent = String(err && err.message ? err.message : err);
      el.style.display = "block";
    }
  });
}
