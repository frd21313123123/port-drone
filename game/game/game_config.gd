class_name GameConfig
extends RefCounted


const DIFF_NAMES: Array = ["ЛЁГКИЙ", "НОРМАЛЬНЫЙ", "СЛОЖНЫЙ"]
const AGGR_NAMES: Array = ["МИРНЫЕ", "ОБЫЧНЫЕ", "АГРЕССИВНЫЕ"]
const VICTORY_NAMES: Array = ["ПО ОЧКАМ", "ПО ВРЕМЕНИ", "ЗАХВАТ СТОЛИЦ"]
const SIZES: Array = [512, 1024, 2048]
const SIZE_NAMES: Array = ["МАЛЫЙ", "СРЕДНИЙ", "БОЛЬШОЙ"]
const TARGETS: Array = [5000, 10000, 15000, 25000]
const TIMES: Array = [15, 30, 45, 60, 90, 0]

static var bots: int = 3
static var difficulty: int = 1
static var aggression: int = 1
static var victory: int = 0
static var target_i: int = 2
static var time_i: int = 1


static var limit_i: int = 5
static var size_i: int = 1

const EXPAND_NAMES: Array = ["МЕДЛЕННО", "НОРМА", "БЫСТРО"]
static var expand_i: int = 1


const AUTODIG_NAMES: Array = ["ВЫКЛ", "ВКЛ", "ПО СЛОЖН."]
static var ai_autodig: int = 0

static var alliances: bool = true


static func autodig_on(c: Country = null) -> bool:
	return ai_autodig == 1 or (ai_autodig == 2 and diff_of(c) >= 1)



const RESERVE_NAMES: Array = ["ОБЫЧНЫЕ", "БОЛЬШИЕ", "БЕСКОНЕЧНЫЕ"]
const RESERVE_MUL: Array = [1.0, 3.0, 1.0]
static var reserves_i: int = 0



static func infinite_res() -> bool:
	return reserves_i == 2



static func reserve_mul() -> float:
	return float(RESERVE_MUL[clampi(reserves_i, 0, RESERVE_MUL.size() - 1)])

static var arch_i: int = 0
static var ranked: Dictionary = {}
static var my_name: String = ""
static var my_flag: String = ""
static var my_land: int = -1




const CB_MAX: int = 7
const MONEY_STEPS: Array = [1000, 2000, 3000, 5000, 8000, 12000, 20000]
static var cb_on: bool = false
static var cb_list: Array = []
static var my_money: int = 3000



static func cb_active() -> bool:
	return cb_on and not tutorial and not cb_list.is_empty()



static func diff_of(c: Country) -> int:
	if c != null and c.ai_diff >= 0:
		return clampi(c.ai_diff, 0, 2)
	return clampi(difficulty, 0, 2)
static var mp_speed: int = 1
static var tutorial: bool = false
static var night: bool = true
static var hints: bool = true
static var opening: bool = true
static var notif_mode: int = 0
static var plan_pos: Vector2 = Vector2(-1, -1)
static var power_save: bool = false
static var creative: bool = false
static var confirm_actions: bool = true
static var fog: bool = true
static var perf_hud: bool = false
static var dev_mode: bool = false
static var econ_fx: bool = true
static var day_grade: bool = true
static var ground_detail: bool = true
static var clouds: bool = true
static var fx_level: int = 1


const ORE_PRESET_NAMES: Array = ["БАЛАНС", "МАЛО", "МНОГО", "СВОИ"]
const ORE_LEVEL_NAMES: Array = ["НЕТ", "МАЛО", "НОРМА", "МНОГО", "ОЧЕНЬ МНОГО"]
const ORE_TYPES: Array = ["metal", "titanium", "oil", "precious", "uranium"]
static var ore_preset: int = 0
static var ore_custom: Dictionary = {"metal": 2, "titanium": 2, "oil": 2, "precious": 2, "uranium": 2}



static func ore_level(res: String) -> int:
	match ore_preset:
		1:
			return 1
		2:
			return 3
		3:
			return clampi(int(ore_custom.get(res, 2)), 0, 4)
	return 2




const MAP_TYPE_NAMES: Array = ["ОБЫЧНАЯ", "АРХИПЕЛАГ", "ОСТРОВА", "МАТЕРИКИ"]
const MAP_TYPE_HINTS: Array = ["Большая суша, заливы и острова", "Много островов: соседи за морем, нужен десант", "Несколько больших островов, на каждом соседи", "Два материка за океаном, на каждом свои соседи"]
const MAP_TYPE_ICONS: Array = ["map_t_normal", "map_t_archipelago", "map_t_islands", "map_t_continents"]
const MAP_LAND: Array = [42, 24, 30, 42]
const WATER_NAMES: Array = ["НЕТ", "МАЛО", "НОРМА", "МНОГО"]
const RIVERS: Array = [0, 10, 22, 36]
static var map_type: int = 0
static var rivers_i: int = 2
static var lakes_i: int = 2
static var map_seed: int = -1



static func lakes_for(size: int) -> int:
	match lakes_i:
		0:
			return 0
		1:
			return 2
		3:
			return maxi(2, size / 256 + 1) * 2 + 2
	return -1




static func apply_map(s: WorldSettings, consume: bool = false) -> void:
	if tutorial:
		return
	if map_seed >= 0:
		s.world_seed = map_seed
		if consume:
			map_seed = -1
	s.map_type = clampi(map_type, 0, 3)
	if s.map_type != 0:
		s.land_percent = int(MAP_LAND[s.map_type])
	s.rivers = int(RIVERS[clampi(rivers_i, 0, 3)])
	s.lakes = lakes_for(s.size)


static func score_target() -> int:
	return int(TARGETS[target_i])



static func time_limit() -> float:
	return float(TIMES[clampi(time_i, 0, TIMES.size() - 1)]) * 60.0



static func match_limit() -> float:
	if victory == 1:
		return time_limit()
	return float(TIMES[clampi(limit_i, 0, TIMES.size() - 1)]) * 60.0



static func ai_income_mul(c: Country = null) -> float:
	return [0.7, 1.0, 1.5][diff_of(c)]



static func ai_think_dt(c: Country = null) -> float:
	return [14.0, 9.0, 5.0][diff_of(c)]






static func early_damp(t: float) -> float:
	if size_i != 0:
		return 0.0
	return clampf((900.0 - t) / 300.0, 0.0, 1.0)


static func player_grace() -> float:
	return 720.0 if size_i == 0 else 600.0



static func ai_pace(t: float) -> float:
	return 1.0 + 0.5 * early_damp(t)



static func ai_cap_cut(t: float) -> int:
	return roundi(4.0 * early_damp(t))





static var no_save: bool = false


static var lang: String = ""
static var pseudo_loc: bool = false
