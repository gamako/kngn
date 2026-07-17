// Context: 入力 + ID stack + interaction state + draw list + arena + font + layout を束ねる。
// フレームライフサイクル（beginFrame / endFrame）と widget behavior の起点。
//
// 本タスク時点の観測（TASK-131）: 以下は 2026-07-18 時点の現行契約である。
// TASK-130 等の並行変更で clip / hit-test 契約が変わる場合は capability matrix §16 と
// 相互参照で確認すること。
//
// ライフサイクル契約（21.2 案A「契約の番人」+ 21.4 layout）:
//   beginFrame(w,h): arena.reset → input/id_stack/state.beginFrame → per_id_state.beginFrame
//                    → draw_list.reset(w,h)
//                    → layout ツリーの暗黙 root を arena 上に生成（当フレームは未 measure/place）
//   widget 呼び出し: 前フレーム rect_cache で同期 hit-test（当フレーム構築中の layout rect は使わない）
//   endFrame():      measure → place → rect_cache.clearRetainingCapacity → updateRectCache
//                    → emitNode（draw cmd 発行）→ frame_active=false
//                    → focus cleanup → active cleanup → PerIdStateStore.trim（frame boundary のみ）
//                    hit-test は行わない。新 rect_cache はこの endFrame 完了後に次フレームから参照される。
//                    arena は触らない（契約の番人）。
//                    endFrame 後も draw_list / id_stack / state / レイアウトツリーは
//                    次 beginFrame まで valid。rect キャッシュ（gpa 所有）は次 endFrame まで valid。
//                    PerIdStateStore の LRU trim は endFrame 末尾のみ（widget 構築中は発火しない）。
//
// 同期 hit-test 契約（21.2/21.4 / TASK-131 で明文化）:
//   widget は呼び出し時に「前フレームの rect キャッシュ」（getNodeRect / rect_cache）で
//   buttonBehavior を呼び、ButtonResult を同期返却する。endFrame 後の再 hit-test はない。
//   layout 変更を伴う drag では描画は新 layout・hit-test は旧 layout となり 1 フレーム遅延する
//   （観測された現行契約。静的 layout では不可視）。
//
// clip / hit-test 可視契約（TASK-130）:
//   - cached `clip` は祖先の clip_children を反映した effective clip（描画 pushClip と同じ境界）。
//   - ノード自身の clip_children は自身ではなく子に適用される。
//   - clip_children=false の overflow は描画・hit-test ともに許可（親 rect 外でも ancestor clip 内なら可）。
//   - clip_children=true の範囲外は描画・hit-test ともに不可。
//   - zero-size effective clip は不可視かつ hit-test 不可。
//   - 判定は pointHitsVisible(rect, clip, p)。active drag capture は clip 外でも維持し、
//     release 時の click だけ可視領域内で成立させる。
//
// draw 発行順: フレーム中に caller が直接 draw_list へ積んだ cmd の後に layout 分が
// append される（= レイアウト UI が上に描かれる）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("geom.zig");
const color_mod = @import("color.zig");
const draw = @import("draw.zig");
const font_mod = @import("font.zig");
const id_mod = @import("id.zig");
const input_mod = @import("input.zig");
const state_mod = @import("state.zig");
const layout = @import("layout.zig");
const style_mod = @import("style.zig");
// widgets.zig とは相互 import（widgets は *Context を取る。Zig の import 循環は合法）。
// Context 構造体内の decl alias で `ctx.button(...)` メソッド構文を提供する。
const widgets = @import("widgets.zig");
// popup.zig も同じ相互 import パターン（TASK-79.1）。
const popup_mod = @import("popup.zig");
const stepgrid_mod = @import("stepgrid.zig");

pub const Rect = geom.Rect;
pub const Vec2 = geom.Vec2;
pub const Vec2f = input_mod.Vec2f;
pub const Color = color_mod.Color;
pub const Id = id_mod.Id;
pub const IdStack = id_mod.IdStack;
pub const Input = input_mod.Input;
pub const InputEvent = input_mod.InputEvent;
pub const InteractionState = state_mod.InteractionState;
pub const DrawList = draw.DrawList;
pub const BitmapFont = font_mod.BitmapFont;
pub const Font = font_mod.Font;
pub const BoxConfig = layout.BoxConfig;
pub const Style = style_mod.Style;
pub const PerIdState = state_mod.PerIdState;
// ポップアップ/コンテキストメニュー（TASK-79.1）。実装・doc comment は popup.zig。
pub const PopupState = popup_mod.PopupState;
pub const PopupItem = popup_mod.PopupItem;
pub const PopupResult = popup_mod.PopupResult;
pub const stepgrid = stepgrid_mod;

/// rect キャッシュのエントリ。
/// `clip` は祖先の `clip_children` を intersect 済みの effective clip（描画の pushClip 境界と一致）。
/// ノード自身の `clip_children` はここには入らず、子へ渡す child_clip にだけ効く。
/// `buttonBehavior` / TextInput / SelectableLabel は `pointHitsVisible(rect, clip, p)` で共有判定する。
pub const CachedRect = struct { rect: Rect, clip: Rect, measured_w: i32 = 0, measured_h: i32 = 0 };

/// scroll area の begin→end 間で持ち越す内部状態（TASK-46）。begin で前フレーム cache から
/// 算出し scroll_stack に push、end で pop してスクロールバーを構築する。
/// TASK-126: wheel は begin では適用せず end（LIFO＝内側優先）で消費・伝播する。
pub const ScrollState = struct {
    bar_thickness: i32,
    track_col: Color,
    thumb_col: Color,
    thumb_hot: Color,
    thumb_active: Color,
    need_v: bool,
    need_h: bool,
    v_off: i32,
    v_len: i32,
    h_off: i32,
    h_len: i32,
    vthumb_id: Id,
    hthumb_id: Id,
    /// caller 所有の scroll 量（wheel 適用先）
    scroll: *Vec2f = undefined,
    /// 前フレーム viewport rect（ヒット判定用。未確定時は null）
    viewport_rect: ?Rect = null,
    max_x: i32 = 0,
    max_y: i32 = 0,
    wheel_px: f32 = 32.0,
    vp_w: i32 = 0,
    vp_h: i32 = 0,
    /// 当フレームの viewport layout node（wheel 後に scroll_x/y を反映）
    viewport_node: ?*layout.Node = null,
};

pub const Context = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    input: Input,
    id_stack: IdStack,
    state: InteractionState = .{},
    per_id_state: state_mod.PerIdStateStore = .{},
    draw_list: DrawList,
    font: Font,
    screen_w: u32 = 0,
    screen_h: u32 = 0,
    frame_active: bool = false,
    frame_index: u64 = 0,
    now_s: f64 = 0,
    /// レイアウトツリーの暗黙 root（beginFrame で arena 上に生成）
    layout_root: ?*layout.Node = null,
    /// beginBox / endBox のカーソル（現在の親）
    layout_current: ?*layout.Node = null,
    /// 明示 ID（cfg.id != 0）ノードの id → {rect, clip}。gpa 所有でフレームを跨いで生存し、
    /// endFrame でのみ更新される（フレーム前半は前フレーム値 = 同期 hit-test 契約）。
    rect_cache: std.AutoHashMapUnmanaged(Id, CachedRect) = .empty,
    /// scroll area の begin→end 間状態スタック（TASK-46。ネスト対応）。arena 不使用（フレーム内 push/pop）。
    scroll_stack: std.ArrayList(ScrollState) = .empty,
    /// TASK-126: フレーム内の未消費 wheel delta（最初の endScrollArea で input.scroll_delta から seed）。
    /// 各 ScrollArea は実移動できた分だけ消費し、端到達の残量は外側へ伝播する。
    wheel_remaining: Vec2f = .{},
    wheel_remaining_seeded: bool = false,
    /// widget 共通スタイル（TASK-21.5）。caller が直接書き換えてよい（push/pop なし）。
    style: Style,
    /// ポップアップ/コンテキストメニューの開閉状態（TASK-79.1）。MVP は同時に1つのみ。
    /// null = 閉じている。非 null 時は buttonBehavior が背後 widget の hover/active 取得を
    /// 抑止する（モーダル吸収。詳細は buttonBehavior の doc comment / popup.zig 参照）。
    popup_state: ?PopupState = null,
    /// IME composition（preedit）の frame-local 状態。beginFrame で空に戻り、
    /// アプリが widget 呼び出し前に setComposition で毎フレーム設定する（TASK-113.3）。
    composition: input_mod.CompositionState = .{},

    // ── widget 層（TASK-21.5）。実装は widgets.zig（メソッド構文用の alias） ──
    pub const button = widgets.button;
    pub const buttonEx = widgets.buttonEx;
    pub const buttonId = widgets.buttonId;
    pub const colorSwatch = widgets.colorSwatch;
    pub const colorSwatchEx = widgets.colorSwatchEx;
    pub const colorSwatchId = widgets.colorSwatchId;
    // Slider（TASK-21.9）
    pub const sliderI32 = widgets.sliderI32;
    pub const sliderI32Id = widgets.sliderI32Id;
    pub const sliderF32 = widgets.sliderF32;
    pub const sliderF32Id = widgets.sliderF32Id;
    // HSV カラーピッカー（TASK-21.14）
    pub const svSquare = widgets.svSquare;
    pub const svSquareId = widgets.svSquareId;
    pub const hueBar = widgets.hueBar;
    pub const hueBarId = widgets.hueBarId;

    pub const imageBox = widgets.imageBox;
    // Checkbox / Toggle(switch) / Radio（bool トグル系。TASK-48）
    pub const checkbox = widgets.checkbox;
    pub const checkboxId = widgets.checkboxId;
    pub const toggle = widgets.toggle;
    pub const toggleId = widgets.toggleId;
    pub const radio = widgets.radio;
    pub const radioId = widgets.radioId;
    // read-only text selection（TASK-113.1）
    pub const selectableLabel = widgets.selectableLabel;
    pub const selectableLabelId = widgets.selectableLabelId;
    // single-line editable text（TASK-113.2）
    pub const textInputId = widgets.textInputId;
    // Splitter（ペイン境界。TASK-41）
    pub const splitter = widgets.splitter;
    // 縦横スクロール領域（TASK-46）
    pub const beginScrollArea = widgets.beginScrollArea;
    pub const endScrollArea = widgets.endScrollArea;
    // ポップアップ/コンテキストメニュー（TASK-79.1）。実装・契約は popup.zig 参照。
    pub const openPopup = popup_mod.openPopup;
    pub const closePopup = popup_mod.closePopup;
    pub const hasOpenPopup = popup_mod.hasOpenPopup;
    pub const isPopupOpen = popup_mod.isPopupOpen;
    pub const popupMenu = popup_mod.popupMenu;

    pub fn init(gpa: Allocator, font: Font) Context {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .input = Input.init(gpa),
            .id_stack = IdStack.init(gpa),
            .draw_list = DrawList.init(gpa),
            .font = font,
            .style = style_mod.defaultStyle(),
        };
    }

    pub fn deinit(self: *Context) void {
        self.rect_cache.deinit(self.gpa);
        self.per_id_state.deinit(self.gpa);
        self.scroll_stack.deinit(self.gpa);
        self.draw_list.deinit();
        self.id_stack.deinit();
        self.input.deinit();
        self.arena.deinit();
    }

    /// arena allocator（cmd の text/image payload 用）。次フレーム beginFrame で reset される。
    pub fn allocator(self: *Context) Allocator {
        return self.arena.allocator();
    }

    pub fn beginFrame(self: *Context, screen_w: u32, screen_h: u32) void {
        const frame_time = @as(f64, @floatFromInt(self.frame_index)) / 60.0;
        self.frame_index += 1;
        self.beginFrameAtInternal(screen_w, screen_h, frame_time);
    }

    /// 実時間または harness 仮想時刻を明示してフレームを開始する。
    pub fn beginFrameAt(self: *Context, screen_w: u32, screen_h: u32, now_s: f64) void {
        self.beginFrameAtInternal(screen_w, screen_h, now_s);
    }

    fn beginFrameAtInternal(self: *Context, screen_w: u32, screen_h: u32, now_s: f64) void {
        std.debug.assert(!self.frame_active);
        self.frame_active = true;
        self.screen_w = screen_w;
        self.screen_h = screen_h;
        self.now_s = now_s;
        _ = self.arena.reset(.retain_capacity); // 前フレームの payload とレイアウトツリーをここで解放
        self.input.beginFrame();
        self.id_stack.clear();
        self.state.beginFrame();
        self.per_id_state.beginFrame();
        self.composition = .{};
        self.wheel_remaining = .{};
        self.wheel_remaining_seeded = false;
        self.draw_list.reset(screen_w, screen_h);
        // レイアウトツリーの暗黙 root（caller は気にせず beginBox から使う）
        const root = self.allocator().create(layout.Node) catch @panic("Context.beginFrame: OOM");
        root.* = .{ .cfg = .{
            .direction = .column,
            .width = .{ .fixed = @intCast(screen_w) },
            .height = .{ .fixed = @intCast(screen_h) },
        } };
        self.layout_root = root;
        self.layout_current = root;
    }

    pub fn endFrame(self: *Context) void {
        std.debug.assert(self.frame_active);
        const root = self.layout_root.?;
        // beginBox / endBox の対応漏れ検出
        std.debug.assert(self.layout_current == root);
        // レイアウト API 未使用フレーム（root が空）は layout / 発行 / キャッシュ更新を
        // 全てスキップ: 手動 DrawList 運用（example 08/09）と互換。rect_cache は前回値のまま。
        if (root.first_child != null) {
            layout.measure(root, self.font);
            const screen_rect = Rect{ .x = 0, .y = 0, .w = self.screen_w, .h = self.screen_h };
            layout.place(root, screen_rect);
            self.rect_cache.clearRetainingCapacity();
            self.updateRectCache(root, screen_rect);
            self.emitNode(root);
        }
        self.frame_active = false;
        // TextInput 等の focus widget が当フレームの外側クリックを claim しなかった
        // 場合だけ keyboard focus を解除する。mouse down の無いフレームは維持する。
        if (self.input.mouse_pressed.left and !self.state.focus_claimed_this_frame) {
            self.state.focused_id = 0;
        }
        // active widget が当フレーム未評価（非表示・分岐で未描画）かつ既にボタンが
        // 離されているなら、active_id の張り付き（wantsMouse の引きずり）を防ぐため解除する。
        if (self.state.active_id != 0 and !self.state.active_submitted and !self.input.mouse_buttons.left) {
            self.state.active_id = 0;
        }
        // PerIdStateStore LRU trim（TASK-127）。frame boundary のみ。表示中・操作中 ID を保護。
        self.per_id_state.trim(.{
            .active_id = self.state.active_id,
            .focused_id = self.state.focused_id,
            .hot_id = self.state.hot_id,
            .next_hot_id = self.state.next_hot_id,
        });
        // arena も draw_list もここでは reset しない（契約の番人）。
    }

    pub fn pushEvent(self: *Context, ev: InputEvent) void {
        std.debug.assert(self.frame_active);
        self.input.pushEvent(ev);
    }

    /// IME composition 状態を frame-local に設定する。`text` は caller 所有の借用 slice
    /// （endFrame の描画まで有効）。platform 型は受け取らない（ADR-007）。
    pub fn setComposition(self: *Context, state: input_mod.CompositionState) void {
        std.debug.assert(self.frame_active);
        self.composition = state;
    }

    /// popup 表示中（TASK-79.1）は背後 widget の buttonBehavior が hover を一切立てなくなり
    /// this_frame_hovered_any も false のままになるため、popup_state を明示的に OR する
    /// （「モーダル吸収中は wantsMouse()==true 相当」という契約を保つ。app 側の canvas 等
    /// 入力ゲートはこれを使って背後入力を抑止できる）。
    pub fn wantsMouse(self: *const Context) bool {
        return self.state.active_id != 0 or self.state.this_frame_hovered_any or self.popup_state != null;
    }

    pub fn wantsKeyboard(self: *const Context) bool {
        return self.state.focused_id != 0;
    }

    /// widget の mouse down 時にキーボード focus を取得する。ID ごとの selection state
    /// は別 store に残るので、focus の切替で選択内容は消えない。
    pub fn claimFocus(self: *Context, id: Id) bool {
        std.debug.assert(self.frame_active);
        if (id == 0) return false;
        self.state.focused_id = id;
        self.state.focus_claimed_this_frame = true;
        return true;
    }

    /// 現在の keyboard focus を解除する。実際の外側クリック解除は endFrame で、当フレーム
    /// にどの widget も claim しなかった場合に自動で行う。
    pub fn releaseFocus(self: *Context) void {
        std.debug.assert(self.frame_active);
        self.state.focused_id = 0;
    }

    pub fn focusedId(self: *const Context) Id {
        return self.state.focused_id;
    }

    pub fn now(self: *const Context) f64 {
        return self.now_s;
    }

    pub fn perIdState(self: *Context, id: Id) *state_mod.PerIdState {
        std.debug.assert(id != 0);
        return self.per_id_state.getOrPut(self.gpa, id);
    }

    // ──────────────────────────────────────────────
    // レイアウトツリー構築 API（TASK-21.4）
    // ──────────────────────────────────────────────

    /// box を開く。endBox と必ず対にする。
    /// cfg.id == 0 なら自動採番（外部参照不可・rect キャッシュ非登録）。
    /// 明示 ID（IdStack 等で生成した非 0 値）を渡すと endFrame 後に
    /// getNodeRect / rect_cache（hit-test 用）の対象になる。
    pub fn beginBox(self: *Context, cfg: BoxConfig) void {
        std.debug.assert(self.frame_active);
        layout.assertSizingValid(cfg.width);
        layout.assertSizingValid(cfg.height);
        const parent = self.layout_current.?;
        const node = self.allocator().create(layout.Node) catch @panic("Context.beginBox: OOM");
        node.* = .{
            .id = if (cfg.id != 0) cfg.id else id_mod.hashInt(parent.id, parent.child_count),
            .cfg = cfg,
        };
        layout.appendChild(parent, node);
        self.layout_current = node;
    }

    pub fn endBox(self: *Context) void {
        std.debug.assert(self.frame_active);
        const cur = self.layout_current.?;
        // root を pop しようとした = beginBox / endBox の不均衡
        std.debug.assert(cur.parent != null);
        self.layout_current = cur.parent;
    }

    /// text leaf（既定色 = style.text）。str は arena に複製されるので caller バッファの
    /// 寿命に依存しない。
    pub fn label(self: *Context, str: []const u8) void {
        self.labelEx(str, self.style.text);
    }

    pub fn labelEx(self: *Context, str: []const u8, col: Color) void {
        std.debug.assert(self.frame_active);
        const dup = self.allocator().dupe(u8, str) catch @panic("Context.labelEx: OOM");
        self.addLeaf(.{ .text = .{ .str = dup, .color = col, .font = null } });
    }

    /// custom leaf。size が measure 結果として使われ、draw_fn は endFrame の layout 確定後に
    /// 最終 rect 付きで呼ばれる（DrawList の OOM は callback 側で catch @panic する）。
    pub fn custom(self: *Context, size: Vec2, draw_fn: layout.CustomDrawFn, ctx_ptr: *anyopaque) void {
        std.debug.assert(self.frame_active);
        self.addLeaf(.{ .custom = .{ .measured = size, .draw_fn = draw_fn, .ctx = ctx_ptr } });
    }

    /// 明示 ID（cfg.id != 0 で登録されたノード）の最終配置 rect。
    /// 前フレーム endFrame で確定した値を返す（beginFrame 直後のフレーム前半も更新されない）。
    /// 次の値は当フレーム endFrame の updateRectCache 完了後に初めて利用可能になる。
    /// 初回フレーム（キャッシュ未生成）・自動採番ノード（beginBox cfg.id==0）・未知 ID・0 は null。
    pub fn getNodeRect(self: *const Context, id: Id) ?Rect {
        if (id == 0) return null;
        const entry = self.rect_cache.get(id) orelse return null;
        return entry.rect;
    }

    /// 明示 ID widget の前フレーム {rect, clip, measured}。
    /// clip は祖先 clip_children を intersect した有効クリップ（buttonBehavior にそのまま渡す）。
    /// getNodeRect と同じく前フレーム値。初回フレーム・自動 ID・未知 ID・0 は null。
    pub fn getNodeCachedRect(self: *const Context, id: Id) ?CachedRect {
        if (id == 0) return null;
        return self.rect_cache.get(id);
    }

    /// 明示 ID ノードの前フレーム measured サイズ（layout.measure の自然サイズ）。
    /// scroll 量の clamp 等に使う。getNodeRect と同じ前フレーム同期契約。
    /// 初回フレーム・自動 ID・未知 ID・0 は null。
    pub fn getNodeMeasured(self: *const Context, id: Id) ?Vec2 {
        if (id == 0) return null;
        const entry = self.rect_cache.get(id) orelse return null;
        return .{ .x = entry.measured_w, .y = entry.measured_h };
    }

    fn addLeaf(self: *Context, leaf: layout.LeafKind) void {
        const parent = self.layout_current.?;
        const node = self.allocator().create(layout.Node) catch @panic("Context.addLeaf: OOM");
        node.* = .{
            .id = id_mod.hashInt(parent.id, parent.child_count),
            .leaf = leaf,
        };
        layout.appendChild(parent, node);
    }

    /// 明示 ID ノードの {rect, clip, measured} を登録（行きがけ DFS）。
    /// endFrame の measure/place 完了後にのみ呼ばれ、当フレーム widget 呼び出し中の hit-test には使われない。
    ///
    /// `clip` 引数 = 祖先由来の effective clip（このノード自身の描画・hit-test に使う）。
    /// 子へ渡す clip:
    ///   - `clip_children=true`  → `intersect(clip, node.rect)`（親 rect 外は不可視・hit 不可）
    ///   - `clip_children=false` → `clip` のまま（overflow 描画・hit を許可。zero-size 親でも
    ///     子は ancestor clip 内なら hit 可）
    /// `emitNode` の pushClip 境界と同じ定義（cached clip ↔ draw clip の対応）。
    /// measured_w/h は layout.measure の結果（scroll clamp 等に使う自然サイズ）。
    /// 同一フレーム内で明示 ID が重複した場合は Debug assert で契約違反（Release では最後勝ち上書きだが
    /// 重複 ID は使わないことを前提とする）。
    fn updateRectCache(self: *Context, node: *const layout.Node, clip: Rect) void {
        if (node.cfg.id != 0) {
            const gop = self.rect_cache.getOrPut(self.gpa, node.cfg.id) catch
                @panic("Context.endFrame: OOM");
            // 同一フレーム内の明示 ID 重複は契約違反（最後勝ちで上書きされ hit-test が壊れる）
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = .{ .rect = node.rect, .clip = clip, .measured_w = node.measured_w, .measured_h = node.measured_h };
        }
        const child_clip = if (node.cfg.clip_children) Rect.intersect(clip, node.rect) else clip;
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) self.updateRectCache(c, child_clip);
    }

    /// draw cmd 発行（行きがけ DFS）: bg → (clip_children なら pushClip(node.rect)) → 子 / leaf →
    /// popClip → border。
    /// `pushClip(node.rect)` は draw_list が祖先 clip と intersect するため、結果の焼き込み clip は
    /// `updateRectCache` が子へ渡す `child_clip = intersect(ancestor, node.rect)` と同じ境界になる。
    /// border は popClip 後（= 祖先 clip）で発行し、子の上に枠が乗る。
    fn emitNode(self: *Context, node: *const layout.Node) void {
        if (node.leaf) |leaf| {
            switch (leaf) {
                .text => |t| self.draw_list.textEx(
                    .{ .x = node.rect.x, .y = node.rect.y },
                    t.str,
                    t.color,
                    t.font,
                ) catch @panic("Context.endFrame: OOM"),
                .custom => |c| c.draw_fn(c.ctx, &self.draw_list, node.rect),
            }
            return;
        }
        if (node.cfg.bg) |bg| {
            self.draw_list.rectFilled(node.rect, bg) catch @panic("Context.endFrame: OOM");
        }
        if (node.cfg.clip_children) {
            self.draw_list.pushClip(node.rect) catch @panic("Context.endFrame: OOM");
        }
        var it = node.first_child;
        while (it) |c| : (it = c.next_sibling) self.emitNode(c);
        if (node.cfg.clip_children) self.draw_list.popClip();
        if (node.cfg.border) |b| {
            self.draw_list.rectOutline(node.rect, b.color, b.thickness) catch
                @panic("Context.endFrame: OOM");
        }
    }
};

pub const ButtonResult = struct {
    clicked: bool = false,
    hovered: bool = false,
    held: bool = false,
};

/// 点が widget の可視 hit 領域内か（`rect ∩ clip` に含まれることと等価）。
///
/// - effective clip の外側は描画と同様に hit-test 不可
/// - zero-size rect / clip（w=0 or h=0）は常に false → hover / press acquire / click なし
/// - `clip_children=false` の overflow 子は ancestor clip を clip に載せる（親 rect 外でも可）
/// - ScrollArea 等の部分見切れは viewport clip 内の部分だけ true
///
/// buttonBehavior・TextInput・SelectableLabel が共有する単一の正。
pub fn pointHitsVisible(rect: Rect, clip: Rect, p: Vec2) bool {
    return rect.contains(p) and clip.contains(p);
}

/// Dear ImGui 流の同期 hit-test + button state machine（Description 修正版 v2）。
/// caller が渡した rect / clip に対して当フレームの mouse 状態をその場で評価し、
/// ButtonResult を同期返却する。endFrame 後の再 hit-test や layout 確定後の遡及評価はない。
/// rect / clip は通常 widgets の behaviorFromCache が前フレーム rect_cache から供給する。
///
/// active drag capture: press で active を取得したあと、clip/rect 外へドラッグしても
/// active は奪わない。release 時の click は `pointHitsVisible`（= 可視領域内）のときだけ成立。
/// TextInput 範囲選択・slider・ScrollArea thumb のドラッグを壊さないための契約。
pub fn buttonBehavior(ctx: *Context, id: Id, rect: Rect, clip: Rect) ButtonResult {
    std.debug.assert(ctx.frame_active);
    // モーダル吸収（TASK-79.1）: popup 表示中は背後 widget の hover/hot/active 取得を
    // 一切行わない。popup.openPopup() が展開時に active_id/hot_id/next_hot_id を必ず 0 に
    // リセットする不変条件があるため、「既に active な widget だけ例外的に通す」特例は
    // 不要（このガード自体が新規 acquire を防ぐので、popup 表示中に active_id が非 0 に
    // なることは構造的に起こらない）。popup 自体は buttonBehavior を経由しない手動
    // hit-test（popup.zig の hitTestItem）で描画するため、このガードの影響を受けない。
    if (ctx.popup_state != null) return .{};

    const mp = ctx.input.mouse_pos;
    const hovered_now = pointHitsVisible(rect, clip, mp);
    var result: ButtonResult = .{};
    result.hovered = hovered_now;

    // 1. hover 反映（active が他 widget に乗ってる時は奪わない）
    if (hovered_now) {
        if (ctx.state.active_id == 0 or ctx.state.active_id == id) {
            ctx.state.next_hot_id = id; // 描画順で最後勝ち
        }
        ctx.state.this_frame_hovered_any = true;
    }

    // 2. acquire active。press 起点（down した瞬間の座標 = mouse_pressed_pos）が
    //    可視領域内のときのみ。フレーム最終位置 mouse_pos ではなく起点を使うことで、
    //    同フレーム内の「外で down → 内へ move」での誤取得を防ぐ。
    if (ctx.state.active_id == 0 and ctx.input.mouse_pressed.left) {
        if (pointHitsVisible(rect, clip, ctx.input.mouse_pressed_pos)) {
            ctx.state.active_id = id;
        }
    }

    // 3. hold / release。active 中は clip 外ドラッグでも held を維持（drag capture）。
    //    release edge で active 解除 + up 時に可視 hover 内なら click 確定。
    if (ctx.state.active_id == id) {
        result.held = true;
        ctx.state.active_submitted = true; // 張り付き防止: 当フレームに評価された印
        if (ctx.input.mouse_released.left) {
            if (hovered_now) result.clicked = true;
            ctx.state.active_id = 0;
        }
    }
    return result;
}

// ============================================================
// Tests
// ============================================================

const full_clip = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
const btn_rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

test "buttonBehavior: hover 中の down→up（別フレーム）で clicked が 1 フレームのみ true" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // フレーム1: hover + down → held, not clicked
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    var r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(!r.clicked);
    try std.testing.expect(r.held);
    ctx.endFrame();

    // フレーム2: hover 内で up → clicked
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(r.clicked);
    ctx.endFrame();

    // フレーム3: clicked は false に戻る
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    r = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(!r.clicked);
    ctx.endFrame();
}

test "buttonBehavior: 同一フレームで down→up 完結でも clicked を返す" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(r.clicked);
    ctx.endFrame();
}

test "buttonBehavior: clip 外なら hover/click しない" {
    var ctx = testCtx();
    defer ctx.deinit();
    const narrow_clip = Rect{ .x = 0, .y = 0, .w = 5, .h = 5 };

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } }); // rect 内だが clip 外
    const r = buttonBehavior(&ctx, 1, btn_rect, narrow_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endFrame();
}

// ── TASK-130: zero-size / overflow / partial clip / drag capture ──

test "pointHitsVisible: zero-size clip は常に false" {
    const rect = Rect{ .x = 0, .y = 0, .w = 24, .h = 24 };
    const zero_w = Rect{ .x = 0, .y = 0, .w = 0, .h = 100 };
    const zero_h = Rect{ .x = 0, .y = 0, .w = 100, .h = 0 };
    try std.testing.expect(!pointHitsVisible(rect, zero_w, .{ .x = 5, .y = 5 }));
    try std.testing.expect(!pointHitsVisible(rect, zero_h, .{ .x = 5, .y = 5 }));
    try std.testing.expect(!pointHitsVisible(zero_w, full_clip, .{ .x = 0, .y = 5 }));
}

test "pointHitsVisible: rect∩clip の部分見切れだけ true" {
    // ScrollArea 相当: widget rect は [0,100)×[0,40)、viewport clip は [0,100)×[0,20)
    const rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 40 };
    const vp_clip = Rect{ .x = 0, .y = 0, .w = 100, .h = 20 };
    try std.testing.expect(pointHitsVisible(rect, vp_clip, .{ .x = 10, .y = 10 })); // 可視
    try std.testing.expect(!pointHitsVisible(rect, vp_clip, .{ .x = 10, .y = 30 })); // rect 内だが clip 外
    try std.testing.expect(!pointHitsVisible(rect, vp_clip, .{ .x = 10, .y = 50 })); // 両方外
}

test "pointHitsVisible: overflow 許可（clip_children=false）= ancestor clip 内なら親 rect 外でも可" {
    // 親は zero-size で clip を作らない → 子 clip = screen。子 rect は 24x24 で hit 可。
    const child = Rect{ .x = 4, .y = 508, .w = 24, .h = 24 };
    try std.testing.expect(pointHitsVisible(child, full_clip, .{ .x = 10, .y = 520 }));
    // ancestor clip が狭いと overflow 子もその外は不可
    const narrow = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expect(!pointHitsVisible(child, narrow, .{ .x = 10, .y = 520 }));
}

test "buttonBehavior: zero-size clip 内では hover/press/click しない" {
    var ctx = testCtx();
    defer ctx.deinit();
    const zero_clip = Rect{ .x = 0, .y = 0, .w = 0, .h = 50 };

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 1, btn_rect, zero_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(!r.held);
    try std.testing.expect(!r.clicked);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    ctx.endFrame();
}

test "buttonBehavior: 部分見切れ clip は可視部分だけ hover/click" {
    var ctx = testCtx();
    defer ctx.deinit();
    const rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 40 };
    const vp_clip = Rect{ .x = 0, .y = 0, .w = 100, .h = 20 };

    // 可視部分で click 成立
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    try std.testing.expect(buttonBehavior(&ctx, 1, rect, vp_clip).clicked);
    ctx.endFrame();

    // rect 内だが clip 外では press 不可
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 30, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 30, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 2, rect, vp_clip);
    try std.testing.expect(!r.hovered);
    try std.testing.expect(!r.held);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    ctx.endFrame();
}

test "buttonBehavior: active drag は clip 外でも capture 維持・clip 外 release は click しない" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;
    const rect = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const clip = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };

    // frame1: 可視内 press → active
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    try std.testing.expect(buttonBehavior(&ctx, id, rect, clip).held);
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // frame2: clip 外へ drag → held 維持（capture を失わない）
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } });
    const mid = buttonBehavior(&ctx, id, rect, clip);
    try std.testing.expect(mid.held);
    try std.testing.expect(!mid.hovered);
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // frame3: clip 外で release → click なし・active 解除
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 200, .y = 200, .button = 0, .modifiers = 0 } });
    const up = buttonBehavior(&ctx, id, rect, clip);
    try std.testing.expect(!up.clicked);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    ctx.endFrame();
}

test "rect_cache: clip_children=false の zero-size 親でも子 clip は ancestor のまま" {
    var ctx = testCtx();
    defer ctx.deinit();
    const parent_id: Id = 10;
    const child_id: Id = 11;

    ctx.beginFrame(800, 600);
    // zero-size 親（clip_children 既定 false）→ 子は overflow 配置可能
    ctx.beginBox(.{ .id = parent_id, .width = .{ .fixed = 0 }, .height = .{ .fixed = 0 } });
    ctx.beginBox(.{ .id = child_id, .width = .{ .fixed = 24 }, .height = .{ .fixed = 24 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const parent = ctx.rect_cache.get(parent_id).?;
    const child = ctx.rect_cache.get(child_id).?;
    try std.testing.expectEqual(@as(u32, 0), parent.rect.w);
    try std.testing.expectEqual(@as(u32, 0), parent.rect.h);
    try std.testing.expectEqual(@as(u32, 24), child.rect.w);
    try std.testing.expectEqual(@as(u32, 24), child.rect.h);
    // 子の clip は screen（親 zero と intersect されていない）
    try std.testing.expectEqual(@as(u32, 800), child.clip.w);
    try std.testing.expectEqual(@as(u32, 600), child.clip.h);
    try std.testing.expect(pointHitsVisible(child.rect, child.clip, .{
        .x = child.rect.x + 1,
        .y = child.rect.y + 1,
    }));
}

test "rect_cache: clip_children=true の zero-size 親は子 clip が空" {
    var ctx = testCtx();
    defer ctx.deinit();
    const parent_id: Id = 20;
    const child_id: Id = 21;

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{
        .id = parent_id,
        .width = .{ .fixed = 0 },
        .height = .{ .fixed = 0 },
        .clip_children = true,
    });
    ctx.beginBox(.{ .id = child_id, .width = .{ .fixed = 24 }, .height = .{ .fixed = 24 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const child = ctx.rect_cache.get(child_id).?;
    try std.testing.expect(child.clip.isEmpty() or child.clip.w == 0 or child.clip.h == 0);
    try std.testing.expect(!pointHitsVisible(child.rect, child.clip, .{
        .x = child.rect.x + 1,
        .y = child.rect.y + 1,
    }));
}

test "rect_cache: clip_children=true の部分見切れ子は viewport 交差 clip" {
    var ctx = testCtx();
    defer ctx.deinit();
    const vp_id: Id = 30;
    const item_id: Id = 31;

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{
        .id = vp_id,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 20 },
        .clip_children = true,
    });
    // 親より高い子（部分見切れ）
    ctx.beginBox(.{ .id = item_id, .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    ctx.endBox();
    ctx.endBox();
    ctx.endFrame();

    const item = ctx.rect_cache.get(item_id).?;
    try std.testing.expectEqual(@as(u32, 40), item.rect.h);
    // child clip = intersect(screen, parent.rect) → h=20
    try std.testing.expectEqual(@as(u32, 20), item.clip.h);
    try std.testing.expect(pointHitsVisible(item.rect, item.clip, .{ .x = item.rect.x + 1, .y = item.rect.y + 1 }));
    try std.testing.expect(!pointHitsVisible(item.rect, item.clip, .{ .x = item.rect.x + 1, .y = item.rect.y + 30 }));
}

test "Context.wantsMouse: hover 開始フレームから true" {
    var ctx = testCtx();
    defer ctx.deinit();

    // hover 外
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endFrame();

    // hover 内（開始フレーム）
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(ctx.wantsMouse());
    ctx.endFrame();
}

test "Context.wantsMouse: active 解除後も hover 継続中は true" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // フレーム1: hover + down → active 取得
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expect(ctx.wantsMouse());
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // フレーム2: hover 内で up → active 解除されるが hover 継続 → wantsMouse true
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    try std.testing.expect(ctx.wantsMouse());
    ctx.endFrame();
}

test "Context: beginFrameAt の時刻、focus claim、ID state persistence" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrameAt(320, 200, 12.5);
    try std.testing.expectEqual(@as(f64, 12.5), ctx.now());
    try std.testing.expect(ctx.claimFocus(77));
    ctx.perIdState(77).selection = .{ .anchor = 2, .extent = 5 };
    ctx.endFrame();

    ctx.beginFrameAt(320, 200, 13.0);
    try std.testing.expectEqual(@as(Id, 77), ctx.state.focused_id);
    try std.testing.expectEqual(@as(usize, 2), ctx.perIdState(77).selection.anchor);
    try std.testing.expectEqual(@as(usize, 5), ctx.perIdState(77).selection.extent);
    ctx.endFrame();
}

test "Context: endFrame trim は focused 非表示 state を保持する" {
    var ctx = testCtx();
    defer ctx.deinit();
    ctx.per_id_state.max_entries = 2;
    ctx.per_id_state.trim_to = 1;

    ctx.beginFrame(320, 200);
    try std.testing.expect(ctx.claimFocus(50));
    ctx.perIdState(50).caret = 9;
    _ = ctx.perIdState(51);
    ctx.endFrame();

    // frame 2: focus 維持、50 は非表示、新規 ID で上限超過
    ctx.beginFrame(320, 200);
    try std.testing.expectEqual(@as(Id, 50), ctx.state.focused_id);
    _ = ctx.perIdState(60);
    _ = ctx.perIdState(61);
    _ = ctx.perIdState(62);
    ctx.endFrame();

    try std.testing.expect(ctx.per_id_state.get(50) != null);
    try std.testing.expectEqual(@as(usize, 9), ctx.per_id_state.get(50).?.caret);
    // 非保護の古い 51 は消える
    try std.testing.expect(ctx.per_id_state.get(51) == null);
}

test "Context: 上限未満の非表示→再表示で PerIdState を保持" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(320, 200);
    ctx.perIdState(88).selection = .{ .anchor = 1, .extent = 4 };
    ctx.perIdState(88).scroll_x = 16;
    ctx.endFrame();

    // 非表示 frame
    ctx.beginFrame(320, 200);
    ctx.endFrame();

    ctx.beginFrame(320, 200);
    try std.testing.expectEqual(@as(usize, 1), ctx.perIdState(88).selection.anchor);
    try std.testing.expectEqual(@as(usize, 4), ctx.perIdState(88).selection.extent);
    try std.testing.expectEqual(@as(i32, 16), ctx.perIdState(88).scroll_x);
    ctx.endFrame();
}

test "Context.beginFrame: 仮想時刻は frame index / 60" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(320, 200);
    try std.testing.expectEqual(@as(f64, 0.0), ctx.now());
    ctx.endFrame();
    ctx.beginFrame(320, 200);
    try std.testing.expectEqual(@as(f64, 1.0 / 60.0), ctx.now());
    ctx.endFrame();
}

test "buttonBehavior: active 中は別 widget が hot を奪わない" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id_a: Id = 1;
    const id_b: Id = 2;
    const rect_a = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const rect_b = Rect{ .x = 0, .y = 60, .w = 100, .h = 50 };

    // フレーム1: A を hover+down → active_id = A
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id_a, rect_a, full_clip);
    try std.testing.expectEqual(id_a, ctx.state.active_id);
    ctx.endFrame();

    // フレーム2: B 上に移動（A は押下継続）。B 上でも next_hot は B に乗らない
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 70, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id_a, rect_a, full_clip);
    _ = buttonBehavior(&ctx, id_b, rect_b, full_clip);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.next_hot_id);
    ctx.endFrame();
}

test "Context: beginFrame でリセット、endFrame では draw_list/id_stack/state を保持" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    try ctx.draw_list.rectFilled(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, color_mod.Color.rgba(0xFF, 0, 0, 0xFF));
    ctx.id_stack.push("scope");
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    ctx.endFrame();

    // endFrame 後も valid（次 beginFrame まで参照できる）
    try std.testing.expect(ctx.draw_list.cmds.items.len > 0);
    try std.testing.expect(ctx.id_stack.stack.items.len > 0);
    try std.testing.expect(ctx.state.this_frame_hovered_any);

    // 次 beginFrame でリセットされる
    ctx.beginFrame(800, 600);
    try std.testing.expectEqual(@as(usize, 0), ctx.draw_list.cmds.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.id_stack.stack.items.len);
    try std.testing.expect(!ctx.state.this_frame_hovered_any);
    ctx.endFrame();
}

test "buttonBehavior: 外で down → 内へ move → up（同フレーム）では click しない" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 200, .y = 200, .button = 0, .modifiers = 0 } }); // 起点は外
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } }); // 内へ移動
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(!r.clicked);
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id);
    ctx.endFrame();
}

test "buttonBehavior: 内で down → 外へ move（同フレーム）でも active は press 起点で取得される" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } }); // 起点は内
    ctx.pushEvent(.{ .mouse_move = .{ .x = 200, .y = 200, .modifiers = 0 } }); // 外へドラッグ
    const r = buttonBehavior(&ctx, 1, btn_rect, full_clip);
    try std.testing.expect(r.held);
    try std.testing.expectEqual(@as(Id, 1), ctx.state.active_id);
    ctx.endFrame();
}

test "Context: active widget が未評価のまま release されたら endFrame で active_id を解除" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 1;

    // フレーム1: hover+down → active 取得
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    _ = buttonBehavior(&ctx, id, btn_rect, full_clip);
    try std.testing.expectEqual(id, ctx.state.active_id);
    ctx.endFrame();

    // フレーム2: widget を呼ばず（非表示）、ボタンを離す
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    // buttonBehavior(id) を呼ばない（widget が消えた状況）
    ctx.endFrame();
    try std.testing.expectEqual(@as(Id, 0), ctx.state.active_id); // 張り付き解除
}

// ──────────────────────────────────────────────
// レイアウト統合テスト（TASK-21.4）
// ──────────────────────────────────────────────

test "layout: 明示 ID の box が endFrame 後に getNodeRect で取れる" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    const id = ctx.id_stack.make("panel");
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
    ctx.endBox();
    // endFrame 前（初回フレーム）は未登録
    try std.testing.expectEqual(@as(?Rect, null), ctx.getNodeRect(id));
    ctx.endFrame();

    const r = ctx.getNodeRect(id).?;
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 0), r.y);
    try std.testing.expectEqual(@as(u32, 200), r.w);
    try std.testing.expectEqual(@as(u32, 100), r.h);
}

test "layout: getNodeRect は自動 ID（cfg.id=0）・未知 ID・0 に対して null" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 50 } }); // 自動 ID
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(@as(?Rect, null), ctx.getNodeRect(0));
    try std.testing.expectEqual(@as(?Rect, null), ctx.getNodeRect(12345)); // 未知 ID
}

test "layout: rect キャッシュは beginFrame を跨いで前フレーム値を返す（同期 hit-test 契約 / AC #6）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 42;

    // フレーム1: 200x100 で配置
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 200 }, .height = .{ .fixed = 100 } });
    ctx.endBox();
    ctx.endFrame();

    // フレーム2 前半（widget 呼び出しタイミング）: 前フレーム値が引ける
    ctx.beginFrame(800, 600);
    const prev = ctx.getNodeRect(id).?;
    try std.testing.expectEqual(@as(u32, 200), prev.w);
    // 前フレーム rect で同期 hit-test できる（クリック成立）
    ctx.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 10, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_down = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    ctx.pushEvent(.{ .mouse_up = .{ .x = 10, .y = 10, .button = 0, .modifiers = 0 } });
    const res = buttonBehavior(&ctx, id, prev, full_clip);
    try std.testing.expect(res.clicked);
    // 当フレームはサイズ変更して配置
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 300 }, .height = .{ .fixed = 150 } });
    ctx.endBox();
    ctx.endFrame();

    // endFrame 後は当フレーム値に更新されている
    try std.testing.expectEqual(@as(u32, 300), ctx.getNodeRect(id).?.w);
}

test "layout: clip_children で子の draw cmd に親 rect が焼き込まれる" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 40 },
        .clip_children = true,
        .bg = Color.rgba(0x20, 0x20, 0x20, 0xFF),
    });
    ctx.label("a long text that overflows the box");
    ctx.endBox();
    ctx.endFrame();

    // 発行順: bg（clip = screen）→ text（clip = 親 rect で intersect 済み）
    try std.testing.expectEqual(@as(usize, 2), ctx.draw_list.cmds.items.len);
    const bg_clip = ctx.draw_list.cmds.items[0].rect_filled.clip;
    try std.testing.expectEqual(@as(u32, 800), bg_clip.w);
    const text_clip = ctx.draw_list.cmds.items[1].text.clip;
    try std.testing.expectEqual(@as(i32, 0), text_clip.x);
    try std.testing.expectEqual(@as(u32, 100), text_clip.w);
    try std.testing.expectEqual(@as(u32, 40), text_clip.h);
}

test "layout: label は文字列を arena に複製する（caller バッファ書き換えに影響されない）" {
    var ctx = testCtx();
    defer ctx.deinit();

    var buf = "hello".*;
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{});
    ctx.label(&buf);
    ctx.endBox();
    buf[0] = 'X'; // endFrame（発行）前に caller バッファを書き換える
    ctx.endFrame();

    try std.testing.expectEqualStrings("hello", ctx.draw_list.cmds.items[0].text.text);
}

test "layout: レイアウト API 未使用フレームは draw 発行ゼロ・rect キャッシュ保持" {
    var ctx = testCtx();
    defer ctx.deinit();
    const id: Id = 7;

    // フレーム1: layout 使用
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    ctx.endBox();
    ctx.endFrame();
    try std.testing.expect(ctx.getNodeRect(id) != null);

    // フレーム2: layout 未使用（手動 DrawList 運用の互換確認）
    ctx.beginFrame(800, 600);
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 0), ctx.draw_list.cmds.items.len);
    try std.testing.expect(ctx.getNodeRect(id) != null); // 前回値を保持
}

test "layout: custom leaf が最終 rect 付きで endFrame 中に呼ばれる" {
    var ctx = testCtx();
    defer ctx.deinit();

    const Capture = struct {
        rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        fn drawFn(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.rect = rect;
            dl.rectFilled(rect, Color.rgba(0xFF, 0, 0, 0xFF)) catch @panic("OOM");
        }
    };
    var cap: Capture = .{};

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .direction = .row, .padding = .{ 5, 5, 5, 5 } });
    ctx.custom(.{ .x = 64, .y = 32 }, Capture.drawFn, &cap);
    ctx.endBox();
    ctx.endFrame();

    // measure に size が使われ、padding 内側に配置される
    try std.testing.expectEqual(@as(i32, 5), cap.rect.x);
    try std.testing.expectEqual(@as(i32, 5), cap.rect.y);
    try std.testing.expectEqual(@as(u32, 64), cap.rect.w);
    try std.testing.expectEqual(@as(u32, 32), cap.rect.h);
    try std.testing.expectEqual(@as(usize, 1), ctx.draw_list.cmds.items.len);
}

// ──────────────────────────────────────────────
// widget 層の Context 側変更（TASK-21.5）
// ──────────────────────────────────────────────

test "layout: border は bg → 子 → border の順で発行される" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 40 },
        .bg = Color.rgba(0x20, 0x20, 0x20, 0xFF),
        .border = .{ .color = Color.rgba(0xA0, 0xA0, 0xB0, 0xFF), .thickness = 2 },
    });
    ctx.label("x");
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(@as(usize, 3), ctx.draw_list.cmds.items.len);
    try std.testing.expect(ctx.draw_list.cmds.items[0] == .rect_filled);
    try std.testing.expect(ctx.draw_list.cmds.items[1] == .text);
    const outline = ctx.draw_list.cmds.items[2].rect_outline;
    try std.testing.expectEqual(@as(u32, 2), outline.thickness);
    try std.testing.expectEqual(@as(u32, 100), outline.rect.w);
}

test "label: 既定色が style.text に追従する" {
    var ctx = testCtx();
    defer ctx.deinit();

    const red = Color.rgba(0xFF, 0x00, 0x00, 0xFF);
    ctx.style.text = red;
    ctx.beginFrame(800, 600);
    ctx.beginBox(.{});
    ctx.label("hello");
    ctx.endBox();
    ctx.endFrame();

    try std.testing.expectEqual(red, ctx.draw_list.cmds.items[0].text.color);
}
