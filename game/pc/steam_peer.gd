extends MultiplayerPeerExtension
## PC port: Godot's high-level multiplayer over Steam Networking Messages (GodotSteam).
## A star like ENet: the host is peer 1, every guest talks to the host only (the server relays).
## Peer ids come from the Steam account ids, so both sides agree without a handshake for ids;
## a HELLO / WELCOME pair (with a random nonce per connection) tells real links from stale ones.

const CH: int = 3  # the Steam message channel of the game's traffic (the lobby uses none)
const SEND_UNRELIABLE: int = 1  # k_nSteamNetworkingSend_UnreliableNoNagle
const SEND_RELIABLE: int = 9  # k_nSteamNetworkingSend_ReliableNoNagle
const MAX_SIZE: int = 512 * 1024 - 64

enum T { DATA, HELLO, WELCOME, BYE, PING, REFUSE }

const PING_S: float = 1.0
const HELLO_EVERY_S: float = 1.0
const CONNECT_GIVE_UP_S: float = 25.0
const TIMEOUT_S: float = 45.0  # no traffic (pings included) for this long = the link is gone

var api: Object = null
var host_mode: bool = false
var my_sid: int = 0
var my_peer_id: int = 0
var host_sid: int = 0
var nonce: int = 0
var status: int = MultiplayerPeer.CONNECTION_DISCONNECTED
var links: Dictionary = {}  # peer id -> {"sid": int, "nonce": int, "seen": msec}
var queue: Array = []  # [peer, channel, mode, PackedByteArray]
var target: int = 0
var tmode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var tchan: int = 0
var refusing: bool = false
var _t_ping: int = 0
var _t_hello: int = 0
var _t_start: int = 0
var _dbg: bool = OS.get_environment("DF_STEAM_DEBUG") != ""
var _dbg_t: int = 0
var _n_in: int = 0
var _n_out: int = 0


static func peer_id_of(sid: int) -> int:
	var acc: int = sid & 0xFFFFFFFF
	return int(acc % 2147483000) + 2


func create_host(steam_api: Object, own_sid: int) -> Error:
	api = steam_api
	host_mode = true
	my_sid = own_sid
	my_peer_id = 1
	nonce = randi() & 0x7FFFFFFF
	status = MultiplayerPeer.CONNECTION_CONNECTED
	return OK


func create_client(steam_api: Object, own_sid: int, host: int) -> Error:
	if host == 0 or host == own_sid:
		return ERR_INVALID_PARAMETER
	api = steam_api
	host_mode = false
	my_sid = own_sid
	host_sid = host
	my_peer_id = peer_id_of(own_sid)
	nonce = (randi() & 0x7FFFFFFF) | 1
	status = MultiplayerPeer.CONNECTION_CONNECTING
	_t_start = Time.get_ticks_msec()
	_t_hello = 0
	return OK


## SteamNet asks: may a Steam session from this account be accepted?
func wants_session(sid: int) -> bool:
	if status == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return false
	return host_mode or sid == host_sid


func session_failed(sid: int) -> void:
	if host_mode:
		var pid: int = peer_id_of(sid)
		if links.has(pid):
			_drop(pid)
	elif sid == host_sid:
		_lose_host()


# ---------------------------------------------------------------- wire

func _send(sid: int, kind: int, n: int, payload: PackedByteArray = PackedByteArray(), ch: int = 0, mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE) -> void:
	if api == null:
		return
	var b: PackedByteArray = PackedByteArray()
	b.resize(7)
	b.encode_u8(0, kind)
	b.encode_u32(1, n)
	b.encode_u8(5, ch)
	b.encode_u8(6, mode)
	if not payload.is_empty():
		b.append_array(payload)
	_n_out += 1
	var flags: int = SEND_RELIABLE if (kind != T.DATA or mode != MultiplayerPeer.TRANSFER_MODE_UNRELIABLE) else SEND_UNRELIABLE
	api.call("sendMessageToUser", sid, b, flags, CH)


func _now() -> int:
	return Time.get_ticks_msec()


# ---------------------------------------------------------------- MultiplayerPeer

func _poll() -> void:
	if api == null or status == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	for _i in 16:
		var msgs: Array = api.call("receiveMessagesOnChannel", CH, 64)
		for m: Variant in msgs:
			if m is Dictionary:
				_on_msg(int((m as Dictionary).get("identity", 0)), (m as Dictionary).get("payload", PackedByteArray()))
			if status == MultiplayerPeer.CONNECTION_DISCONNECTED:
				return
		if msgs.size() < 64:
			break
	var now: int = _now()
	if _dbg and now - _dbg_t > 3000:
		_dbg_t = now
		print("[SteamDbg] %s nonce=%d status=%d links=%s in=%d out=%d queue=%d" % ["host" if host_mode else "guest", nonce, status, str(links.keys()), _n_in, _n_out, queue.size()])
	if not host_mode and status == MultiplayerPeer.CONNECTION_CONNECTING:
		if now - _t_hello >= int(HELLO_EVERY_S * 1000.0):
			_t_hello = now
			_send(host_sid, T.HELLO, nonce)
		if now - _t_start > int(CONNECT_GIVE_UP_S * 1000.0):
			print("[Steam] the host did not answer")
			status = MultiplayerPeer.CONNECTION_DISCONNECTED  # SceneMultiplayer: connection_failed
		return
	if now - _t_ping >= int(PING_S * 1000.0):
		_t_ping = now
		for pid: int in links.keys():
			var l: Dictionary = links[pid]
			_send(int(l["sid"]), T.PING, int(l["nonce"]) if host_mode else nonce)
	for pid: int in links.keys():
		if now - int((links[pid] as Dictionary)["seen"]) > int(TIMEOUT_S * 1000.0):
			print("[Steam] peer %d timed out" % pid)
			if host_mode:
				_drop(pid)
			else:
				_lose_host()
				return


func _on_msg(sid: int, b: PackedByteArray) -> void:
	if b.size() < 7:
		return
	_n_in += 1
	var kind: int = b.decode_u8(0)
	var n: int = b.decode_u32(1)
	var ch: int = b.decode_u8(5)
	var mode: int = b.decode_u8(6)
	if host_mode:
		var pid: int = peer_id_of(sid)
		match kind:
			T.HELLO:
				if links.has(pid) and int(links[pid]["nonce"]) == n:
					_send(sid, T.WELCOME, n)  # a repeated hello: the welcome got lost
					return
				if refusing:
					_send(sid, T.REFUSE, n)
					return
				if links.has(pid):
					_drop(pid)  # the same person on a new link: the old one is stale
				links[pid] = {"sid": sid, "nonce": n, "seen": _now()}
				_send(sid, T.WELCOME, n)
				peer_connected.emit(pid)
			T.DATA:
				if links.has(pid) and int(links[pid]["nonce"]) == n:
					links[pid]["seen"] = _now()
					queue.append([pid, ch, mode, b.slice(7)])
			T.PING:
				if links.has(pid) and int(links[pid]["nonce"]) == n:
					links[pid]["seen"] = _now()
			T.BYE:
				if links.has(pid) and int(links[pid]["nonce"]) == n:
					_drop(pid, false)
		return
	if sid != host_sid or n != nonce:
		return
	match kind:
		T.WELCOME:
			if status == MultiplayerPeer.CONNECTION_CONNECTING:
				links[1] = {"sid": host_sid, "nonce": nonce, "seen": _now()}
				status = MultiplayerPeer.CONNECTION_CONNECTED
				peer_connected.emit(1)
		T.REFUSE:
			if status == MultiplayerPeer.CONNECTION_CONNECTING:
				print("[Steam] the host refused (room closed)")
				status = MultiplayerPeer.CONNECTION_DISCONNECTED
		T.DATA:
			if links.has(1):
				links[1]["seen"] = _now()
				queue.append([1, ch, mode, b.slice(7)])
		T.PING:
			if links.has(1):
				links[1]["seen"] = _now()
		T.BYE:
			_lose_host(false)


func _drop(pid: int, say_bye: bool = true) -> void:
	var l: Dictionary = links.get(pid, {})
	print("[Steam] link to peer %d closed%s" % [pid, "" if say_bye else " by the guest"])
	links.erase(pid)
	if say_bye and not l.is_empty():
		_send(int(l["sid"]), T.BYE, int(l["nonce"]))
	peer_disconnected.emit(pid)


func _lose_host(say_bye: bool = true) -> void:
	print("[Steam] link to the host closed%s" % ("" if say_bye else " by the host"))
	if say_bye and status != MultiplayerPeer.CONNECTION_DISCONNECTED:
		_send(host_sid, T.BYE, nonce)
	var had: bool = links.has(1)
	links.clear()
	queue.clear()
	status = MultiplayerPeer.CONNECTION_DISCONNECTED
	if had:
		peer_disconnected.emit(1)


func _put_packet_script(p_buffer: PackedByteArray) -> Error:
	if status != MultiplayerPeer.CONNECTION_CONNECTED:
		return ERR_UNCONFIGURED
	if p_buffer.size() > MAX_SIZE:
		push_error("[Steam] packet too big: %d" % p_buffer.size())
		return ERR_OUT_OF_MEMORY
	if not host_mode:
		if links.has(1):
			_send(host_sid, T.DATA, nonce, p_buffer, tchan, tmode)
		return OK
	for pid: int in links.keys():
		if target == 0 or target == pid or (target < 0 and -target != pid):
			var l: Dictionary = links[pid]
			_send(int(l["sid"]), T.DATA, int(l["nonce"]), p_buffer, tchan, tmode)
	return OK


func _get_available_packet_count() -> int:
	return queue.size()


func _get_packet_script() -> PackedByteArray:
	if queue.is_empty():
		return PackedByteArray()
	var q: Array = queue.pop_front()
	return q[3]


func _get_packet_peer() -> int:
	return int(queue[0][0]) if not queue.is_empty() else 0


func _get_packet_channel() -> int:
	return int(queue[0][1]) if not queue.is_empty() else 0


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return (int(queue[0][2]) if not queue.is_empty() else MultiplayerPeer.TRANSFER_MODE_RELIABLE) as MultiplayerPeer.TransferMode


func _get_max_packet_size() -> int:
	return MAX_SIZE


func _set_transfer_channel(p_channel: int) -> void:
	tchan = p_channel


func _get_transfer_channel() -> int:
	return tchan


func _set_transfer_mode(p_mode: MultiplayerPeer.TransferMode) -> void:
	tmode = p_mode


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return tmode as MultiplayerPeer.TransferMode


func _set_target_peer(p_peer: int) -> void:
	target = p_peer


func _is_server() -> bool:
	return host_mode


func _is_server_relay_supported() -> bool:
	return true


func _get_unique_id() -> int:
	return my_peer_id


func _set_refuse_new_connections(p_enable: bool) -> void:
	refusing = p_enable


func _is_refusing_new_connections() -> bool:
	return refusing


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return status as MultiplayerPeer.ConnectionStatus


func _disconnect_peer(p_peer: int, _p_force: bool) -> void:
	if host_mode:
		if links.has(p_peer):
			_drop(p_peer)
	elif p_peer == 1:
		_lose_host()


func _close() -> void:
	if status == MultiplayerPeer.CONNECTION_DISCONNECTED and links.is_empty():
		return
	if host_mode:
		for pid: int in links.keys():
			var l: Dictionary = links[pid]
			_send(int(l["sid"]), T.BYE, int(l["nonce"]))
		links.clear()  # like ENet: closing emits nothing (the session is being torn down)
	elif status != MultiplayerPeer.CONNECTION_DISCONNECTED:
		_send(host_sid, T.BYE, nonce)
		links.clear()
	queue.clear()
	status = MultiplayerPeer.CONNECTION_DISCONNECTED
