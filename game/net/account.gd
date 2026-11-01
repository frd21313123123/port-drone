class_name Account
extends RefCounted
## BACKEND 1: the player's backend account (docs/BACKEND.md): tokens, register / login / refresh with the
## device check, the profile (/user/info), nick change, logout. Static state; Api.i().account_changed
## tells the screens. Tokens live in the Keychain / EncryptedSharedPreferences (BACKEND 1b: the DFDevice
## native side); without it in an encrypted user:// file (desktop). Never print them.

const FILE: String = "user://account.bin"
const REFRESH_AHEAD_S: int = 86400  # refresh a day before the access token runs out (client-integration §2.4)

static var access: String = ""
static var refresh_tok: String = ""
static var access_until: int = 0  # unix s
static var info: Dictionary = {}  # the last /user/info (username, match_played, is_multiplayer_available...)
static var last_email: String = ""
static var expired: bool = false  # the session ended (refresh -> 401): the sign-in block says so
static var _loaded: bool = false
static var persist: bool = true  # dev/net_autotest.gd --net-account: two processes share user://
static var _refreshing: bool = false


static func load_state() -> void:
	if _loaded:
		return
	_loaded = true
	if not persist:
		return
	var d: Variant = DeviceCheck.secure_load("account", FILE, "|droneflames-account-1")  # BACKEND 1b: the Keychain when there
	if d is Dictionary:
		access = String(d.get("a", ""))
		refresh_tok = String(d.get("r", ""))
		access_until = int(d.get("au", 0))
		info = d.get("i", {})
		set_suspension(info.get("mp_suspension"), false)  # (critic) from disk: its remaining_s is old — counted from «until»
		last_email = String(d.get("e", ""))
		seen = d.get("s", [])
		seen_init = bool(d.get("si", false))


static func _save() -> void:
	if not persist:
		return
	DeviceCheck.secure_store("account", {"a": access, "r": refresh_tok, "au": access_until, "i": info, "e": last_email, "s": seen, "si": seen_init}, FILE, "|droneflames-account-1")


## The server closed the socket with 4003 / said so: the ONLINE tab shows the ban (saved, told).
static func mark_banned() -> void:
	info["is_multiplayer_available"] = false
	_save()
	_changed()


static func signed_in() -> bool:
	load_state()
	return refresh_tok != ""


static func username() -> String:
	load_state()
	return String(info.get("username", ""))


## Online play allowed for this account (false = ban: the ONLINE tab says so).
static func mp_ok() -> bool:
	return bool(info.get("is_multiplayer_available", true))


# ------------------------------------------------------------------ REPORTS: a temporary suspension (docs/REPORTS.md)
# The server sends {"until": UTC ISO, "remaining_s", "reason": code} (/user/info «mp_suspension», or the signal error
# «suspended»). The end is counted from remaining_s on this device's monotonic clock: its wall clock may be wrong.
const SUSPEND_WHY: Dictionary = {"cheats": "ЧИТЫ", "chat_toxic": "ТОКСИЧНОСТЬ В ЧАТЕ", "unsporting": "НЕСПОРТИВНОЕ ПОВЕДЕНИЕ",
	"bad_name_flag": "НИК ИЛИ ФЛАГ", "griefing": "НЕСПОРТИВНОЕ ПОВЕДЕНИЕ", "leaver": "ЧАСТЫЕ ВЫХОДЫ ИЗ ПАРТИЙ",
	"abuse_reports": "ЛОЖНЫЕ ЖАЛОБЫ"}
static var _sus: Dictionary = {}  # the last one seen
static var _sus_end_ms: int = 0  # Time.get_ticks_msec() when it ends


## A suspension from the server (the profile's, the socket's refusal, the chat's 403): kept with its local end.
static func set_suspension(d: Variant, fresh: bool = true) -> void:
	if not (d is Dictionary):
		_sus = {}
		_sus_end_ms = 0
		return
	var left: int = int((d as Dictionary).get("remaining_s", 0))
	if not fresh:
		# a copy from disk: remaining_s is as old as the copy; the device clock against «until» (wrong clocks are
		# corrected by the next /user/info)
		var end_unix: int = Time.get_unix_time_from_datetime_string(String((d as Dictionary).get("until", "")).left(19))
		left = end_unix - int(Time.get_unix_time_from_system()) if end_unix > 0 else 0
	if left <= 0:
		_sus = {}
		_sus_end_ms = 0
		return
	_sus = d
	_sus_end_ms = Time.get_ticks_msec() + left * 1000


## Seconds left of the suspension, 0 = none (kept by set_suspension: /user/info, the socket's refusal, the chat's 403).
static func suspended_s() -> int:
	if _sus.is_empty():
		return 0
	return maxi(0, ceili((_sus_end_ms - Time.get_ticks_msec()) / 1000.0))


static func suspension_reason() -> String:
	return String(SUSPEND_WHY.get(String(_sus.get("reason", "")), "НАРУШЕНИЕ ПРАВИЛ"))


## «18:40», another day «30.10 18:40» (the device's local time of the end).
static func suspension_until() -> String:
	var end_unix: float = Time.get_unix_time_from_system() + float(suspended_s())
	var bias: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(int(end_unix) + bias)
	var today: Dictionary = Time.get_datetime_dict_from_unix_time(int(Time.get_unix_time_from_system()) + bias)
	var hm: String = "%02d:%02d" % [int(d["hour"]), int(d["minute"])]
	return hm if int(d["day"]) == int(today["day"]) and int(d["month"]) == int(today["month"]) else "%02d.%02d %s" % [int(d["day"]), int(d["month"]), hm]


## «37 МИН», «1 Ч 05 МИН», «2 ДН 3 Ч», «МЕНЬШЕ МИНУТЫ».
static func suspension_left() -> String:
	var s: int = suspended_s()
	if s < 60:
		return "МЕНЬШЕ МИНУТЫ"
	var m: int = s / 60
	if m < 60:
		return "%d МИН" % m
	if m < 24 * 60:
		return "%d Ч %02d МИН" % [m / 60, m % 60]
	return "%d ДН %d Ч" % [m / 1440, (m % 1440) / 60]


## New online games are open (rooms, codes, the ranked queue): not banned and not suspended.
static func mp_open() -> bool:
	return mp_ok() and suspended_s() <= 0


static func _changed() -> void:
	Api.i().account_changed.emit()


## The production server needs App Attest / Play Integrity, a desktop build has neither: say it before
## a request burns one of the 10 attempts.
static func device_check_missing() -> bool:
	NetConfig.load_cfg()
	return not DeviceCheck.available() and NetConfig.api_url.contains("snaipix.com")


## register / login: -> {"ok": bool, "err": text, "field": "nick" | "email" | "password" | ""}.
static func register(nick: String, email: String, password: String) -> Dictionary:
	return await _auth("/user/register", {"username": nick, "email": email.strip_edges(), "password": password}, 201)


static func login(email: String, password: String) -> Dictionary:
	return await _auth("/user/login", {"email": email.strip_edges(), "password": password}, 200)


static func _auth(path: String, fields: Dictionary, ok_code: int) -> Dictionary:
	load_state()
	if device_check_missing():
		return {"ok": false, "err": DeviceCheck.TXT_MISSING, "field": ""}
	var r: Dictionary = await _signed("POST", path, fields, false)
	if int(r["code"]) != 0:
		DeviceCheck.key_accepted(int(r["code"]))
	if int(r["code"]) != ok_code:
		var d: String = String((r["data"] as Dictionary).get("detail", "")) if r["data"] is Dictionary else ""
		var fld: String = {"Username already taken": "nick", "Email already registered": "email", "Invalid email or password": "password"}.get(d, "")
		return {"ok": false, "err": String(r["err"]), "field": fld, "code": int(r["code"])}
	_take_tokens(r["data"])
	last_email = String(fields.get("email", last_email))
	expired = false
	await fetch_info()
	return {"ok": true, "err": "", "field": ""}


## A device-checked call: new challenge, the body serialized ONCE, its SHA-256 signed, the same bytes sent.
static func _signed(method: String, path: String, fields: Dictionary, assertion_only: bool) -> Dictionary:
	var ch: Dictionary = await Api.i().call_api("GET", "/user/challenge", null, false)
	if int(ch["code"]) != 200 or not (ch["data"] is Dictionary):
		return ch
	var body: Dictionary = {"challenge": String((ch["data"] as Dictionary).get("challenge", ""))}
	body.merge(fields)
	var raw: PackedByteArray = JSON.stringify(body).to_utf8_buffer()
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	hc.update(raw)
	var dc: Dictionary = await DeviceCheck.headers(hc.finish(), assertion_only)
	if not bool(dc["ok"]):
		return {"code": 0, "data": null, "err": String(dc["err"])}
	return await Api.i().call_api(method, path, null, false, raw, dc["headers"])


static func _take_tokens(d: Variant) -> void:
	if not (d is Dictionary):
		return
	access = String((d as Dictionary).get("access_token", ""))
	if (d as Dictionary).has("refresh_token"):
		refresh_tok = String(d["refresh_token"])
	access_until = int(Time.get_unix_time_from_system()) + int((d as Dictionary).get("access_expires_in", (d as Dictionary).get("expires_in", 259200)))
	_save()


## A new access token. false = no (the screens offer the sign-in; a 401 from refresh ends the session).
static func refresh() -> bool:
	load_state()
	if refresh_tok == "":
		return false
	if _refreshing:
		while _refreshing:
			await Api.i().get_tree().process_frame
		return access != "" and access_until > int(Time.get_unix_time_from_system())
	_refreshing = true
	var r: Dictionary = await _signed("POST", "/user/refresh", {"refresh_token": refresh_tok, "rotate": true}, true)  # (server #22) a new refresh token every time
	_refreshing = false
	if int(r["code"]) == 200:
		_take_tokens(r["data"])
		return true
	if int(r["code"]) == 401:
		lost_session()
	return false


## The token runs out within a day: refresh now (before a socket / a match).
static func ensure_fresh() -> void:
	if signed_in() and access_until - int(Time.get_unix_time_from_system()) < REFRESH_AHEAD_S:
		await refresh()


static func fetch_info() -> Dictionary:
	var r: Dictionary = await Api.i().call_api("GET", "/user/info")
	if int(r["code"]) == 200 and r["data"] is Dictionary:
		info = r["data"]
		set_suspension(info.get("mp_suspension"))  # (critic) a lifted one goes at once
		_save()
		_changed()
	return r


## -> {"ok", "err"}; 409 «Этот ник уже занят».
static func change_username(nick: String) -> Dictionary:
	var r: Dictionary = await Api.i().call_api("POST", "/user/change_username", {"username": nick})
	if int(r["code"]) == 200 and r["data"] is Dictionary:
		info = r["data"]
		set_suspension(info.get("mp_suspension"))
		_save()
		_changed()
		return {"ok": true, "err": ""}
	return {"ok": false, "err": String(r["err"]), "code": int(r["code"])}


static func logout() -> void:
	access = ""
	refresh_tok = ""
	access_until = 0
	info = {}
	set_suspension(null)  # (critic) another account on this device never sees this one's suspension
	owned = []  # (critic) another account on this device never sees this one's exclusives
	catalog = {}
	seen = []
	seen_init = false
	expired = false
	_save()
	_changed()


## refresh_token rejected: back to the sign-in (the e-mail stays filled in).
static func lost_session() -> void:
	if refresh_tok == "" and access == "":
		return
	access = ""
	refresh_tok = ""
	access_until = 0
	owned = []
	set_suspension(null)
	expired = true
	_save()
	_changed()


## The client-side checks of the forms (client-integration §2.3) — before a request burns an attempt.
static func nick_error(n: String) -> String:
	if n.length() < 3:
		return "НИК: МИНИМУМ 3 СИМВОЛА"
	if n.length() > 32:
		return "НИК: НЕ БОЛЬШЕ 32 СИМВОЛОВ"
	for ch: String in n:
		if not _nick_char(ch):
			return NICK_RULE
	return ""


static func email_error(e: String) -> String:
	e = e.strip_edges()
	if e == "":
		return "ПОЧТА: ВВЕДИТЕ АДРЕС"
	var re := RegEx.create_from_string("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$")
	return "" if re.search(e) != null else "ПОЧТА: ПРОВЕРЬТЕ АДРЕС"


static func password_error(p: String) -> String:
	if p.length() < 8:
		return "ПАРОЛЬ: МИНИМУМ 8 СИМВОЛОВ"
	if p.length() > 128:
		return "ПАРОЛЬ: НЕ БОЛЬШЕ 128 СИМВОЛОВ"
	return ""


const NICK_RULE: String = "НИК: ТОЛЬКО ЛАТИНИЦА И ЦИФРЫ"


## The owner's rule (2026-10-29), the same on the server (schemas/user.py USERNAME_RE): A-Z a-z 0-9 only.
static func _nick_char(ch: String) -> bool:
	return (ch >= "A" and ch <= "Z") or (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9")


## A typed nick: anything outside [A-Za-z0-9] goes (spaces, «_», Cyrillic). -> [clean, dropped something].
static func filter_nick(t: String) -> Array:
	var out: String = ""
	var dropped: bool = false
	for ch: String in t:
		if _nick_char(ch):
			out += ch
		else:
			dropped = true
	return [out.left(32), dropped]


## GET /user/username_available (no token; the server limits it per IP). -> "free" | "taken" | "invalid" |
## "" (unknown: no network / the limit — the form decides on submit, the server answers 409 then).
static func nick_state(nick: String) -> String:
	var r: Dictionary = await Api.i().call_api("GET", "/user/username_available?username=%s" % nick.uri_encode(), null, false)
	if int(r["code"]) != 200 or not (r["data"] is Dictionary):
		return ""
	var d: Dictionary = r["data"]
	if bool(d.get("available", false)):
		return "free"
	return String(d.get("reason", ""))


# ------------------------------------------------------------------ BACKEND 2a: cosmetics (docs/COSMETICS.md)

static var owned: Array = []  # the last /user/cosmetics «owned» (codes)
static var seen: Array = []  # owned codes the player has already looked at («НОВОЕ» = owned - seen)
static var seen_init: bool = false  # the first list ever is all «seen» (no wall of «НОВОЕ»)


static func unseen() -> Array:
	return owned.filter(func(c: String) -> bool: return not seen.has(c) and not bool(Cosmetics.item(c).get("is_default", false)))


static func mark_seen(code: String) -> void:
	if not seen.has(code):
		seen.append(code)
		_save()
static var catalog: Dictionary = {}  # code -> the server's item (its unlock rule may differ from the client registry)


## Equipped codes (from /user/info; null = the standard look).
static func equipped() -> Dictionary:
	var c: Variant = info.get("cosmetics", {})
	return c if c is Dictionary else {}


## -> {"ok", "err"}: /cosmetics (once) + /user/cosmetics.
static func fetch_cosmetics() -> Dictionary:
	if catalog.is_empty():
		var rc: Dictionary = await Api.i().call_api("GET", "/cosmetics")
		if int(rc["code"]) == 200 and rc["data"] is Dictionary:
			for it: Dictionary in (rc["data"] as Dictionary).get("cosmetics", []):
				catalog[String(it["code"])] = it
	var r: Dictionary = await Api.i().call_api("GET", "/user/cosmetics")
	if int(r["code"]) != 200 or not (r["data"] is Dictionary):
		return {"ok": false, "err": String(r["err"])}
	_take_cosmetics(r["data"])
	return {"ok": true, "err": ""}


## kind -> code / null (null = take it off). -> {"ok", "err", "code"}.
static func equip(kind: String, code: Variant) -> Dictionary:
	var r: Dictionary = await Api.i().call_api("POST", "/user/cosmetics/equip", {kind: code})
	if int(r["code"]) == 200 and r["data"] is Dictionary:
		_take_cosmetics(r["data"])
		return {"ok": true, "err": "", "code": 200}
	return {"ok": false, "err": String(r["err"]), "code": int(r["code"])}


static func _take_cosmetics(d: Dictionary) -> void:
	owned = (d.get("owned", []) as Array).map(func(it: Dictionary) -> String: return String(it["code"]))
	if not seen_init:
		seen_init = true
		seen = owned.duplicate()
	info["cosmetics"] = d.get("equipped", {})
	_save()
	_changed()
