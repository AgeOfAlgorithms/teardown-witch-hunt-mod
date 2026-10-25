#version 2
#include "script/include/common.lua"
#include "script/include/player.lua"
#include "mplib/hud.lua"
#include "mplib/spectate.lua"
#include "mplib/util.lua"
#include "mplib/spawn.lua"
#include "script/toolanimation.lua"
#include "wh_witch_rig.lua"
#include "wh_spirit_visual.lua"
#include "wh_spirit.lua"
#include "wh_items.lua"
#include "wh_mantle.lua"

-- Witch Hunt: the game mode (gamemodes.txt; any map). Some players are secretly witches; they don't know each other.
-- Lobby (mplib): the host sets the number of witches, the round time, the item amount and the time of day. A round:
-- a short intro tells each player their role (privately), then everyone plays; humans win when every witch is dead,
-- witches when the time runs out or every human is dead. When someone dies everyone is told - but not who, nor which
-- side (the user): 4 s later a bell tolls and "SOMEONE HAS DIED" shows - for any death, accidents included (a player who
-- leaves the game isn't announced). The dead spectate, talk only
-- to each other (Proximity Comms' dead channel) and see a journal the player they watch reads. Dead bodies keep a name.
-- When the time runs out the witches win only if a witch has killed at least one human (the user: else they could hide all
-- round); a human killed by a human or by a fire nobody lit doesn't count.
-- wh_spirit.lua: the witches' spirit form (flight, the claw, fire, the cross's stun); wh_items.lua: the items.
-- (Every script below only shares GLOBALS with its includes: an included file's locals are its own.)

HUD_SCOREBOARD_KEY = "l"     -- (mplib/hud.lua: L during the round - the rules of your side and who is playing)
WH_TEST = false              -- the TEST build (tools/make_test_mod.py): 2 players may start, log lines
MIN_PLAYERS = 3
DEATH_DELAY = 4              -- s after a death before everyone is told (the user)
INTRO_TIME = 6               -- s the role screen shows (everyone frozen)
WH_LOADOUT = {{"wh_fists", 1}}      -- (1: a tool with no ammo can't be selected - wh_items whHideToolCounts)
WH_PICK_WITCHES = false      -- (the TEST build's autotest: a function(players) -> the witches)
WH_NO_END = false            -- (the TEST build's autotest: the round goes on with a side wiped out)
WH_ALIVE_KEY = "witchhunt.alive"   -- GetTime() of the mode's last tick, each machine (the sandbox TEST mod stands aside)

ROUND_KEY = "savegame.mod.wh.roundsec"
WITCH_KEY = "savegame.mod.wh.witches"
ITEMS_KEY = "savegame.mod.wh.items"
WEATHER_KEY = "savegame.mod.wh.weather"

-- a list starting at its default and wrapping round (mplib's stepper is cyclic; a setting not chosen yet and its
-- Reset take the first option) - HvC's
local function steps(first, last, step, default, label)
	local l, n = {}, math.floor((last - first) / step + 0.5) + 1
	local d = math.floor((default - first) / step + 0.5)
	for i = 0, n - 1 do
		local v = first + ((d + i) % n) * step
		l[#l + 1] = {label = label(v), value = v}
	end
	return l
end

SETTINGS = {
	{
		title = "",
		items = {
			{key = WITCH_KEY, label = "Wraiths", info = "How many wraiths hide among the players (at most a third of them)",
				options = steps(1, 4, 1, 1, function(v) return v == 1 and "1 wraith" or (v .. " wraiths") end)},
			{key = ROUND_KEY, label = "Round time", info = "The wraiths win if they survive this long",
				options = steps(120, 900, 30, 360, function(v) return string.format("%d:%02d", math.floor(v / 60), v % 60) end)},
			{key = ITEMS_KEY, label = "Items", info = "How many items lie around the map",
				options = {{label = "Normal", value = 1}, {label = "Many", value = 1.6}, {label = "Few", value = 0.6}}},
			{key = WEATHER_KEY, label = "Time of day", info = "For everyone (the map's own: leave it as it is)",
				options = {{label = "Night", value = "night"}, {label = "Evening", value = "sunset"}, {label = "Day", value = "sunny"},
					{label = "Foggy", value = "foggy"}, {label = "Rainy night", value = "rainynight"}, {label = "The map's own", value = "map"}}},
		},
	},
}

-- the Spawn-tag log trick (only in the TEST build): a line "<body tags='whtest ...'/>" in log.txt
function whLog(s)
	if not WH_TEST then return end
	local ok, ents = pcall(Spawn, "<body tags='whtest " .. tostring(s):gsub("[^%w%._:=,%-]", "_") .. "'/>", Transform(Vec(0, -500, 0)))
	if ok and type(ents) == "table" then for _, h in ipairs(ents) do Delete(h) end end
end

----- server -----

local G = {phase = "lobby", t = 0, roundTime = 360, nWitches = 1, items = 1, weather = "night", witch = {}, roster = {},
	late = {}, alive = {}, kills = {}, killedBy = {}, witchKills = 0, announce = {}, winner = "", pubT = -1, rev = 0, roleT = -100, startT = 0,
	lobbyMsgT = -100}
local spawns = {}

function whIsWitch(p) return G.witch[p] == true end           -- (server)
function whPhase() return G.phase end
-- (the sandbox TEST mod: switch a player's side mid-round; a spirit turns back first)
function whSetWitch(p, on)
	if not on and whServerIsSpirit(p) then whSpiritOnDeath(p) end
	G.witch[p] = on and true or nil
	G.roleT = -100
end
function whInRound(p) return G.roster[p] == true and not G.late[p] end
function whPlayStart() return G.startT end
function whWitchList()
	local l = {}
	for p in pairs(G.witch) do l[#l + 1] = p end
	return l
end

local function publish(force)
	local now = GetTime()
	if not force and now - G.pubT < 0.2 then return end
	G.pubT = now
	local roster, late = {}, {}
	for p in pairs(G.roster) do roster[p] = true end
	for p in pairs(G.late) do late[p] = true end
	local e = {phase = G.phase, t = G.t, n = G.nWitches, winner = G.winner, roster = roster, late = late, rev = G.rev,
		lobbyMsg = now - G.lobbyMsgT < 4}
	if G.phase == "over" then                                    -- (the results: the roles are no secret any more)
		local witches, kills, by = {}, {}, {}
		for p in pairs(G.witch) do witches[p] = true end
		for p, n in pairs(G.kills) do kills[p] = n end
		for p, k in pairs(G.killedBy) do by[p] = k end
		e.witches, e.kills, e.killedBy = witches, kills, by
		local alive = {}
		for p in pairs(G.alive) do alive[p] = true end
		e.alive = alive
	end
	shared.wh = e
end

function server.init()
	spawns = utilLoadLevelPlayerSpawns()
	if #spawns == 0 then spawns = utilLoadLevelPlayerSpawns(1) end
	if #spawns == 0 then spawns = utilGenerateSpawnPoints(32) end
	hudInit(true)
	spawnInit()
	mantleServerInit()
	spawnSetRespawnTime(99999)                                   -- (nobody comes back during a round)
	spawnSetDefaultLoadout(WH_LOADOUT)
	whSpiritServerInit()
	whItemsServerInit()
	publish(true)
end

-- the host's Start (hudDrawGameSetup): the settings; the round begins in server.tick (at least MIN_PLAYERS)
function server.start(settings)
	G.roundTime = tonumber(settings.roundTime) or 360
	G.nWitches = math.floor(tonumber(settings.witches) or 1)
	G.items = tonumber(settings.items) or 1
	G.weather = settings.weather or "night"
end

local function shuffled(list)
	local l = {}
	for i = 1, #list do l[i] = list[i] end
	for i = #l, 2, -1 do local j = math.random(1, i); l[i], l[j] = l[j], l[i] end
	return l
end

-- HvC's spawn check: no vehicle or loose object within ~1 m up to the player's height, not inside a wall; else the
-- nearest clear spot on the ground around it
local function spawnClear(pos, height)
	for _, b in ipairs(QueryAabbBodies(VecAdd(pos, Vec(-1.1, 0.15, -1.1)), VecAdd(pos, Vec(1.1, height, 1.1))) or {}) do
		if GetBodyVehicle(b) ~= 0 or IsBodyDynamic(b) then return false end
	end
	for _, sh in ipairs(QueryAabbShapes(VecAdd(pos, Vec(-0.35, 0.3, -0.35)), VecAdd(pos, Vec(0.35, height, 0.35))) or {}) do
		local b = GetShapeBody(sh)
		if b ~= 0 and not IsBodyDynamic(b) then return false end
	end
	return true
end

local function clearSpawn(t, height)
	if not t then return t end
	if spawnClear(t.pos, height) then return t end
	for r = 1.5, 7.5, 1.5 do
		for k = 0, 7 do
			local a = k / 8 * 2 * math.pi + r
			local top = VecAdd(t.pos, Vec(math.cos(a) * r, height + 1, math.sin(a) * r))
			local hit, d = QueryRaycast(top, Vec(0, -1, 0), height + 4)
			if hit then
				local ground = VecAdd(top, Vec(0, -d + 0.05, 0))
				if spawnClear(ground, height) then return Transform(ground, t.rot) end
			end
		end
	end
	return t
end

-- everyone starts together roughly in the middle of the map (the user): the spawn point nearest the play area's centre (a
-- map's own or a generated one - known good ground, not the centre itself, which may be in a wall or in water), and the
-- players in a loose ring 2-4 m round it, each put on the ground there and checked for room (clearSpawn)
local function centralAnchor()
	if #spawns == 0 then return nil end
	local mn, mx = GetBoundaryBounds()
	local c
	if mn and mx and mx[1] - mn[1] > 1 then
		c = Vec((mn[1] + mx[1]) / 2, 0, (mn[3] + mx[3]) / 2)
	else                                                         -- (no boundary: the middle of the spawn points)
		c = Vec(0, 0, 0)
		for _, t in ipairs(spawns) do c = VecAdd(c, VecScale(t.pos, 1 / #spawns)) end
	end
	local best, bd = nil, 1e9
	for _, t in ipairs(spawns) do
		local d = (t.pos[1] - c[1]) ^ 2 + (t.pos[3] - c[3]) ^ 2
		if d < bd then best, bd = t, d end
	end
	return best
end

-- a spot in the ring: ground within about a metre of the anchor's height (a ray from 1.6 m above it: one from higher up
-- put a player on a roof, 14 m from the other - autotest on Isla Estocastica) with room to stand; other angles and a
-- tighter ring if not; else beside the anchor
local function ringSpawn(anchor, i, n)
	local a0 = (i - 1) / math.max(1, n) * 2 * math.pi + math.random() * 0.5
	for try = 0, 11 do
		local a = a0 + try * 0.55
		local r = (try < 6 and 2 or 1.2) + math.random() * 1.5
		local top = Vec(anchor.pos[1] + math.cos(a) * r, anchor.pos[2] + 1.6, anchor.pos[3] + math.sin(a) * r)
		local hit, d = QueryRaycast(top, Vec(0, -1, 0), 3)
		if hit then
			local ground = VecAdd(top, Vec(0, -d + 0.05, 0))
			if math.abs(ground[2] - anchor.pos[2]) < 1.1 and spawnClear(ground, 1.9) then
				return Transform(ground, QuatEuler(0, math.deg(a) + 180 + math.random() * 60 - 30, 0))   -- (facing roughly inward)
			end
		end
	end
	return clearSpawn(anchor, 1.9)
end

local function playerList()
	local l = {}
	for p in Players() do l[#l + 1] = p end
	return l
end

function whMaxWitches(n) return math.max(1, math.floor(n / 3)) end
-- (a test build starts with two; the sandbox's MIN_PLAYERS = 1 holds in its test build too)
function whMinPlayers() return WH_TEST and math.min(2, MIN_PLAYERS) or MIN_PLAYERS end

local function beginRound()
	-- (Lua's random is never seeded: HvC drew the same "random" spawns every launch)
	SetInt("savegame.mod.wh.rounds", GetInt("savegame.mod.wh.rounds") + 1)
	math.randomseed(math.floor(GetTime() * 1000) % 1000000 + GetInt("savegame.mod.wh.rounds") * 7919)
	for i = 1, 5 do math.random() end
	local ps = shuffled(playerList())
	local nw = math.max(1, math.min(G.nWitches, whMaxWitches(#ps)))
	G.witch, G.roster, G.late, G.alive, G.kills, G.killedBy, G.witchKills, G.announce = {}, {}, {}, {}, {}, {}, 0, {}
	for i, p in ipairs(ps) do
		G.roster[p] = true
		G.alive[p] = true
		if i <= nw then G.witch[p] = true end
	end
	if WH_PICK_WITCHES then
		G.witch = {}
		for _, p in ipairs(WH_PICK_WITCHES(ps)) do G.witch[p] = true end
	end
	G.nWitches = nw
	if G.weather ~= "map" then applyWeather(G.weather) end
	local anchor = centralAnchor()
	for i, p in ipairs(shuffled(ps)) do
		spawnSpawnPlayer(anchor and ringSpawn(anchor, i, #ps) or nil, WH_LOADOUT, p)
	end
	G.rev = G.rev + 1
	G.winner = ""
	G.phase, G.t = "intro", INTRO_TIME
	G.roleT = -100
	whSpiritReset()
	whItemsBeginRound(#ps, G.items)
	whLog("round players=" .. #ps .. " witches=" .. nw)
	publish(true)
end

local function endRound(winner)
	G.phase, G.winner, G.t = "over", winner, 0
	local k = winner == "humans" and "witchhunt.tally.h" or "witchhunt.tally.w"   -- (the session's: survives Play Again)
	SetInt(k, GetInt(k) + 1)
	whSpiritReset()
	whItemsEndRound()
	whLog("over winner=" .. winner)
	publish(true)
end

-- each player is told their role privately (ClientCall), again every 2 s during the round (a lost call, a late script)
local function tellRoles(now)
	if now - G.roleT < 2 then return end
	G.roleT = now
	for p in pairs(G.roster) do
		if IsPlayerValid(p) then ClientCall(p, "client.whRole", G.rev, G.witch[p] == true, G.witch[p] == true and G.witchKills == 0) end
	end
end

-- Proximity Comms (if the host runs it): everyone hears everyone in the lobby and on the results; during the round the
-- dead and the late joiners talk only to each other (and hear everyone): its dead channel
local function chatKeys()
	local open = G.phase == "lobby" or G.phase == "over"
	SetBool("proxchat.lobby", open)
	for p in Players() do
		local out = not open and (G.late[p] or (G.roster[p] and not G.alive[p]))
		SetString("proxchat.channel." .. p, out and "dead" or "")
		if GetInt("proxchat.version") >= PINGANON_VERSION then   -- (a spirit's pins without her name: client.tick)
			SetBool("proxchat.pinganon." .. p, not open and whServerIsSpirit(p))
		end
	end
end
PINGANON_VERSION = 16

-- deaths: who died this frame (everyone is told that someone did, never who), who killed them (the engine's playerdied event, else
-- the last one who hurt them: wh_spirit / wh_items report with whNoteHurt)
local lastHurt = {}
function whNoteHurt(victim, attacker) lastHurt[victim] = {p = attacker, t = GetTime()} end

local function deaths(now)
	local by = {}
	for i = 1, GetEventCount("playerdied") do
		local victim, attacker = GetEvent("playerdied", i)
		if victim and attacker and attacker ~= 0 and attacker ~= victim then by[victim] = attacker end
	end
	for p in pairs(G.roster) do
		if G.alive[p] and (not IsPlayerValid(p) or GetPlayerHealth(p) <= 0) then
			G.alive[p] = nil
			local k = by[p] or (lastHurt[p] and now - lastHurt[p].t < 10 and lastHurt[p].p) or nil
			if k and k ~= p then
				G.killedBy[p] = k
				G.kills[k] = (G.kills[k] or 0) + 1
				if G.witch[k] and not G.witch[p] then G.witchKills = G.witchKills + 1; G.roleT = -100 end   -- (the witches told at once)
			end
			whSpiritOnDeath(p)
			whItemsOnDeath(p)
			if IsPlayerValid(p) then G.announce[#G.announce + 1] = now + DEATH_DELAY end   -- (any death; not a leaver)
			whLog("died p=" .. p .. " by=" .. tostring(k) .. " witch=" .. tostring(G.witch[p] == true))
		end
	end
end

local function checkWin()
	if WH_NO_END then return end
	local w, h = 0, 0
	for p in pairs(G.alive) do
		if IsPlayerValid(p) then
			if G.witch[p] then w = w + 1 else h = h + 1 end
		end
	end
	if w == 0 then endRound("humans")
	elseif h == 0 then endRound("witches")
	elseif G.t <= 0 then endRound(G.witchKills > 0 and "witches" or "humans") end   -- (no human killed by a witch: the humans)
end

function server.tick(dt)
	local now = GetTime()
	SetFloat(WH_ALIVE_KEY, now)
	chatKeys()
	if G.phase == "lobby" then
		for p in Players() do DisablePlayer(p) end
		if hudGameIsSetup() then
			local n = #playerList()
			if n >= whMinPlayers() then
				beginRound()
			else
				shared._hud.gameIsSetup = false                      -- (Start refused: too few players)
				G.lobbyMsgT = now
				publish(true)
			end
		end
		publish(false)
		return
	end
	if G.phase == "intro" or G.phase == "play" then          -- joined mid-round: a spectator until the next round
		for p in Players() do
			if not G.roster[p] then
				if not G.late[p] then
					G.late[p] = true
					SetPlayerHealth(0, p)                            -- (dead: mplib's spectating takes over on their machine)
					publish(true)
				end
				DisablePlayer(p)
			end
		end
		tellRoles(now)
	end
	if G.phase == "intro" then
		G.t = G.t - dt
		for p in Players() do DisablePlayerInput(p) end
		if G.t <= 0 then
			G.phase, G.t, G.startT = "play", G.roundTime, now
			whSpiritStartPlay(now)
			whLog("play")
			publish(true)
		end
		whSpiritTick(dt, false)
		whItemsTick(dt, false)
	elseif G.phase == "play" then
		G.t = G.t - dt
		whSpiritTick(dt, true)
		whItemsTick(dt, true)
		deaths(now)
		for i = #G.announce, 1, -1 do                                -- (to everyone, DEATH_DELAY s on: no name, no side)
			if now >= G.announce[i] then
				ClientCall(0, "client.whDeath", G.rev)
				table.remove(G.announce, i)
			end
		end
		if G.phase == "play" then checkWin() end
	else
		whSpiritTick(dt, false)
		whItemsTick(dt, false)
		for p in Players() do DisablePlayerInput(p) end
	end
	publish(false)
end

function server.update(dt)
	mantleServerUpdate(dt)
	if G.phase == "play" then whSpiritUpdate(dt) end
end

-- mantling (wh_mantle.lua, as Humans vs Clickers): not in wraith form (she flies) nor while applying a medkit (held
-- still), nor outside the round; its rays pass through the wraith models (WV_SHAPES: on the host they share the scene)
function mantleBlocked(p)
	return whServerIsSpirit(p) or not whInRound(p) or (type(shared.whMed) == "table" and shared.whMed[p] ~= nil)
end
function mantleQueryMask() if #WV_SHAPES > 0 then QueryRejectShapes(WV_SHAPES) end end

function server.postUpdate()
	if G.phase == "play" then whItemsPostUpdate() end
end

----- client -----

local C = {rev = -1, witch = false, roleT0 = -100, needKill = false, deathT = -100, toll = nil}
DEATH_SHOW = 4             -- s "SOMEONE HAS DIED" stays

function client.whDeath(rev)
	if rev ~= C.rev and C.rev ~= -1 then return end            -- (a late call from an earlier round)
	C.deathT = GetTime()
	whLog("death announced")
	if C.toll then PlaySound(C.toll, GetCameraTransform().pos, 1.0, false) end
end
function whAmWitch() return C.witch end                         -- (client: this machine's player, told by the server)
function whRoundRev() return C.rev end

function client.whRole(rev, witch, needKill)
	if rev ~= C.rev then C.roleT0 = GetTime() end
	C.rev, C.witch, C.needKill = rev, witch == true, needKill == true
end

local function inRound(e) return e and (e.phase == "intro" or e.phase == "play") end

function client.init()
	C.toll = LoadSound("MOD/snd/death_toll.ogg")
	whSpiritClientInit()
	whItemsClientInit()
end

function client.destroy()
	SetBool("level.hidenameplates", false)
	whVisualClear()
end

-- the players still in the round, for spectating (never the dead, never late joiners)
local function spectateList(e)
	local list = {}
	for p in Players() do
		if e.roster and e.roster[p] and not (e.late and e.late[p]) and GetPlayerHealth(p) > 0 and not IsPlayerDisabled(p) then
			list[#list + 1] = p
		end
	end
	return list
end

function whSpectating()
	local e = shared.wh
	local me = GetLocalPlayer()
	if not inRound(e) then return nil end
	if GetPlayerHealth(me) > 0 and not (e.late and e.late[me]) then return nil end
	return _spectateState and _spectateState.enabled and _spectateState.currPlayer or nil
end

function client.tick(dt)
	SetFloat(WH_ALIVE_KEY, GetTime())
	hudTick(dt)
	SetLowHealthBlurThreshold(0.2)
	local e = shared.wh
	local round = inRound(e) or false
	if GetBool("level.hidenameplates") ~= round then SetBool("level.hidenameplates", round) end   -- (ours: drawNames)
	if e and e.phase == "play" then
		spectateTick(spectateList(e))
		local sp = whSpectating()
		if _spectateState then _spectateState.hideLabel = sp ~= nil and whIsSpirit(sp) end   -- (a spirit has no name)
	end
	whSpiritClientTick(dt)
	whItemsClientTick(dt)
	mantleClientTick(true)                                       -- (wh_mantle.lua: the pull-up's camera dip)
	-- pings (Proximity Comms: as far as the pinger's talk mode): no teams - witches ping as everyone does, spirits too,
	-- and whoever stands near sees it (the user: witches mind where they stand), without her name (proxchat.pinganon, API
	-- 16: chatKeys). Her ray passes her own model. An older chat would show her name: her ray aims at the empty sky
	if e and e.phase == "play" and whIsSpirit(GetLocalPlayer()) then
		if GetInt("proxchat.version") >= PINGANON_VERSION then
			-- her model is spawned on each machine: negative (local) handles, which the chat refuses with a warning on
			-- screen every frame (the user; still so in API 17, 2026-10-24 - a version gate guessed wrong once): only
			-- handles it takes are sent, so none for now (her pin may land on her own model in first person)
			local skip = {}
			for _, b in ipairs(whVisualBodies(GetLocalPlayer())) do if b > 0 then skip[#skip + 1] = b end end
			if #skip > 0 then SetString("proxchat.pingskip", table.concat(skip, " ")) end
		else
			local c = GetCameraTransform()
			SetString("proxchat.aim", string.format("%f %f %f 0 1 0", c.pos[1], c.pos[2] + 2000, c.pos[3]))
		end
	end
end

local function clock(t)
	t = math.max(0, math.ceil(t))
	return string.format("%d:%02d", math.floor(t / 60), t % 60)
end

function whBigText(y, size, text, r, g, b, a)
	UiPush()
	UiTranslate(UiCenter(), y)
	UiAlign("center middle")
	UiFont("bold.ttf", size)
	UiColor(r, g, b, a or 1)
	UiText(text)
	UiPop()
end

-- names over players (ours; the engine's nameplates are off during the round): a living player in plain sight shows
-- their name - except a spirit, whose name only witches see. The dead and late joiners see what a human sees.
-- a living player's name: only on screen, in plain sight (nothing solid between your view and them - mplib's
-- hudDrawWorldMarkers casts the ray) and under NAME_RANGE m away (the user: 40 m or more, no name)
NAME_RANGE = 40
local function nameMarker(p, color)
	local up = GetPlayerUp(p)
	return {pos = VecAdd(GetPlayerTransform(p).pos, up), offset = VecScale(up, 1.2), color = color, label = GetPlayerName(p),
		lineOfSightRequired = true, maxRange = NAME_RANGE - 0.01, icon = "ui/hud/team-direction.png", drawIconInView = false, player = p}
end

local function drawNames(e, me)
	local witchEyes = C.witch and GetPlayerHealth(me) > 0
	local markers = {}
	for p in Players() do
		if p ~= me and IsPlayerValid(p) and GetPlayerHealth(p) > 0 and not IsPlayerDisabled(p) and e.roster and e.roster[p] then
			if whIsSpirit(p) then
				if witchEyes then markers[#markers + 1] = nameMarker(p, {0.75, 0.9, 1.0, 1}) end
			else
				markers[#markers + 1] = nameMarker(p, {1, 1, 1, 1})
			end
		end
	end
	hudDrawWorldMarkers(markers)
end

-- the dead keep their names: a label over the body, read from within ~3.5 m in plain sight
local function bodyPos(p)
	local anim = GetPlayerAnimator(p)
	if anim and anim ~= 0 then
		local ok, t = pcall(GetBoneWorldTransform, anim, "head")
		if ok and t and t.pos then return t.pos end
	end
	return VecAdd(GetPlayerTransform(p).pos, Vec(0, 0.4, 0))
end

local function drawBodies(e)
	local cam = GetCameraTransform().pos
	for p in Players() do
		if e.roster and e.roster[p] and not (e.late and e.late[p]) and GetPlayerHealth(p) <= 0 then
			local pos = bodyPos(p)
			local d = VecLength(VecSub(pos, cam))
			if d < 3.5 then
				local dir = VecScale(VecSub(pos, cam), 1 / math.max(d, 0.01))
				local hit = QueryRaycast(cam, dir, math.max(0, d - 0.3))
				if not hit then
					local x, y, dist = UiWorldToPixel(VecAdd(pos, Vec(0, 0.35, 0)))
					if dist > 0 then
						UiPush()
						UiTranslate(x, y)
						UiAlign("center middle")
						UiFont("bold.ttf", 22)
						UiColor(0, 0, 0, 0.6)
						UiRect(UiGetTextSize(GetPlayerName(p)) + 18, 30)
						UiColor(0.85, 0.8, 0.75, math.min(1, (3.5 - d) / 0.8))
						UiTextDisableWildcards(true)
						UiText(GetPlayerName(p))
						UiPop()
					end
				end
			end
		end
	end
end

local function drawIntro(e, me)
	UiPush(); UiColor(0, 0, 0, 0.75); UiRect(UiWidth(), UiHeight()); UiPop()
	local n = e.n or 1
	if C.rev ~= e.rev then
		whBigText(UiMiddle(), 30, "...", 1, 1, 1)
		return
	end
	local a = math.min(1, (GetTime() - C.roleT0) / 0.6)
	if C.witch then
		whBigText(UiMiddle() - 70, 72, "YOU ARE A WRAITH", 0.85, 0.15, 0.12, a)
		whBigText(UiMiddle() + 5, 26, "Kill every human - or kill at least one and survive until the time runs out.", 0.9, 0.9, 0.9, a)
		whBigText(UiMiddle() + 45, 22, n > 1 and ("There are " .. n .. " wraiths. You don't know who the others are.") or
			"You are the only wraith.", 0.8, 0.8, 0.8, a)
		whBigText(UiMiddle() + 85, 20, "Q: wraith form (15 s, then 60 s to recover) - fly with Space / Crouch, LMB: claw. Fire burns you out.",
			0.75, 0.75, 0.75, a)
	else
		whBigText(UiMiddle() - 70, 72, "YOU ARE HUMAN", 0.75, 0.85, 1.0, a)
		whBigText(UiMiddle() + 5, 26, (n > 1 and (n .. " wraiths hide") or "A wraith hides") .. " among you. Kill " ..
			(n > 1 and "them all" or "her") .. " - or prevent " .. (n > 1 and "them" or "her") .. " from killing anyone before the time runs out.", 0.9, 0.9, 0.9, a)
		whBigText(UiMiddle() + 45, 22, "Journals tell who is a wraith - or who is human. Fire forces a wraith out of hiding. Holy crosses stun them.", 0.8, 0.8, 0.8, a)
		whBigText(UiMiddle() + 85, 20, "E: pick up   G: drop   Don't trust anyone.", 0.75, 0.75, 0.75, a)
	end
	whBigText(UiHeight() - 80, 22, "The hunt begins in " .. math.ceil(e.t or 0), 0.8, 0.8, 0.8, 0.9)
end

local function drawPlay(e, me)
	hudDrawTimer(e.t, 1.0)
	local da = GetTime() - C.deathT                                 -- (someone died: everyone sees it, nobody sees who)
	if da < DEATH_SHOW then
		local a = math.min(1, da / 0.4) * math.min(1, (DEATH_SHOW - da) / 1.0)
		whBigText(UiMiddle() - 220, 46, "SOMEONE HAS DIED", 0.86, 0.9, 0.96, a)
	end
	drawNames(e, me)
	drawBodies(e)
	local late = e.late and e.late[me]
	if late then
		whBigText(110, 28, "JOINED MID-ROUND - you are watching", 0.85, 0.85, 0.9, 0.9)
		whBigText(145, 18, "You play from the next round. You can talk with the dead.", 0.75, 0.75, 0.75, 0.85)
		spectateDraw()
	elseif GetPlayerHealth(me) <= 0 then
		whBigText(110, 28, "YOU ARE DEAD - spectating", 1, 0.4, 0.35, 0.9)
		whBigText(145, 18, "Only the dead hear you now.", 0.75, 0.75, 0.75, 0.85)
		spectateDraw()
	else
		UiPush()                                                   -- (your role, small, top left)
		UiTranslate(40, 40)
		UiAlign("left middle")
		UiFont("bold.ttf", 22)
		if C.witch then UiColor(0.9, 0.25, 0.2, 0.9); UiText("WRAITH") else UiColor(0.75, 0.85, 1, 0.9); UiText("HUMAN") end
		UiTranslate(0, 26)
		UiFont("regular.ttf", 18)
		UiColor(0.85, 0.85, 0.85, 0.75)
		UiText((e.n or 1) == 1 and "1 wraith in this round" or ((e.n or 1) .. " wraiths in this round"))
		if C.witch and C.needKill then
			UiTranslate(0, 24)
			UiColor(1, 0.45, 0.4, 0.85)
			UiText("No human has died at a wraith's hand yet - kill one before the time runs out")
		end
		UiTranslate(0, 24)
		UiColor(0.85, 0.85, 0.85, 0.55)
		UiText("L: rules and players")
		UiPop()
	end
	if not late and hudIsScoreboardRequested() and not whChatTyping() then whDrawRoundRules(e) end
end

local function resultGroups(e)
	local groups = {
		{name = "Wraiths", color = {0.85, 0.2, 0.15}, rows = {}},
		{name = "Humans", color = {0.35, 0.65, 1.0}, rows = {}},
	}
	for p in Players() do
		if e.roster and e.roster[p] then
			local status = (e.alive and e.alive[p]) and "alive" or "dead"
			local k = e.killedBy and e.killedBy[p]
			local by = k and IsPlayerValid(k) and GetPlayerName(k) or (k and "?" or "-")
			local row = {player = p, columns = {status, tostring((e.kills or {})[p] or 0), status == "dead" and by or "-"}}
			local g = (e.witches and e.witches[p]) and groups[1] or groups[2]
			g.rows[#g.rows + 1] = row
		end
	end
	return groups
end

local RESULT_COLUMNS = {{name = "Status", align = "center"}, {name = "Kills", align = "center"}, {name = "Killed by", align = "center"}}

local function drawResults(e)
	local groups = resultGroups(e)
	local win = e.winner == "witches"
	local banner = win and "THE WRAITHS WIN" or "THE HUMANS WIN"
	local color = win and {0.5, 0.06, 0.08, 0.8} or {0.15, 0.35, 0.6, 0.8}
	if win then groups[2].dim = true else groups[1].dim = true; groups[1], groups[2] = groups[2], groups[1] end
	local th, tw = GetInt("witchhunt.tally.h"), GetInt("witchhunt.tally.w")
	hudDrawResults(banner, color, string.format("Wraith Hunt   (this session: humans %d, wraiths %d)", th, tw), RESULT_COLUMNS, groups)
end

-- Proximity Comms (HvC's lobby chat): Enter opens it through its API; while typing the lobby isn't drawn
local function chatAlive() return GetFloat("proxchat.alive") > GetTime() - 2 end
local function chatTyping() return GetBool("proxchat.typing." .. GetLocalPlayer()) end
local function lobbyChatOpening() return chatAlive() and not chatTyping() and InputPressed("return") end
function whChatTyping() return chatAlive() and chatTyping() end

local function chatHint()
	if not chatAlive() or chatTyping() then return end
	UiPush()
	UiTranslate(40, UiHeight() - 40)
	UiAlign("left middle")
	UiFont("bold.ttf", 20)
	UiColor(1, 1, 1, 0.75)
	local key = GetString("proxchat.key.open")
	UiText((key ~= "" and key or "Enter") .. ": chat")
	UiPop()
end

local function chattingNote()
	whBigText(60, 22, "Chatting - Enter: send, Esc: close", 1, 1, 1, 0.8)
end

-- the rules (the user: the lobby explains the game; L in the round shows your side's)
RULES_INTRO = "Some of you are secretly wraiths in human form - and the wraiths don't know each other. When someone dies, everyone hears it - but not who."
RULES_HUMAN = {
	"Win by killing all the wraiths, or by preventing them from killing anyone before the time runs out.",
	"Fire reveals a wraith: 2 s in fire forces her out of human form into wraith form.",
	"Journals say who is a wraith - or who is human - to the reader only. Put one down and it crumbles.",
	"Hold a holy cross up (LMB) at a wraith in wraith form to freeze her. It works twice, then cracks.",
	"Pistol, knife, flamethrower (fuel for about two wraiths), medkit, sensor, walkie-talkie, speakerphone.",
	"E: pick up   G: drop",
}
RULES_WITCH = {
	"Kill every human - or kill at least one and survive until the time runs out.",
	"Q: wraith form for 15 s, then 60 s to recover. Fly with Space / Crouch.",
	"In wraith form, LMB claws: three strikes kill. Bullets and blades pass through you.",
	"Fire hurts you in either form - and 2 s in fire throws you out of human form.",
	"Other wraiths see your name in wraith form. Humans don't.",
	"Never touch a holy cross.",
}

-- a rules panel: a title and a list, wrapped to width w, its top left at the cursor; the height it took
function whDrawRules(w, title, rgb, lines, size)
	size = size or 20
	local pad, gap = 22, 8
	local function body(draw)
		local y = pad
		UiPush()
		UiAlign("left top")
		UiTranslate(pad, pad)
		UiFont("bold.ttf", size + 10)
		UiColor(rgb[1], rgb[2], rgb[3], draw and 1 or 0)
		local _, h = UiText(title)
		UiTranslate(0, h + 10); y = y + h + 10
		UiFont("regular.ttf", size)
		UiWordWrap(w - pad * 2 - 18)
		for _, l in ipairs(lines) do
			UiPush()
			UiColor(rgb[1], rgb[2], rgb[3], draw and 0.9 or 0)
			UiText("-")
			UiTranslate(18, 0)
			UiColor(0.9, 0.92, 0.95, draw and 0.95 or 0)
			local _, lh = UiText(l)
			UiPop()
			UiTranslate(0, lh + gap); y = y + lh + gap
		end
		UiPop()
		return y + pad - gap
	end
	local h = body(false)
	UiPush()
	UiAlign("left top")
	UiColor(0.02, 0.03, 0.05, 0.78)
	UiRoundedRect(w, h, 10)
	UiColor(rgb[1], rgb[2], rgb[3], 0.6)
	UiRect(w, 3)
	UiPop()
	body(true)
	return h
end

local HUMAN_RGB, WITCH_RGB = {0.95, 0.78, 0.45}, {0.6, 0.88, 1.0}

-- the lobby: the premise above the player list, the humans' rules on its left, the witches' on its right
local function drawLobbyRules()
	local w = math.min(520, UiCenter() - 230)
	if w < 300 then return end
	UiPush()
	UiTextDisableWildcards(true)
	UiPush()
	UiTranslate(UiCenter(), UiMiddle() - 300)
	UiAlign("center middle")
	UiFont("bold.ttf", 24)
	UiColor(0.9, 0.93, 0.97, 0.95)
	UiWordWrap(900)
	UiText(RULES_INTRO)
	UiPop()
	UiPush()
	UiTranslate(UiCenter() - 200 - w, UiMiddle() - 240)
	whDrawRules(w, "HUMANS", HUMAN_RGB, RULES_HUMAN)
	UiPop()
	UiPush()
	UiTranslate(UiCenter() + 200, UiMiddle() - 240)
	whDrawRules(w, "WRAITHS", WITCH_RGB, RULES_WITCH)
	UiPop()
	UiPop()
end

-- L in the round: the rules of your own side, and who is in the round (names only: never who is dead)
function whDrawRoundRules(e)
	local witch = C.witch
	local w = 640
	UiPush()
	UiTextDisableWildcards(true)
	UiTranslate(UiCenter() - w - 20, UiMiddle() - 220)
	whDrawRules(w, witch and "YOU ARE A WRAITH" or "YOU ARE HUMAN", witch and WITCH_RGB or HUMAN_RGB, witch and RULES_WITCH or RULES_HUMAN, 21)
	UiPop()
	local names = {}
	for p in Players() do
		if e.roster and e.roster[p] then names[#names + 1] = GetPlayerName(p) end
	end
	UiPush()
	UiTextDisableWildcards(true)
	UiTranslate(UiCenter() + 20, UiMiddle() - 220)
	whDrawRules(360, "PLAYERS (" .. (e.n or 1) .. (e.n == 1 and " wraith)" or " wraiths)"), {0.85, 0.87, 0.9}, names, 21)
	UiPop()
end

local function drawLobby(e)
	local typing = chatAlive() and chatTyping()
	local opening = lobbyChatOpening()
	if typing then chattingNote(); return end
	UiPush()
	if opening then UiDisableInput() end
	drawLobbyRules()
	hudDrawPlayerList()
	local n = #GetAllPlayers()
	local need = whMinPlayers()
	if not hudGameIsSetup() then
		if hudDrawGameSetup(SETTINGS) and not opening then
			ServerCall("server.start", {roundTime = GetFloat(ROUND_KEY), witches = GetFloat(WITCH_KEY), items = GetFloat(ITEMS_KEY),
				weather = GetString(WEATHER_KEY)})
		end
	end
	UiPop()
	if n < need or (e and e.lobbyMsg) then
		whBigText(UiMiddle() + 270, 22, "Wraith Hunt needs at least " .. need .. " players (" .. n .. " here)",
			1, (e and e.lobbyMsg) and 0.4 or 0.85, (e and e.lobbyMsg) and 0.35 or 0.85, 0.9)
	end
	chatHint()
	if opening then SetBool("proxchat.open", true) end
end

function client.draw(dt)
	local e = shared.wh
	if not e or e.phase == "lobby" then drawLobby(e); hudDrawFade(dt); return end
	local me = GetLocalPlayer()
	if e.phase == "intro" then
		drawIntro(e, me)
	elseif e.phase == "play" then
		whSpiritClientDraw()
		whItemsClientDraw()
		drawPlay(e, me)
		hudDrawDamageIndicators(dt)
	elseif e.phase == "over" then
		local typing = chatAlive() and chatTyping()
		local opening = lobbyChatOpening()
		if typing then
			chattingNote()
		else
			UiPush()
			if opening then UiDisableInput() end
			drawResults(e)
			UiPop()
			chatHint()
			if opening then SetBool("proxchat.open", true) end
		end
	end
	hudDrawFade(dt)
end

function client.render(dt)
	whSpiritClientRender(dt)
	local e = shared.wh
	if e and e.phase == "play" then spectateRender(dt) end
end

function client.postUpdate(dt)
	whItemsClientPostUpdate(dt)
	mantleClientPostUpdate()
end

----- the time of day (HvC's copy of the game's data/script/weather.lua presets; server) -----

local function nightDark()
	SetEnvironmentProperty("skyboxbrightness", 0.02)
	SetEnvironmentProperty("sunBrightness", 0)
	SetEnvironmentProperty("ambient", 0.2)
	SetEnvironmentProperty("constant", 0.0004, 0.0004, 0.0005)
	SetEnvironmentProperty("fogColor", 0.006, 0.006, 0.008)
	SetEnvironmentProperty("exposure", 1, 1.8)
end

function applyWeather(env)
	SetEnvironmentDefault()
	SetPostProcessingDefault()
	if env == "sunset" then
		SetEnvironmentProperty("skybox", "sunset.dds")
		SetEnvironmentProperty("skyboxtint", 1, 0.5, 0.2)
		SetEnvironmentProperty("fogColor", 0.3, 0.2, 0.08)
		SetEnvironmentProperty("fogParams", 80, 200, 1, 6)
		SetEnvironmentProperty("sunBrightness", 1)
		SetEnvironmentProperty("sunColorTint", 0.2, 0.3, 1)
		SetEnvironmentProperty("sunFogScale", 1.0)
		SetEnvironmentProperty("sunGlare", 0.8)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("nightlight", false)
	elseif env == "sunny" then
		SetEnvironmentProperty("skybox", "day.dds")
		SetEnvironmentProperty("skyboxbrightness", 0.7)
		SetEnvironmentProperty("fogColor", 0.9, 0.9, 0.9)
		SetEnvironmentProperty("fogParams", 50, 200, 0.9, 8)
		SetEnvironmentProperty("sunBrightness", 4)
		SetEnvironmentProperty("sunColorTint", 1, 0.8, 0.6)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("sunFogScale", 0.15)
		SetEnvironmentProperty("nightlight", false)
	elseif env == "night" then
		SetEnvironmentProperty("skybox", "cloudy.dds")
		SetEnvironmentProperty("fogParams", 20, 120, 0.9, 2)
		nightDark()
		SetEnvironmentProperty("ambience", "outdoor/night.ogg")
		SetEnvironmentProperty("nightlight", true)
		SetPostProcessingProperty("gamma", 0.9)
		SetPostProcessingProperty("bloom", 1.5)
	elseif env == "foggy" then
		SetEnvironmentProperty("skybox", "cloudy.dds")
		SetEnvironmentProperty("skyboxtint", 1.0, 0.6, 0.4)
		SetEnvironmentProperty("fogType", "exp2")
		SetEnvironmentProperty("fogColor", 0.48, 0.46, 0.42)
		SetEnvironmentProperty("fogParams", 18.0, 0.3, 1.0, 0.22)
		SetEnvironmentProperty("fogHeightOffset", -31.5)
		SetEnvironmentProperty("exposure", 1, 5)
		SetEnvironmentProperty("wetness", 0.4)
		SetEnvironmentProperty("puddleamount", 0.3)
		SetEnvironmentProperty("nightlight", false)
		SetEnvironmentProperty("slippery", 0.1)
	elseif env == "rainynight" then
		SetEnvironmentProperty("skybox", "cloudy.dds")
		SetEnvironmentProperty("fogParams", 10, 90, 0.9, 2)
		nightDark()
		SetEnvironmentProperty("wetness", 0.7)
		SetEnvironmentProperty("puddleamount", 0.7)
		SetEnvironmentProperty("puddlesize", 0.7)
		SetEnvironmentProperty("rain", 0.9)
		SetEnvironmentProperty("ambience", "outdoor/rain_heavy.ogg")
		SetEnvironmentProperty("nightlight", true)
		SetEnvironmentProperty("slippery", 0.3)
		SetPostProcessingProperty("gamma", 0.9)
		SetPostProcessingProperty("bloom", 1.5)
	end
end
