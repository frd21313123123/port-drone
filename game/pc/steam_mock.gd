extends RefCounted
## PC port, tests only (DF_STEAM_MOCK=<steam id>): a local stand-in for the GodotSteam calls SteamNet
## uses. Messages go over UDP on 127.0.0.1, lobbies are JSON files in /tmp/df_steam_mock.
## Same signal names and argument order as GodotSteam 4.x.

signal lobby_created(connect: int, lobby_id: int)
signal lobby_joined(lobby: int, permissions: int, locked: bool, response: int)
signal lobby_match_list(lobbies: Array)
signal join_requested(lobby_id: int, steam_id: int)
signal network_messages_session_request(remote_steam_id: int)
signal network_messages_session_failed(reason: int, remote_steam_id: int, connection_state: int, debug_message: String)

const DIR: String = "/tmp/df_steam_mock"
const BASE_PORT: int = 41000

var sid: int = 0
var udp: PacketPeerUDP = null
var accepted: Dictionary = {}
var asked: Dictionary = {}
var held: Dictionary = {}  # sid -> Array of messages waiting for acceptSessionWithUser
var inbox: Array = []
var _events: Array = []  # deferred signals: [name, args]
var _filters: Dictionary = {}


static func port_of(id: int) -> int:
	return BASE_PORT + int(id % 1000)


func steamInitEx(_app: int, _embed: bool) -> Dictionary:
	sid = int(OS.get_environment("DF_STEAM_MOCK"))
	if sid == 0:
		return {"status": 1, "verbal": "mock: bad id"}
	DirAccess.make_dir_recursive_absolute(DIR)
	udp = PacketPeerUDP.new()
	var err: int = udp.bind(port_of(sid), "127.0.0.1")
	if err != OK:
		return {"status": 1, "verbal": "mock: port busy"}
	# a «friend invite» for tests: DF_STEAM_MOCK_INVITE=<lobby id> after a few seconds
	var inv: String = OS.get_environment("DF_STEAM_MOCK_INVITE")
	if inv != "":
		(Engine.get_main_loop() as SceneTree).create_timer(float(OS.get_environment("DF_STEAM_MOCK_INVITE_S")) if OS.get_environment("DF_STEAM_MOCK_INVITE_S") != "" else 8.0).timeout.connect(func() -> void:
			var lid: int = int(inv)
			if lid == 0:
				lid = _first_lobby()
			_events.append(["join_requested", [lid, 1]]))
	return {"status": 0, "verbal": "mock ok"}


func _first_lobby() -> int:
	var d: DirAccess = DirAccess.open(DIR)
	if d == null:
		return 0
	for f: String in d.get_files():
		if f.begins_with("lobby_"):
			return int(f.trim_prefix("lobby_").trim_suffix(".json"))
	return 0


func getSteamID() -> int:
	return sid


func getPersonaName() -> String:
	return "Mock%d" % (sid % 1000)


func initRelayNetworkAccess() -> void:
	pass


func run_callbacks() -> void:
	if udp != null:
		while udp.get_available_packet_count() > 0:
			var b: PackedByteArray = udp.get_packet()
			if b.size() < 8:
				continue
			var from: int = b.decode_s64(0)
			var m: Dictionary = {"payload": b.slice(8), "identity": from, "size": b.size() - 8}
			if accepted.has(from):
				inbox.append(m)
			else:
				if not held.has(from):
					held[from] = []
				(held[from] as Array).append(m)
				if not asked.has(from):
					asked[from] = true
					network_messages_session_request.emit(from)
	var ev: Array = _events
	_events = []
	for e: Array in ev:
		callv("emit_signal", [e[0]] + e[1])


func acceptSessionWithUser(remote: int) -> bool:
	accepted[remote] = true
	inbox.append_array(held.get(remote, []))
	held.erase(remote)
	return true


func closeSessionWithUser(remote: int) -> bool:
	accepted.erase(remote)
	asked.erase(remote)
	return true


func sendMessageToUser(remote: int, data: PackedByteArray, _flags: int, _channel: int) -> int:
	accepted[remote] = true  # the sender's side of a session is open
	var b: PackedByteArray = PackedByteArray()
	b.resize(8)
	b.encode_s64(0, sid)
	b.append_array(data)
	udp.set_dest_address("127.0.0.1", port_of(remote))
	var err: int = udp.put_packet(b)
	if err != OK:
		push_error("[SteamMock] send failed (%s): a real Steam would queue it" % error_string(err))
	return 1


func receiveMessagesOnChannel(_channel: int, max_messages: int) -> Array:
	run_callbacks()
	var out: Array = inbox.slice(0, max_messages)
	inbox = inbox.slice(max_messages)
	return out


# ---------------------------------------------------------------- lobbies (files)

func _path(id: int) -> String:
	return DIR.path_join("lobby_%d.json" % id)


func _read(id: int) -> Dictionary:
	var f: FileAccess = FileAccess.open(_path(id), FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	return v if v is Dictionary else {}


func _write(id: int, d: Dictionary) -> void:
	var f: FileAccess = FileAccess.open(_path(id), FileAccess.WRITE)
	f.store_string(JSON.stringify(d))


func createLobby(_type: int, max_members: int) -> void:
	var id: int = 109775240000000000 + (randi() % 100000)
	_write(id, {"owner": str(sid), "members": [str(sid)], "data": {}, "max": max_members, "joinable": true})
	_events.append(["lobby_created", [1, id]])
	_events.append(["lobby_joined", [id, 0, false, 1]])


func setLobbyData(id: int, key: String, value: String) -> bool:
	var d: Dictionary = _read(id)
	if d.is_empty():
		return false
	(d["data"] as Dictionary)[key] = value
	_write(id, d)
	return true


func getLobbyData(id: int, key: String) -> String:
	return String((_read(id).get("data", {}) as Dictionary).get(key, ""))


func setLobbyJoinable(id: int, on: bool) -> bool:
	var d: Dictionary = _read(id)
	if d.is_empty():
		return false
	d["joinable"] = on
	_write(id, d)
	return true


func getNumLobbyMembers(id: int) -> int:
	return (_read(id).get("members", []) as Array).size()


func getLobbyMemberLimit(id: int) -> int:
	return int(_read(id).get("max", 0))


func getLobbyOwner(id: int) -> int:
	return int(String(_read(id).get("owner", "0")))


func addRequestLobbyListStringFilter(key: String, value: String, _cmp: int) -> void:
	_filters[key] = value


func addRequestLobbyListDistanceFilter(_d: int) -> void:
	pass


func requestLobbyList() -> void:
	var ids: Array = []
	var d: DirAccess = DirAccess.open(DIR)
	if d != null:
		for f: String in d.get_files():
			if not f.begins_with("lobby_"):
				continue
			var id: int = int(f.trim_prefix("lobby_").trim_suffix(".json"))
			var l: Dictionary = _read(id)
			if l.is_empty() or not bool(l.get("joinable", false)):
				continue
			var okf: bool = true
			for k: String in _filters:
				if String((l.get("data", {}) as Dictionary).get(k, "")) != String(_filters[k]):
					okf = false
			if okf:
				ids.append(id)
	_filters = {}
	_events.append(["lobby_match_list", [ids]])


func joinLobby(id: int) -> void:
	var d: Dictionary = _read(id)
	if d.is_empty():
		_events.append(["lobby_joined", [id, 0, false, 2]])
		return
	if not bool(d.get("joinable", true)):
		_events.append(["lobby_joined", [id, 0, false, 3]])
		return
	if not (d["members"] as Array).has(str(sid)):
		(d["members"] as Array).append(str(sid))
	_write(id, d)
	_events.append(["lobby_joined", [id, 0, false, 1]])


func leaveLobby(id: int) -> void:
	var d: Dictionary = _read(id)
	if d.is_empty():
		return
	(d["members"] as Array).erase(str(sid))
	if (d["members"] as Array).is_empty():
		DirAccess.remove_absolute(_path(id))
		return
	if String(d["owner"]) == str(sid):
		d["owner"] = (d["members"] as Array)[0]
	_write(id, d)


func activateGameOverlayInviteDialog(id: int) -> void:
	print("[SteamMock] invite dialog for lobby %d" % id)
