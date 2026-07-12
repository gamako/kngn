// video-proto wasm JS glue（TASK-73.1 + TASK-73.2 audio + TASK-73.3 file/clipboard）
// import table:
//   env: vp_now / vp_present / vp_log / vp_set_cursor
//        + vp_audio_open / vp_audio_start / vp_audio_stop / vp_audio_close（audio app）
//        + vp_request_open / vp_clipboard_write / vp_request_paste（file dialog / clipboard）
//   wasi_snapshot_preview1: 手書き shim + in-memory FS（path_open/fd_read/write/seek/close）
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
//
// ファイル I/O（TASK-73.3）:
//   - open: <input type=file> → 仮想 path `pick/<name>` にバイト登録 → vp_file_picked
//   - save: Zig が path を書き WASI write → fd_close で Blob download
//   - OPFS は不採用（download/pick 往復で .pix round-trip 可）

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
const WASI_EEXIST = 20;
const WASI_EFBIG = 22;
const WASI_EINVAL = 28;
const WASI_ENOENT = 44;
const WASI_ENOSYS = 52;
const WASI_ENOTCAPABLE = 76;
/** memFS の size/offset/成長上限（64 MiB）。超過は EFBIG/EINVAL。 */
const MEMFS_MAX_BYTES = 64 * 1024 * 1024;
const WASI_CLOCK_REALTIME = 0;
const WASI_CLOCK_MONOTONIC = 1;
const WASI_FILETYPE_CHARACTER_DEVICE = 2;
const WASI_FILETYPE_DIRECTORY = 3;
const WASI_FILETYPE_REGULAR_FILE = 4;
/** Zig wasi cwd = fd 3（最初の preopen） */
const WASI_PREOPEN_FD = 3;
/** oflags bits（wasi oflags_t packed） */
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

/** filestat_t（64B）: dev/ino u64, filetype u8 + pad, nlink u64, size u64, atim/mtim/ctim u64 */
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

// ---- in-memory FS（TASK-73.3）----
/** @type {Map<string, Uint8Array>} path → file bytes */
const memFiles = new Map();
/**
 * @typedef {{ path: string, data: Uint8Array, pos: number, writable: boolean, dirty: boolean }} MemFd
 * @type {Map<number, MemFd>}
 */
const memFds = new Map();
let nextMemFd = 4;

/** open picker 進行中（二重発火防止） */
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
  // path traversal 除去（basename 済みだが念のため）
  base = base.replace(/[\\/]/g, "_");
  if (!base || base === "." || base === "..") base = "file";
  return "pick/" + base;
}

/**
 * UTF-8 バイト長が maxBytes 以下になるよう code point 単位で末尾を落とす。
 * 単純な byte 切断による UTF-8 破壊と、memFS key / wasm 配送 path の不一致を防ぐ（TASK-73.3 修正2）。
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
 * BigInt/number → 非負の SafeInteger。不正なら null。
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
 * BigInt/number → 符号付き SafeInteger（fd_seek の delta 用）。不正なら null。
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
    // revoke を遅延（一部 browser が即 revoke で download 失敗）
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
    input.value = ""; // 同一ファイル再選択を許可
    if (!file) {
      openPickerBusy = false;
      if (instance && typeof instance.exports.vp_file_cancelled === "function") {
        instance.exports.vp_file_cancelled();
      }
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      openPickerBusy = false;
      try {
        const buf = new Uint8Array(reader.result);
        // 登録 key と wasm 配送 path を同一文字列に（UTF-8 安全クランプ。scratch 256B 契約）
        const vpath = clampUtf8(makePickPath(file.name), 256);
        registerMemFile(vpath, buf);
        deliverPickedPath(vpath);
      } catch (e) {
        console.error("file pick deliver failed:", e);
        if (instance && typeof instance.exports.vp_file_cancelled === "function") {
          instance.exports.vp_file_cancelled();
        }
      }
    };
    reader.onerror = () => {
      openPickerBusy = false;
      console.error("FileReader error");
      if (instance && typeof instance.exports.vp_file_cancelled === "function") {
        instance.exports.vp_file_cancelled();
      }
    };
    reader.readAsArrayBuffer(file);
  });
  // cancel: 一部 browser は cancel イベントを持つ
  input.addEventListener("cancel", () => {
    openPickerBusy = false;
    if (instance && typeof instance.exports.vp_file_cancelled === "function") {
      instance.exports.vp_file_cancelled();
    }
  });
  document.body.appendChild(input);
  hiddenFileInput = input;
  return input;
}

function deliverPickedPath(vpath) {
  // vpath は呼び出し側で clampUtf8(..., 256) 済み。ここでの再切断はしない（key 不一致防止）。
  if (!instance || typeof instance.exports.vp_file_path_scratch !== "function") return;
  const enc = new TextEncoder();
  const bytes = enc.encode(vpath);
  const scratch = instance.exports.vp_file_path_scratch();
  const view = new Uint8Array(memory.buffer, scratch, 256);
  view.set(bytes);
  instance.exports.vp_file_picked(bytes.length);
}

/**
 * Zig `vp_request_open` — <input type=file> を発火。
 * @param {number} extPtr
 * @param {number} extLen
 */
function envRequestOpen(extPtr, extLen) {
  if (openPickerBusy) return; // 二重発火防止
  openPickerBusy = true;
  const input = ensureFileInput();
  let accept = "";
  if (extLen > 0) {
    try {
      const ext = new TextDecoder().decode(bytesAt(extPtr, extLen));
      // "png" → ".png,image/png" 程度のヒント
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
  // user gesture 外でも click は多くの browser で動く（button 由来 frame 経由）
  try {
    input.click();
  } catch (e) {
    openPickerBusy = false;
    console.error("file input click failed:", e);
    if (instance && typeof instance.exports.vp_file_cancelled === "function") {
      instance.exports.vp_file_cancelled();
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
    if (!instance || typeof instance.exports.vp_clipboard_text_scratch !== "function") return;
    const enc = new TextEncoder();
    const bytes = enc.encode(String(text || ""));
    const scratch = instance.exports.vp_clipboard_text_scratch();
    const view = new Uint8Array(memory.buffer, scratch, 64);
    const n = Math.min(bytes.length, 64);
    view.set(bytes.subarray(0, n));
    instance.exports.vp_clipboard_text(n);
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
 * wasi_snapshot_preview1 — 手書き shim + in-memory FS（TASK-73.3）。
 * 標準入出力は console。通常ファイルは memFiles/memFds。cwd preopen = fd 3。
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
    if (fd === 0 || fd === 1 || fd === 2 || fd === WASI_PREOPEN_FD) return WASI_ESUCCESS;
    const ent = memFds.get(fd);
    if (!ent) return WASI_EBADF;
    memFds.delete(fd);
    // write 済みなら memFiles に確定 + download 発火
    if (ent.writable && ent.dirty) {
      memFiles.set(ent.path, ent.data);
      triggerDownload(pathBasename(ent.path), ent.data);
    } else if (ent.writable) {
      // 空書きでも path は登録（create のみ）
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
  // M3: per-fd 行バッファ → newline で console.log/error。複数 iovec 連結。
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
      // 相対 open は cwd のみサポート
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
    // cwd preopen のみ（Zig Dir.cwd handle=3）
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
    // rights は無視。writeFile は CREAT|TRUNC、read は oflags=0。
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
  // まず総バイト数
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
    ((e.metaKey || e.ctrlKey) &&
      (c === "KeyZ" || c === "KeyS" || c === "KeyO" || c === "KeyQ" || c === "KeyC" || c === "KeyV" || c === "KeyX")) ||
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
      // TASK-73.3 file dialog / clipboard
      vp_request_open: envRequestOpen,
      vp_clipboard_write: envClipboardWrite,
      vp_request_paste: envRequestPaste,
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
