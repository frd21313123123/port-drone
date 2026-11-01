extends SceneTree
## Differential CPU checks and deterministic scheduling/save regressions.

class ProbeNaval:
	extends Naval
	var attempts: Array = []
	var success: Vector2i = Vector2i(-999, -999)
	func _ready_why(port: Facility, c: Country, _skip_res: bool = false) -> String:
		return "captured" if port == null or port.country_id != c.id else ""
	func launch_expedition(port: Facility, cell: Vector2i) -> String:
		attempts.append([port.country_id, cell])
		return "" if cell == success else "no site"
	func _near_land_of(_country_id: int, _cell: Vector2i, _reach: int) -> bool:
		return false

var checks: int = 0
var failures: Array = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var gw := GameWorld.new()
	gw.data = WorldData.new(64, 64, 1)
	gw.mil = Military.new(gw)
	gw.econ = Economy.new(gw)
	gw.army = Army.new(gw)
	gw.naval = Naval.new(gw)
	for id in range(1, 4):
		var c := Country.new()
		c.id = id
		c.capital_id = 0
		c.money = 10000
		c.food = 1000
		gw.countries.append(c)
	var r := RandomNumberGenerator.new()
	r.seed = 7472
	_test_inventory(gw, r)
	_test_spatial(gw, r)
	_test_water(gw, r)
	_test_land(gw, r)
	_test_colonies(gw)
	_test_entity_codec()
	await _test_save(gw)
	var result: Dictionary = {"passed": failures.is_empty(), "checks": checks, "failures": failures}
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			FileAccess.open(a.trim_prefix("--out="), FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	print("REGRESSION ", JSON.stringify(result))
	gw.free()
	quit(0 if failures.is_empty() else 1)

func _test_inventory(gw: GameWorld, r: RandomNumberGenerator) -> void:
	for i in 150:
		var f := Facility.new()
		f.country_id = r.randi_range(1, 3)
		f.kind = r.randi_range(0, Facility.Kind.size() - 1)
		f.was_alive = i % 2 == 0
		gw.mil.facilities.append(f)
	var ai := AiBots.new(gw)
	for pass_i in 2:
		for c: Country in gw.countries:
			var counts: Dictionary = ai._kind_counts(c)
			for kind in Facility.Kind.size():
				check(ai._count(c, kind, counts) == ai._count(c, kind), "Inventory must include exactly the original facilities")
		# Capture and building must be reflected in the next decision, not cached by time.
		gw.mil.facilities[0].country_id = 3
		var f := Facility.new()
		f.country_id = 1
		f.kind = Facility.Kind.FARM
		gw.mil.facilities.append(f)

func _test_spatial(gw: GameWorld, r: RandomNumberGenerator) -> void:
	for i in 60:
		var k := Vector2i(r.randi_range(-5, 5), r.randi_range(-5, 5))
		gw.army._grid[k] = [i, i + 100]
		gw.army._fgrid[k] = [i + 200]
	gw.army._flines = [900, 901]
	for i in 300:
		var p := Vector2(r.randf_range(-600, 600), r.randf_range(-600, 600))
		var radius := r.randf_range(0, 400)
		var expected: Array = []
		var facilities: Array = gw.army._flines.duplicate()
		for y in range(floori((p.y - radius) / Army.GRID_PX), floori((p.y + radius) / Army.GRID_PX) + 1):
			for x in range(floori((p.x - radius) / Army.GRID_PX), floori((p.x + radius) / Army.GRID_PX) + 1):
				expected.append_array(gw.army._grid.get(Vector2i(x, y), []))
				facilities.append_array(gw.army._fgrid.get(Vector2i(x, y), []))
		check(gw.army._near(p, radius) == expected, "Unit query membership/order changed")
		check(gw.army._near_fac(p, radius) == facilities, "Facility query membership/order changed")
	gw.army._grid.clear()
	gw.army._fgrid.clear()
	gw.army._flines.clear()

# Pre-optimization reference, including sampling order, bridge margins and edges.
func _reference_water(e: Economy, a: Vector2, b: Vector2) -> Vector2:
	var length: float = a.distance_to(b)
	if length < 0.5:
		return Vector2.INF
	var side: Vector2 = (b - a).normalized().orthogonal() * e.BODY_HALF
	var steps: int = maxi(1, int(length / 2.0))
	var last: int = -1
	for s in range(1, steps):
		var m: Vector2 = a.lerp(b, float(s) / steps)
		var c0 := Vector2i(floori(m.x / 4.0), floori(m.y / 4.0))
		var c1 := Vector2i(floori((m.x + side.x) / 4.0), floori((m.y + side.y) / 4.0))
		var c2 := Vector2i(floori((m.x - side.x) / 4.0), floori((m.y - side.y) / 4.0))
		var w: int = e.gw.data.w
		var key: int = ((c0.y * w + c0.x) * 31 + c1.y * w + c1.x) * 31 + c2.y * w + c2.x
		if key == last:
			continue
		last = key
		if (e._water_px(m) or e._water_px(m + side) or e._water_px(m - side)) and not e._bridge_near(m):
			return m
	return Vector2.INF

func _test_water(gw: GameWorld, r: RandomNumberGenerator) -> void:
	for terrain in 3:
		for i in gw.data.biome.size():
			gw.data.biome[i] = Biome.GRASS if terrain == 0 else r.randi_range(0, Biome.FOREST)
			gw.data.flags[i] = WorldData.F_BRIDGE if terrain == 2 and r.randi_range(0, 9) == 0 else 0
		for i in 400:
			var a := Vector2(r.randf_range(-20, 276), r.randf_range(-20, 276))
			var b: Vector2 = a if i % 40 == 0 else Vector2(r.randf_range(-20, 276), r.randf_range(-20, 276))
			check(gw.econ._wet_on(a, b) == _reference_water(gw.econ, a, b), "Route water/bridge result changed")

func _test_land(gw: GameWorld, r: RandomNumberGenerator) -> void:
	for i in gw.data.owners.size():
		gw.data.owners[i] = r.randi_range(0, 80) % 4 if i % 7 == 0 else 0
	for i in 300:
		var cell := Vector2i(r.randi_range(-30, 94), r.randi_range(-30, 94))
		var reach: int = r.randi_range(0, 35)
		var country: int = r.randi_range(1, 3)
		var expected: bool = false
		for dy in range(-reach, reach + 1, 3):
			for dx in range(-reach, reach + 1, 3):
				var q := cell + Vector2i(dx, dy)
				if gw.data.inside(q.x, q.y) and gw.data.get_owner_id(q.x, q.y) == country:
					expected = true
		check(gw.naval._near_land_of(country, cell, reach) == expected, "Ownership sample/edge result changed")

func _job(c: int, port: Facility, candidates: Array) -> Dictionary:
	return {"country": c, "port": port, "candidates": candidates, "sites": [], "tries": 0, "fallback": []}

func _test_colonies(gw: GameWorld) -> void:
	var n := ProbeNaval.new(gw)
	var p1 := Facility.new()
	p1.country_id = 1
	var p2 := Facility.new()
	p2.country_id = 2
	n._colony_jobs = [_job(1, p1, [Vector2i(1, 1), Vector2i(1, 2)]), _job(2, p2, [Vector2i(2, 1), Vector2i(2, 2)])]
	for i in 4:
		var before: int = n.attempts.size()
		n._ai_colony_step()
		check(n.attempts.size() == before + 1, "Exactly one colony probe per step")
	check(n.attempts == [[1, Vector2i(1, 1)], [2, Vector2i(2, 1)], [1, Vector2i(1, 2)], [2, Vector2i(2, 2)]], "Colony search round-robin/order")
	n._colony_jobs = [_job(1, p1, [Vector2i(3, 1), Vector2i(3, 2)])]
	n.success = Vector2i(3, 1)
	n._ai_colony_step()
	check(n._colony_jobs.is_empty(), "Successful expedition ends its search")
	p1.country_id = 2
	n._colony_jobs = [_job(1, p1, [Vector2i(4, 1)])]
	var before: int = n.attempts.size()
	n._ai_colony_step()
	check(n.attempts.size() == before and n._colony_jobs.is_empty(), "Captured port cancels queued search")
	p1.country_id = 1
	gw.countries[0].money = 0
	n._colony_jobs = [_job(1, p1, [Vector2i(4, 1)])]
	n._ai_colony_step()
	check(n.attempts.size() == before and n._colony_jobs.is_empty(), "Recheck resources before launching")
	gw.countries[0].money = 10000
	n.success = Vector2i(-999, -999)
	var job: Dictionary = _job(1, p1, [])
	job["sites"] = [[10, Vector2i(10, 10)], [9, Vector2i(20, 20)], [8, Vector2i(30, 30)], [7, Vector2i(40, 40)], [6, Vector2i(50, 50)]]
	job["fallback"] = [Vector2i(60, 60)]
	n._colony_jobs = [job]
	n.attempts.clear()
	for i in 65:
		before = n.attempts.size()
		n._ai_colony_step()
		check(n.attempts.size() <= before + 1, "Never batch colony route/plan queries")
	check(n.attempts.size() == 49 and n.attempts[-1][1] == Vector2i(60, 60), "Preserve 4x12 resource probes, then fallback")
	check(n._colony_jobs.is_empty(), "Exhausted search finishes")

func _test_entity_codec() -> void:
	var f := Facility.new()
	var module := Facility.new()
	f.modules = [module]
	module.parent = f
	f.spot_owner = [null, module]
	f.cell_hp = {Vector2i(1, 2): 3}
	f.fx = [123, 456]
	var u := Unit.new()
	u.home = f
	u.target = module
	u.path = PackedVector2Array([Vector2(1, 2), Vector2(3, 4)])
	var city := City.new()
	city.visited = {123: true, 345: true}
	city.frontier = [Vector3i(1, 2, 3)]
	var entities: Array = [Country.new(), city, f, module, u, Drone.new(), Missile.new(), Aircraft.new(), Bridge.new(), Rng.new(2)]
	for o: Object in entities:
		var skip: Array = ["fx"] if o is Facility else (["visited"] if o is City else [])
		Save._reset_codec()
		var expected: Dictionary = Save.dump_slow(o, skip)
		var expected_refs: Array = Save._ents.duplicate()
		Save._reset_codec()
		check(Save._entity_dump(o, skip) == expected, "Entity save fields match reference: " + o.get_script().get_global_name())
		check(Save._ents == expected_refs, "Entity reference order/cycles match reference")
	Save._reset_codec()

func _test_save(gw: GameWorld) -> void:
	Save._reset_codec()
	var p := Facility.new()
	p.country_id = 1
	gw.naval._colony_jobs = [_job(1, p, [Vector2i(7, 7), Vector2i(8, 8)])]
	var state: Dictionary = Save.enc(gw.naval.save_state())
	Save._dec = Save._ents.duplicate()
	var restored := Naval.new(gw)
	restored.load_state(Save.dec(state))
	check(restored._colony_jobs.size() == 1 and restored._colony_jobs[0]["port"] == p, "Resume queued colony search after codec round-trip")
	check(restored._colony_jobs[0]["candidates"] == [Vector2i(7, 7), Vector2i(8, 8)], "Save pending candidate order")
	Save._dec = []
	var source: Dictionary = {"array": [1, {"nested": [2, 3]}], "owners": gw.data.owners, "biome": gw.data.biome, "naval": state}
	var body: Dictionary = {"core": Save.enc(source), "ents": []}
	var expected: PackedByteArray = var_to_bytes(body)
	var thumb: Dictionary = Save.SaveSlots.thumb_input(gw)
	var expected_thumb: PackedByteArray = Save.SaveSlots.render_thumb(thumb).get_data()
	var task: int = Save._queue_write({"slot": 1, "game_time": 123, "seq": 1}, body, thumb)
	source["array"][1]["nested"][0] = 999
	gw.data.owners[0] = 99
	gw.data.biome[0] = Biome.OCEAN
	gw.naval._colony_jobs[0]["candidates"].clear()
	while not WorkerThreadPool.is_task_completed(task):
		await process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	check(Save._write_ok, "Background save write completes")
	var loaded: Dictionary = Save._read(Save.SaveSlots.path(1, "a0"))
	check(not loaded.is_empty() and loaded.get("body") == bytes_to_var(expected), "Background serialization must preserve the frozen snapshot while live state mutates")
	var image: Image = Image.load_from_file(Save.SaveSlots.path(1, "png"))
	check(image != null and image.get_data() == expected_thumb, "Autosave thumbnail must use the same frozen world as the save")
