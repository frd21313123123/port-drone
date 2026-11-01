extends SceneTree


















const ALPHABET: String = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const MAX_PEERS: int = 4


const TURN_TTL: int = 4 * 3600
const MAX_CONN_PER_IP: int = 8
const MAX_ROOMS_PER_IP: int = 3
const MAX_MSG_PER_S: int = 30
const MAX_JOINS_PER_MIN: int = 10
const IDLE_NO_ROOM_S: float = 60.0
const IDLE_IN_ROOM_S: float = 70.0
const MAX_CLIENTS: int = 5000
const MAX_ROOMS: int = 2000
const LIST_MAX: int = 30
const NAME_MAX: int = 16

var _tcp: = TCPServer.new()
var _tls: TLSOptions = null
var _pending: Array = []
var _clients: Dictionary = {}
var _rooms: Dictionary = {}
var _next_key: int = 1
var _stun: PackedStringArray = []
var _turn: PackedStringArray = []
var _secret: String = ""
var _cf_key: String = ""
var _cf_token: String = ""
var _cf_api: String = "https://rtc.live.cloudflare.com"
const CF_STUN: Dictionary = {"urls": ["stun:stun.cloudflare.com:3478"]}
var _proxied: bool = false



func _initialize() -> void:
	Engine.max_fps = 30
	var port: int = 9080
	var bind: String = "*"
	var cert: String = ""
	var key: String = ""
	for a: String in OS.get_cmdline_user_args():
		var v: String = a.get_slice("=", 1)
		if a.begins_with("--port="):
			port = int(v)
		elif a.begins_with("--bind="):
			bind = v
		elif a.begins_with("--stun="):
			_stun = v.split(",", false)
		elif a.begins_with("--turn="):
			_turn = v.split(",", false)
		elif a.begins_with("--cert="):
			cert = v
		elif a.begins_with("--key="):
			key = v
		elif a.begins_with("--cf-api="):
			_cf_api = v
		elif a == "--behind-proxy":
			_proxied = true
	_secret = OS.get_environment("DF_TURN_SECRET")
	_cf_key = OS.get_environment("DF_CF_TURN_KEY_ID")
	_cf_token = OS.get_environment("DF_CF_TURN_TOKEN")
	if cert != "" and key != "":
		var c: = X509Certificate.new()
		var k: = CryptoKey.new()
		if c.load(cert) != OK or k.load(key) != OK:
			printerr("[Signal] cannot load TLS cert / key")
			quit(1)
			return
		_tls = TLSOptions.server(k, c)
	var err: int = _tcp.listen(port, bind)
	if err != OK:
		printerr("[Signal] cannot listen on %d: %s" % [port, error_string(err)])
		quit(1)
		return
	var turn_mode: String = "Cloudflare Realtime TURN" if _cf_key != "" and _cf_token != "" else ("own coturn" if not _turn.is_empty() and _secret != "" else "OFF (no --turn + DF_TURN_SECRET, no DF_CF_TURN_KEY_ID + DF_CF_TURN_TOKEN)")
	print("[Signal] listening on %d (%s), TURN: %s%s" % [port, "wss" if _tls != null else "ws", turn_mode, ", behind a proxy (client IP from ?rip=)" if _proxied else ""])


func _process(_delta: float) -> bool:
	while _tcp.is_connection_available():
		var tcp: StreamPeerTCP = _tcp.take_connection()
		var ip: String = tcp.get_connected_host()
		if _clients.size() + _pending.size() >= MAX_CLIENTS or (not _proxied and _count_ip(ip) >= MAX_CONN_PER_IP):
			tcp.disconnect_from_host()
			continue
		var s: StreamPeer = tcp
		if _tls != null:
			var t: = StreamPeerTLS.new()
			t.accept_stream(s, _tls)
			s = t
		_pending.append([s, null, Time.get_ticks_msec(), ip])
	for i in range(_pending.size() - 1, -1, -1):
		var p: Array = _pending[i]
		if p[1] == null:
			if p[0] is StreamPeerTLS:
				(p[0] as StreamPeerTLS).poll()
				if (p[0] as StreamPeerTLS).get_status() == StreamPeerTLS.STATUS_HANDSHAKING:
					continue
				if (p[0] as StreamPeerTLS).get_status() != StreamPeerTLS.STATUS_CONNECTED:
					_pending.remove_at(i)
					continue
			var ws: = WebSocketPeer.new()
			ws.accept_stream(p[0])
			p[1] = ws
		var w: WebSocketPeer = p[1]
		w.poll()
		var st: int = w.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			var cip: String = String(p[3])
			if _proxied:
				cip = _url_ip(w.get_requested_url(), cip)
				if _count_ip(cip) >= MAX_CONN_PER_IP:
					w.close(1008, "too many connections")
					_pending.remove_at(i)
					continue
			_clients[_next_key] = {"ws": w, "room": "", "id": 0, "ip": cip, "t0": Time.get_ticks_msec(), "last": Time.get_ticks_msec(),
				"msg_s": 0, "msg_n": 0, "join_m": 0, "join_n": 0}
			_next_key += 1
			_pending.remove_at(i)
		elif st == WebSocketPeer.STATE_CLOSED or Time.get_ticks_msec() - int(p[2]) > 8000:
			_pending.remove_at(i)
	for ck: int in _clients.keys():
		var cl: Dictionary = _clients[ck]
		var ws2: WebSocketPeer = cl["ws"]
		ws2.poll()
		if ws2.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_drop(ck)
			continue
		var now_ms: int = Time.get_ticks_msec()
		if String(cl["room"]) == "" and now_ms - int(cl["t0"]) > int(IDLE_NO_ROOM_S * 1000.0):
			ws2.close(1000, "idle")
			_drop(ck)
			continue
		if String(cl["room"]) != "" and now_ms - int(cl["last"]) > int(IDLE_IN_ROOM_S * 1000.0):
			ws2.close(1000, "dead")
			_drop(ck)
			continue
		var bad: bool = false
		while ws2.get_available_packet_count() > 0:
			var pkt: PackedByteArray = ws2.get_packet()
			cl["last"] = now_ms
			var sec: int = now_ms / 1000
			if int(cl["msg_s"]) != sec:
				cl["msg_s"] = sec
				cl["msg_n"] = 0
			cl["msg_n"] = int(cl["msg_n"]) + 1
			if int(cl["msg_n"]) > MAX_MSG_PER_S or pkt.size() > 16384:
				bad = true
				break
			var d: Variant = JSON.parse_string(pkt.get_string_from_utf8())
			if d is Dictionary:
				_on_msg(ck, d)
			if not _clients.has(ck):
				break
		if bad and _clients.has(ck):
			ws2.close(1008, "rate")
			_drop(ck)
	return false



func _url_ip(url: String, fallback: String) -> String:
	var q: int = url.find("rip=")
	if q < 0:
		return fallback
	var v: String = url.substr(q + 4).get_slice("&", 0).uri_decode()
	return v if v.is_valid_ip_address() else fallback


func _count_ip(ip: String) -> int:
	var n: int = 0
	for k: int in _clients:
		if String(_clients[k]["ip"]) == ip:
			n += 1
	for p: Array in _pending:
		if String(p[3]) == ip:
			n += 1
	return n


func _send(ck: int, d: Dictionary) -> void:
	if _clients.has(ck):
		(_clients[ck]["ws"] as WebSocketPeer).send_text(JSON.stringify(d))


func _on_msg(ck: int, d: Dictionary) -> void:
	var cl: Dictionary = _clients[ck]
	match String(d.get("t", "")):
		"host":
			if String(cl["room"]) != "":
				return
			var mine: int = 0
			for k: int in _clients:
				var o: Dictionary = _clients[k]
				if String(o["ip"]) == String(cl["ip"]) and int(o["id"]) == 1:
					mine += 1
			if mine >= MAX_ROOMS_PER_IP or _rooms.size() >= MAX_ROOMS:
				_send(ck, {"t": "error", "why": "Слишком много комнат с одного адреса"})
				return
			var want: String = String(d.get("code", "")).to_upper()
			var code: String = want if _code_ok(want) and not _rooms.has(want) else _new_code()
			_rooms[code] = {"v": String(d.get("v", "")), "peers": {1: ck}, "next": 2, "sealed": false,
				"pub": bool(d.get("pub", false)), "name": _clean_name(String(d.get("name", ""))), "t": Time.get_ticks_msec()}
			cl["room"] = code
			cl["id"] = 1
			_with_ice(ck, 1, func(ice: Array) -> void: _send(ck, {"t": "room", "code": code, "ice": ice}))
			print("[Signal] room %s opened (%d rooms)" % [code, _rooms.size()])
		"join":
			var minute: int = Time.get_ticks_msec() / 60000
			if int(cl["join_m"]) != minute:
				cl["join_m"] = minute
				cl["join_n"] = 0
			cl["join_n"] = int(cl["join_n"]) + 1
			if int(cl["join_n"]) > MAX_JOINS_PER_MIN:
				_send(ck, {"t": "error", "why": "Слишком много попыток входа, подождите минуту"})
				return
			var code2: String = String(d.get("code", "")).to_upper()
			var r: Dictionary = _rooms.get(code2, {})
			var why: String = ""
			if r.is_empty():
				why = "Комната %s не найдена" % code2
			elif String(r["v"]) != String(d.get("v", "")):
				why = "Другая версия игры у хоста: обновите игру"
			elif bool(r["sealed"]) and not bool(d.get("rejoin", false)):
				why = "Партия уже идёт"
			elif bool(r["sealed"]) and not (r.get("toks", []) as Array).has(String(d.get("tok_h", ""))):
				why = "Партия уже идёт"
			elif (r["peers"] as Dictionary).size() >= MAX_PEERS and not bool(r["sealed"]):
				why = "Комната заполнена"
			if why != "":
				_send(ck, {"t": "error", "why": why})
				return
			var id: int = int(r["next"])
			r["next"] = id + 1
			(r["peers"] as Dictionary)[id] = ck
			cl["room"] = code2
			cl["id"] = id
			_with_ice(ck, id, func(ice: Array) -> void: _send(ck, {"t": "joined", "id": id, "code": code2, "ice": ice}))
			_send(int(r["peers"][1]), {"t": "peer", "id": id})
		"seal":
			var r2: Dictionary = _rooms.get(String(cl["room"]), {})
			if not r2.is_empty() and int(cl["id"]) == 1:
				r2["sealed"] = true
				var th: Array = []
				for h: Variant in (d.get("toks", []) as Array):
					if h is String and String(h).length() == 64:
						th.append(String(h))
				r2["toks"] = th.slice(0, MAX_PEERS)
		"set_pub":
			var r4: Dictionary = _rooms.get(String(cl["room"]), {})
			if not r4.is_empty() and int(cl["id"]) == 1:
				r4["pub"] = bool(d.get("pub", false))
		"list":
			cl["t0"] = Time.get_ticks_msec()
			_send(ck, {"t": "rooms", "rooms": _public_rooms()})
		"peek":
			cl["t0"] = Time.get_ticks_msec()
			var pc: String = String(d.get("code", "")).to_upper()
			var pr: Dictionary = _rooms.get(pc, {}) if _code_ok(pc) else {}
			_send(ck, {"t": "peek", "code": pc, "open": not pr.is_empty() and bool(pr.get("sealed", false))})
		"offer", "answer", "cand":
			var r3: Dictionary = _rooms.get(String(cl["room"]), {})
			var to: int = int(d.get("to", 0))
			if r3.is_empty() or not (r3["peers"] as Dictionary).has(to):
				return
			d["from"] = int(cl["id"])
			d.erase("to")
			_send(int(r3["peers"][to]), d)


func _drop(ck: int) -> void:
	var cl: Dictionary = _clients[ck]
	_clients.erase(ck)
	var code: String = String(cl["room"])
	if code == "" or not _rooms.has(code):
		return
	var r: Dictionary = _rooms[code]
	var peers: Dictionary = r["peers"]
	peers.erase(int(cl["id"]))
	if int(cl["id"]) == 1:
		for id: int in peers:
			_send(int(peers[id]), {"t": "error", "why": "Хост закрыл комнату"})
		_rooms.erase(code)
		print("[Signal] room %s closed" % code)
	elif peers.has(1):
		_send(int(peers[1]), {"t": "left", "id": int(cl["id"])})



func _public_rooms() -> Array:
	var out: Array = []
	for code: String in _rooms:
		var r: Dictionary = _rooms[code]
		var n: int = (r["peers"] as Dictionary).size()
		if bool(r.get("pub", false)) and not bool(r["sealed"]) and n < MAX_PEERS:
			out.append({"code": code, "name": String(r.get("name", "")), "n": n, "max": MAX_PEERS, "v": String(r["v"]), "t": int(r.get("t", 0))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["n"]) > int(b["n"]) if int(a["n"]) != int(b["n"]) else int(a["t"]) > int(b["t"]))
	out = out.slice(0, LIST_MAX)
	for e: Dictionary in out:
		e.erase("t")
	return out



static func _clean_name(s: String) -> String:
	var o: String = ""
	for ch: String in s.strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			o += ch
	return o.left(NAME_MAX)


func _code_ok(c: String) -> bool:
	if c.length() != 6:
		return false
	for ch: String in c:
		if ALPHABET.find(ch) < 0:
			return false
	return true


func _new_code() -> String:
	var code: String = ""
	while code == "" or _rooms.has(code):
		code = ""
		for i in 6:
			code += ALPHABET[randi() % ALPHABET.length()]
	return code





func _with_ice(ck: int, id: int, done: Callable) -> void:
	if _cf_key == "" or _cf_token == "":
		done.call(_ice(id))
		return
	var req: = HTTPRequest.new()
	req.timeout = 8.0
	root.add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		req.queue_free()
		var ice: Array = [CF_STUN]
		if result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
			var d: Variant = JSON.parse_string(body.get_string_from_utf8())
			if d is Dictionary and (d as Dictionary).get("iceServers") is Array:
				ice = _cf_filter((d as Dictionary)["iceServers"])
		else:
			printerr("[Signal] Cloudflare TURN credentials failed: result %d, HTTP %d" % [result, code])
		if _clients.has(ck):
			done.call(ice))
	var url: String = "%s/v1/turn/keys/%s/credentials/generate-ice-servers" % [_cf_api, _cf_key.uri_encode()]
	var err: int = req.request(url, ["Authorization: Bearer " + _cf_token, "Content-Type: application/json"],
		HTTPClient.METHOD_POST, JSON.stringify({"ttl": TURN_TTL}))
	if err != OK:
		req.queue_free()
		printerr("[Signal] Cloudflare TURN request not sent: %s" % error_string(err))
		done.call([CF_STUN])



func _cf_filter(servers: Array) -> Array:
	var out: Array = []
	for sv: Variant in servers:
		if not (sv is Dictionary):
			continue
		var e: Dictionary = (sv as Dictionary).duplicate()
		var urls: Array = []
		for u: Variant in (e.get("urls", []) if e.get("urls") is Array else [e.get("urls", "")]):
			if not String(u).contains(":53?") and not String(u).ends_with(":53"):
				urls.append(String(u))
		if not urls.is_empty():
			e["urls"] = urls
			out.append(e)
	return out if not out.is_empty() else [CF_STUN]



func _ice(id: int) -> Array:
	var out: Array = []
	if not _stun.is_empty():
		out.append({"urls": Array(_stun)})
	if not _turn.is_empty() and _secret != "":
		var user: String = "%d:df%d" % [int(Time.get_unix_time_from_system()) + TURN_TTL, id]
		var mac: PackedByteArray = Crypto.new().hmac_digest(HashingContext.HASH_SHA1, _secret.to_utf8_buffer(), user.to_utf8_buffer())
		out.append({"urls": Array(_turn), "username": user, "credential": Marshalls.raw_to_base64(mac)})
	return out
