extends Control
## PC port: army control in the style of desktop strategy games (Hearts of Iron).
##  * every army gets a counter on the map (unit icon + soldiers); zoomed out, counters that
##    would overlap fold into one stack counter (soldiers in total, "×N" armies)
##  * LMB on a counter: select that army (or the whole stack) — the army card opens for one army
##  * Shift+LMB on a counter / unit: add or remove it; Shift+LMB drag: box selection
##  * RMB on the map: the selected armies go there (RMB drag still moves the map);
##    RMB / Esc in a build mode leaves the mode
##  * Ctrl+1…9 remembers the selection, 1…9 recalls it (twice quickly: camera to it)
##  * Esc / ✕: clear the selection
## Orders go through the same network-safe commands as the game's own army card.

const AG = preload("res://game/army_groups.gd")
const U = preload("res://ui/ui24/arm_kit.gd")
const MD = preload("res://ui/ui24/map_declutter.gd")

const FOLD_PX: float = 44.0
const BOX_MIN_PX: float = 6.0
const UNIT_HIT_PX: float = 14.0
const RECALL_DBL_MS: int = 450
const STANCE_WORD: Array = ["ЖДУТ", "ДЕРЖАТ", "НАСТУПАЮТ"]

var hud: Node
var gw: GameWorld
var sel: Dictionary = {}
## true: the selection was made here (several armies) and our own card shows it;
## false: it mirrors the game's army / group card.
var multi: bool = false
var _hits: Array = []
var _cores: Dictionary = {}
var _box_from: Vector2 = Vector2.INF
var _box_to: Vector2 = Vector2.INF
var _box_add: bool = false
var _hot: Dictionary = {}
var _recall_k: int = -1
var _recall_ms: int = 0
var _player: Object = null

var card: PanelContainer
var _card_title: Label
var _card_sig: String = ""


func mount(h: Node) -> void:
	hud = h
	gw = h.gw
	name = "PcArmySelect"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.root.add_child(self)
	var pn: Variant = h.get("army_pennants")
	var at: int = (pn as Node).get_index() + 1 if pn is Node and is_instance_valid(pn) and (pn as Node).get_parent() == h.root else mini(1, h.root.get_child_count() - 1)
	h.root.move_child(self, at)
	_build_card()


func _main() -> Node:
	return hud.main_node if hud != null else null


func _cam() -> MapCamera:
	var m: Node = _main()
	return m.get("cam") as MapCamera if m != null else null


func _ux() -> Node:
	var u: Variant = hud.get("army_ux") if hud != null else null
	return u as Node if u is Node and is_instance_valid(u) else null


func ok() -> bool:
	var m: Node = _main()
	return gw != null and gw.player != null and not gw.player.eliminated and gw.army != null and gw.ops != null and m != null and not bool(m.get("in_menu")) and _cam() != null and _ux() != null


func _mode_none() -> bool:
	var m: Node = _main()
	return m != null and int(m.get("mode")) == 0


# ---------------------------------------------------------------- selection

func alive_fids() -> PackedInt32Array:
	var out: = PackedInt32Array()
	for fid: int in sel:
		var f: Facility = AG.fac(gw, fid)
		if f != null and f.country_id == gw.player.id and AG.army_alive(gw, f):
			out.append(fid)
	return out


func clear() -> void:
	sel.clear()
	multi = false
	_card_sig = ""


func _set_sel(fids: Array, add: bool) -> void:
	var ux: Node = _ux()
	if add:
		var all_in: bool = not fids.is_empty()
		for fid: int in fids:
			if not sel.has(fid):
				all_in = false
		for fid: int in fids:
			if all_in:
				sel.erase(fid)
			else:
				sel[fid] = true
	else:
		sel.clear()
		for fid: int in fids:
			sel[fid] = true
	var n: int = alive_fids().size()
	if n == 0:
		clear()
		if ux != null and String(ux.view) in ["army", "group"]:
			ux.close_view()
		return
	if n == 1:
		multi = false
		if ux != null:
			ux.open_army(int(alive_fids()[0]))
		return
	multi = true
	_card_sig = ""
	if ux != null and String(ux.view) != "":
		ux.close_view()
	var m: Node = _main()
	if m != null and m.has_method("drop_cards_for_sheet"):
		m.drop_cards_for_sheet()


## The game's own cards drive the selection while we are not in multi mode.
func _mirror() -> void:
	var ux: Node = _ux()
	if ux == null:
		return
	var v: String = String(ux.view)
	if multi:
		if v != "":
			multi = false
		else:
			return
	match v:
		"army", "place":
			if String(ux.view) == "place" and String(ux.place_kind) != "move_army":
				_mirror_group(int(ux.cur_gid))
			else:
				sel = {int(ux.cur_fid): true}
		"group":
			_mirror_group(int(ux.cur_gid))
		"pick":
			sel = (ux.picked as Dictionary).duplicate()
		_:
			sel.clear()


func _mirror_group(gid: int) -> void:
	sel.clear()
	for fid: int in AG.by_id(gw, gw.player.id, gid).get("fids", []):
		sel[int(fid)] = true


# ---------------------------------------------------------------- per frame

func _process(_delta: float) -> void:
	if gw != null and gw.player != _player:
		_player = gw.player
		clear()
		_hot.clear()
	if not ok():
		if card.visible:
			card.visible = false
		_hits.clear()
		queue_redraw()
		return
	_mirror()
	_card_tick()
	queue_redraw()


func _armies_on_map() -> Dictionary:
	var per: Dictionary = {}
	var pid: int = gw.player.id
	for u: Unit in gw.army.units:
		if u.home == null or u.country_id != pid or not u.alive() or u.type == Unit.Type.FPV or u.reinf != 0:
			continue
		var e: Array = per.get(u.home.id, [Vector2.ZERO, 0, []])
		e[0] = (e[0] as Vector2) + u.pos
		e[1] = int(e[1]) + 1
		(e[2] as Array).append(u.pos)
		per[u.home.id] = e
	return per


func _core(fid: int, e: Array) -> Vector2:
	var pn: Variant = hud.get("army_pennants")
	if pn is Object and is_instance_valid(pn) and (pn as Object).has_method("_core_of"):
		var k: Array = pn._core_of(fid, e, Time.get_ticks_msec())
		return k[0]
	return (e[0] as Vector2) / float(maxi(1, int(e[1])))


func _draw() -> void:
	_hits.clear()
	if not ok():
		return
	var cam: MapCamera = _cam()
	var z: float = cam.zoom.x
	var vr: Rect2 = get_viewport_rect()
	var top: float = float(cam.margin_top_px)
	var bot: float = hud.holder.get_global_rect().position.y if hud.holder != null else vr.size.y
	var ux: Node = _ux()
	var f: Font = UiKit.f_black
	var per: Dictionary = _armies_on_map()
	_cores.clear()

	# rings under the selected armies' units
	if not sel.is_empty() and z >= 0.45:
		var rr: float = clampf(6.0 * z, 4.0, 10.0)
		for fid: int in sel:
			for p: Vector2 in (per.get(fid, [Vector2.ZERO, 0, []]) as Array)[2]:
				var sp: Vector2 = cam.world_to_screen(p)
				draw_arc(sp, rr, 0.0, TAU, 12, U.DARK, 3.0)
				draw_arc(sp, rr, 0.0, TAU, 12, UiKit.GOLD, 1.5)

	# armies -> screen points, biggest first, then fold the ones that would overlap
	var items: Array = []
	for fid: int in per:
		var e: Array = per[fid]
		var c: Vector2 = _core(fid, e)
		_cores[fid] = c
		items.append([fid, cam.world_to_screen(c), int(e[1])])
	items.sort_custom(func(a: Array, b: Array) -> bool: return int(a[2]) > int(b[2]) or (int(a[2]) == int(b[2]) and int(a[0]) < int(b[0])))
	var stacks: Array = []
	for it: Array in items:
		var sp2: Vector2 = it[1]
		var joined: bool = false
		for st: Dictionary in stacks:
			if (st["p"] as Vector2).distance_to(sp2) < FOLD_PX:
				(st["fids"] as Array).append(it[0])
				st["n"] = int(st["n"]) + int(it[2])
				joined = true
				break
		if not joined:
			stacks.append({"p": sp2, "fids": [it[0]], "n": int(it[2])})

	var near: bool = z >= 1.2
	for st2: Dictionary in stacks:
		var p0: Vector2 = st2["p"]
		var cp: Vector2 = p0 + (Vector2(0, 14) if near else Vector2.ZERO)
		if cp.y < top - 10.0 or cp.y > bot + 10.0 or cp.x < -40.0 or cp.x > vr.size.x + 40.0:
			continue
		var fids: Array = st2["fids"]
		var lead: int = int(fids[0])
		var a: Dictionary = ux.ast(lead) if ux != null else {}
		var hp: float = 0.0
		var nsel: int = 0
		for fid2: int in fids:
			hp += float((ux.ast(fid2) if ux != null else {}).get("hp", 1.0))
			if sel.has(fid2):
				nsel += 1
		hp /= float(fids.size())
		var txt: String = str(int(st2["n"]))
		var tw: float = f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var w: float = roundf(4.0 + 16.0 + 3.0 + tw + 6.0)
		var h: float = 19.0
		var r: = Rect2((cp - Vector2(w * 0.5, h * 0.5)).round(), Vector2(w, h))
		var lf: Facility = AG.fac(gw, lead)
		var col: Color = gw.player.color
		if lf != null and lf.group_id >= 0:
			var g: Dictionary = AG.by_id(gw, gw.player.id, lf.group_id)
			if not g.is_empty():
				col = U.color(int(g["color"]))
		draw_rect(r.grow(1.0), U.DARK)
		draw_rect(r, Color(0.09, 0.07, 0.05, 0.93))
		draw_rect(Rect2(r.position, Vector2(4, h)), col)
		var ic: Texture2D = U.tex(String(a.get("build_icon", "icon_infantry")))
		if ic == null:
			ic = U.tex("icon_infantry")
		if ic != null:
			draw_texture_rect(ic, Rect2(r.position + Vector2(6, 2), Vector2(15, 15)), false)
		draw_string(f, r.position + Vector2(24, 14), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)
		draw_rect(Rect2(r.position + Vector2(4, h - 2), Vector2((w - 4) * clampf(hp, 0.0, 1.0), 2)), Color("a2e35f").lerp(Color("ff6a4d"), 1.0 - clampf(hp, 0.0, 1.0)))
		if nsel > 0:
			draw_rect(r.grow(2.0), UiKit.GOLD if nsel == fids.size() else UiKit.GOLD.darkened(0.35), false, 2.0)
		if fids.size() > 1:
			var bt: String = "×%d" % fids.size()
			var bw: float = f.get_string_size(bt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x + 6.0
			var br: = Rect2((r.position + Vector2(w - bw * 0.5, -8)).round(), Vector2(roundf(bw), 12))
			draw_rect(br.grow(1.0), U.DARK)
			draw_rect(br, Color(0.35, 0.27, 0.05, 0.95))
			draw_string(f, br.position + Vector2(3, 10), bt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color.WHITE)
		elif lf != null and z >= 0.7:
			var nt: String = Loc.no(lf.army_no)
			draw_string_outline(f, r.position + Vector2(w + 3, 13), nt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, 4, U.DARK)
			draw_string(f, r.position + Vector2(w + 3, 13), nt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, UiKit.MUTED)
		_hits.append([r.grow(3.0), fids.duplicate()])

	if _box_from.is_finite() and _box_to.is_finite():
		var br2: Rect2 = Rect2(_box_from, Vector2.ZERO).expand(_box_to)
		draw_rect(br2, Color(1.0, 0.84, 0.37, 0.12))
		draw_rect(br2, UiKit.GOLD, false, 1.5)


func counter_at(pos: Vector2) -> Array:
	var best: Array = []
	var bd: float = INF
	for e: Array in _hits:
		var r: Rect2 = e[0]
		if r.has_point(pos):
			var d: float = r.get_center().distance_to(pos)
			if d < bd:
				bd = d
				best = e[1]
	return best


## Armies under the cursor: a counter, else one of our units, else a group pennant.
func fids_at(pos: Vector2) -> Array:
	var c: Array = counter_at(pos)
	if not c.is_empty():
		return c
	var cam: MapCamera = _cam()
	var bu: Unit = null
	var bd: float = UNIT_HIT_PX
	for u: Unit in gw.army.units:
		if u.home == null or u.country_id != gw.player.id or not u.alive() or u.type == Unit.Type.FPV:
			continue
		var d: float = cam.world_to_screen(u.pos).distance_to(pos)
		if d < bd:
			bd = d
			bu = u
	if bu != null and AG.army_alive(gw, bu.home):
		return [bu.home.id]
	var pn: Variant = hud.get("army_pennants")
	if pn is Object and is_instance_valid(pn) and (pn as Object).has_method("hit_at"):
		var hit: Array = pn.hit_at(pos)
		if not hit.is_empty() and String(hit[0]) == "g":
			return Array(AG.by_id(gw, gw.player.id, int(hit[1])).get("fids", []))
		if not hit.is_empty() and String(hit[0]) == "a":
			return [int(hit[1])]
	return []


# ---------------------------------------------------------------- input (called by main.gd)

## Plain left tap (Mode.NONE). True = handled.
func tap(pos: Vector2) -> bool:
	if not ok():
		return false
	var c: Array = counter_at(pos)
	if not c.is_empty():
		_set_sel(c, false)
		UiKit.snd("ui_select")
		return true
	if multi:
		clear()
	return false


## Left button with Shift: add / remove under the cursor, or drag a selection box.
func lmb(mb: InputEventMouseButton) -> bool:
	if mb.pressed:
		if not (mb.shift_pressed and ok() and _mode_none()):
			return false
		var ux: Node = _ux()
		if ux != null and String(ux.view) in ["place", "pick"]:
			return false
		_box_from = mb.position
		_box_to = mb.position
		_box_add = true
		return true
	if not _box_from.is_finite():
		return false
	var a: Vector2 = _box_from
	var b: Vector2 = mb.position
	_box_from = Vector2.INF
	_box_to = Vector2.INF
	if not ok():
		return true
	if a.distance_to(b) < BOX_MIN_PX:
		var f: Array = fids_at(b)
		if not f.is_empty():
			if not multi:
				_mirror()
			_set_sel(f, true)
			UiKit.snd("ui_select")
		return true
	var rect: Rect2 = Rect2(a, Vector2.ZERO).expand(b)
	var cam: MapCamera = _cam()
	var got: Dictionary = {}
	for u: Unit in gw.army.units:
		if u.home == null or u.country_id != gw.player.id or not u.alive() or u.type == Unit.Type.FPV or got.has(u.home.id):
			continue
		if rect.has_point(cam.world_to_screen(u.pos)) and AG.army_alive(gw, u.home):
			got[u.home.id] = true
	if got.is_empty():
		return true
	if not multi:
		_mirror()
	for fid: int in got:
		sel[fid] = true
	_set_sel(sel.keys(), false)
	UiKit.snd("ui_select")
	return true


func mouse_move(pos: Vector2) -> bool:
	if not _box_from.is_finite():
		return false
	_box_to = pos
	queue_redraw()
	return true


## A right click (not a drag). True = handled.
func rmb_click(pos: Vector2) -> bool:
	if not ok():
		return false
	var m: Node = _main()
	var wp: Vector2 = _cam().screen_to_world(pos)
	var ux: Node = _ux()
	if ux != null and String(ux.view) == "place":
		if bool(ux.draw_on):
			return false
		ux.place_tap(wp)
		return true
	var ad: Variant = hud.get("army_dock")
	if ad != null and is_instance_valid(ad) and ad.is_placing():
		ad.cancel_place()
		UiKit.snd("ui_close")
		return true
	if not _mode_none():
		if m.has_method("pc_cancel_mode") and bool(m.pc_cancel_mode()):
			UiKit.snd("ui_close")
			return true
		return false
	var fids: PackedInt32Array = alive_fids()
	if fids.is_empty():
		return false
	order_move(fids, wp)
	return true


## Keys: Esc, Ctrl+digit, digit. True = handled.
func key(k: InputEventKey) -> bool:
	if not ok():
		return false
	if k.keycode == KEY_ESCAPE and multi and not sel.is_empty():
		clear()
		UiKit.snd("ui_close")
		return true
	var d: int = k.keycode - KEY_0
	if d < 1 or d > 9 or k.alt_pressed or k.shift_pressed:
		return false
	if k.ctrl_pressed:
		var fids: PackedInt32Array = alive_fids()
		if fids.is_empty():
			_hot.erase(d)
			_say(Loc.t("Ячейка %d очищена") % d)
		else:
			_hot[d] = fids
			_say(Loc.t("Выделение → %d (%s). Нажмите %d, чтобы выбрать снова") % [d, Loc.n(fids.size(), "%d армия", "%d армии", "%d армий") % fids.size(), d])
		UiKit.snd("ui_select")
		return true
	if not _hot.has(d) or not _mode_none():
		return false
	var keep: PackedInt32Array = PackedInt32Array()
	for fid: int in _hot[d]:
		var f: Facility = AG.fac(gw, fid)
		if f != null and AG.army_alive(gw, f):
			keep.append(fid)
	_hot[d] = keep
	if keep.is_empty():
		_say(Loc.t("В ячейке %d армий не осталось") % d)
		return true
	var now: int = Time.get_ticks_msec()
	var dbl: bool = _recall_k == d and now - _recall_ms < RECALL_DBL_MS
	_recall_k = d
	_recall_ms = now
	_set_sel(Array(keep), false)
	UiKit.snd("ui_select")
	if dbl:
		_center_on_sel()
	return true


func _center_on_sel() -> void:
	var s: = Vector2.ZERO
	var n: int = 0
	for fid: int in sel:
		var f: Facility = AG.fac(gw, fid)
		if f == null:
			continue
		for u: Unit in gw.army.units_of(f):
			s += u.pos
			n += 1
	if n > 0:
		_cam().center_on(s / float(n))


func _say(t: String) -> void:
	var ux: Node = _ux()
	if ux != null:
		ux.toast(t)
	else:
		hud.show_toast(t)


# ---------------------------------------------------------------- orders

func _who(fids: PackedInt32Array) -> String:
	if fids.size() == 1:
		return ""
	var gid: int = -2
	for fid: int in fids:
		var f: Facility = AG.fac(gw, fid)
		var g: int = f.group_id if f != null else -1
		if gid == -2:
			gid = g
		elif gid != g:
			gid = -1
	if gid >= 0:
		var gg: Dictionary = AG.by_id(gw, gw.player.id, gid)
		if not gg.is_empty() and (gg.get("fids", []) as Array).size() == fids.size():
			return Loc.name(String(gg["name"]))
	return Loc.t("Выделенные армии")


func _cmd(fn: String, args: Array, done: Callable = Callable()) -> void:
	NetSession.sim("", "cmd_static", [gw.player, "groups", fn, args], func(r: Variant) -> void:
		var ux: Node = _ux()
		if ux != null and ux.has_method("_drop_cache"):
			ux._drop_cache()
		if is_instance_valid(self) and done.is_valid():
			done.call(r))


func order_move(fids: PackedInt32Array, wp: Vector2) -> void:
	var ux: Node = _ux()
	if ux != null:
		# the same path preview the army card draws (green lines, red crosses for those that cannot go)
		var pk: String = String(ux.place_kind)
		var ps: bool = bool(ux.place_sea)
		ux.place_kind = "move"
		ux.place_sea = false
		var chk: Dictionary = ux.check(fids, wp, "move")
		ux.place_kind = pk
		ux.place_sea = ps
		ux.preview = {"to": wp, "ok": chk["ok"], "bad": chk["bad"], "until": Time.get_ticks_msec() + 4000}
	var m: Node = _main()
	if m != null and m.get("overlay") != null:
		m.overlay.ripple(wp, "grass_light")
	var who: String = _who(fids)
	_cmd("order_fids", [fids, "move", wp, who], func(r: Variant) -> void:
		var d: Dictionary = r if r is Dictionary else {}
		var n: int = int(d.get("ok", 0))
		var u2: Node = _ux()
		if n > 0:
			var lbl: String = (Loc.t("Армия №%d") % AG.fac(gw, fids[0]).army_no) if fids.size() == 1 and AG.fac(gw, fids[0]) != null else who
			var t: String = Loc.t("%s: идут %d из %d") % [lbl, n, fids.size()] if n < fids.size() else Loc.t("%s: в путь") % lbl
			if u2 != null:
				u2.toast(t, u2._ok_fids(fids, d))
			UiKit.snd("ui_build")
		else:
			_say(Loc.t("Не пошли: %s") % (u2._skip_why(d) if u2 != null else ""))
			UiKit.snd("ui_error"))


func _act(what: String, arg: int = 0) -> void:
	var fids: PackedInt32Array = alive_fids()
	if fids.is_empty():
		return
	var who: String = _who(fids)
	var done: = func(_r: Variant) -> void:
		_card_sig = ""
	match what:
		"stop":
			for fid: int in fids:
				var f: Facility = AG.fac(gw, fid)
				if f != null:
					NetSession.sim("ops", "cancel", [f])
			_say(Loc.t("%s: стоп") % who)
		"retreat":
			_cmd("order_fids", [fids, "retreat", Vector2.INF, who], func(r: Variant) -> void:
				var d: Dictionary = r if r is Dictionary else {}
				_say(Loc.t("%s: отход к казармам (%d)") % [who, int(d.get("ok", 0))]))
		"trench":
			_cmd("trench_in_fids", [fids, who], func(r: Variant) -> void:
				var d: Dictionary = r if r is Dictionary else {}
				if String(d.get("why", "")) != "":
					_say(String(d["why"]))
					UiKit.snd("ui_error"))
		"stance":
			_cmd("set_stance", [fids, arg, who], done)
			_say(Loc.t("%s: %s") % [who, Loc.t(String(STANCE_WORD[arg])).to_lower()])
		"group":
			var ux: Node = _ux()
			if ux != null:
				var pk: Dictionary = {}
				for fid2: int in fids:
					pk[fid2] = true
				multi = false
				ux.picked = pk
				ux.open_pick(-1)
	UiKit.snd("ui_click")


# ---------------------------------------------------------------- the card for several armies

func _build_card() -> void:
	card = PanelContainer.new()
	card.name = "PcArmySelCard"
	card.add_theme_stylebox_override("panel", UiKit.sb("wb_panel", 8, 6))
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.visible = false
	hud.root.add_child(card)
	var vb: = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	card.add_child(vb)
	var hb: = HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	vb.add_child(hb)
	var tv: = VBoxContainer.new()
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_theme_constant_override("separation", 0)
	hb.add_child(tv)
	_card_title = UiKit.lbl("", 13, UiKit.TITLE, 3, 3)
	tv.add_child(_card_title)
	var hint: Label = UiKit.lbl("ПКМ по карте — идти · Shift+ЛКМ — добавить/убрать · Shift+рамка — выделить · Ctrl+1…9 — запомнить", 9, UiKit.MUTED, 1)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tv.add_child(hint)
	var cb: Button = UiKit.close_btn(36.0)
	cb.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cb.pressed.connect(func() -> void:
		clear()
		UiKit.snd("ui_close"))
	hb.add_child(cb)
	var row: = HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 4)
	row.add_theme_constant_override("v_separation", 4)
	vb.add_child(row)
	for it: Array in [["СТОП", "stop", 0, "stone"], ["ОТХОД", "retreat", 0, "stone"], ["ОКОПАТЬСЯ", "trench", 0, "stone"],
			["ЖДУТ", "stance", 0, "blue"], ["ДЕРЖАТ", "stance", 1, "green"], ["НАСТУПАЮТ", "stance", 2, "red"], ["В ГРУППУ", "group", 0, "gold"]]:
		var b: Button = UiKit.big(String(it[0]), String(it[3]), "", 36.0, 9)
		b.custom_minimum_size = Vector2(0, 36)
		var w: String = String(it[1])
		var a: int = int(it[2])
		b.pressed.connect(func() -> void: _act(w, a))
		row.add_child(b)


func _card_tick() -> void:
	var fids: PackedInt32Array = alive_fids() if multi else PackedInt32Array()
	var busy: bool = (hud.panel != null and is_instance_valid(hud.panel)) or (hud.ops_panel != null and hud.ops_panel.visible)
	var want: bool = fids.size() > 1 and not busy
	if multi and fids.size() <= 1:
		var one: PackedInt32Array = fids
		clear()
		if one.size() == 1 and _ux() != null:
			_ux().open_army(int(one[0]))
	if card.visible != want:
		card.visible = want
	if not want:
		return
	var n: int = 0
	for fid: int in fids:
		n += int(_ux().ast(fid).get("n", 0))
	var sig: String = "%d|%d" % [fids.size(), n]
	if sig != _card_sig:
		_card_sig = sig
		_card_title.text = Loc.t("ВЫДЕЛЕНО: %s · %d бойцов") % [Loc.n(fids.size(), "%d армия", "%d армии", "%d армий") % fids.size(), n]
	var vs: Vector2 = get_viewport_rect().size
	var w: float = minf(vs.x - 16.0, 600.0)
	card.size = Vector2(w, 0)
	card.reset_size()
	card.size.x = w
	var bot: float = hud.holder.get_global_rect().position.y if hud.holder != null else vs.y
	card.position = Vector2(roundf((vs.x - w) * 0.5), roundf(bot - card.size.y - 8.0))
