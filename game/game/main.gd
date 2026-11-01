extends "res://game/main/main_input.gd"
## Entry point: world + camera + HUD, touch/mouse input, tool modes.
## Taps: build modes place facilities; TARGET / MISSILE plan a strike; with nothing active a tap
## selects an own drone or missile (telemetry, camera follow) or a facility (card with actions);
## while a drone is selected, a tap anywhere on the map gives it a new target.


func _ready() -> void:
	RenderingServer.set_default_clear_color(Palette.c("water_deep"))
	world = GameWorld.new()
	world.name = "World"
	add_child(world)
	cam = MapCamera.new()
	cam.name = "Camera"
	add_child(cam)
	cam.make_current()
	cam.zoom_changed.connect(_on_zoom)
	world.camera = cam
	world.selected_fn = follow_drone
	world.selected_fac_fn = func() -> Facility: return selected_fac
	world.missile_launched.connect(_on_missile_launched)
	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.setup(self, world)
	hud.action.connect(_on_action)
	_ghost = Node2D.new()
	_ghost.name = "PendingGhost"
	_ghost.z_index = 60
	_ghost.draw.connect(_draw_ghost)
	world.add_child(_ghost)
	overlay = RouteOverlay.new()
	overlay.name = "RouteOverlay"
	overlay.gw = world
	overlay.main_node = self
	hud.add_child(overlay)
	hud.move_child(overlay, 0)
	net = NetSession.new()
	net.name = "Net"  # same path on every peer: the RPC target
	add_child(net)
	net.setup(self)
	menus = Menus.new()
	menus.name = "Menus"
	add_child(menus)
	menus.setup(world)
	menus.net = net
	menus.request.connect(_on_menu)
	tutorial = Tutorial.new()
	tutorial.name = "Tutorial"
	add_child(tutorial)
	tutorial.setup(world, hud)
	world.news.connect(hud.push_news)
	world.war_declared.connect(_on_war)
	world.match_ended.connect(_on_match_end)
	world.city_captured.connect(_on_city_captured)
	world.offer_received.connect(_on_offer)  # v0.28 UX-CALM: the inbox pill counts it (journal line, no toast)
	loading = Loading.new()
	loading.name = "Loading"
	add_child(loading)
	if LangPicker.needed(self):  # R340 I18N-LANG: first launch - the language first, then the opening (i18n333 §6)
		await LangPicker.first_run(self)
	if Opening.should_autoplay(self):  # v0.30.8: the cinematic first; it ends on the loading look
		await play_opening(true)
	else:
		loading.show_screen("Создаём мир...")
	_snd("set_listener", [cam])
	settings = WorldSettings.new()
	await get_tree().process_frame
	_main_menu()
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--net-test="):  # NET: dev/net_autotest.gd (two-instance LAN test)
			var nt: RefCounted = (load("res://dev/net_autotest.gd") as GDScript).new()
			set_meta("net_test", nt)  # keeps the test object alive while its coroutine runs
			nt.call("run", self, a)
		elif a.begins_with("--mp-shots="):  # NET: dev/mp_shots.gd (multiplayer UI screenshots)
			var ms: RefCounted = (load("res://dev/mp_shots.gd") as GDScript).new()
			set_meta("mp_shots", ms)
			ms.call("run", self, a)


## Main menu: a living world of bots behind the menu, camera drifting.
func _main_menu() -> void:
	in_menu = true
	tutorial.stop()
	hud.visible = false
	menus.close()
	hud.close_panel()
	if not loading.visible:
		loading.show_screen("Создаём мир...")
	loading.set_progress(0.1, "Рельеф, реки и леса...")
	await get_tree().process_frame
	await get_tree().process_frame
	var s := WorldSettings.new()
	s.world_seed = randi() % 100000000
	s.size = 512
	settings = s
	_deselect()
	_clear_plan()
	world.new_world(s)
	loading.set_progress(0.7, "Страны и города...")
	await get_tree().process_frame
	world.spawn_ai_countries(4)
	world._flush_territory()
	world.time_scale = 2.0
	cam.set_zoom_at(MapCamera.zk(1.0), cam.view_size() * 0.5)  # R347
	_on_zoom(1.0)
	var caps: Array = []
	for c: City in world.cities:
		if c.kind == City.Kind.CAPITAL:
			caps.append(c)
	if not caps.is_empty():
		cam.center_on(Vector2((caps[0] as City).center * GameWorld.CELL))
	mode = Mode.NONE
	loading.finish()
	_snd("music", ["menu"])
	_snd("loop", ["amb_wind", "ambient_wind_loop", true, Vector2.INF, -16.0])
	menus.show_main()


## v0.30.8 OPENING: plays the cinematic over everything. `boot`: the loading screen appears under its
## fade (same first frame). Otherwise («СМОТРЕТЬ ЗАСТАВКУ») the menu music pauses meanwhile.
func play_opening(boot: bool) -> void:
	var op := Opening.new()
	op.name = "Opening"
	if boot:
		op.reveal.connect(func() -> void: loading.show_screen("Создаём мир..."))
	else:
		_snd("music", [""])
	add_child(op)
	await op.finished
	if not boot:
		_snd("music", ["menu" if in_menu else "game"])


func _on_menu(req: String) -> void:
	match req:
		"watch_opening":
			menus.close()
			await play_opening(false)
			menus.show_settings_sub("opening")
		"main":
			menus.show_main()
		"setup":
			if net.in_match:
				net.leave()  # NET: the end screen's «НОВАЯ ПАРТИЯ»: leave the network match first
				return
			if not in_menu:
				_main_menu()
			menus.show_setup()
		"mp":
			menus.show_mp()
		"mp_lobby":
			menus.show_lobby()  # NET: back from the match setup to the room
		"settings_main":
			menus.show_settings(false)
		"settings_pause":
			menus.show_settings(true)
		"start":
			GameConfig.tutorial = false
			if GameConfig.cb_on:
				CustomBots.sanitize()  # CUSTOMBOTS R331: prefs may hold anything
				if GameConfig.cb_list.is_empty():
					menus.show_custom_bots()  # no enemy: back to the roster (its empty state says why)
					return
			_new_game()
		"tutorial", "tutorial_restart":
			if net.in_match:
				net.leave()
				return
			# Gentle settings for the tutorial match only; the player's choice is restored after.
			var keep: Array = [GameConfig.bots, GameConfig.difficulty, GameConfig.aggression, GameConfig.size_i]
			GameConfig.tutorial = true
			GameConfig.bots = 2
			GameConfig.difficulty = 0
			GameConfig.aggression = 0
			GameConfig.size_i = 0
			_new_game()
			GameConfig.bots = keep[0]
			GameConfig.difficulty = keep[1]
			GameConfig.aggression = keep[2]
			GameConfig.size_i = keep[3]
		"pause":
			menus.show_pause()
		"scores":
			menus.show_scores()
		"resume", "continue":
			menus.close()
			_paused = _menu_paused  # v0.21: the menu keeps the player's own pause
			_menu_paused = false
			_apply_speed()
		"restart":
			if net.in_match:
				net.leave()
				return
			_new_game()
		"main_menu":
			if net.in_match:
				if net.reconnecting or net.rejoining:
					net.leave(true, true, true)  # NET 32: the place stays («ВЕРНУТЬСЯ В ПАРТИЮ» in «Мультиплеер»)
				else:
					net.leave()  # NET: leaving a network match; net_match_closed() shows the menu
				return
			Save.save_game(self)
			_main_menu()
		"mp_start":
			var whys: String = net.host_start()  # NET: the host starts with the setup-screen rules
			if whys != "":
				menus.show_lobby(whys)
		"load_save":
			if net.in_match:
				net.leave()
				return
			menus.close()
			hud.hide_prompt()
			if not await Save.load_game(self):
				_main_menu()  # R332 SAVES: the slot is marked damaged (the saves screen shows it), not deleted
				hud.show_toast("Сохранение повреждено")
			else:
				_plan_refresh()  # the plan showed an old early step for seconds after a load


func _new_game() -> void:
	RankedRules.clear()  # (critic) a ranked match's settings never reach a single-player game
	# The old save stays until this match's first autosave (60 s): backing out keeps «ПРОДОЛЖИТЬ».
	Save.begin_new()  # R332 SAVES: the slot picked on the setup screen (ЗАНОВО: the same slot)
	hud.hide_prompt()
	menus.close()
	in_menu = false
	hud.visible = true
	var s := WorldSettings.new()
	s.world_seed = randi() % 100000000
	s.size = int(GameConfig.SIZES[GameConfig.size_i])
	GameConfig.apply_map(s, true)  # v0.25 MAP: map type, rivers, lakes, the previewed seed
	GameConfig.bots = maxi(1, GameConfig.bots)  # kiwy-multiplayer: 0 bots is for network matches only
	_paused = false
	_speed_i = 0
	start_world(s)
	if GameConfig.tutorial:
		tutorial.start()
	else:
		tutorial.stop()


func start_world(s: WorldSettings) -> void:
	settings = s
	if not net.in_match:
		world.net_driven = false  # NET: a single-player world is never stepped by the lockstep
	loading.show_screen("Генерация мира...")
	_deselect()
	_clear_plan()
	hud.close_panel()
	loading.set_progress(0.15, "Рельеф, реки и леса...")
	await get_tree().process_frame
	await get_tree().process_frame
	world.new_world(s)
	loading.set_progress(0.9, "Готовим карту...")
	await get_tree().process_frame
	_apply_speed()
	cam.set_zoom_at(MapCamera.zk(1.0), cam.view_size() * 0.5)  # R347
	_on_zoom(1.0)
	loading.finish()
	_snd("music", ["game"])
	_snd("loop", ["amb_wind", "ambient_wind_loop", true, Vector2.INF, -12.0])
	hud.city_labels_reset()
	hud.refresh()
	_set_mode(Mode.CAPITAL)
	hud.select_page(1)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if bool(load("res://ui/ui24/tutorial_feed.gd").call("close_if_open")):
			return  # SP 0.31.3: BACK over the tutorial feed closes it (was: resumed the paused match under the feed)
		if (menus == null or not menus.is_open()) and _army_back():
			return
		if menus != null and menus.is_open():
			if not in_menu:
				_on_menu("resume")
		else:
			_open_pause()
	elif what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_touches.clear()  # fingers lifted while the app was away never send a release
		_pinch_d = 0.0
		_pinch_mid = Vector2.INF
		_dtz = false
		if net != null and net.in_match:
			# NET: no local save, no pause; a host going to the background pauses the match for all.
			if OS.has_feature("mobile"):
				net.set_host_active(false)
			return
		if not in_menu:
			Save.save_game(self)
		if not in_menu and menus != null and not menus.is_open() and OS.has_feature("mobile"):
			_open_pause()
	elif what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if net != null and net.in_match:
			net.set_host_active(true)
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if net != null and net.in_match:
			if net.is_host:
				net.host_exit_saved()  # NET 35: the match stays saved: the host may resume it, the guests keep their places
			else:
				net.leave(false)
		elif not in_menu:
			Save.save_game(self)


## REPORTS: «ЖАЛОБА» from the chat (ui/ui24/dip_chat_view.gd): the menu opens on the report about that country.
func open_report(cid: int) -> void:
	if in_menu:
		return
	_open_pause()
	ReportScreen.start(cid, true)
	menus.show_report()


func _open_pause() -> void:
	if in_menu:
		return
	if not menus.is_open():
		_menu_paused = _paused
	_paused = true
	_apply_speed()
	menus.show_pause()


## A new diplomatic item. NET: the signal fires on every device; only a new item for this player counts.
func _on_offer() -> void:
	if net.in_match and world.diplo != null:
		var fresh: bool = false
		var now: Dictionary = {}
		for it: Dictionary in world.diplo.pending_for_player():
			var id: String = String(it["id"])
			now[id] = true
			fresh = fresh or not _seen_pend.has(id)
		_seen_pend = now
		if not fresh:
			return
	var was: bool = world.ui_mute
	world.ui_mute = false  # NET: another person's command made it, but the item is ours
	hud._on_world_message("Дипломатия: новое предложение")
	world.ui_mute = was  # v0.28 UX-CALM: the inbox pill counts it (journal line, no toast)


func _on_war(a: int, b: int) -> void:
	if world.player == null or (a != world.player.id and b != world.player.id):
		return  # NET: someone else's war (the signal fires on every device)
	var other: int = b if a == world.player.id else a
	var oc: Country = world.country_by_id(other)
	hud.war_flash(Loc.msg(Loc.mk("ВОЙНА: %s", [(Loc.name(oc.name).to_upper() if oc != null else "")])), "war")  # R340
	hud.plan_state = 0
	hud.plan_open = false
	hud._plan_sig = ""
	world.camera_shake_small()


func _on_match_end(winner: int) -> void:
	if net.in_match and RankedRules.active():  # BACKEND 2: every player reports by himself, at once
		var wt: int = world.session.win_team if world.session != null else -1
		var mid: String = String(GameConfig.ranked.get("match", net.match_id))
		if mid == "":
			mid = net.match_id
		if mid != "":
			Ranked.report(mid, null if wt < 0 else wt, RankedRules.left_names(net))
		_menu_paused = false
		_paused = true
		_apply_speed()
		NetConfig.clear_rejoin()
		menus.show_end_ranked(wt, mid)
		return
	if not net.in_match:
		Save.match_over(world.player != null and winner == world.player.id)  # R332: the slot keeps its saves, marked ended  # NET: a network match never touches the single-player save
	else:
		net.match_decided = true  # leaving now ends the match on the server (counted), never a hand-over
		NetConfig.clear_rejoin()  # NET 32: nothing to come back to
		if net.is_host:
			NetConfig.clear_match()  # NET 35: the match is over: nothing to resume
	_menu_paused = false
	_paused = true
	_apply_speed()
	menus.show_end(winner)


func _on_city_captured(city: City, _old: int) -> void:
	hud.city_label_drop(city.id)
	if selected_fac != null and world.player != null and selected_fac.country_id != world.player.id:
		_deselect()
	if follow is Aircraft and world.player != null and (follow as Aircraft).country_id != world.player.id:
		_deselect()
	if world.player != null and city.country_id == world.player.id:
		var annex: bool = world.diplo != null and world.diplo.get("conf") != null and bool(world.diplo.conf.applying)  # v0.26 DIP2
		hud.war_flash((Loc.t("АННЕКСИЯ: %s") if annex else Loc.t("ГОРОД ВЗЯТ: %s")) % Loc.name(city.name).to_upper())  # R340
	elif world.player != null and _old == world.player.id:
		var by_c: Country = world.country_by_id(city.country_id)  # v0.30.13 PEACE313: who took it (an ally of the defeated is not the defeated)
		hud.war_flash(Loc.msg(Loc.mk("ПОТЕРЯН ГОРОД: %s — взял %s", [Loc.name(city.name).to_upper(), Loc.name(by_c.name).to_upper() if by_c != null else "?"])), "lost")


const _TutorialFeed = preload("res://ui/ui24/tutorial_feed.gd")  # R346C (is_open: the idle frame cap)


func _process(delta: float) -> void:
	# R346C: the plain main menu screen, the pause, a menu over the match: Save.IDLE_FPS (heat, battery). Not under the
	# tutorial feed (its flick is read per frame) nor on the other main-menu screens (flag editor strokes, lists).
	var idle: bool = ((in_menu and menus.current == "main") or (not in_menu and (_paused or menus.is_open()))) and not _TutorialFeed.is_open()
	if idle != Save.fps_idle:
		Save.fps_idle = idle
		Save.apply_power_save()
	if not _focus.is_empty():
		_focus_tick()
	if in_menu:
		# Slow drift over the bots' world behind the main menu.
		cam.position += _menu_pan * delta * 14.0
		var wpx: Vector2 = cam.world_px
		if cam.position.x < 200.0 or cam.position.x > wpx.x - 200.0:
			_menu_pan.x = -_menu_pan.x
		if cam.position.y < 300.0 or cam.position.y > wpx.y - 300.0:
			_menu_pan.y = -_menu_pan.y
		return
	Save.tick(self, delta)
	if _strat_tap.is_finite() and Time.get_ticks_msec() - _strat_tap_ms >= 320:
		var stp: Vector2 = _strat_tap
		_strat_tap = Vector2.INF
		# SP 0.31.1 (STRANGE332): the pending tap is dropped when the view moved / zoomed or a menu opened meanwhile
		# (was: a country page opened under the pause menu; after a quick pinch the tap hit whatever was there now)
		if not menus.is_open() and mode == Mode.NONE and _strat_tap_w.is_finite() and cam.world_to_screen(_strat_tap_w).distance_to(stp) < 12.0:
			_tap(stp)
	world.selected_army = selected_fac if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS else null
	_creative_t -= delta
	if world.get("vfx") != null and world.vfx.has_method("set_focus"):
		# v0.20: clouds / smoke step aside while aiming (any mode) and over the pending mark.
		var fp: Vector2 = _pend["wp"] if _pend.has("wp") else Vector2.INF
		var fsig := Vector3(fp.x if fp.is_finite() else -1.0, fp.y if fp.is_finite() else -1.0, float(mode))
		if fsig != _focus_sig:
			_focus_sig = fsig
			world.vfx.set_focus([fp] if fp.is_finite() else [], mode != Mode.NONE or fp.is_finite())
	if _auto_card != null:
		# v0.20: a card opened by a build closes by itself if untouched (it hid the plan for minutes).
		_auto_card_t -= delta
		if selected_fac != _auto_card:
			_auto_card = null
		elif _auto_card_t <= 0.0 and not _confirming:
			_auto_card = null
			_deselect()
	if GameConfig.creative and _creative_t <= 0.0 and world.player != null and not GameConfig.tutorial and not net.in_match:  # NET: online top-up runs on the ticks
		_creative_t = 0.5  # creative mode: money and every resource stay topped up
		var cp: Country = world.player
		cp.money = maxi(cp.money, 1000000)
		for rk: String in Economy.TRADE_RES + ["fuel"]:
			var cap: int = int(world.econ.res_cap(cp, rk)) if world.econ.has_method("res_cap") else 0
			cp.set(rk, maxi(int(cp.get(rk)), cap if cap > 0 else 999))
	# Camera may bring every map edge into the free area between the HUD bars.
	var mt: float = hud.top_col.position.y + hud.top_col.size.y
	var mb: float = hud.root.size.y - hud.holder.position.y
	if absf(cam.margin_top_px - mt) > 2.0 or absf(cam.margin_bottom_px - mb) > 2.0:
		cam.margin_top_px = mt
		cam.margin_bottom_px = mb
		cam.center_on(cam.position)
	var g_live: bool = not _pend.is_empty() or mode == Mode.TARGET or BUILD_KIND.has(mode) or mode == Mode.RAIL_ST or mode == Mode.RAIL_LINE  # R335
	if (g_live or _ghost_live) and _ghost != null:
		_ghost.queue_redraw()  # R323 PLACE: build modes too (own AD rings before the first tap); one more to clear
	_ghost_live = g_live
	_cam_tick(delta)
	_prompt_tick(delta)
	_update_ops(delta)
	_net_banner_tick(delta)
	strike.tick(world)  # v0.28 UX-STRIKE: staggered (synchronised) launches on game time
	if strike_marks != null:
		strike_marks.tick()
	if jet316_marks != null:
		jet316_marks.tick()
	_perf_t += delta
	if _perf_t >= 5.0:
		_perf_t = 0.0
		print("[Perf] fps=%d draw_calls=%d objects=%d cities=%d zoom=%.2f" % [Engine.get_frames_per_second(), int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)), world.obj_spr.size() - world._free_ids.size(), world.cities.size(), cam.zoom.x])


func _on_action(nm: String) -> void:
	_auto_card = null
	if world.player != null and world.player.eliminated and not in_menu and not (nm in SPECTATOR_OK or nm.begins_with("page_") or nm.begins_with("dipx:")):
		hud.show_toast("Наблюдение: ваша страна выбыла. «Новая партия» — в меню")
		return
	# A card of something that is no longer ours (captured) does nothing.
	if selected_fac != null and world.player != null and selected_fac.country_id != world.player.id:
		_deselect()
	if net.in_match and nm == "pause":
		hud.show_toast("Мультиплеер: пауза — только когда хост свернул игру")
		return
	if net.in_match and nm in ["speed", "speed_next"]:
		_speed_picker()  # NET 31: agreed / automatic match speed
		return
	match nm:
		"pause":
			_paused = not _paused
			_apply_speed()
		"speed":
			_speed_picker()  # v0.26.1 owner: a popup row of speed chips (was: cycle per tap)
		"speed_next":
			if net.in_match:
				_speed_picker()  # NET 31: the match speed is agreed / automatic, not this device's
				return
			_speed_i = (_speed_i + 1) % SPEEDS.size()
			_paused = false
			_apply_speed()
		"zoom_in":
			cam.step_zoom(1, cam.view_size() * 0.5)
		"zoom_out":
			cam.step_zoom(-1, cam.view_size() * 0.5)
		"center":
			if world.player != null and world.player.capital_id >= 0:
				cam_lock = false
				cam.center_on(Vector2(world.cities[world.player.capital_id].center * GameWorld.CELL))
		"new_world":
			hud.open_new_world(settings)
		"borders":
			world.territory.visible = not world.territory.visible
			world.territory_border.visible = world.territory.visible
			hud.set_key_pressed("borders", not world.territory.visible)
		"capital":
			_set_mode(Mode.NONE if mode == Mode.CAPITAL else Mode.CAPITAL)
		"town":
			if _has_capital():
				_set_mode(Mode.NONE if mode == Mode.TOWN else Mode.TOWN)
			else:
				_set_mode(Mode.CAPITAL)
		"strike":
			if net.in_match:
				hud.show_toast("Тестовый удар в сетевой партии недоступен")
				return
			_set_mode(Mode.NONE if mode == Mode.STRIKE else Mode.STRIKE)
		"menu":
			_open_pause()
		"scores":
			if not menus.is_open():
				_menu_paused = _paused
			_paused = true
			_apply_speed()
			menus.show_scores("pause" if menus.is_open() and menus.current == "pause" else "resume")  # R332 T4: HUD score -> back to the game
		"diplomacy":
			hud.open_diplomacy()
		"trade":
			hud.open_trade()
		"ad_rules":  # R335 UX335: country-wide AD target rules (ПВО tab key, AD site card act)
			hud.open_ad_rules(selected_fac.kind if selected_fac != null and Defense.AD_CLASSES.has(selected_fac.kind) else -1)
		"doctrine":
			hud.open_doctrine()
		"attack":
			if _has_capital():
				attack_from = null
				_set_mode(Mode.NONE if mode == Mode.ATTACK else Mode.ATTACK)
		"attack_from":
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				var bf: Facility = selected_fac
				_set_mode(Mode.ATTACK)
				attack_from = bf
				hud.set_hint("АТАКА ИЗ КАЗАРМ: ТАП ПО ГОРОДУ")
		"hold":
			if world.player != null:
				var now_h: float = Time.get_ticks_msec() / 1000.0
				if now_h - _hold_t > 3.0:
					_hold_t = now_h
					hud.show_toast("Остановить ВСЕ армии? Нажмите «СТОЯТЬ» ещё раз")
				else:
					_hold_t = -10.0
					_sim("army", "order_hold", [world.player.id])
					hud.show_toast("Все армии: стоять на месте")
		"army_next":
			_cycle_army()
		"bar_0", "bar_1", "bar_2", "bar_3":
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				_sim("", "cmd_field", [selected_fac, "prod_type", int(nm.substr(4))])
		"ad_rearm":
			if selected_fac != null:
				_sim("defense", "rearm", [selected_fac, world.player], func(r: Variant) -> void:
					hud.show_toast(_why(r) if _why(r) != "" else "Боекомплект пополнен"))
		"pylon_1", "pylon_2":
			if follow is Aircraft:
				var a2: Aircraft = follow as Aircraft
				var np: int = int(nm.substr(6))
				_sim("mil.air", "set_pylon", [a2, 0 if a2.pylon == np else np], func(r: Variant) -> void:
					hud.show_toast(_why(r) if _why(r) != "" else Loc.msg(Loc.mk("Подвес: %s", [Loc.t(Air.PYLON_NAMES[a2.pylon])]))))
		"air_hyp":
			if follow is Aircraft:
				strike_open("hyper")  # v0.28 UX-STRIKE: the one strike panel, hypersonic preselected
		"page_0", "page_1", "page_2", "page_3", "page_4", "page_5", "page_6":
			pass
		"defend":
			if world.player != null:
				_sim("", "cmd_field", [world.player, "army_defend", not world.player.army_defend], func(_r: Variant) -> void:
					hud.set_key_pressed("defend", world.player.army_defend)
					hud.show_toast("Режим обороны: пехота занимает окопы" if world.player.army_defend else "Режим обороны выключен"))
		"occupy":
			if selected_fac != null and Army.is_trench(selected_fac.kind):
				_sim("army", "occupy", [selected_fac, world.player.id], func(r: Variant) -> void:
					var no: int = int(r) if r != null else 0
					hud.show_toast(Loc.msg(Loc.mk("В окоп идут: %d", [no])) if no > 0 else "Нет свободной пехоты рядом (казармы)"))
		"leave":
			if selected_fac != null and Army.is_trench(selected_fac.kind):
				_sim("army", "leave", [selected_fac])
		"bar_4":
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				_sim("", "cmd_field", [selected_fac, "prod_type", 4])
		"factory", "droneport", "tel", "mfactory", "refinery", "power", "airfield", "farm", "civ", "mine", "barracks", "ad_mfg", "ad_spaag", "ad_sam", "ad_patriot", "ad_int", "ad_radar", "ad_ew", "trench", "teeth", "dugout", "sawmill", "oil_rig", "port", "solar_farm", "navbase", "coastal_asm", "npp", "umine":  # QA v0.27.1: + coastal_asm; v0.30 URAN30: + npp, umine
			var bm: int = BUILD_KEYS[nm]
			if not _has_capital():
				_set_mode(mode)
			else:
				_set_mode(Mode.NONE if mode == bm else bm)
		"rail_st", "rail_line":  # R335 RAIL335
			var rm: int = Mode.RAIL_ST if nm == "rail_st" else Mode.RAIL_LINE
			if _has_capital():
				RB.reset()
				_set_mode(Mode.NONE if mode == rm else rm)
			else:
				_set_mode(mode)
		"launch":
			if mode == Mode.TARGET and not strike.active:
				_set_mode(Mode.NONE)
			elif _has_capital():
				route_mode = false
				strike_open("jet" if plan_jet else "drone")  # v0.28 UX-STRIKE
			else:
				_set_mode(mode)
		"ship_cr":
			if mode == Mode.SHIP_CR:
				_set_mode(Mode.NONE)
			else:
				ship_cr_begin(null)
		"missile":
			if mode == Mode.MISSILE and not strike.active:
				_set_mode(Mode.NONE)
			elif _has_capital():
				route_mode = false
				strike_open("tel")  # v0.28 UX-STRIKE
			else:
				_set_mode(mode)
		"route":
			if mode == Mode.NONE and follow is Drone:
				route_mode = not route_mode  # taps add waypoints to the selected drone
				hud.show_toast("Тап по карте добавит точку маршрута" if route_mode else "Тап по карте задаёт новую цель")
			elif mode != Mode.TARGET:
				if not _has_capital():
					_set_mode(mode)
					return
				strike_open("jet" if plan_jet else "drone")  # v0.28 UX-STRIKE
				route_mode = true
			else:
				route_mode = not route_mode
			hud.set_key_pressed("route", route_mode)
		"follow":
			_cycle_follow()
		"plan_minus":
			plan_count = maxi(1, plan_count - 1)
			_plan_per_all()
		"plan_plus":
			if plan_list.is_empty():
				plan_count = mini(maxi(1, int(_plan_info.get("available", 1))), plan_count + 1)
			else:
				plan_count = mini(12, plan_count + 1)
				_plan_per_all()
		"plan_back":
			if mode == Mode.JET_KAB or mode == Mode.JET_CAS:
				_jet_back()
			else:
				_plan_back()
		"plan_launch":
			if mode == Mode.JET_KAB or mode == Mode.JET_CAS:
				_jet_fire()
			elif strike.active:
				strike_fire()  # v0.28 UX-STRIKE
			else:
				_do_launch()
		"plan_cancel":
			_set_mode(Mode.NONE)
		"ops_close":
			_deselect()
		"open_stats":
			hud.open_stats()
		"map_modes":
			hud.open_map_modes()
		"own_icons":
			world.show_own_icons = not world.show_own_icons
			hud.set_key_pressed("own_icons", world.show_own_icons)
			hud.show_toast(Loc.msg(Loc.mk("Значки построек: %s", [(Loc.t("вкл") if world.show_own_icons else Loc.t("выкл"))])))
			if hud.panel_kind == "map_modes" and hud.panel != null and is_instance_valid(hud.panel):
				hud.open_map_modes()
		"ores":
			hud.toggle_ores()
		"command":
			hud.open_command()
		"armies":
			hud.toggle_armies()
		"fleet":
			hud.open_navy_dock(null)  # v0.26 NAVY: the fleet dock
		"move_all":
			_set_mode(Mode.MOVE_ALL)
		_ when nm.begins_with("arm_all_set:"):
			var sa: int = int(nm.get_slice(":", 1))
			_sim("ops", "set_stance_all", [world.player.id, sa])
			hud.show_toast(Loc.msg(Loc.mk("Все армии: %s", [Loc.t(String(Operations.AutoCmd.STANCE_TITLES[sa]))])))
			hud._arm_sig = ""
		"arm_all":
			var sm: Dictionary = world.ops.command_summary(world.player.id)
			var cur: int = -1
			for a: Dictionary in sm.get("armies", []):
				cur = int(a["stance"]) if cur == -1 or cur == int(a["stance"]) else -2
			var nx: int = 1 if cur < 0 else (cur + 1) % 3
			_sim("ops", "set_stance_all", [world.player.id, nx])
			hud.show_toast(Loc.msg(Loc.mk("Все армии: %s", [Loc.t(String(Operations.AutoCmd.STANCE_TITLES[nx]))])))
			hud._arm_sig = ""
		_ when nm.begins_with("arm_sel:"):
			var aid: int = int(nm.get_slice(":", 1))
			if aid >= 0 and aid < world.mil.facilities.size():
				var af: Facility = world.mil.facilities[aid]
				_set_mode(Mode.NONE)
				_deselect()
				if hud.get("army_ux") != null and preload("res://game/army_groups.gd").army_alive(world, af):
					hud.army_ux.open_army(af.id)  # v0.30.3 ARMUX303
					return
				selected_fac = af
				army_view = true  # v0.30.3 ARMUX303: a dock row = the army card
				cam_lock = false
				var sum := Vector2.ZERO
				var cnt: int = 0
				for u: Unit in world.army.units:
					if u.home == af and u.alive():
						sum += u.pos
						cnt += 1
				cam.center_on(sum / cnt if cnt > 0 else af.center_px())
				_focus = {"fid": af.id, "n": 3}  # CRITIC303 #1: then out from under the card
				hud._arm_sig = ""
		"auto_refill":
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				var arf: Facility = selected_fac
				_sim("army", "set_auto_refill", [arf, not bool(arf.get("auto_refill"))], func(r: Variant) -> void:
					hud.show_toast(_why(r) if _why(r) != "" else String(world.army.refill_status(arf))))
		"build_pick":
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				hud.open_builds(selected_fac)
		"army_trench_in", "army_trench_out":  # v0.30.3 ARMUX303: the army card's В ОКОПЫ / ИЗ ОКОПОВ (nearest free places)
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				var tf: Facility = selected_fac
				var tin: bool = nm == "army_trench_in"
				NetSession.sim("", "cmd_static", [world.player, "groups", "trench_in_fids" if tin else "trench_out_fids", [PackedInt32Array([tf.id]), "Армия №%d" % tf.army_no]], func(r: Variant) -> void:
					var tr: Dictionary = r if r is Dictionary else {}
					if String(tr.get("why", "")) != "":
						hud.show_toast(String(tr["why"]))
						UiKit.snd("ui_error")
					else:
						UiKit.snd("ui_select"))
		"army_group":  # v0.30.3 ARMUX303: the army card's ГРУППА: the АРМИЯ dock on its group (or «без группы» to add it)
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS and hud.get("army_dock") != null:
				var gf2: Facility = selected_fac
				_deselect()
				hud.army_dock.open_group_card(gf2.group_id if gf2.group_id >= 0 else -2, gf2.id)
		"army_barracks":  # v0.30.3 ARMUX303: from the army card to its building (builds, refill, demolish)
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				army_view = false
				cam_lock = false
				UiKit.snd("ui_select")
		"army_card":  # v0.30.3 ARMUX303: from the barracks card to its army
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				army_view = true
				cam_lock = false
				UiKit.snd("ui_select")
		"garrison":
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				var gb: Facility = selected_fac
				garrison_from = gb
				_set_mode(Mode.GARRISON)
		"plan_toggle":
			Hud.plan_closed = not Hud.plan_closed
			hud.open_economy()
		"economy":
			hud.open_economy()
		_ when nm.begins_with("plan_go:"):
			_plan_go(nm.get_slice(":", 1))
		_ when nm.begins_with("fac_go:") or nm.begins_with("dep_go:"):
			_res_go(nm)  # R332 ECONUI: a resource sheet row -> camera + card
		"prot:net", "prot:conc":
			if selected_fac != null and world.get("protect") != null:
				var pw: String = nm.substr(5)
				var pf: Facility = selected_fac
				var pinf: Dictionary = world.protect.info(pf)
				var broken_p: bool = String(pinf[pw + "_state"]) in ["torn", "broken"]
				_sim("protect", "repair" if broken_p else "upgrade", [pf, pw, world.player], func(r: Variant) -> void:
					if _why(r) != "":
						hud.show_toast(_why(r)))  # success toasts come from Protect itself
		"fac_halt":
			if selected_fac != null and world.mil.has_method("set_halted"):
				var hf: Facility = selected_fac
				_sim("mil", "set_halted", [hf, not bool(hf.get("halted"))], func(r: Variant) -> void:
					hud.show_toast(_why(r) if _why(r) != "" else ("Производство остановлено" if bool(hf.get("halted")) else "Производство запущено")))
		"stance_cycle":
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				var ns: int = (world.ops.stance_of(selected_fac) + 1) % 3
				_sim("ops", "set_stance", [selected_fac, ns], func(r: Variant) -> void:
					hud.show_toast(_why(r) if _why(r) != "" else Loc.msg(Loc.mk("Армия: %s", [Loc.t(String(Operations.AutoCmd.STANCE_TITLES[ns]))]))))
		"cc_auto_orders":
			_sim("ops", "set_auto_orders", [world.player.id, not world.ops.auto_orders_of(world.player.id)], func(_r: Variant) -> void: hud.open_command())
		"cc_auto_strike":
			_sim("mil", "set_auto_strike", [world.player.id, (world.mil.auto_strike_of(world.player.id) + 1) % 3], func(_r: Variant) -> void: hud.open_command())
		"cc_auto_kab":
			_sim("mil", "set_auto_kab", [world.player.id, not world.mil.auto_kab_of(world.player.id)], func(_r: Variant) -> void: hud.open_command())
		"smart_toggle", "cc_smart":
			if world.player != null and world.mil.has_method("set_smart"):
				_sim("mil", "set_smart", [world.player.id, not world.mil.smart_of(world.player.id)])
				_danger_t = 0.0
				if hud.panel_kind == "command":
					hud.open_command()
		"cc_auto_drones":
			_sim("mil", "set_auto_drones", [world.player.id, not world.mil.auto_drones_of(world.player.id)], func(_r: Variant) -> void: hud.open_command())
		_ when nm.begins_with("cc_"):
			var cp: PackedStringArray = nm.split(":")
			match cp[0]:
				"cc_go":
					var gf: Facility = world.mil.facilities[int(cp[1])] if int(cp[1]) < world.mil.facilities.size() else null
					if gf != null:
						hud.close_panel()
						_deselect()
						selected_fac = gf
						cam_lock = false
						cam.center_on(gf.center_px())
				"cc_pos":
					hud.close_panel()
					cam_lock = false
					cam.center_on(Vector2(float(cp[1]), float(cp[2])))
				"cc_st":
					var sf: Facility = world.mil.facilities[int(cp[1])] if int(cp[1]) < world.mil.facilities.size() else null
					if sf != null:
						_sim("ops", "set_stance", [sf, int(cp[2])], func(r: Variant) -> void:
							if _why(r) != "":
								hud.show_toast(_why(r)))
					hud.open_command()
				"cc_all":
					_sim("ops", "set_stance_all", [world.player.id, int(cp[1])])
					hud.show_toast(Loc.msg(Loc.mk("Все армии: %s", [Loc.t(String(Operations.AutoCmd.STANCE_TITLES[int(cp[1])]))])))
					hud.open_command()
		"ult_send":
			var u: Dictionary = hud.ult
			var opts2: Array = world.diplo.demand_options(world.player.id, int(u["to"]))
			var prm: Dictionary = {"conseq": String(u["conseq"])}
			var kind: String = String(u["kind"])
			if int(u.get("opt", -1)) >= 0 and int(u["opt"]) < opts2.size():
				var o2: Dictionary = opts2[int(u["opt"])]
				kind = String(o2["kind"])
				prm.merge(o2.get("params", {}), true)
			else:
				prm["n"] = int(u["n"])
				if kind == "res":
					prm["res"] = String(u["res"])
			var uc: Country = world.country_by_id(int(u["to"]))
			_sim("diplo", "demand", [world.player.id, int(u["to"]), kind, prm], func(r: Variant) -> void:
				var whyu: String = _why(r)
				hud.show_toast(whyu if whyu != "" else Loc.msg(Loc.mk("%s уступает: требование выполнено", [(Loc.name(uc.name) if uc != null else "")])))  # R340
				UiKit.snd("ui_error" if whyu != "" else "ui_money")
				hud.open_diplomacy())
		"pend_ok":
			_pend_ok()
		"pend_cancel":
			_pend_cancel()
		"operation":
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				var obf: Facility = selected_fac
				_set_mode(Mode.OPERATION)
				op_from = obf
		"op_retreat":
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				_sim("ops", "start", [selected_fac, 2, Vector2.ZERO], func(r: Variant) -> void: hud.show_toast(_or_ok(_why(r), "Отход к казармам")))
		"op_cancel":
			if selected_fac != null:
				_sim("ops", "cancel", [selected_fac])
				hud.show_toast("Приказ отменён")
		"order_0", "order_1", "order_2":
			var ok2: int = int(nm.right(1))
			if world.player == null or not _has_capital():
				return
			var cdl: float = world.ops.cooldown_left(world.player.id, ok2)
			if mode == Mode.ORDER and order_kind == ok2:
				_set_mode(Mode.NONE)
			elif cdl > 0.0:
				hud.show_toast(Loc.msg(Loc.mk("%s: ещё %d с", [Loc.t(String(world.ops.order_info(ok2).get("name", ""))), ceili(cdl)])))
			else:
				order_kind = ok2
				_set_mode(Mode.ORDER)
		"battle_cam":
			_battle_cam()
		"prompt_go":
			if world.ops.has_method("prompt_accepted"):
				_sim("ops", "prompt_accepted", [hud.prompt_data])
			_prompt_act(hud.prompt_data)
			hud.hide_prompt()
		"prompt_no":
			if world.ops.has_method("dismiss_prompt"):
				_sim("ops", "dismiss_prompt", [hud.prompt_data])
			hud.hide_prompt()
		"recon":
			if world.get("recon") != null and _has_capital():
				if mode == Mode.RECON:
					_set_mode(Mode.NONE)
				else:
					var rw: String = world.recon.can_launch(world.player.id)
					if rw != "":
						hud.show_toast(rw)
					else:
						_set_mode(Mode.RECON)
		"recon_recall":
			var rd: Variant = world.selected_drone() if world.has_method("selected_drone") else null
			if rd != null:
				_sim("", "cmd_recall", [world.player.id, int(rd.get("id"))])
		"satellite":
			if net.in_match:
				hud.show_toast("Спутник в сетевой партии пока недоступен")  # NET: Vision is the local player's
				return
			if world.get("vision") == null or not world.vision.has_method("reveal"):
				hud.show_toast("Спутниковая разведка недоступна")
			elif _has_capital():
				_set_mode(Mode.NONE if mode == Mode.SATELLITE else Mode.SATELLITE)
		_ when nm.begins_with("map_mode:"):
			world.set_map_mode(int(nm.get_slice(":", 1)))
		_ when nm.begins_with("goto_dep:"):
			var gp: PackedStringArray = nm.split(":")
			var gc := Vector2i(int(gp[1]), int(gp[2]))
			_deselect()
			_set_mode(Mode.NONE)
			cam.center_on(Vector2(gc * GameWorld.CELL) + Vector2(0, 40))
			if cam.zoom.x < 1.5:
				cam.set_zoom_at(MapCamera.zk(1.5), cam.view_size() * 0.5)  # R347
			selected_dep = world.econ.deposit_at(gc, 1)
		"inventory":
			hud.open_inventory()
		"cancel_select":
			_set_mode(Mode.NONE)
			_deselect()
			_clear_plan()
			hud.hide_ops()
		"buy_bomber", "buy_fighter", "buy_heli", "buy_attack":
			if selected_fac != null:
				var t: int = {"buy_bomber": Aircraft.Type.BOMBER, "buy_fighter": Aircraft.Type.FIGHTER, "buy_heli": Aircraft.Type.HELI, "buy_attack": Aircraft.Type.ATTACK}[nm]
				_sim("mil.air", "buy", [selected_fac, t, world.player], func(r: Variant) -> void:
					hud.show_toast(_why(r) if _why(r) != "" else Loc.msg(Loc.mk("Куплен: %s", [Loc.t(String(Air.SPEC[t]["name"]))]))))
		"air_land":
			if follow is Aircraft:
				_sim("mil.air", "order_land", [follow])
				hud.show_toast("Возврат на базу")
		"air_patrol":
			if follow is Aircraft:
				air_patrol_pending = true
				hud.show_toast("Тапните центр зоны патрулирования")
		"air_upgrade":
			if follow is Aircraft:
				_sim("mil.air", "upgrade", [follow, world.player], func(r: Variant) -> void:
					hud.show_toast(_why(r) if _why(r) != "" else "Истребитель улучшен"))
		"air_cr":
			if follow is Aircraft:
				strike_open("bomber")  # v0.28 UX-STRIKE: КР from aircraft in the one strike panel
		"air_kab", "air_cas", "jet_kab", "jet_cas":
			# R316: attack jet — card keys (the followed jet) and the side-panel keys (best ready jet).
			# R316: the bomber КАБ payload (air_payload / launch_kab) is gone; КАБ fly on attack jets.
			var jm: int = Mode.JET_KAB if nm.ends_with("kab") else Mode.JET_CAS
			if nm.begins_with("jet_") and mode == jm:
				_set_mode(Mode.NONE)
			else:
				_jet_begin(follow as Aircraft if nm.begins_with("air_") and follow is Aircraft else null, jm)
		_ when nm.begins_with("dip:"):
			_dip_action(nm)
		_ when nm.begins_with("dipx:"):
			var xid: int = int(nm.get_slice(":", 1))
			hud.dip_open = -1 if hud.dip_open == xid else xid
			hud._dip_scroll_to = hud.dip_open
			hud.open_diplomacy()
		_ when nm.begins_with("warask:"):
			hud.war_arm = int(nm.get_slice(":", 1))
			hud.war_arm_until = Time.get_ticks_msec() + 4000
			hud.open_diplomacy()
		"demand_arrived":
			if _speed_i > 0 and not _paused:
				_speed_i = 0
				_apply_speed()
				hud.show_toast("Ультиматум: скорость x1 — ответьте в окне дипломатии")
		_ when nm.begins_with("treaty:") or nm.begins_with("untreaty:") or nm.begins_with("embargo:") or nm.begins_with("aid:") or nm.begins_with("dem:") or nm.begins_with("pend:"):
			_dip11(nm)
		_ when nm.begins_with("offer:"):
			var parts: PackedStringArray = nm.split(":")
			_sim("diplo", "answer_as", [world.player.id, "o%d" % int(parts[1]), "accept" if parts[2] == "1" else "refuse"], func(_r: Variant) -> void:
				hud.open_diplomacy())  # NET 29: a command (was answer_offer_from on this device only)
		_ when nm.begins_with("trade:"):
			var tp: PackedStringArray = nm.split(":")
			var t_m: String = ("propose_treaty" if tp[2] == "1" else "cancel_treaty") if world.diplo.has_method("propose_treaty") else "set_trade"
			var t_a: Array = [world.player.id, int(tp[1]), tp[2] == "1"] if t_m == "set_trade" else [world.player.id, int(tp[1]), "trade"]
			_sim("econ" if t_m == "set_trade" else "diplo", t_m, t_a, func(r: Variant) -> void:
				if _why(r) != "":
					hud.show_toast(_why(r))
				hud.open_trade())
		_ when nm.begins_with("build_"):
			if selected_fac != null and selected_fac.kind == Facility.Kind.BARRACKS:
				_sim("army", "set_build", [selected_fac, nm.substr(6)], func(r: Variant) -> void:
					if _why(r) != "":
						hud.show_toast(_why(r))
					elif hud.panel_kind == "builds":
						hud.close_panel()
						hud.show_toast("Сборка армии изменена"))
		_ when nm.begins_with("doc:"):
			var p: Country = world.player
			if p != null:
				match nm:
					"doc:fpv":
						_sim("", "cmd_field", [p, "doctrine_fpv", not p.doctrine_fpv])
					"doc:assault":
						_sim("", "cmd_field", [p, "doctrine_assault", not p.doctrine_assault])
					"doc:support":
						_sim("army", "toggle_support", [p.id])
					"doc:defend":
						_sim("", "cmd_field", [p, "army_defend", not p.army_defend], func(_r: Variant) -> void: hud.set_key_pressed("defend", p.army_defend))
			hud.open_doctrine()
		"fac_upgrade":
			if selected_fac != null and world.econ.has_method("upgrade"):
				var uf: Facility = selected_fac
				_sim("econ", "upgrade", [uf, world.player], func(r: Variant) -> void:
					var whyu: String = _why(r)
					hud.show_toast(whyu if whyu != "" else (String(world.econ.call("upgrade_toast", uf)) if world.econ.has_method("upgrade_toast") else Loc.msg(Loc.mk("Улучшено: %s, уровень %d", [Loc.t(Military.title_of(uf.kind)), int(world.econ.call("level_of", uf))]))))  # v0.27 ECON27
					UiKit.snd("ui_error" if whyu != "" else "ui_build"))
		"intel_strike":
			# Intel card → missile strike plan aimed at the last known position.
			if selected_intel != null:
				var tp: Vector2 = world.vision.last_pos(selected_intel)
				_deselect()
				route_mode = false
				strike_open("tel")  # v0.28 UX-STRIKE: the intel point joins the ОТРК points
				if plan_has_target:
					plan_list.append({"pos": plan_target, "n": plan_count, "wps": plan_wps.duplicate()})
					plan_wps.clear()
					plan_count = 1
				plan_target = tp
				plan_has_target = true
				cam.center_on(tp)
		"dep_build":
			_dep_build()
		"repair_all":
			if world.player != null:
				_sim("mil", "restore_all", [world.player], func(r: Variant) -> void:
					var rr: Array = r if r is Array else [0, 0, 0]
					var rwhy: String = String(rr[3]) if rr.size() > 3 else ""  # v0.28: the exact reason (fire / money)
					if int(rr[0]) > 0:
						hud.show_toast(Loc.msg(Loc.mk("Ремонт: %d объект(ов), −%d%s", [int(rr[0]), int(rr[1]), (Loc.t(" · не начато: ") + rwhy) if rwhy != "" else ""])))
						UiKit.snd("ui_build")
					else:
						hud.show_toast((Loc.t("Ремонт не начат: ") + rwhy) if rwhy != "" else "Ремонтировать нечего")
						UiKit.snd("ui_error"))
		"fac_restore":
			if selected_fac != null:
				_sim("mil", "restore", [selected_fac, world.player])
		"fac_demolish":
			# v0.25 DEMOLISH: always through the confirm card (destructive), whatever confirm_actions says.
			if selected_fac != null and world.player != null and world.mil.has_method("demolish"):
				var whyd: String = world.mil.demolish_why(world.player, selected_fac)
				if whyd != "":
					hud.show_toast(whyd)
					UiKit.snd("ui_error")
				else:
					_pend = {"kind": "demolish", "fac": selected_fac}
					_show_pend()
		"plan_reset":
			_clear_plan()
			hud.show_toast("Цели сброшены")
		"plan_standing":
			if world.mil.has_method("set_standing"):
				var on: bool = not _standing_on()
				if on and not plan_has_target:
					hud.show_toast("Сначала отметьте цели")
				else:
					_sim("mil", "set_standing", [world.player.id, _plan_targets() if on else [], plan_jet, on, 1])
					hud.show_toast("Автопуск: каждый новый дрон летит по этим целям" if on else "Автопуск выключен")
		"plan_kind_0", "plan_kind_1":
			plan_jet = nm == "plan_kind_1"
			plan_count = 1
		"dtype_0", "dtype_1":
			if selected_fac != null and selected_fac.kind == Facility.Kind.DRONE_FACTORY:
				_sim("", "cmd_field", [selected_fac, "prod_type", int(nm.substr(6))])
		_ when nm.begins_with("mtype_"):  # R316: mtype_5 = КАБ
			if selected_fac != null:
				_sim("mil", "set_prod_type", [selected_fac, int(nm.substr(6))])
		"mod_ramp", "mod_runway", "mod_store", "mod_solar", "mod_crane":
			if selected_fac != null and world.mil.alive(selected_fac):
				module_port = selected_fac
				module_kind = {"mod_ramp": Facility.Kind.DP_RAMP, "mod_runway": Facility.Kind.DP_RUNWAY, "mod_store": Facility.Kind.DP_STORE, "mod_solar": Facility.Kind.SOLAR, "mod_crane": Facility.Kind.PORT_CRANE}[nm]
				_set_mode(Mode.MODULE)
		"expedition":
			if selected_fac != null and selected_fac.kind == Facility.Kind.PORT and world.get("naval") != null:
				var ready: String = String(world.naval.port_info(selected_fac).get("ready", ""))
				if ready != "":
					hud.show_toast(ready)
					UiKit.snd("ui_error")
					if bool(world.naval.port_info(selected_fac).get("short_res", false)):  # R333: a flag, not the words
						_offer_buy(Naval.EXP_COST)
				else:
					exp_port = selected_fac
					_deselect()
					_set_mode(Mode.EXPEDITION)
		"to_boats":
			if selected_fac != null and world.get("naval") != null:
				var li: Dictionary = world.naval.landing_info(selected_fac)
				if li.get("pos") is Vector2:
					cam_lock = false
					cam.center_on(li["pos"])
		"port_export":
			if world.player != null:
				_sim("econ", "set_export", [world.player, world.econ.export_off.has(world.player.id)])
		"dip_best", "upg_best", "net_best", "dp_ramp":
			_plan_action(nm)
		_ when nm.begins_with("mkt_why:"):
			hud.show_toast(nm.substr(8))
			UiKit.snd("ui_error")
			if hud.panel_kind == "trade":
				hud.trade_status(Loc.t("НЕ ВЫШЛО: %s") % Loc.t(nm.substr(8)), false)  # R340
				hud.open_trade()
		_ when nm.begins_with("mkt:"):
			# mkt:<buy|sell>:<partner id, 0 = foreign market>:<res>:<n>
			var mp: PackedStringArray = nm.split(":")
			var other: Country = world.country_by_id(int(mp[2])) if int(mp[2]) > 0 else null
			# v0.30.6 MKT306: one command for both directions (NetSession.ALLOWED "econ.market_order"); the
			# answer is this device's only: what / how many / price / how it travels / when it arrives
			_sim("econ", "market_order", [world.player, other, mp[3], int(mp[4]), mp[1] == "buy"], func(r: Variant) -> void:
				var whym: String = _why(r)
				var ld: Dictionary = world.econ.last_deal
				if whym != "" or ld.is_empty():
					var tmsg: String = whym if whym != "" else (Loc.t("Сделка оформлена: %s") % Loc.t(String(Economy.RES_NAMES.get(mp[3], mp[3]))).to_lower())  # R340
					hud.show_toast(tmsg)
					hud.trade_status((Loc.t("НЕ ВЫШЛО: %s") % Loc.t(whym)) if whym != "" else tmsg, whym == "")  # R340
				else:
					var rn: String = String(Economy.RES_NAMES.get(String(ld["res"]), "")).to_lower()
					var how: String = String({"truck": "грузовиком", "rail": "поездом", "ship": "кораблём", "import": "кораблём", "export": "кораблём", "queue": "ближайшим кораблём"}.get(String(ld["mode"]), ""))
					var txt: String = ""
					if String(ld["kind"]) == "buy":
						txt = Loc.t("КУПЛЕНО: %s ×%d за %d (%s) · поступит, когда приедет %s, %s") % [rn, int(ld["n"]), int(ld["price"]), String(ld["partner"]), how, Economy.eta_text(float(ld["eta"]))]
					else:
						txt = Loc.t("ПРОДАНО: %s ×%d (%s) за %d · оплата при доставке %s, %s") % [rn, int(ld["n"]), String(ld["partner"]), int(ld["price"]), how, Economy.eta_text(float(ld["eta"]))]
					var eta_s: String = Economy.eta_text(float(ld["eta"]))
					if String(ld["kind"]) == "buy":
						hud.trade_status(Loc.t("КУПЛЕНО: %s ×%d за %d · в пути %s") % [rn, int(ld["n"]), int(ld["price"]), eta_s], true)
					else:
						hud.trade_status(Loc.t("ПРОДАНО: %s ×%d за %d · в пути %s") % [rn, int(ld["n"]), int(ld["price"]), eta_s], true)
					if hud.lane != null and is_instance_valid(hud.lane):
						hud.lane.call("push", "msg", {"title": txt, "icon": hud._res_icon(String(ld["res"])), "ttl": 5.0})
					else:
						hud.show_toast(txt)
				UiKit.snd("ui_error" if whym != "" else "ui_money")
				if hud.panel_kind == "trade":
					hud.open_trade())
		_ when nm.begins_with("req:"):
			var rp: PackedStringArray = nm.split(":")
			if rp[1] == "ok":
				_sim("econ", "accept_request", [world.player, int(rp[2])], func(r: Variant) -> void:  # R335 FIX335: answering country
					hud.show_toast(_why(r) if _why(r) != "" else "Сделка принята"))
			else:
				_sim("econ", "decline_request", [world.player, int(rp[2])])
			hud.open_trade()


func _unhandled_input(event: InputEvent) -> void:
	if in_menu:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var kc: int = (event as InputEventKey).keycode
		if not menus.is_open() and _pc_army() != null and bool(_pc_army().key(event as InputEventKey)):
			return
		if kc == KEY_ESCAPE or kc == KEY_BACK:
			if not menus.is_open() and _army_back():
				return
			if not menus.is_open() and pc_cancel_mode():
				return  # PC port: Esc leaves a build / placement mode first
			if menus.is_open():
				_on_menu("resume")
			else:
				_open_pause()
			return
		_debug_key(kc)
		return
	if event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		cam.set_zoom_at(cam.zoom.x * mg.factor, mg.position)
		_on_zoom(cam.zoom.x)
		return
	if event is InputEventPanGesture:
		var pg := event as InputEventPanGesture
		cam.pan_screen(-pg.delta * 8.0)
		cam_lock = false
		return
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			# Index 0 = the first finger of a new gesture: forget fingers whose release the UI ate
			# (a stale entry made every later touch a "pinch" — the zoom-on-any-action bug).
			if st.index == 0:
				_touches.clear()
				_pinch_d = 0.0
				_pinch_mid = Vector2.INF
			_touches[st.index] = st.position
			if _touches.size() == 1:
				_begin_press(st.position)
			else:
				_drag_pt = -2
				_dtz = false
				_pinch_z0 = cam.zoom.x
			_pinch_d = 0.0
		else:
			var was_single: bool = _touches.size() == 1
			_touches.erase(st.index)
			if was_single:
				_release_press(st.position)
			else:
				_end_drag()
			if _touches.size() < 2 and _pinch_d > 0.0:
				# v0.22: glide to the pixel step around the fingers (was an instant jump about the
				# screen centre, which yanked the map sideways and often undid the pinch).
				var zf: Vector2 = _pinch_mid if _pinch_mid.is_finite() else cam.view_size() * 0.5
				cam.settle_zoom(zf, signi(int(signf(cam.zoom.x - _pinch_z0))))
				_pinch_d = 0.0
			if _touches.size() < 2:
				_pinch_mid = Vector2.INF
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_touches[sd.index] = sd.position
		if _touches.size() == 1:
			if _dtz:
				_dtz_drag(sd.position)
			elif _moved or sd.position.distance_to(_press_pos) > 6.0:
				_moved = true
				_drag_or_pan(sd.position, sd.relative)
		elif _touches.size() >= 2:
			var pts: Array = _touches.values()
			var a: Vector2 = pts[0]
			var b: Vector2 = pts[1]
			var d: float = a.distance_to(b)
			var mid: Vector2 = (a + b) * 0.5
			if _pinch_d > 0.0 and d > 1.0:
				cam.set_zoom_at(cam.zoom.x * d / _pinch_d, mid)
			if _pinch_mid != Vector2.INF:
				cam.pan_screen(mid - _pinch_mid)  # two-finger drag moves the map (needed while drawing lines)
				cam_lock = false
			_pinch_mid = mid
			_pinch_d = d
			_moved = true
			if not line_cells.is_empty():
				line_cells.clear()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.device == InputEvent.DEVICE_ID_EMULATION:
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam.step_zoom(1, mb.position)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam.step_zoom(-1, mb.position)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if _pc_army() != null and bool(_pc_army().lmb(mb)):
				_mouse_down = false
				return
			if mb.pressed:
				_mouse_down = true
				_begin_press(mb.position)
			else:
				_mouse_down = false
				_release_press(mb.position)
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_pc_pan = mb.pressed  # PC port: right / middle drag moves the map
			if mb.button_index == MOUSE_BUTTON_RIGHT:
				# PC port: a right click that did not move the map is an order (Hearts of Iron style)
				if mb.pressed:
					_rmb_at = mb.position
					_rmb_path = 0.0
				elif _rmb_at.is_finite() and _rmb_path < 6.0 and _pc_army() != null:
					_pc_army().rmb_click(mb.position)
				if not mb.pressed:
					_rmb_at = Vector2.INF
	elif event is InputEventMouseMotion:
		var mm: = event as InputEventMouseMotion
		if mm.device != InputEvent.DEVICE_ID_EMULATION and _pc_army() != null and bool(_pc_army().mouse_move(mm.position)):
			return
		if mm.device != InputEvent.DEVICE_ID_EMULATION and _pc_pan and not _mouse_down:
			_rmb_path += mm.relative.length()
			if (mm.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE)) == 0:
				_pc_pan = false
				return
			if cam_lock:
				cam_lock = false
				hud.set_key_pressed("follow", false)
			cam.pan_screen(mm.relative)
			return
		if mm.device == InputEvent.DEVICE_ID_EMULATION or not _mouse_down:
			return
		if _dtz:
			_dtz_drag(mm.position)
		elif _moved or mm.position.distance_to(_press_pos) > 6.0:
			_moved = true
			_drag_or_pan(mm.position, mm.relative)



var _pc_pan: bool = false
var _rmb_at: Vector2 = Vector2.INF
var _rmb_path: float = 0.0


func _pc_army() -> Object:
	var pa: Variant = hud.get("pc_army") if hud != null else null
	return pa as Object if pa != null and is_instance_valid(pa) else null


## Desktop / MCP test keys: -/= zoom, arrows pan, Space = tap at screen centre,
## 1 capital mode, 2 town mode, 3 strike mode, P pause, S speed, K next checkpoint,
## B strike next bridge, N next capital.
func _debug_key(k: int) -> void:
	if net.in_match and (k == KEY_3 or k == KEY_B):
		return  # NET 34: the test strike changes the world on this device only (critic)
	if not OS.is_debug_build() and (k == KEY_B or k == KEY_K):
		return  # PC port: developer keys (B = strike a bridge) are not for players
	var c: Vector2 = cam.view_size() * 0.5
	match k:
		KEY_MINUS:
			cam.step_zoom(-1, c)
		KEY_EQUAL:
			cam.step_zoom(1, c)
		KEY_LEFT:
			cam.pan_screen(Vector2(120, 0))
		KEY_RIGHT:
			cam.pan_screen(Vector2(-120, 0))
		KEY_UP:
			cam.pan_screen(Vector2(0, 120))
		KEY_DOWN:
			cam.pan_screen(Vector2(0, -120))
		KEY_SPACE:
			_tap(c)
		KEY_1:
			_set_mode(Mode.CAPITAL)
		KEY_2:
			_set_mode(Mode.TOWN)
		KEY_3:
			_set_mode(Mode.STRIKE)
		KEY_P:
			_on_action("pause")
		KEY_S:
			_on_action("speed_next")
		KEY_K:
			var keys: Array = world.checkpoints.keys()
			if not keys.is_empty():
				_kpp_i = (_kpp_i + 1) % keys.size()
				var cp: Dictionary = world.checkpoints[keys[_kpp_i]]
				var cc: Vector2i = cp["cell"]
				cam.set_zoom_at(MapCamera.zk(3.0), c)  # R347
				cam.center_on(Vector2(cc * GameWorld.CELL))
				var d: WorldData = world.data
				var row: String = ""
				for yy in range(cc.y - 2, cc.y + 3):
					for xx in range(cc.x - 2, cc.x + 3):
						row += str(d.get_owner_id(xx, yy))
					row += "|"
				print("[Debug] KPP %d/%d %s at %s owners %s flag=%s" % [_kpp_i + 1, keys.size(), keys[_kpp_i], cc, row, cp["flag"] != null])
		KEY_B:
			if not world.bridges.is_empty():
				_br_i = (_br_i + 1) % world.bridges.size()
				var br: Bridge = world.bridges[_br_i]
				var mid: Vector2i = br.cells[br.cells.size() / 2]
				cam.set_zoom_at(MapCamera.zk(3.0), c)  # R347
				cam.center_on(Vector2(mid * GameWorld.CELL))
				world.strike(mid)
				print("[Debug] strike bridge %d (%d cells) at %s" % [br.id, br.cells.size(), mid])
		KEY_N:
			var caps: Array = []
			for ct: City in world.cities:
				if ct.kind == City.Kind.CAPITAL:
					caps.append(ct)
			if not caps.is_empty():
				_cap_i = (_cap_i + 1) % caps.size()
				cam.center_on(Vector2((caps[_cap_i] as City).center * GameWorld.CELL))


## «ПОКАЗАТЬ» / «ИСПРАВИТЬ»: camera to the best site for `key`, enter its build mode and put the
## confirm mark there, so one tap on ✓ builds it.
func _plan_go(key: String) -> void:
	if key == "" or world.player == null:
		return
	hud.close_panel()
	if not BUILD_KEYS.has(key) and key != "town" and key != "capital":
		_on_action(key)  # trade / diplomacy / economy windows
		return
	var pos: Vector2 = Vector2.INF
	if world.get("guide") != null and world.guide.has_method("best_site"):
		pos = world.guide.best_site(world.player, key)
	_deselect()
	var want: int = int(BUILD_KEYS[key]) if BUILD_KEYS.has(key) else (Mode.TOWN if key == "town" else Mode.CAPITAL)
	if mode != want:
		_on_action(key)
	if pos.is_finite():
		cam_lock = false
		cam.center_on(pos)
		if mode == want and _confirm_mode(mode):
			_tap(cam.world_to_screen(pos))
	else:
		hud.show_toast("Подходящего места не видно — выберите сами")


## Development-plan steps that are not a build: open the right window / card for the player.
func _plan_action(nm: String) -> void:
	var p: Country = world.player
	var g = world.get("guide")
	if p == null or g == null:
		return
	match nm:
		"dip_best":
			var cid: int = int(g.best_neighbour(p)) if g.has_method("best_neighbour") else -1
			hud.dip_open = cid
			hud._dip_scroll_to = cid
			hud.dip_hint_treaty = "trade"
			hud.open_diplomacy()
		"upg_best", "net_best", "dp_ramp":
			var f: Facility = null
			if nm == "upg_best" and g.has_method("upgrade_target"):
				f = g.upgrade_target(p)
			elif nm == "net_best" and g.has_method("net_target"):
				f = g.net_target(p)
			elif nm == "dp_ramp" and g.has_method("ramp_port"):
				f = g.ramp_port(p)
			if f == null:
				hud.show_toast("Пока не на чем: постройте объект")
				return
			_deselect()
			selected_fac = f
			cam_lock = false
			cam.center_on(f.center_px())
			if nm == "dp_ramp":
				_on_action("mod_ramp")
			else:
				hud.show_toast("Нажмите «СЕТКА» в карточке" if nm == "net_best" else "Улучшение — кнопка «УР» в карточке")


## NetSession._start on every peer: the same world from the host's settings, one country per
## human, then each places a capital (NetSession «cap» commands).
func net_begin(s: WorldSettings, humans: int, local_slot: int) -> void:
	hud.hide_prompt()
	menus.close()
	in_menu = false
	hud.visible = true
	_paused = false
	_speed_i = 0
	tutorial.stop()
	await start_world(s)
	world.mp_setup_humans(humans, local_slot, net.start_names, net.start_archs, net.start_flags)
	hud.set_net_mode(true)
	hud.refresh()
	_apply_speed()
	hud.show_toast("Мультиплеер: выберите место для столицы")


## After a resync snapshot was restored (NetSession._apply_snapshot). NET 29: the snapshot has no
## FrontPlan caches / timers and no staggered УДАР launches - every device drops them the same way.
func net_after_restore() -> void:
	(load("res://game/front_plan.gd") as GDScript).call("reset")  # FrontPlan has no class_name
	world.strike_net = null
	hud.set_net_mode(true)
	_apply_speed()
	hud.refresh()


## The network match is over for this device (left, host lost, kicked): back to the menu.
func net_match_closed() -> void:
	hud.set_net_mode(false)
	if not in_menu:
		await _main_menu()
	menus.show_mp()


## NET 31: the match speed changed (the host's decision): HUD + a toast with the reason (UX:
## a rise in АВТО only on the button; a drop at most once in 15 s; none for one's own event).
func _on_net_speed(old: int, new: int) -> void:
	_apply_speed()
	if _spick != null and is_instance_valid(_spick) and bool(_spick.get("is_open")):
		_spick.call("refresh_net")
	if not net.in_match:
		return
	var why: String = net.speed_why
	var me_name: String = world.player.name if world.player != null else ""
	if net.speed_why_prev == "start" and why != "start" and not _speed_hinted:
		_speed_hinted = true  # the guests never saw the setting
		if GameConfig.mp_speed == 2:
			hud.show_toast("УСКОРЕНИЕ ВЫКЛЮЧЕНО ХОСТОМ · ИГРА ИДЁТ x1")
		elif GameConfig.mp_speed == 1:
			hud.show_toast("АВТОУСКОРЕНИЕ · В ЗАТИШЬЕ ДО x3")
		else:
			hud.show_toast(Loc.t("УСКОРЕНИЕ ПО СОГЛАСИЮ · КНОПКА «СКОРОСТЬ»") + (Loc.msg(Loc.mk(" · ВСЕ ЗА x%d", [new])) if new > 1 else ""))
		return
	if old == new:
		return
	var t: String = Loc.t("СКОРОСТЬ x%d") % new
	if new > old:
		if GameConfig.mp_speed == 1:
			return
		t += Loc.t(" · ВСЕ ЗА") if why == "want" else ""
	else:
		var now: int = Time.get_ticks_msec()
		if GameConfig.mp_speed == 1 and now - _speed_toast_ms < 15000:
			return
		_speed_toast_ms = now
		if why == "lag":
			t += Loc.t(" · ВАШЕ УСТРОЙСТВО НЕ УСПЕВАЕТ") if net.speed_who == NetConfig.nick() else (Loc.t(" · НЕ УСПЕВАЕТ %s") % net.speed_who.to_upper() if net.speed_who != "" else "")
		elif why == "want":
			t += Loc.t(" · ВАШ ВЫБОР") if net.my_want == new else Loc.t(" · ВЫБОР %s") % net.speed_who.to_upper()
		elif why.begins_with("auto:"):
			if net.speed_who == me_name:
				return  # one's own event has its own notification
			t += " · %s%s" % [why.substr(5), (Loc.t(" У %s") % net.speed_who.to_upper()) if net.speed_who != "" else ""]
	hud.show_toast(t)


## NET 32: connected back to a running match: the snapshot comes next (it builds the world).
func net_rejoin_wait() -> void:
	menus.close()
	loading.show_screen("Возвращаемся в партию...")
	hud.set_net_mode(true)


func _on_net_player_back(nick: String) -> void:
	hud.show_toast(Loc.msg(Loc.mk("%s СНОВА В ПАРТИИ", [nick.to_upper()])))
	UiKit.snd("ui_select")


## A toast from the network session (UI only).
func net_toast(t: String) -> void:
	hud.show_toast(t)


func _net_banner_tick(delta: float) -> void:
	if net == null:
		return
	if not net.speed_changed.is_connected(_on_net_speed):
		net.speed_changed.connect(_on_net_speed)
	if not net.player_left.is_connected(_on_net_player_left):
		net.player_left.connect(_on_net_player_left)
	if not net.player_back.is_connected(_on_net_player_back):
		net.player_back.connect(_on_net_player_back)
	var st: Dictionary = net.plate() if net.in_match else {}
	var key: String = String(st.get("key", ""))
	if key != _net_last_key:
		if _net_last_key == "lost" and key == "" and net.in_match:
			hud.show_toast("СВЯЗЬ ВОССТАНОВЛЕНА")
		_net_last_key = key
	if _net_banner == null:
		if st.is_empty():
			return
		_net_banner = MpKit.Plate.new()
		hud.root.add_child(_net_banner)
	var w: float = minf(380.0, hud.root.size.x - 16.0)
	_net_banner.size = Vector2(w, 0.0)  # height: the content (a long under-line wraps)
	_net_banner.position = Vector2((hud.root.size.x - w) * 0.5, hud.top_col.position.y + hud.top_col.size.y + 4.0)
	_net_banner.set_state(st, delta)
	var extra: float = _resume_btn_tick(key == "resume" and net.is_host and _net_banner.visible)
	if hud.lane != null and is_instance_valid(hud.lane):  # the notification lane goes under the plate (UX: no overlap)
		hud.lane.set("push_y", (_net_banner.size.y + 4.0 + extra) if _net_banner.visible else 0.0)


## NET 35 (UX): «ИГРАТЬ БЕЗ НИХ» — a green 150 x 44 button under the «ЖДЁМ ИГРОКОВ» plate, right edge
## (the host only; the AI plays who is not back, they can still return). Returns the height it takes.
func _resume_btn_tick(show: bool) -> float:
	if not show:
		if _resume_btn != null and is_instance_valid(_resume_btn):
			_resume_btn.queue_free()
		_resume_btn = null
		return 0.0
	if _resume_btn == null or not is_instance_valid(_resume_btn):
		_resume_btn = UiKit.big("ИГРАТЬ БЕЗ НИХ", "green", "", 44.0, 11)
		_resume_btn.custom_minimum_size = Vector2(150, 44)
		_resume_btn.pressed.connect(func() -> void:
			UiKit.snd("ui_select")
			net.resume_go(false))
		hud.root.add_child(_resume_btn)
	_resume_btn.size = Vector2(150, 44)
	_resume_btn.position = Vector2(_net_banner.position.x + _net_banner.size.x - 150.0, _net_banner.position.y + _net_banner.size.y + 4.0)
	return 48.0


func _on_net_player_left(nick: String, lost: bool = true) -> void:
	hud.show_toast((Loc.t("У %s ПРОПАЛА СВЯЗЬ · СТРАНУ ВЕДЁТ ИИ") if lost else Loc.t("%s ВЫШЕЛ · СТРАНУ ВЕДЁТ ИИ")) % nick.to_upper())  # R340
	UiKit.snd("ui_select")
