extends SceneTree
## CPU simulation timings, not GPU FPS. Use --load to compare the same late-game state.

class TimedWorld:
	extends GameWorld
	var totals: Dictionary = {}
	var peaks: Dictionary = {}
	func _pf(nm: String) -> void:
		var now: int = Time.get_ticks_usec()
		var us: int = now - _pu
		totals[nm] = int(totals.get(nm, 0)) + us
		peaks[nm] = maxi(int(peaks.get(nm, 0)), us)
		_pu = now

class Host:
	extends Node
	var world: GameWorld
	var cam: MapCamera
	var _speed_i: int = 0
	var _paused: bool = false
	var in_menu: bool = false

var args: Dictionary = {}

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		args[a.get_slice("=", 0).trim_prefix("--")] = a.substr(a.find("=") + 1)
	_run.call_deferred()

func _run() -> void:
	seed(91234)
	Engine.max_fps = 0
	GameWorld.perf_prof = true
	GameConfig.bots = int(args.get("bots", 4))
	GameConfig.size_i = GameConfig.SIZES.find(int(args.get("size", 2048)))
	GameConfig.victory = 2
	var host := Host.new()
	root.add_child(host)
	var gw := TimedWorld.new()
	host.world = gw
	host.add_child(gw)
	gw.set_process(false)
	host.cam = MapCamera.new()
	host.add_child(host.cam)
	gw.camera = host.cam
	var s := WorldSettings.new()
	s.size = int(args.get("size", 2048))
	s.world_seed = int(args.get("seed", 20261016))
	if args.has("load"):
		var packed: Array = bytes_to_var(FileAccess.get_file_as_bytes(args["load"]))
		var body: Dictionary = bytes_to_var((packed[1] as PackedByteArray).decompress(int(packed[0]), FileAccess.COMPRESSION_ZSTD))
		Save.fill(s, body["core"]["settings"])
		Save._set_cfg(body["core"]["cfg"])
		gw.new_world(s)
		Save._load_core(gw, body)
		Save._load_systems(gw, body["sys"])
		Save._finish(gw, body["core"])
	else:
		gw.new_world(s)
		gw.spawn_ai_countries(GameConfig.bots + 1)
		gw.player = gw.countries[0]
		gw.player.is_player = true
		gw.session.start()
	for _i in 5:
		await process_frame
	var dt: float = float(args.get("dt", 0.2))
	var warm_steps: int = ceili(float(args.get("warmup", 1800)) / dt)
	for i in warm_steps:
		gw._sim_step(dt)
		gw._poll_roads()
		if i % 30 == 0:
			await process_frame
	if args.has("checkpoint"):
		FileAccess.open(args["checkpoint"], FileAccess.WRITE).store_buffer(Save.net_snapshot(host))
	gw.totals.clear()
	gw.peaks.clear()
	var samples: Array = []
	var total_us: int = 0
	var over50: int = 0
	var over100: int = 0
	var steps: int = ceili(float(args.get("seconds", 300)) / dt)
	for i in steps:
		var t: int = Time.get_ticks_usec()
		gw._sim_step(dt)
		var us: int = Time.get_ticks_usec() - t
		samples.append(us)
		total_us += us
		over50 += int(us > 50000)
		over100 += int(us > 100000)
		gw._poll_roads()
		if i % 30 == 0:
			await process_frame
	samples.sort()
	var saves: Array = []
	for i in 3:
		Save._last_gt = -1.0
		var t: int = Time.get_ticks_usec()
		var ok: bool = Save.autosave(host)
		saves.append({"ok": ok, "main_ms": (Time.get_ticks_usec() - t) / 1000.0})
		while Save._task >= 0 and not WorkerThreadPool.is_task_completed(Save._task):
			await process_frame
		Save._wait()
		if not ok or not Save._write_ok:
			push_error("Benchmark autosave failed")
			quit(1)
			return
	var result: Dictionary = {"passed": true, "samples": samples.size(), "size": gw.data.w, "bots": GameConfig.bots,
		"dt": dt, "game_time": gw.game_time, "cities": gw.cities.size(), "facilities": gw.mil.facilities.size(), "units": gw.army.units.size(),
		"mean_ms": float(total_us) / samples.size() / 1000.0, "p95_ms": samples[int(samples.size() * 0.95)] / 1000.0,
		"p99_ms": samples[int(samples.size() * 0.99)] / 1000.0, "max_ms": samples[-1] / 1000.0,
		"over50ms": over50, "over100ms": over100, "autosaves": saves, "system_total_us": gw.totals, "system_peak_us": gw.peaks}
	FileAccess.open(args["out"], FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	print("BENCHMARK ", JSON.stringify(result))
	quit()
