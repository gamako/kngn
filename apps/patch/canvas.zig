//! apps/patch: パッチキャンバスの純粋幾何/ヒットテストロジック（TASK-40.6.2）。
//!
//! platform / gui / modular を import しない純 Zig。camera 変換・ノード/ポート幾何・ヒットテスト・
//! ビューポート内包判定（見切れ自動検出）を提供し、display/audio 無しで単体テストできる（test-patch）。
//! 描画/入力（main.zig）はこのロジックの上に window・DrawList・イベントを載せるだけ。

const std = @import("std");

pub const Handle = u16;

pub const Vec2f = struct {
    x: f32,
    y: f32,
    pub fn add(a: Vec2f, b: Vec2f) Vec2f {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2f, b: Vec2f) Vec2f {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Vec2f, s: f32) Vec2f {
        return .{ .x = a.x * s, .y = a.y * s };
    }
};

// --- レイアウト定数（world 単位） ---
pub const NODE_W: f32 = 120;
pub const TITLE_H: f32 = 22;
pub const PORT_SPACING: f32 = 20;
pub const BODY_PAD: f32 = 8; // ポート帯の下の余白
pub const WORLD_PORT_R: f32 = 6;
pub const PORT_R_MIN: f32 = 3;
pub const PORT_R_MAX: f32 = 10;
pub const ZOOM_MIN: f32 = 0.25;
pub const ZOOM_MAX: f32 = 4.0;
pub const CABLE_HIT_SLOP: f32 = 6; // world 単位のケーブル当たり判定しきい値

// Inspector の slider 行は GUI widget の [label] [track] [value] 構造に合わせる。
// value_w は最大値文字列（f32 の小数表示）を収める固定予約幅、track_min は短い
// ラベルでも操作領域を残すための下限。通常の inspector content 幅（260px）では
// value_w/track_min とも固定値になる。
// 外形（right/bottom slot）は PanelHost が所有する（TASK-149.1）。
pub const INSPECTOR_PARAM_GAP: i32 = 6;
pub const INSPECTOR_PARAM_VALUE_W: i32 = 64;
pub const INSPECTOR_PARAM_TRACK_MIN: i32 = 48;

pub const ParamRowLayout = struct {
    label_w: i32,
    track_w: i32,
    value_w: i32,

    pub fn total(self: ParamRowLayout) i32 {
        return self.label_w + self.track_w + self.value_w + 2 * INSPECTOR_PARAM_GAP;
    }
};

/// Inspector content 幅に収まる slider 行の純粋な横方向レイアウトを返す。
///
/// label_w は測定済みラベル幅。長いラベルは value_w + track_min + gap を先に
/// 確保して切り詰め、残りを track に渡す。極端に狭い viewport では value/track
/// を縮めるが、通常の panel 幅では value_w=64, track_min=48 を維持する。
pub fn inspectorParamRowLayout(avail: i32, label_w: i32) ParamRowLayout {
    const width = @max(avail, 0);
    const gap_w = 2 * INSPECTOR_PARAM_GAP;
    const value_w = @min(INSPECTOR_PARAM_VALUE_W, @max(0, width - gap_w - INSPECTOR_PARAM_TRACK_MIN));
    const track_min = @min(INSPECTOR_PARAM_TRACK_MIN, @max(0, width - gap_w - value_w));
    const label_max = @max(0, width - gap_w - value_w - track_min);
    const fitted_label = @min(@max(label_w, 0), label_max);
    const track_w = @max(track_min, width - gap_w - value_w - fitted_label);
    return .{ .label_w = fitted_label, .track_w = track_w, .value_w = value_w };
}

/// 描画側が渡すノード幾何。pos は world 左上。
/// grid_rows>0 は本体に step grid を描く箱（畳みマクロ箱 / 選択中の単体 step_seq）:
/// ポート数由来の高さに加えて grid 行数ぶんを nodeSize で確保する（ヒットテスト矩形も同じ高さで整合）。
/// 0 = grid なし。1 = drum 単体 on 行。4 = bass 単体 on/accent/slide/pitch。マクロ箱は group metadata 由来。
pub const NodeGeom = struct {
    handle: Handle,
    pos: Vec2f,
    n_in: u8,
    n_out: u8,
    grid_rows: u8 = 0,
};

/// 出力ポート src_out → 入力ポート dst_in の接続（単一接続なので dst で一意）。
pub const Edge = struct {
    src_handle: Handle,
    src_out: u8,
    dst_handle: Handle,
    dst_in: u8,
};

pub const PortRef = struct {
    handle: Handle,
    is_input: bool,
    index: u8,
};

/// ケーブルの安定 ID（単一接続なので入力ポートで一意）。選択/削除に使う（フレーム内 edge index は
/// add/remove/publish で別ケーブルを指し得るため使わない）。
pub const CableRef = struct {
    dst_handle: Handle,
    dst_in: u8,
};

pub const ScreenRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// モジュールパレットのボタン（screen 座標・pan/zoom 非依存）。
pub const PaletteButton = struct {
    kind_index: u8,
    rect: ScreenRect,
};

/// 2 ポートからケーブルの src(出力)/dst(入力) を決める。一方が出力・他方が入力のときのみ有効。
/// 同方向（out-out / in-in、同一 PortRef 含む）は null。同一ノードの out→in（別ポート＝self-loop）は許可
/// （エンジンが遅延辺として扱う）。種別一致は呼び出し側（dyn.outKindOf/inKindOf）で事前検証する。
pub fn resolveConnection(a: PortRef, b: PortRef) ?struct { src: PortRef, dst: PortRef } {
    if (a.is_input == b.is_input) return null; // 同方向（同一 PortRef もここで弾かれる）
    const src = if (!a.is_input) a else b;
    const dst = if (a.is_input) a else b;
    return .{ .src = src, .dst = dst };
}

fn pointInScreenRect(mx: f32, my: f32, r: ScreenRect) bool {
    return mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h;
}

/// screen 座標のマウスがどのパレットボタン上か（world hit より先に判定する）。
pub fn hitTestPalette(mouse: Vec2f, buttons: []const PaletteButton) ?u8 {
    for (buttons) |btn| {
        if (pointInScreenRect(mouse.x, mouse.y, btn.rect)) return btn.kind_index;
    }
    return null;
}

pub const OffscreenCounts = struct {
    node: u32 = 0,
    port: u32 = 0,
    cable: u32 = 0,
};

// ============================================================================
// ノード/ポート幾何（world 座標）
// ============================================================================

/// ポート行数（入力/出力の多い方。最低 1）。
fn rowCount(g: NodeGeom) f32 {
    const rows = @max(g.n_in, g.n_out);
    return @floatFromInt(@max(rows, 1));
}

/// ノードの world サイズ（幅固定・高さはポート数依存＝見切れ防止のため十分な高さ）。
/// grid_rows>0（マクロ箱 / 選択中 standalone step_seq）は grid が収まる高さと比べて大きい方を採る。
/// TASK-170: n_out>0 のノードは、ミニスコープ/パラメータ値の帯（MINI_H+MINI_GAP）を高さへ常時加算する
/// （tap の有無で高さを変えない＝drag 中の cable 追従を不安定にしないため。tap されていない時は空帯）。
pub fn nodeSize(g: NodeGeom) Vec2f {
    const port_h = TITLE_H + PORT_SPACING * rowCount(g) + BODY_PAD;
    const base_h = if (g.grid_rows == 0) port_h else @max(port_h, TITLE_H + gridBlockHeight(g.grid_rows) + BODY_PAD);
    const band: f32 = if (g.n_out > 0) MINI_H + MINI_GAP else 0;
    return .{ .x = NODE_W, .y = base_h + band };
}

/// 入力ポート i の world 中心（左辺）。
pub fn inPortPos(g: NodeGeom, i: u8) Vec2f {
    const fi: f32 = @floatFromInt(i);
    return .{ .x = g.pos.x, .y = g.pos.y + TITLE_H + PORT_SPACING * (fi + 0.5) };
}

/// 出力ポート j の world 中心（右辺）。
pub fn outPortPos(g: NodeGeom, j: u8) Vec2f {
    const fj: f32 = @floatFromInt(j);
    return .{ .x = g.pos.x + NODE_W, .y = g.pos.y + TITLE_H + PORT_SPACING * (fj + 0.5) };
}

fn portPos(g: NodeGeom, is_input: bool, index: u8) Vec2f {
    return if (is_input) inPortPos(g, index) else outPortPos(g, index);
}

fn pointInRect(p: Vec2f, top_left: Vec2f, size: Vec2f) bool {
    return p.x >= top_left.x and p.x <= top_left.x + size.x and
        p.y >= top_left.y and p.y <= top_left.y + size.y;
}

fn findNode(nodes: []const NodeGeom, h: Handle) ?NodeGeom {
    for (nodes) |n| {
        if (n.handle == h) return n;
    }
    return null;
}

// ============================================================================
// Camera（world <-> screen 変換）
// ============================================================================
pub const Camera = struct {
    pan: Vec2f = .{ .x = 0, .y = 0 },
    zoom: f32 = 1.0,

    pub fn worldToScreen(c: Camera, w: Vec2f) Vec2f {
        return .{ .x = w.x * c.zoom + c.pan.x, .y = w.y * c.zoom + c.pan.y };
    }
    pub fn screenToWorld(c: Camera, s: Vec2f) Vec2f {
        return .{ .x = (s.x - c.pan.x) / c.zoom, .y = (s.y - c.pan.y) / c.zoom };
    }

    /// カーソル下の world 点を固定したまま zoom する（zoom は [ZOOM_MIN,ZOOM_MAX] に clamp）。
    pub fn zoomAt(c: *Camera, cursor_screen: Vec2f, factor: f32) void {
        const new_zoom = std.math.clamp(c.zoom * factor, ZOOM_MIN, ZOOM_MAX);
        const eff = new_zoom / c.zoom; // clamp 後の実効倍率
        c.pan = .{
            .x = cursor_screen.x - (cursor_screen.x - c.pan.x) * eff,
            .y = cursor_screen.y - (cursor_screen.y - c.pan.y) * eff,
        };
        c.zoom = new_zoom;
    }

    /// ポートの screen 描画半径（zoom 0.25 で消えず zoom 4 で肥大しないよう clamp）。
    pub fn portScreenRadius(c: Camera) f32 {
        return std.math.clamp(WORLD_PORT_R * c.zoom, PORT_R_MIN, PORT_R_MAX);
    }
};

// ============================================================================
// ヒットテスト（world 座標で判定。呼び出し側で screenToWorld してから渡す）
// ============================================================================

/// world 点を含む最前面ノード（描画順の逆＝末尾優先）。
pub fn hitTestNode(world_pt: Vec2f, nodes: []const NodeGeom) ?Handle {
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        const g = nodes[i];
        if (pointInRect(world_pt, g.pos, nodeSize(g))) return g.handle;
    }
    return null;
}

/// world 点近傍のポート（当たり半径 = WORLD_PORT_R。最前面優先）。
pub fn hitTestPort(world_pt: Vec2f, nodes: []const NodeGeom) ?PortRef {
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        const g = nodes[i];
        var k: u8 = 0;
        while (k < g.n_in) : (k += 1) {
            if (dist(world_pt, inPortPos(g, k)) <= WORLD_PORT_R) return .{ .handle = g.handle, .is_input = true, .index = k };
        }
        k = 0;
        while (k < g.n_out) : (k += 1) {
            if (dist(world_pt, outPortPos(g, k)) <= WORLD_PORT_R) return .{ .handle = g.handle, .is_input = false, .index = k };
        }
    }
    return null;
}

// ----------------------------------------------------------------------------
// 折り畳みトグル [±]（TASK-40.7.1）: タイトル行右端の小矩形。group.zig の畳み箱・展開枠のヘッダーが
// NodeGeom 形状で表現される前提で、位置決め/ヒットテストのみをここに置く（group.zig は modular 非依存の
// ため合成 handle の意味は main.zig 側の責務。ここは純幾何）。
// ----------------------------------------------------------------------------
pub const TOGGLE_SIZE: f32 = 14;
pub const TOGGLE_MARGIN: f32 = 4;

/// タイトル行内の折り畳みトグルの world 左上位置（ノード右端寄せ、固定 NODE_W 基準）。
pub fn togglePos(g: NodeGeom) Vec2f {
    return .{ .x = g.pos.x + NODE_W - TOGGLE_SIZE - TOGGLE_MARGIN, .y = g.pos.y + (TITLE_H - TOGGLE_SIZE) / 2 };
}

fn pointInToggle(world_pt: Vec2f, g: NodeGeom) bool {
    return pointInRect(world_pt, togglePos(g), .{ .x = TOGGLE_SIZE, .y = TOGGLE_SIZE });
}

/// world 点近傍のトグルを持つノード（最前面優先）。
pub fn hitTestToggle(world_pt: Vec2f, nodes: []const NodeGeom) ?Handle {
    var i: usize = nodes.len;
    while (i > 0) {
        i -= 1;
        const g = nodes[i];
        if (pointInToggle(world_pt, g)) return g.handle;
    }
    return null;
}

// ----------------------------------------------------------------------------
// step grid レイアウト定数（マクロ箱 / 単体 step_seq 共通。TASK-40.7.2 / TASK-110.2）。
// セル矩形とヒットテストは libs/gui.stepgrid が一元管理し、main.zig が camera 変換前後の
// adapter を担当する。
// ----------------------------------------------------------------------------
pub const GRID_STEPS: u8 = 16;
pub const GRID_SIDE_PAD: f32 = 10; // 左右マージン（左右ポート dot を避ける）
pub const GRID_TOP_PAD: f32 = 4; // タイトル下からグリッド先頭までの余白
pub const GRID_CELL_H: f32 = 8; // セル高
pub const GRID_ROW_GAP: f32 = 2; // 行間
/// マクロ箱タイトル帯の evolve/lock トグル（step grid と非衝突。TASK-160.2）。
pub const MACRO_MUT_TOGGLE_W: f32 = 12;
pub const MACRO_MUT_TOGGLE_H: f32 = 10;
pub const MACRO_MUT_TOGGLE_GAP: f32 = 4;

pub const MacroToggleRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// box-local: evolve トグル矩形（タイトル帯左端。collapse [±] と非衝突）。
pub fn macroEvolveToggleRect() MacroToggleRect {
    return .{
        .x = GRID_SIDE_PAD,
        .y = (TITLE_H - MACRO_MUT_TOGGLE_H) * 0.5,
        .w = MACRO_MUT_TOGGLE_W,
        .h = MACRO_MUT_TOGGLE_H,
    };
}

/// box-local: lane 番目の lock トグル（evolve の右に横並び）。
pub fn macroLockToggleRect(lane: u8) MacroToggleRect {
    const e = macroEvolveToggleRect();
    const x = e.x + e.w + MACRO_MUT_TOGGLE_GAP + @as(f32, @floatFromInt(lane)) * (MACRO_MUT_TOGGLE_W + MACRO_MUT_TOGGLE_GAP);
    return .{ .x = x, .y = e.y, .w = MACRO_MUT_TOGGLE_W, .h = MACRO_MUT_TOGGLE_H };
}

/// トグル帯が step grid 原点より上にあること（衝突しない）を保証する判定。
pub fn macroToggleAboveGrid(r: MacroToggleRect) bool {
    return r.y + r.h <= TITLE_H + GRID_TOP_PAD - 0.5;
}

/// evolve + lock(n レーン分) トグル帯がタイトル帯左端から占有する幅（box-local）。
/// タイトルテキストの描画 x をこの分だけ右へ逃がし、トグルとの視覚的な重なりを防ぐ
/// （TASK-160.2 実装直後の実機フィードバックで発覚: トグルとタイトル文字が同じ x 帯に
/// 描画され判読不能だった。n=0 なら 0 を返しテキストは従来どおり）。
pub fn macroToggleReservedWidth(n: u8) f32 {
    if (n == 0) return 0;
    const e = macroEvolveToggleRect();
    return e.x + e.w + MACRO_MUT_TOGGLE_GAP + @as(f32, @floatFromInt(n)) * (MACRO_MUT_TOGGLE_W + MACRO_MUT_TOGGLE_GAP);
}

/// stepgrid へ渡す前の box-local / screen grid 幾何。gui を import しない canvas 側でも、描画と
/// hit-test が同じ定数を使う adapter の入力を単一化する。
pub const GridGeometry = struct {
    origin_x: f32,
    origin_y: f32,
    cell_w: f32,
    cell_h: f32,
    step_pitch: f32,
    row_pitch: f32,
};

/// 1 step の水平ピッチ（cell 幅 + gap 込み）。16 step が箱内幅に収まる。
pub fn gridStepWidth() f32 {
    return (NODE_W - 2 * GRID_SIDE_PAD) / @as(f32, @floatFromInt(GRID_STEPS));
}

/// タイトル下端からグリッド下端までの高さ（rows 行）。nodeSize の箱高さ拡張に使う。
pub fn gridBlockHeight(rows: u8) f32 {
    const fr: f32 = @floatFromInt(rows);
    return GRID_TOP_PAD + fr * (GRID_CELL_H + GRID_ROW_GAP);
}

/// ノード/マクロ箱共通の grid geometry。camera 変換済み origin / cell size / pitch。
/// box-local の呼び出しでは box_pos = (0, 0)・zoom=1 を渡す。
pub fn gridGeometry(cam: Camera, box_pos: Vec2f) GridGeometry {
    const top_left = cam.worldToScreen(box_pos);
    const step_pitch = gridStepWidth() * cam.zoom;
    return .{
        .origin_x = top_left.x + GRID_SIDE_PAD * cam.zoom,
        .origin_y = top_left.y + (TITLE_H + GRID_TOP_PAD) * cam.zoom,
        .cell_w = step_pitch - 1.5 * cam.zoom,
        .cell_h = GRID_CELL_H * cam.zoom,
        .step_pitch = step_pitch,
        .row_pitch = (GRID_CELL_H + GRID_ROW_GAP) * cam.zoom,
    };
}

/// world 点近傍のケーブル（点と線分の距離 <= CABLE_HIT_SLOP）。edge index を返す。
pub fn hitTestCable(world_pt: Vec2f, nodes: []const NodeGeom, edges: []const Edge) ?usize {
    var idx: usize = edges.len;
    while (idx > 0) {
        idx -= 1;
        const e = edges[idx];
        const sg = findNode(nodes, e.src_handle) orelse continue;
        const dg = findNode(nodes, e.dst_handle) orelse continue;
        const a = outPortPos(sg, e.src_out);
        const b = inPortPos(dg, e.dst_in);
        if (distPointSegment(world_pt, a, b) <= CABLE_HIT_SLOP) return idx;
    }
    return null;
}

fn dist(a: Vec2f, b: Vec2f) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

/// 点 p と線分 ab の距離。
fn distPointSegment(p: Vec2f, a: Vec2f, b: Vec2f) f32 {
    const abx = b.x - a.x;
    const aby = b.y - a.y;
    const len2 = abx * abx + aby * aby;
    if (len2 <= 1e-9) return dist(p, a);
    var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2;
    t = std.math.clamp(t, 0.0, 1.0);
    const proj = Vec2f{ .x = a.x + abx * t, .y = a.y + aby * t };
    return dist(p, proj);
}

// ============================================================================
// ミニ oscilloscope（TASK-40.8 D）: 出力ポート別の直近波形小窓の幾何 + tap 対象選択（純ロジック）。
// 表示は 1 ノード 1 窓（out0 を代表）。ノード矩形の直下に screen 固定サイズで置き、ノード位置に追従する。
// modular / dyn 非依存（global port id 解決は main.zig 側の責務）。
// ============================================================================
pub const MINI_W: f32 = 64; // world 単位（TASK-170: screen 固定 px から world 単位へ変更。ノードの
// 他の幾何(NODE_W 等)と同じ scale 前提に揃え、nodeSize() へ帯として組み込めるようにする）
pub const MINI_H: f32 = 28; // world 単位
pub const MINI_GAP: f32 = 4; // world 単位（ノード下端 - スコープ帯上端の内側マージン）
pub const MINI_ZOOM_MIN: f32 = 0.5; // これ未満の zoom では非表示（視認不能な窓のため RT tap を払わない）
/// selectTapPortsStable の候補一時バッファ上限（TASK-170）。呼び出し側の TAP_SLOTS(16) を
/// 十分に超える固定値。canvas.zig は modular/dyn 非依存のため TAP_SLOTS を直接 import しない。
const MAX_TAP_CANDIDATES: usize = 32;

/// ノード内側・下端に置くミニスコープ矩形（screen 座標）。TASK-170: ノード枠外ではなく枠内（下端から
/// band=MINI_H+MINI_GAP 分だけ上）に描くよう変更。`node_tl_screen`/`node_size_screen` は呼び出し側で
/// zoom 適用済み（screen 座標）、`MINI_W`/`MINI_H`/`MINI_GAP` は world 単位定数のためここで `zoom` を
/// 乗じる（二重 scale/未 scale を避けるためこの関数内でのみ乗算する契約）。
pub fn miniScopeRect(node_tl_screen: Vec2f, node_size_screen: Vec2f, zoom: f32) ScreenRect {
    return .{
        .x = node_tl_screen.x,
        .y = node_tl_screen.y + node_size_screen.y - (MINI_H + MINI_GAP) * zoom,
        .w = MINI_W * zoom,
        .h = MINI_H * zoom,
    };
}

/// ミニスコープの表示開始 index（立ち上がりゼロ交差トリガ）。oldest→newest 並びの `samples` から、末尾 `disp`
/// 点を表示するとき、その表示窓を「最新の rising zero-crossing」に揃えて周期波形を静止させる。交差が無い
/// （＝gate/単極 cv のようにゼロを跨がない）場合は最新窓（= 非ロック・流れる表示）へ自然降格する。
/// 返す start は必ず start+disp<=samples.len（呼び出し側の slice が安全）。
pub fn findTriggerStart(samples: []const f32, disp: usize) usize {
    const n = samples.len;
    if (disp >= n or disp < 2) return if (n > disp) n - disp else 0;
    const newest = n - disp; // 非ロック時の開始（最新 disp 点）
    var t = newest;
    while (t > 0) : (t -= 1) {
        if (samples[t - 1] < 0.0 and samples[t] >= 0.0) return t; // newest 以下で最も新しい rising 交差
    }
    return newest;
}

/// tap 候補か: 出力ポートを持ち、ノード矩形が viewport と交差する（TASK-170: ミニスコープはノード内側に
/// 描くようになったため、完全内包ではなく「ノード自体が viewport と交差するか」のみを見る。下端付近で
/// 一部だけ見えているノードも対象にする。vh はキャンバス有効高）。
fn isTapCandidate(cam: Camera, vw: f32, vh: f32, g: NodeGeom) bool {
    if (g.n_out == 0) return false;
    if (cam.zoom < MINI_ZOOM_MIN) return false;
    const tl = cam.worldToScreen(g.pos);
    const sz = nodeSize(g).scale(cam.zoom);
    return tl.x < vw and tl.x + sz.x > 0 and tl.y < vh and tl.y + sz.y > 0;
}

fn containsHandle(list: []const Handle, h: Handle) bool {
    for (list) |x| {
        if (x == h) return true;
    }
    return false;
}

/// ミニスコープ表示対象（＝tap 対象）のノード handle を優先度順に out へ最大 out.len 個選ぶ。
/// zoom<MINI_ZOOM_MIN は 0 本（tap を張らない）。優先順位: selected > hover > nodes の並び順。
/// 返す handle は display node の handle（collapsed 箱＝合成 handle 可。global port id 解決は呼び出し側）。
pub fn selectTapPorts(
    cam: Camera,
    vw: f32,
    vh: f32,
    nodes: []const NodeGeom,
    selected: ?Handle,
    hover: ?Handle,
    out: []Handle,
) usize {
    if (cam.zoom < MINI_ZOOM_MIN or out.len == 0) return 0;
    var n: usize = 0;
    if (selected) |sh| {
        if (findNode(nodes, sh)) |g| {
            if (isTapCandidate(cam, vw, vh, g) and n < out.len) {
                out[n] = sh;
                n += 1;
            }
        }
    }
    if (hover) |hh| {
        if (findNode(nodes, hh)) |g| {
            if (isTapCandidate(cam, vw, vh, g) and !containsHandle(out[0..n], hh) and n < out.len) {
                out[n] = hh;
                n += 1;
            }
        }
    }
    for (nodes) |g| {
        if (n >= out.len) break;
        if (isTapCandidate(cam, vw, vh, g) and !containsHandle(out[0..n], g.handle)) {
            out[n] = g.handle;
            n += 1;
        }
    }
    return n;
}

fn keptElsewhere(slots: []const ?Handle, h: Handle) bool {
    for (slots) |m| {
        if (m) |x| {
            if (x == h) return true;
        }
    }
    return false;
}

/// TASK-170: 安定版 tap 対象選択。`prev`（前回の各 slot の display handle。空きは null）のうち
/// 今フレームも `isTapCandidate` を満たすものは**同じ slot 番号のまま**維持し、無関係な hover/selected
/// の変化で巻き添えリセットしない（TASK-170 の実機フィードバックで発覚した回帰の根治）。
///
/// **置換できるのは selected/hover のみ**（v2 修正。codex レビューで検出: 通常候補〈走査順のみで
/// 選ばれる優先度の低い候補〉にも置換権を与えると、候補数が cap を超える環境で「今フレーム A・B が
/// 通常候補 C・D に置換され、次フレームは C・D が A・B に置換され…」というフレーム間の永久
/// ローテーションが起き、tap config の republish/RT リング reset が毎フレーム走ってしまう）。
/// 空いた slot は selected > hover > nodes 走査順の優先度で新規候補を割り当てるが、**空き slot が無い
/// 場合に既存の温存 slot を明け渡させて良いのは selected/hover だけ**（selected でも hover でもない
/// 通常候補は、空きが無ければそのフレームでは表示されず脱落する＝安定第一）。
/// `prev`/`out` は同じ長さ（呼び出し側の TAP_SLOTS 相当）。`out` は `prev` と別バッファでも同一でも良い。
pub fn selectTapPortsStable(
    cam: Camera,
    vw: f32,
    vh: f32,
    nodes: []const NodeGeom,
    selected: ?Handle,
    hover: ?Handle,
    prev: []const ?Handle,
    out: []?Handle,
) void {
    std.debug.assert(out.len == prev.len);
    const cap = out.len;
    if (cap == 0) return;
    if (cam.zoom < MINI_ZOOM_MIN) {
        for (out) |*o| o.* = null;
        return;
    }

    // 1. 既存 slot の温存判定（slot 番号を維持する）。
    for (prev, 0..) |maybe_h, idx| {
        out[idx] = null;
        if (maybe_h) |h| {
            if (findNode(nodes, h)) |g| {
                if (isTapCandidate(cam, vw, vh, g)) out[idx] = h;
            }
        }
    }

    // 2a. 優先候補（selected/hover のみ。既に温存された handle は除く）。最大2件。
    std.debug.assert(cap <= MAX_TAP_CANDIDATES);
    var priority: [2]Handle = undefined;
    var nprio: usize = 0;
    if (selected) |sh| {
        if (findNode(nodes, sh)) |g| {
            if (isTapCandidate(cam, vw, vh, g) and !keptElsewhere(out, sh)) {
                priority[nprio] = sh;
                nprio += 1;
            }
        }
    }
    if (hover) |hh| {
        if (findNode(nodes, hh)) |g| {
            if (isTapCandidate(cam, vw, vh, g) and !keptElsewhere(out, hh) and
                !containsHandle(priority[0..nprio], hh))
            {
                priority[nprio] = hh;
                nprio += 1;
            }
        }
    }

    // 2b. 通常候補（nodes 走査順。優先候補・温存済み handle は除く。cap で切る）。
    var plain: [MAX_TAP_CANDIDATES]Handle = undefined;
    var nplain: usize = 0;
    for (nodes) |g| {
        if (nprio + nplain >= cap) break;
        if (isTapCandidate(cam, vw, vh, g) and !keptElsewhere(out, g.handle) and
            !containsHandle(priority[0..nprio], g.handle) and !containsHandle(plain[0..nplain], g.handle))
        {
            plain[nplain] = g.handle;
            nplain += 1;
        }
    }

    // 3. 空き slot への充填（優先候補 → 通常候補の順）。`locked` は「この呼び出し内で新規に
    // 割り当てた slot」だけに立てる（step1 で温存された既存 slot は locked にしない＝引き続き
    // 満杯時置換〈優先候補のみ〉の victim になれる。容量1で旧 hover を新 selected が置換する
    // ケースはこの経路を通る）。
    var locked: [MAX_TAP_CANDIDATES]bool = [_]bool{false} ** MAX_TAP_CANDIDATES;
    var pi: usize = 0; // priority index
    var qi: usize = 0; // plain index
    for (out, 0..) |*o, idx| {
        if (o.* != null) continue; // step1 で温存済み（locked にはしない）
        if (pi < nprio) {
            o.* = priority[pi];
            pi += 1;
        } else if (qi < nplain) {
            o.* = plain[qi];
            qi += 1;
        } else continue;
        locked[idx] = true; // 新規充填。直後の反復で同じ slot を再度置換しない
    }

    // 4. 満杯時の置換（**優先候補のみ**。未割当の通常候補は空きが無ければ脱落する＝安定第一）。
    while (pi < nprio) {
        var victim: ?usize = null;
        for (out, 0..) |o, idx| {
            if (locked[idx]) continue;
            const h = o orelse continue;
            if (selected != null and h == selected.?) continue;
            if (hover != null and h == hover.?) continue;
            victim = idx;
            break;
        }
        const v = victim orelse break; // 置換対象なし（cap が selected+hover で埋まっている等）
        out[v] = priority[pi];
        locked[v] = true; // 直後の反復で同じ slot を再度 victim にしない
        pi += 1;
    }
}

// ============================================================================
// ビューポート内包判定（見切れ自動検出。TASK-43 教訓）
// ============================================================================

fn pointInViewport(p: Vec2f, vw: f32, vh: f32) bool {
    return p.x >= 0 and p.x <= vw and p.y >= 0 and p.y <= vh;
}

/// screen 空間で、全ノード矩形・全ポート円・全ケーブル端点が viewport [0,vw]x[0,vh] 内に収まるか。
/// offscreen 件数を返す（0 = 見切れ無し）。初期／制御された代表配置での不変条件チェックに使う。
pub fn viewportContains(cam: Camera, vw: f32, vh: f32, nodes: []const NodeGeom, edges: []const Edge) OffscreenCounts {
    var out = OffscreenCounts{};
    const r = cam.portScreenRadius();
    for (nodes) |g| {
        const tl = cam.worldToScreen(g.pos);
        const sz = nodeSize(g).scale(cam.zoom);
        const br = Vec2f{ .x = tl.x + sz.x, .y = tl.y + sz.y };
        if (!pointInViewport(tl, vw, vh) or !pointInViewport(br, vw, vh)) out.node += 1;

        var k: u8 = 0;
        while (k < g.n_in) : (k += 1) {
            if (!portCircleInside(cam.worldToScreen(inPortPos(g, k)), r, vw, vh)) out.port += 1;
        }
        k = 0;
        while (k < g.n_out) : (k += 1) {
            if (!portCircleInside(cam.worldToScreen(outPortPos(g, k)), r, vw, vh)) out.port += 1;
        }
    }
    for (edges) |e| {
        const sg = findNode(nodes, e.src_handle) orelse continue;
        const dg = findNode(nodes, e.dst_handle) orelse continue;
        const a = cam.worldToScreen(outPortPos(sg, e.src_out));
        const b = cam.worldToScreen(inPortPos(dg, e.dst_in));
        if (!pointInViewport(a, vw, vh) or !pointInViewport(b, vw, vh)) out.cable += 1;
    }
    return out;
}

fn portCircleInside(center: Vec2f, r: f32, vw: f32, vh: f32) bool {
    return center.x - r >= 0 and center.x + r <= vw and center.y - r >= 0 and center.y + r <= vh;
}

// ============================================================================
// tests（display/audio 不要。test-patch）
// ============================================================================
const testing = std.testing;

fn expectApproxVec(a: Vec2f, b: Vec2f) !void {
    try testing.expectApproxEqAbs(a.x, b.x, 1e-3);
    try testing.expectApproxEqAbs(a.y, b.y, 1e-3);
}

test "canvas: worldToScreen/screenToWorld round-trip" {
    const cams = [_]Camera{
        .{ .pan = .{ .x = 0, .y = 0 }, .zoom = 1.0 },
        .{ .pan = .{ .x = 30, .y = -12 }, .zoom = 2.0 },
        .{ .pan = .{ .x = -100, .y = 50 }, .zoom = 0.25 },
    };
    for (cams) |c| {
        const w = Vec2f{ .x = 123.5, .y = -7.25 };
        try expectApproxVec(w, c.screenToWorld(c.worldToScreen(w)));
    }
}

test "canvas: zoomAt keeps cursor world point fixed" {
    var c = Camera{ .pan = .{ .x = 40, .y = 20 }, .zoom = 1.0 };
    const cursor = Vec2f{ .x = 300, .y = 200 };
    const w_before = c.screenToWorld(cursor);
    c.zoomAt(cursor, 1.5);
    const w_after = c.screenToWorld(cursor);
    try expectApproxVec(w_before, w_after);
    // clamp: 極端 zoom-in でも上限、zoom-out でも下限
    c.zoomAt(cursor, 100.0);
    try testing.expectApproxEqAbs(ZOOM_MAX, c.zoom, 1e-6);
    c.zoomAt(cursor, 0.0001);
    try testing.expectApproxEqAbs(ZOOM_MIN, c.zoom, 1e-6);
    // clamp してもカーソル world 点は不変
    const w2 = c.screenToWorld(cursor);
    c.zoomAt(cursor, 2.0);
    try expectApproxVec(w2, c.screenToWorld(cursor));
}

test "canvas: hitTestNode inside/outside and topmost on overlap" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 50, .y = 20 }, .n_in = 2, .n_out = 1 }, // 0 と重なる
    };
    // 重なり領域は末尾（handle 1）が最前面
    try testing.expectEqual(@as(?Handle, 1), hitTestNode(.{ .x = 60, .y = 30 }, &nodes));
    // node0 だけの領域
    try testing.expectEqual(@as(?Handle, 0), hitTestNode(.{ .x = 10, .y = 10 }, &nodes));
    // どのノードにも無い
    try testing.expectEqual(@as(?Handle, null), hitTestNode(.{ .x = 500, .y = 500 }, &nodes));
}

test "canvas: port positions lie on node edges within node rect" {
    const g = NodeGeom{ .handle = 3, .pos = .{ .x = 10, .y = 10 }, .n_in = 3, .n_out = 2 };
    const sz = nodeSize(g);
    var i: u8 = 0;
    while (i < g.n_in) : (i += 1) {
        const p = inPortPos(g, i);
        try testing.expectApproxEqAbs(g.pos.x, p.x, 1e-4); // 左辺
        try testing.expect(p.y > g.pos.y and p.y < g.pos.y + sz.y);
    }
    var j: u8 = 0;
    while (j < g.n_out) : (j += 1) {
        const p = outPortPos(g, j);
        try testing.expectApproxEqAbs(g.pos.x + NODE_W, p.x, 1e-4); // 右辺
        try testing.expect(p.y > g.pos.y and p.y < g.pos.y + sz.y);
    }
}

test "canvas: hitTestPort / hitTestCable" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 200, .y = 0 }, .n_in = 1, .n_out = 0 },
    };
    const edges = [_]Edge{.{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 }};
    // node0 の出力ポート近傍
    const op = outPortPos(nodes[0], 0);
    try testing.expect(hitTestPort(op, &nodes) != null);
    const pr = hitTestPort(op, &nodes).?;
    try testing.expectEqual(@as(Handle, 0), pr.handle);
    try testing.expect(!pr.is_input);
    // ケーブル中点近傍
    const ip = inPortPos(nodes[1], 0);
    const mid = Vec2f{ .x = (op.x + ip.x) / 2, .y = (op.y + ip.y) / 2 };
    try testing.expectEqual(@as(?usize, 0), hitTestCable(mid, &nodes, &edges));
    // ケーブルから離れた点は当たらない
    try testing.expectEqual(@as(?usize, null), hitTestCable(.{ .x = mid.x, .y = mid.y + 100 }, &nodes, &edges));
}

test "canvas: hitTestToggle hits the toggle box and misses node body / outside" {
    const nodes = [_]NodeGeom{
        .{ .handle = 5, .pos = .{ .x = 100, .y = 50 }, .n_in = 1, .n_out = 1 },
    };
    const tp = togglePos(nodes[0]);
    const inside = Vec2f{ .x = tp.x + TOGGLE_SIZE / 2, .y = tp.y + TOGGLE_SIZE / 2 };
    try testing.expectEqual(@as(?Handle, 5), hitTestToggle(inside, &nodes));
    // ノード内だがトグル外（左端付近）。
    const node_body = Vec2f{ .x = nodes[0].pos.x + 5, .y = nodes[0].pos.y + 5 };
    try testing.expectEqual(@as(?Handle, null), hitTestToggle(node_body, &nodes));
    // ノード外。
    try testing.expectEqual(@as(?Handle, null), hitTestToggle(.{ .x = 900, .y = 900 }, &nodes));
}

test "canvas: nodeSize grows for grid box (grid_rows>0) and matches gridBlockHeight" {
    const plain = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 };
    const box = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1, .grid_rows = 2 };
    try testing.expect(nodeSize(box).y > nodeSize(plain).y); // grid 行ぶん拡張
    // 明示式と一致（port 高さより grid 高さが大きいケース）。TASK-170: n_out>0 の帯(MINI_H+MINI_GAP)込み。
    const expect_h = TITLE_H + gridBlockHeight(2) + BODY_PAD + MINI_H + MINI_GAP;
    try testing.expectApproxEqAbs(expect_h, nodeSize(box).y, 1e-4);
}

test "canvas: nodeSize contains 1-row inline grid (drum standalone)" {
    const g = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1, .grid_rows = 1 };
    const geom = gridGeometry(.{ .zoom = 1.0 }, g.pos);
    const last_y = geom.origin_y + geom.cell_h; // row 0 下端
    try testing.expect(last_y <= g.pos.y + nodeSize(g).y);
    // port 高さと grid 高さの max（1 行 grid は port 高より低いことが多い）+ TASK-170 の n_out>0 帯。
    const port_h = TITLE_H + PORT_SPACING * 1.0 + BODY_PAD;
    const grid_h = TITLE_H + gridBlockHeight(1) + BODY_PAD;
    try testing.expectApproxEqAbs(@max(port_h, grid_h) + MINI_H + MINI_GAP, nodeSize(g).y, 1e-4);
}

test "canvas: nodeSize contains 4-row inline grid (bass standalone)" {
    const g = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 3, .grid_rows = 4 };
    const geom = gridGeometry(.{ .zoom = 1.0 }, g.pos);
    // row 3 下端が node 下端以内
    const last_y = geom.origin_y + 3.0 * geom.row_pitch + geom.cell_h;
    try testing.expect(last_y <= g.pos.y + nodeSize(g).y);
    // bass は n_out=3 の port 高と 4 行 grid 高の max + TASK-170 の n_out>0 帯。
    const port_h = TITLE_H + PORT_SPACING * 3.0 + BODY_PAD;
    const grid_h = TITLE_H + gridBlockHeight(4) + BODY_PAD;
    try testing.expectApproxEqAbs(@max(port_h, grid_h) + MINI_H + MINI_GAP, nodeSize(g).y, 1e-4);
}

test "canvas: gridGeometry is shared by macro box and standalone node positions" {
    const cam = Camera{ .pan = .{ .x = 12, .y = -4 }, .zoom = 1.5 };
    const pos = Vec2f{ .x = 160, .y = 470 };
    // 同一 adapter・同一入力なら同一セル矩形（macro / standalone の意味差は呼び出し側のみ）。
    const a = gridGeometry(cam, pos);
    const b = gridGeometry(cam, pos);
    try testing.expectEqual(a.origin_x, b.origin_x);
    try testing.expectEqual(a.origin_y, b.origin_y);
    try testing.expectEqual(a.cell_w, b.cell_w);
    try testing.expectEqual(a.cell_h, b.cell_h);
    try testing.expectEqual(a.step_pitch, b.step_pitch);
    try testing.expectEqual(a.row_pitch, b.row_pitch);
    // 代表セル中心が box 内（standalone 1 行 / macro 3 行とも同じ定数）
    const cx = a.origin_x + a.cell_w * 0.5;
    const cy = a.origin_y + a.cell_h * 0.5;
    try testing.expect(cx > pos.x * cam.zoom + cam.pan.x);
    try testing.expect(cy > pos.y * cam.zoom + cam.pan.y);
}

test "canvas: resolveConnection direction rules (self-loop allowed, same-dir rejected)" {
    const out0 = PortRef{ .handle = 0, .is_input = false, .index = 0 };
    const in0 = PortRef{ .handle = 1, .is_input = true, .index = 0 };
    // out→in
    {
        const rc = resolveConnection(out0, in0).?;
        try testing.expectEqual(@as(Handle, 0), rc.src.handle);
        try testing.expectEqual(@as(Handle, 1), rc.dst.handle);
        try testing.expect(!rc.src.is_input and rc.dst.is_input);
    }
    // in→out（順不同でも src=出力）
    {
        const rc = resolveConnection(in0, out0).?;
        try testing.expectEqual(@as(Handle, 0), rc.src.handle);
        try testing.expectEqual(@as(Handle, 1), rc.dst.handle);
    }
    // out-out / in-in は無効
    try testing.expect(resolveConnection(out0, .{ .handle = 2, .is_input = false, .index = 0 }) == null);
    try testing.expect(resolveConnection(in0, .{ .handle = 2, .is_input = true, .index = 1 }) == null);
    // 同一ノードの out→in（別ポート = self-loop）は許可
    {
        const s_out = PortRef{ .handle = 5, .is_input = false, .index = 0 };
        const s_in = PortRef{ .handle = 5, .is_input = true, .index = 1 };
        const rc = resolveConnection(s_out, s_in).?;
        try testing.expectEqual(@as(Handle, 5), rc.src.handle);
        try testing.expectEqual(@as(Handle, 5), rc.dst.handle);
    }
}

test "canvas: hitTestPalette inside/outside" {
    const buttons = [_]PaletteButton{
        .{ .kind_index = 0, .rect = .{ .x = 10, .y = 20, .w = 100, .h = 24 } },
        .{ .kind_index = 1, .rect = .{ .x = 10, .y = 50, .w = 100, .h = 24 } },
    };
    try testing.expectEqual(@as(?u8, 0), hitTestPalette(.{ .x = 50, .y = 30 }, &buttons));
    try testing.expectEqual(@as(?u8, 1), hitTestPalette(.{ .x = 50, .y = 60 }, &buttons));
    try testing.expectEqual(@as(?u8, null), hitTestPalette(.{ .x = 500, .y = 30 }, &buttons));
}

test "canvas: miniScopeRect sits inside the node's bottom edge (TASK-170)" {
    const tl = Vec2f{ .x = 100, .y = 50 };
    const zoom: f32 = 1.0;
    // n_out>0 のノードは nodeSize() が既に帯込みなので、そのまま sz として渡す。
    const g = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 };
    const sz = nodeSize(g).scale(zoom);
    const r = miniScopeRect(tl, sz, zoom);
    try testing.expectApproxEqAbs(tl.x, r.x, 1e-4);
    try testing.expectApproxEqAbs(tl.y + sz.y - (MINI_H + MINI_GAP) * zoom, r.y, 1e-4);
    try testing.expectApproxEqAbs(MINI_W * zoom, r.w, 1e-4);
    try testing.expectApproxEqAbs(MINI_H * zoom, r.h, 1e-4);
    // ノードの内側（下端からはみ出さない）に収まること。
    try testing.expect(r.y >= tl.y);
    try testing.expect(r.y + r.h <= tl.y + sz.y + 1e-4);
    try testing.expect(r.x + r.w <= tl.x + sz.x + 1e-4);
}

test "canvas: miniScopeRect stays within node bounds across zoom range (0.25/0.5/4.0)" {
    const g = NodeGeom{ .handle = 0, .pos = .{ .x = 0, .y = 0 }, .n_in = 1, .n_out = 1 };
    const tl = Vec2f{ .x = 200, .y = 150 };
    for ([_]f32{ 0.25, 0.5, 4.0 }) |zoom| {
        const sz = nodeSize(g).scale(zoom);
        const r = miniScopeRect(tl, sz, zoom);
        try testing.expect(r.x >= tl.x - 1e-3);
        try testing.expect(r.x + r.w <= tl.x + sz.x + 1e-3);
        try testing.expect(r.y >= tl.y - 1e-3);
        try testing.expect(r.y + r.h <= tl.y + sz.y + 1e-3);
    }
}

test "canvas: selectTapPorts — priority selected>hover>order, cap, zoom gate, n_out filter" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 0 }, // 出力なし → 非候補
    };
    const cam = Camera{ .zoom = 1.0 };
    const vw: f32 = 800;
    const vh: f32 = 400;
    var out: [8]Handle = undefined;
    // selected=1, hover=0 → [1, 0, ...残り順]。handle 2 は n_out=0 で除外。
    {
        const n = selectTapPorts(cam, vw, vh, &nodes, 1, 0, &out);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqual(@as(Handle, 1), out[0]); // selected 先頭
        try testing.expectEqual(@as(Handle, 0), out[1]); // hover 次
    }
    // 選択/hover なし → node 並び順（handle 2 除外）。
    {
        const n = selectTapPorts(cam, vw, vh, &nodes, null, null, &out);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqual(@as(Handle, 0), out[0]);
        try testing.expectEqual(@as(Handle, 1), out[1]);
    }
    // zoom < MINI_ZOOM_MIN → 0 本。
    {
        const n = selectTapPorts(.{ .zoom = 0.3 }, vw, vh, &nodes, 1, 0, &out);
        try testing.expectEqual(@as(usize, 0), n);
    }
    // cap: out 長 1 → 1 本（selected 優先）。
    {
        var one: [1]Handle = undefined;
        const n = selectTapPorts(cam, vw, vh, &nodes, 1, 0, &one);
        try testing.expectEqual(@as(usize, 1), n);
        try testing.expectEqual(@as(Handle, 1), one[0]);
    }
}

test "canvas: findTriggerStart locks periodic signal to a rising zero crossing; free-runs otherwise" {
    // 1 周期 64 サンプルの正弦を 3 周期ぶん。disp=64 の表示窓は rising 交差に揃う。
    var sine: [192]f32 = undefined;
    for (&sine, 0..) |*s, i| s.* = @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 64.0);
    const start = findTriggerStart(&sine, 64);
    try testing.expect(start + 64 <= sine.len); // slice 安全
    try testing.expect(sine[start - 1] < 0.0 and sine[start] >= 0.0); // rising 交差に揃う
    // 単極（ゼロを跨がない）は交差無し → 最新窓（非ロック）へ降格。
    var uni: [192]f32 = undefined;
    for (&uni, 0..) |*s, i| s.* = 0.5 + 0.4 * @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 64.0);
    try testing.expectEqual(uni.len - 64, findTriggerStart(&uni, 64));
    // disp>=n はロック不能 → 0（全窓表示）。
    try testing.expectEqual(@as(usize, 0), findTriggerStart(sine[0..32], 32));
}

test "canvas: selectTapPorts — offscreen node (out0 outside viewport) is not tapped" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 4000, .y = 60 }, .n_in = 0, .n_out = 1 }, // 画面外
    };
    var out: [8]Handle = undefined;
    const n = selectTapPorts(.{ .zoom = 1.0 }, 800, 400, &nodes, null, null, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(Handle, 0), out[0]);
}

// ============================================================================
// selectTapPortsStable（TASK-170）: hover/selected の切替で既存 slot が無関係に巻き添えリセット
// されないことを固定する table test 群。
// ============================================================================

test "canvas: selectTapPortsStable —既存 slot は候補のままなら維持される（hover 切替の巻き添えなし）" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 1 },
    };
    const cam = Camera{ .zoom = 1.0 };
    // 前回: slot0=handle0（例えば以前 hover していたノード）。
    var prev = [_]?Handle{ 0, null, null };
    var out: [3]?Handle = undefined;
    // 今回 hover が handle2 に変わっても、handle0 は今も候補（isTapCandidate を満たす）なので
    // slot0 のまま維持され、handle2 は空き slot（slot1）へ新規追加される。
    selectTapPortsStable(cam, 800, 400, &nodes, null, 2, &prev, &out);
    try testing.expectEqual(@as(?Handle, 0), out[0]); // 維持
    try testing.expectEqual(@as(?Handle, 2), out[1]); // 新規（hover）
}

test "canvas: selectTapPortsStable — selected と hover が同時に新規候補でも両方表示される" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 1 },
    };
    const cam = Camera{ .zoom = 1.0 };
    var prev = [_]?Handle{ null, null, null };
    var out: [3]?Handle = undefined;
    selectTapPortsStable(cam, 800, 400, &nodes, 1, 2, &prev, &out);
    var has1 = false;
    var has2 = false;
    for (out) |m| {
        if (m) |h| {
            if (h == 1) has1 = true;
            if (h == 2) has2 = true;
        }
    }
    try testing.expect(has1);
    try testing.expect(has2);
}

test "canvas: selectTapPortsStable — 容量1で旧 hover を新 selected が置換する" {
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
    };
    const cam = Camera{ .zoom = 1.0 };
    // 前回: slot0 = handle0（旧 hover が占有していた想定）。容量1のテスト用バッファ。
    var prev = [_]?Handle{0};
    var out: [1]?Handle = undefined;
    // 今回 selected=handle1（新規）、hover=null（旧 hover は外れた）。
    selectTapPortsStable(cam, 800, 400, &nodes, 1, null, &prev, &out);
    try testing.expectEqual(@as(?Handle, 1), out[0]); // 旧 handle0 を置換して選択が入る
}

test "canvas: selectTapPortsStable — 満杯時に selected と hover を両方置換する（同一 slot 二重上書きの回帰防止）" {
    // 前回 slot0/slot1 を占有していた A・B は今回どちらも selected/hover ではない（=置換可能な
    // 最低優先度）。selected=C・hover=D が両方新規候補で、容量が2しかない（空き slot 0個）ため
    // 両方とも満杯時置換（step4）を通る。1つ目の置換で使った slot をすぐ2つ目の victim に選び直して
    // しまうと、2つ目の slot（B）が手つかずのまま残り、1つ目の置換結果（C）まで消えてしまう回帰が
    // あった（codex レビューで検出。`locked` による同一 slot 再選出防止で修正済み）。
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 }, // A（旧・非選択非hover）
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 }, // B（旧・非選択非hover）
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 1 }, // C（新・selected）
        .{ .handle = 3, .pos = .{ .x = 700, .y = 60 }, .n_in = 1, .n_out = 1 }, // D（新・hover）
    };
    const cam = Camera{ .zoom = 1.0 };
    var prev = [_]?Handle{ 0, 1 }; // 前回: slot0=A, slot1=B（両方今回も isTapCandidate を満たす）
    var out: [2]?Handle = undefined;
    selectTapPortsStable(cam, 800, 400, &nodes, 2, 3, &prev, &out);
    // A・B はどちらも selected/hover ではないため両方置換対象になり、C（selected）・D（hover）が
    // それぞれ別の slot へ正しく入る（二重上書きで C か D の片方が消えることがない）。
    var has_selected = false;
    var has_hover = false;
    for (out) |m| {
        if (m) |h| {
            if (h == 2) has_selected = true;
            if (h == 3) has_hover = true;
        }
    }
    try testing.expect(has_selected);
    try testing.expect(has_hover);
    // A・B（旧候補）はどちらも残っていない（両方置換された）。
    for (out) |m| {
        if (m) |h| {
            try testing.expect(h != 0);
            try testing.expect(h != 1);
        }
    }
}

test "canvas: selectTapPortsStable — selected/hover 無しで通常候補が cap を超えても既存 slot を置換しない（フレーム間ローテーション回帰防止）" {
    // v1 修正（同一 slot 二重上書き防止）だけでは、selected/hover が無い状態で候補数が cap を
    // 超えると「今フレーム A・B → C・D、次フレーム C・D → A・B …」という永久ローテーションが
    // 残っていた（codex 2回目レビューで検出）。通常候補（selected でも hover でもないもの）には
    // 置換権を与えず、空き slot が無ければそのフレームでは脱落させることで、既存 slot は
    // selected/hover が変化しない限り安定させる。
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 }, // A
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 }, // B
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 1 }, // C（通常候補。selected/hover ではない）
        .{ .handle = 3, .pos = .{ .x = 700, .y = 60 }, .n_in = 1, .n_out = 1 }, // D（同上）
    };
    const cam = Camera{ .zoom = 1.0 };
    var prev = [_]?Handle{ 0, 1 }; // 前回: slot0=A, slot1=B
    var out: [2]?Handle = undefined;
    // selected=null, hover=null。C・D は通常候補だが空き slot が無いので置換されない。
    selectTapPortsStable(cam, 800, 400, &nodes, null, null, &prev, &out);
    try testing.expectEqual(@as(?Handle, 0), out[0]);
    try testing.expectEqual(@as(?Handle, 1), out[1]);

    // 「次フレーム」を模して out をそのまま prev として再度呼んでも、結果は不変（ローテーションしない）。
    var prev2 = out;
    var out2: [2]?Handle = undefined;
    selectTapPortsStable(cam, 800, 400, &nodes, null, null, &prev2, &out2);
    try testing.expectEqual(@as(?Handle, 0), out2[0]);
    try testing.expectEqual(@as(?Handle, 1), out2[1]);
}

test "canvas: selectTapPortsStable と resolveTapPort 相当（handle 変化と port ID 変化の分離）" {
    // selectTapPortsStable 自体は port ID を解決しない（呼び出し側=main.zig の責務）ため、
    // ここでは「handle の安定化」と「実 port ID の変化検出」が別軸であることを、
    // slot の handle 遷移パターンで固定する（handle が変わるケース／変わらないケースの両方を
    // selectTapPortsStable のレベルで確認し、実 port ID 側の republish 判定は main.zig の
    // updateViz が new_ports[]!=tap_ports[] で行う契約を plan として明記済み）。
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 1, .n_out = 1 },
    };
    const cam = Camera{ .zoom = 1.0 };
    // ケース A: handle が変わらない（同じノードが選択され続ける）→ slot0 は同じ handle を維持。
    {
        var prev = [_]?Handle{0};
        var out: [1]?Handle = undefined;
        selectTapPortsStable(cam, 800, 400, &nodes, 0, null, &prev, &out);
        try testing.expectEqual(@as(?Handle, 0), out[0]);
    }
    // ケース B: handle が変わる（selected が別ノードへ移る）→ slot0 の handle は新しい方に変わる。
    {
        var prev = [_]?Handle{0};
        var out: [1]?Handle = undefined;
        selectTapPortsStable(cam, 800, 400, &nodes, 1, null, &prev, &out);
        try testing.expectEqual(@as(?Handle, 1), out[0]);
    }
}

test "canvas: viewportContains — fit layout has zero offscreen at representative zoom" {
    // 3 ノードを画面内に収まるよう配置。
    const nodes = [_]NodeGeom{
        .{ .handle = 0, .pos = .{ .x = 40, .y = 60 }, .n_in = 0, .n_out = 1 },
        .{ .handle = 1, .pos = .{ .x = 260, .y = 60 }, .n_in = 2, .n_out = 1 },
        .{ .handle = 2, .pos = .{ .x = 480, .y = 60 }, .n_in = 1, .n_out = 0 },
    };
    const edges = [_]Edge{
        .{ .src_handle = 0, .src_out = 0, .dst_handle = 1, .dst_in = 0 },
        .{ .src_handle = 1, .src_out = 0, .dst_handle = 2, .dst_in = 0 },
    };
    const vw: f32 = 800;
    const vh: f32 = 400;
    // zoom=1（pan 0）で全て収まる
    {
        const oc = viewportContains(.{ .zoom = 1.0 }, vw, vh, &nodes, &edges);
        try testing.expectEqual(@as(u32, 0), oc.node);
        try testing.expectEqual(@as(u32, 0), oc.port);
        try testing.expectEqual(@as(u32, 0), oc.cable);
    }
    // 見切れ検出: 大きく右へ pan するとノードが画面外へ → offscreen>0
    {
        const oc = viewportContains(.{ .pan = .{ .x = 700, .y = 0 }, .zoom = 1.0 }, vw, vh, &nodes, &edges);
        try testing.expect(oc.node > 0 or oc.port > 0 or oc.cable > 0);
    }
}

test "canvas: inspector param row は長いラベルでも value を content 幅内に収める" {
    const avail: i32 = 260; // 典型的な Inspector content 幅（PanelHost right extent − padding）
    const longest_labels = [_]i32{
        8 * "cutoff_mod_oct (oct)".len,
        8 * "level_mod_depth".len,
        8 * "mod_octaves (oct)".len,
    };

    for (longest_labels) |label_w| {
        const row = inspectorParamRowLayout(avail, label_w);
        try testing.expectEqual(INSPECTOR_PARAM_VALUE_W, row.value_w);
        try testing.expect(row.track_w >= INSPECTOR_PARAM_TRACK_MIN);
        try testing.expectEqual(avail, row.total());
        try testing.expect(row.label_w <= label_w);
    }

    const short = inspectorParamRowLayout(avail, 8 * "base_hz (Hz)".len);
    try testing.expectEqual(@as(i32, @intCast(8 * "base_hz (Hz)".len)), short.label_w);
    try testing.expectEqual(avail, short.total());
}
