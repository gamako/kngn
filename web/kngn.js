// KNGN wasm JS glue (audio + file/clipboard)
// import table:
//   env: kngn_now / kngn_present / kngn_log / kngn_set_cursor
//        + kngn_audio_open / kngn_audio_start / kngn_audio_stop / kngn_audio_close (audio app)
//        + kngn_request_open / kngn_clipboard_write / kngn_request_paste (file dialog / clipboard)
//   wasi_snapshot_preview1: hand-written shim + in-memory FS (path_open/fd_read/write/seek/close)
//
// boot options (from a script type=module import, or data-*):
//   wasm: "pixie.wasm" | "synth.wasm" (default pixie.wasm)
//   sharedMemory: true imports shared memory (required for synth audio)
//   audio: true enables the AudioWorklet path (requires sharedMemory)
//
// Time contract:
//   - App frame time is always env.kngn_now (performance.now based, seconds)
//   - WASI clock_time_get is for stdlib internals only. monotonic is also performance.now based
// DOM → kngn_push_* (KeyCode conversion is a Zig-side table. JS only identifies code strings and calls exports)
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

// ImageData is reused (recreated only on size change or memory growth)
let imageData = null;
let imageW = 0;
let imageH = 0;

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

/** clientX/Y → canvas logical px (HiDPI / CSS scale) */
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

/** Notify wasm of the container's logical px (no DPR). Applied at the frame boundary via pending. */
function reportCanvasSize() {
  if (!instance) return;
  const w = Math.round(canvas.clientWidth);
  const h = Math.round(canvas.clientHeight);
  if (w > 0 && h > 0) {
    instance.exports.kngn_resize(w, h);
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

/**
 * boot: after the main Instance is created and before kngn_init, build AudioWorkletNode
 * and await worklet-side 2nd Instance + sentinel ready.
 * g_state is unset yet, but the worklet only reads it inside the running gate, so this is safe.
 * @param {number} channels
 * @returns {Promise<void>}
 */
function prepareAudioWorkletNode(channels) {
  return new Promise((resolve, reject) => {
    if (!audioCtx || !wasmModule || !memory || !instance) {
      reject(new Error("prepareAudioWorkletNode: ctx/module/memory/instance missing"));
      return;
    }
    if (typeof instance.exports.kngn_audio_set_sentinel !== "function") {
      reject(new Error("prepareAudioWorkletNode: missing kngn_audio_set_sentinel"));
      return;
    }
    // main writes the magic on shared memory (before worklet instantiate)
    instance.exports.kngn_audio_set_sentinel();

    const stackTop =
      typeof instance.exports.kngn_audio_worklet_stack_top === "function"
        ? instance.exports.kngn_audio_worklet_stack_top() >>> 0
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
 * Zig `kngn_audio_open` → confirm the boot-time worklet and return the real sample rate.
 * Node creation already ran at boot. Returns 0 unless audioReady.
 * @returns {number} actual sample rate, or 0 on failure
 */
function envAudioOpen(sampleRate, channels, bufferFrames) {
  void sampleRate;
  void bufferFrames;
  void channels;
  try {
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
      kngn_log(ptr, len) {
        const bytes = new Uint8Array(memory.buffer, ptr, len);
        console.log(new TextDecoder().decode(bytes));
      },
      kngn_set_cursor(shape) {
        canvas.style.cursor = CURSOR_CSS[shape] || "default";
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
    const { x, y } = canvasLogicalXY(e);
    instance.exports.kngn_push_mouse(0, x, y, -1, buttonsFromEvent(e), modsFromEvent(e));
  });
  canvas.addEventListener("mousedown", (e) => {
    canvas.focus();
    const { x, y } = canvasLogicalXY(e);
    instance.exports.kngn_push_mouse(1, x, y, buttonIndex(e), buttonsFromEvent(e), modsFromEvent(e));
  });
  canvas.addEventListener("mouseup", (e) => {
    const { x, y } = canvasLogicalXY(e);
    instance.exports.kngn_push_mouse(2, x, y, buttonIndex(e), buttonsFromEvent(e), modsFromEvent(e));
  });
  canvas.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault(); // Suppress page scroll
      const { x, y } = canvasLogicalXY(e);
      // DOM wheel is positive downward → flip dy to match the pixie/gui convention
      instance.exports.kngn_push_scroll(x, y, -e.deltaX, -e.deltaY, modsFromEvent(e));
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
    // addModule must target the same AudioContext that creates the node.
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) throw new Error("AudioContext not available");
    if (typeof SharedArrayBuffer === "undefined" || !globalThis.crossOriginIsolated) {
      throw new Error(
        "audio requires cross-origin isolation (COOP/COEP). Use: python3 scripts/serve-web.py zig-out/web",
      );
    }
    audioCtx = new AC({ sampleRate: 48000 });
    await audioCtx.audioWorklet.addModule(new URL("./kngn-worklet.js", import.meta.url).href);
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

  // audio: finish 2nd Instance + sentinel checks before kngn_init (failure → open also fails)
  if (useAudio) {
    try {
      await prepareAudioWorkletNode(2);
      audioReady = true;
      ensureAudioGestureResume();
    } catch (e) {
      audioReady = false;
      showAudioError(e && e.message ? e.message : e);
      // Graphics continue. audio.open returns OpenFailed.
      console.warn("audio disabled:", e);
    }
  }

  bindInput();
  bindResize();
  instance.exports.kngn_init();

  function loop(ts) {
    instance.exports.kngn_frame(ts); // rAF ms. Zig divides by 1000
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
}

// Default: index.html with no data attribute or query loads pixie
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
