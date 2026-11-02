extends RefCounted
## Ammo depots (ARMY tab): small / medium / large.
##
## A depot keeps what does not fit into the country's normal stock: missiles above Military.MT_CAP
## of their type and drones when every drone port is full. Room is counted in places:
## a cruise missile takes 2, so the depots hold 5 / 15 / 40 cruise missiles; small munitions
## (KAB, air-to-air) take 1, ballistic and hypersonic missiles take 4, drones 2 (jets 3).
##
## The contents are not stored per depot: the overflow of the country is laid out over its depots
## in a fixed order (facility id, big munitions first), so it stays deterministic in multiplayer and
## needs nothing new in the save. A depot that changes hands (captured, handed to an ally, ceded in peace)
## takes its share with it: the ammo goes from the old owner's stock to the new owner's (check_owners).
## When a depot is destroyed its share is lost and detonates:
## the more is inside, the bigger and wider the blast; an empty depot does not blow up.
##
## Military is not referenced by name here (it preloads this script); its constants are read
## through the `mil` instance.

const CAP: Dictionary = {Facility.Kind.DEPOT_S: 10, Facility.Kind.DEPOT_M: 30, Facility.Kind.DEPOT_L: 80}
const KINDS: Array = [Facility.Kind.DEPOT_S, Facility.Kind.DEPOT_M, Facility.Kind.DEPOT_L]
const KEYS: Array = ["depot_s", "depot_m", "depot_l"]
const SIZE_NAMES: Array = ["МАЛЫЙ", "СРЕДНИЙ", "БОЛЬШОЙ"]

## Places per missile, by Military.MT_*: ballistic, cruise, air-to-air, SAM, hypersonic, KAB.
const MT_VOL: Array = [4, 2, 1, 2, 4, 1]
## Places per drone: [delta, jet].
const DRONE_VOL: Array = [2, 3]
const CRUISE_VOL: int = 2
## Fill order inside depots: big munitions first, so a destroyed first depot hurts the most.
const FILL_ORDER: Array = [0, 4, 1, 3, 2, 5]

## Detonation: a big blast in the middle from this many places, extra big blasts from BIG_FROM.
const CORE_FROM: int = 16
const BIG_FROM: int = 40
const BLASTS_MAX: int = 20


static func is_depot(kind: int) -> bool:
	return CAP.has(kind)


static func cap_of(kind: int) -> int:
	return int(CAP.get(kind, 0))


## How many items of a missile type fit into an empty depot of this kind.
static func fits_type(kind: int, t: int) -> int:
	return cap_of(kind) / int(MT_VOL[t])


static func depots(mil: Object, cid: int, prev: bool = false) -> Array[Facility]:
	var out: Array[Facility] = []
	for f: Facility in mil.facilities:
		if f.country_id != cid or not CAP.has(f.kind):
			continue
		if (f.was_alive and f.restore_t <= 0.0) if prev else mil.alive(f):
			out.append(f)
	return out


static func capacity(mil: Object, cid: int) -> int:
	var n: int = 0
	for f: Facility in depots(mil, cid):
		n += int(CAP[f.kind])
	return n


static func overflow(mil: Object, c: Country, t: int) -> int:
	if t < 0 or t >= c.missile_stock.size():
		return 0
	return maxi(0, c.missile_stock[t] - int(mil.MT_CAP[t]))


static func _drones(c: Country, j: int) -> int:
	return int(c.depot_drones[j]) if j < c.depot_drones.size() else 0


static func used(mil: Object, c: Country) -> int:
	var n: int = 0
	for t in mini(MT_VOL.size(), c.missile_stock.size()):
		n += overflow(mil, c, t) * int(MT_VOL[t])
	for j in DRONE_VOL.size():
		n += _drones(c, j) * int(DRONE_VOL[j])
	return n


static func room(mil: Object, c: Country) -> int:
	return maxi(0, capacity(mil, c.id) - used(mil, c))


## Can one more missile of type t be made / received (normal stock or a depot)?
static func missile_fits(mil: Object, c: Country, t: int) -> bool:
	if c == null or t < 0 or t >= c.missile_stock.size():
		return false
	if c.missile_stock[t] < int(mil.MT_CAP[t]):
		return true
	return room(mil, c) >= int(MT_VOL[t])


## The stock limit of a missile type with the depots counted in (what is there + what still fits).
static func missile_cap(mil: Object, c: Country, t: int) -> int:
	if c == null or t < 0 or t >= MT_VOL.size():
		return 0
	return int(mil.MT_CAP[t]) + overflow(mil, c, t) + room(mil, c) / int(MT_VOL[t])


static func drone_fits(mil: Object, c: Country, jet: bool) -> bool:
	return c != null and room(mil, c) >= int(DRONE_VOL[1 if jet else 0])


static func store_drone(mil: Object, c: Country, jet: bool) -> bool:
	if not drone_fits(mil, c, jet):
		return false
	while c.depot_drones.size() < DRONE_VOL.size():
		c.depot_drones.append(0)
	c.depot_drones[1 if jet else 0] += 1
	return true


static func stored_drones(c: Country) -> int:
	var n: int = 0
	for j in DRONE_VOL.size():
		n += _drones(c, j)
	return n


static func _empty_share() -> Dictionary:
	var m: Array[int] = []
	m.resize(MT_VOL.size())
	m.fill(0)
	var d: Array[int] = [0, 0]
	return {"m": m, "d": d, "pts": 0, "cap": 0}


## What lies in each depot of a country: {facility id: {"m": [n per missile type], "d": [delta, jet], "pts", "cap"}}.
## prev = lay out over the depots that were standing before this tick (used when one has just been destroyed).
static func shares(mil: Object, cid: int, prev: bool = false) -> Dictionary:
	var out: Dictionary = {}
	var c: Country = mil.gw.country_by_id(cid)
	if c == null:
		return out
	var left_m: Array[int] = []
	for t in MT_VOL.size():
		left_m.append(overflow(mil, c, t))
	var left_d: Array[int] = [_drones(c, 0), _drones(c, 1)]
	for f: Facility in depots(mil, cid, prev):
		var sh: Dictionary = _empty_share()
		var free: int = int(CAP[f.kind])
		sh["cap"] = free
		for t: int in FILL_ORDER:
			var k: int = mini(left_m[t], free / int(MT_VOL[t]))
			if k > 0:
				(sh["m"] as Array)[t] = k
				left_m[t] -= k
				free -= k * int(MT_VOL[t])
		for j in DRONE_VOL.size():
			var k2: int = mini(left_d[j], free / int(DRONE_VOL[j]))
			if k2 > 0:
				(sh["d"] as Array)[j] = k2
				left_d[j] -= k2
				free -= k2 * int(DRONE_VOL[j])
		sh["pts"] = int(sh["cap"]) - free
		out[f.id] = sh
	return out


static func share_of(mil: Object, f: Facility) -> Dictionary:
	return shares(mil, f.country_id).get(f.id, _empty_share())


## Short text of the contents for the facility card: "КР 12 · КАБ 6 · ДРОНЫ 2".
static func contents_text(mil: Object, share: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var m: Array = share.get("m", [])
	for t in m.size():
		if int(m[t]) > 0:
			parts.append("%s %d" % [Loc.t(String(SHORT[t])), int(m[t])])
	var d: Array = share.get("d", [0, 0])
	if int(d[0]) > 0:
		parts.append(Loc.t("ДРОНЫ %d") % int(d[0]))
	if int(d[1]) > 0:
		parts.append(Loc.t("РЕАКТ. %d") % int(d[1]))
	return Loc.t("ПУСТО") if parts.is_empty() else " · ".join(parts)


const SHORT: Array = ["БАЛЛ.", "КР", "В-В", "ЗУР", "ГИПЕР.", "КАБ"]


## How strong the blast of a depot with this many places inside is, 0..1 (for the card).
static func danger(pts: int) -> float:
	return clampf(float(pts) / float(CAP[Facility.Kind.DEPOT_L]), 0.0, 1.0)


## A depot that changed hands (captured, handed to an ally, ceded in peace) takes its contents with it:
## they leave the old owner's stock and go to the new owner's. Run every tick before anything else looks at depots.
static func check_owners(mil: Object) -> void:
	var moved: Array[Facility] = []
	var now_id: Dictionary = {}
	for f: Facility in mil.facilities:
		if not CAP.has(f.kind):
			continue
		if f.depot_owner < 0:
			f.depot_owner = f.country_id
		elif f.depot_owner != f.country_id:
			moved.append(f)
			now_id[f.id] = f.country_id
	if moved.is_empty():
		return
	var olds: Dictionary = {}
	for f: Facility in moved:
		olds[f.depot_owner] = true
	for old_id: int in olds:
		# Lay the old owner's overflow out as it was before the handover: the moved depots count for it again.
		for f: Facility in moved:
			if f.depot_owner == old_id:
				f.country_id = old_id
		var sh: Dictionary = shares(mil, old_id)
		for f: Facility in moved:
			if f.depot_owner == old_id:
				f.country_id = int(now_id[f.id])
		for f: Facility in moved:
			if f.depot_owner == old_id and sh.has(f.id):
				_hand_over(mil, f, old_id, int(now_id[f.id]), sh[f.id])
	for f: Facility in moved:
		f.depot_owner = f.country_id


static func _hand_over(mil: Object, f: Facility, old_id: int, new_id: int, share: Dictionary) -> void:
	var gw: GameWorld = mil.gw
	var co: Country = gw.country_by_id(old_id)
	var cn: Country = gw.country_by_id(new_id)
	if co == null or cn == null or int(share.get("pts", 0)) <= 0:
		return
	var got_m: int = 0
	var got_d: int = 0
	var m: Array = share["m"]
	for t in mini(m.size(), mini(co.missile_stock.size(), cn.missile_stock.size())):
		var k: int = mini(int(m[t]), co.missile_stock[t])
		co.missile_stock[t] -= k
		cn.missile_stock[t] += k
		got_m += k
	var d: Array = share["d"]
	while cn.depot_drones.size() < DRONE_VOL.size():
		cn.depot_drones.append(0)
	for j in mini(d.size(), co.depot_drones.size()):
		var k2: int = mini(int(d[j]), co.depot_drones[j])
		co.depot_drones[j] -= k2
		cn.depot_drones[j] += k2
		got_d += k2
	if got_m + got_d <= 0:
		return
	var title: String = Loc.t(String(mil.TITLES[f.kind]))
	if cn.is_player:
		gw.say(cn, Loc.mk("%s захвачен: боеприпасы теперь ваши — ракет %d, дронов %d", [title, got_m, got_d]))
	elif co.is_player:
		gw.say(co, Loc.mk("%s захвачен: боеприпасы потеряны — ракет %d, дронов %d", [title, got_m, got_d]))


## The depot has just been destroyed: its share is lost and goes off.
static func detonate(mil: Object, f: Facility, share: Dictionary) -> void:
	var gw: GameWorld = mil.gw
	var c: Country = gw.country_by_id(f.country_id)
	var pts: int = int(share.get("pts", 0))
	if c == null or pts <= 0:
		return
	var m: Array = share["m"]
	var d: Array = share["d"]
	var lost_m: int = 0
	for t in mini(m.size(), c.missile_stock.size()):
		var k: int = mini(int(m[t]), c.missile_stock[t])
		c.missile_stock[t] -= k
		lost_m += k
	var lost_d: int = 0
	for j in mini(d.size(), c.depot_drones.size()):
		var k2: int = mini(int(d[j]), c.depot_drones[j])
		c.depot_drones[j] -= k2
		lost_d += k2
	var center: Vector2i = f.cell + f.size / 2
	var reach: float = 1.0 + sqrt(float(pts)) * 1.8
	var n: int = clampi(ceili(float(pts) / 4.0), 1, BLASTS_MAX)
	var t0: float = 0.05
	if pts >= CORE_FROM:
		gw._delay(t0, gw.strike_big.bind(center, 0))
		t0 += 0.25
	for i in n:
		var a: float = gw.rng.roll() * TAU
		var r: float = reach * sqrt(gw.rng.roll())
		var cell: Vector2i = center + Vector2i(roundi(cos(a) * r), roundi(sin(a) * r))
		if pts >= BIG_FROM and i % 3 == 0:
			gw._delay(t0, gw.strike_big.bind(cell, 0))
		else:
			gw._delay(t0, gw.strike.bind(cell, 0))
		t0 += 0.12 + gw.rng.roll() * 0.22
	if c.is_player:
		gw.say(c, Loc.mk("%s: детонация боеприпасов! Потеряно ракет %d, дронов %d", [Loc.t(String(mil.TITLES[f.kind])), lost_m, lost_d]))


## Drones waiting in depots fly over to a drone port as soon as one has a free spot.
static func dispatch(mil: Object) -> void:
	for c: Country in mil.gw.countries:
		if stored_drones(c) <= 0:
			continue
		var near: Vector2 = Vector2.ZERO
		var ds: Array[Facility] = depots(mil, c.id)
		if not ds.is_empty():
			near = ds[0].center_px()
		elif c.capital_id >= 0:
			near = Vector2(mil.gw.cities[c.capital_id].center * GameWorld.CELL)
		for j in [1, 0]:
			while _drones(c, j) > 0:
				var port: Facility = mil._port_with_space(c, near)
				if port == null:
					break
				c.depot_drones[j] -= 1
				mil.park_new_drone(c, port, j == 1)
