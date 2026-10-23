-- Witch Hunt: the items. Included by witchhunt.lua (no #version line); only GLOBALS are shared. Interface:
--   server: whItemsServerInit(), whItemsBeginRound(nPlayers, amount), whItemsEndRound(), whItemsTick(dt, playing),
--           whItemsPostUpdate(), whItemsOnDeath(p)
--   client: whItemsClientInit(), whItemsClientTick(dt), whItemsClientDraw(), whItemsClientPostUpdate(dt)
-- Items lie around the map (spots found on floors, indoors preferred), more appear during the round (counts by the
-- map's size, the players and the host's amount). E picks one up (a witch can't take the holy cross; a spirit takes
-- nothing), G drops the held one, a death drops everything (a journal burns). Everyone has bare hands.
--   pistol (the game's gun) | knife: LMB stab | walkie-talkie: heard from wherever it is, talks while in hand (RMB: off / on)
--   (Proximity Comms devices) | speakerphone: in hand your voice carries far (RMB: off / on) | medkit: hold LMB 5 s, +50 health (RMB: the one in front) |
--   journal: the name of a witch, for the reader only; put it down and it crumbles | flamethrower: hold LMB, fuel for
--   ~2 witches | holy cross: hold LMB up, a spirit close in front is stunned | sensor: LMB, everyone's position 5 s

PISTOL_AMMO = 6
FLAMER_FUEL = 9            -- s of fire (FLAME_DPS 0.26: ~3.9 s kill a witch in the stream)
FLAMER_RANGE = 7
KNIFE_DAMAGE, KNIFE_CD, KNIFE_RANGE = 0.25, 0.55, 1.9
PUNCH_DAMAGE, PUNCH_CD, PUNCH_RANGE = 0.07, 0.6, 1.6
MEDKIT_TIME, MEDKIT_HEAL = 5, 0.5   -- (s to apply it, on yourself or someone else - the user: 5)
MEDKIT_REACH = 2.5          -- m: RMB heals the player in front this close
MEDKIT_GRACE = 0.3          -- s off them before an RMB heal starts over
CROSS_RANGE, CROSS_COS, CROSS_STUN, CROSS_CD = 4, 0.75, 4, 6
CROSS_CHARGES = 2           -- stuns a cross holds (its tool ammo, shown); the last one cracks it to dust (the user)
SENSOR_CD, SENSOR_SHOW = 20, 5
PICK_RANGE = 2.2
WH_PICKUP_ANY = false      -- (the sandbox TEST mod: true - an item already carried is taken anyway, full again)
SPAWN_EVERY = 20           -- s between top-ups during the round
SPAWN_AWAY = 15            -- m from every living player (nobody sees an item appear)

ITEM_DEF = {
	gun = {tool = "gun", label = "Pistol"},
	knife = {tool = "wh_knife", label = "Knife", group = 1},
	walkie = {tool = "wh_walkie", label = "Walkie-talkie", group = 4},
	speaker = {tool = "wh_speaker", label = "Speakerphone", group = 4},
	medkit = {tool = "wh_medkit", label = "Medkit", group = 5},
	journal = {tool = "wh_journal", label = "Journal", group = 6},
	flamer = {tool = "wh_flamer", label = "Flamethrower", group = 2},
	cross = {tool = "wh_cross", label = "Holy cross", group = 3},
	sensor = {tool = "wh_sensor", label = "Sensor", group = 5},
}
ITEM_KINDS = {"gun", "knife", "walkie", "speaker", "medkit", "journal", "flamer", "cross", "sensor"}
KIND_OF = {}
for k, d in pairs(ITEM_DEF) do KIND_OF[d.tool] = k end
WH_TOOLS = {"wh_fists"}
for _, k in ipairs(ITEM_KINDS) do WH_TOOLS[#WH_TOOLS + 1] = ITEM_DEF[k].tool end

----- server -----

local IS = {world = {}, spots = {}, stock = {}, nextSpawn = 0, devices = {}, named = {}, reading = {}, h = {}, regenT = -1}

local function hs(p)
	local h = IS.h[p]
	if not h then
		h = {knifeT = 0, punchT = 0, med = 0, sensorCd = 0, crossCd = 0, journal = nil, flame = false, stateT = -1}
		IS.h[p] = h
	end
	return h
end

function whItemsServerInit()
	RegisterTool("wh_fists", "Hands", "MOD/prefab/fists.xml", 1)
	for _, k in ipairs(ITEM_KINDS) do
		local d = ITEM_DEF[k]
		if d.group then RegisterTool(d.tool, d.label, "MOD/prefab/" .. k .. ".xml", d.group) end
	end
	whHideToolCounts()
end

-- A TOOL WITH NO AMMO CAN'T BE SELECTED: greyed out in the bar, scroll and number keys skip it (the user, in the
-- sandbox: only the gun and the flamethrower would equip; the tests switch tools by script and never saw it). So
-- every item without ammo holds 1, never used up (as the game's capture-the-flag tool), and its count is hidden: the
-- HUD (data/ui/hud.lua) draws game.tool.<id>.ammo.display instead of the number when the key exists, nothing for ""
function whNoAmmo(kind) return kind ~= "gun" and kind ~= "flamer" and kind ~= "cross" end   -- (the cross: its charges)
function whHideToolCounts()
	SetString("game.tool.wh_fists.ammo.display", "")
	for _, k in ipairs(ITEM_KINDS) do
		if whNoAmmo(k) then SetString("game.tool." .. ITEM_DEF[k].tool .. ".ammo.display", "") end
	end
end

-- floors to lay items on: random columns over the map, every floor down each column with room above it; indoors
-- (a roof within 15 m above) preferred
local function findSpots(want)
	local mn, mx = GetBoundaryBounds()
	local spots, indoor = {}, 0
	if not mn or not mx or mx[1] - mn[1] < 1 then mn, mx = Vec(-100, 0, -100), Vec(100, 0, 100) end
	for i = 1, want * 4 do
		if #spots >= want then break end
		local x, z = mn[1] + math.random() * (mx[1] - mn[1]), mn[3] + math.random() * (mx[3] - mn[3])
		local inside, edge = IsPointInBoundaries(Vec(x, 0, z))
		if inside and (edge or 99) > 4 then
			local from = Vec(x, 150, z)
			for floor = 1, 8 do
				QueryRequire("physical large")
				local hit, d, n = QueryRaycast(from, Vec(0, -1, 0), 300)
				if not hit then break end
				local at = VecAdd(from, Vec(0, -d, 0))
				if n and n[2] > 0.7 and not IsPointInWater(VecAdd(at, Vec(0, 0.2, 0))) then
					QueryRequire("physical large")
					local blocked = QueryRaycast(VecAdd(at, Vec(0, 0.1, 0)), Vec(0, 1, 0), 1.9)
					if not blocked then
						QueryRequire("physical large")
						local roof = QueryRaycast(VecAdd(at, Vec(0, 2.0, 0)), Vec(0, 1, 0), 15)
						spots[#spots + 1] = {pos = at, indoor = roof and true or false}
						if roof then indoor = indoor + 1 end
					end
				end
				from = VecAdd(at, Vec(0, -0.45, 0))                   -- (on through the floor to the one below)
				if at[2] < -50 then break end
			end
		end
	end
	return spots, indoor
end

local function itemCount(kind)
	local n = 0
	for b, it in pairs(IS.world) do if it.kind == kind then n = n + 1 end end
	local tool = ITEM_DEF[kind].tool
	for p in Players() do
		if whInRound(p) and GetPlayerHealth(p) > 0 and IsToolEnabled(tool, p) then n = n + 1 end
	end
	return n
end

local function farFromPlayers(pos, r)
	for p in Players() do
		if IsPlayerValid(p) and GetPlayerHealth(p) > 0 and VecLength(VecSub(GetPlayerTransform(p).pos, pos)) < r then return false end
	end
	for b in pairs(IS.world) do
		if IsHandleValid(b) and VecLength(VecSub(GetBodyTransform(b).pos, pos)) < 3 then return false end
	end
	return true
end

local function pickSpot(away)
	local n = #IS.spots
	if n == 0 then return nil end
	for tries = 1, 40 do
		local s = IS.spots[math.random(1, n)]
		if (s.indoor or math.random() < 0.3) and farFromPlayers(s.pos, away) then return s.pos end
	end
	return IS.spots[math.random(1, n)].pos
end

-- a loose item in the world (the tool's own model, a little bigger to be seen), carrying its ammo / journal
local function spawnItem(kind, t, ammo)
	local d = ITEM_DEF[kind]
	local ok, ents = pcall(SpawnTool, d.tool, t, false, 1.2)
	if not ok or type(ents) ~= "table" or #ents == 0 then return nil end
	local body = nil
	for i = #ents, 1, -1 do if GetEntityType(ents[i]) == "body" then body = ents[i]; break end end
	if not body then return nil end
	SetTag(body, "whitem", kind)
	SetTag(body, "interact", "Pick up")
	SetTag(body, "desc", d.label)
	SetTag(body, "nocull")
	for _, sh in ipairs(GetBodyShapes(body) or {}) do SetTag(sh, "nocull") end
	IS.world[body] = {kind = kind, ammo = ammo, ents = ents}
	return body
end

local function defaultAmmo(kind)
	if kind == "gun" then return PISTOL_AMMO elseif kind == "flamer" then return FLAMER_FUEL elseif kind == "cross" then return CROSS_CHARGES end
	return 0
end

local function spawnAt(kind, pos)
	return spawnItem(kind, Transform(VecAdd(pos, Vec(0, 0.25, 0)), QuatEuler(0, math.random() * 360, 0)), defaultAmmo(kind))
end

local function stockFor(n, area, mult)
	local a = math.max(0.4, math.min(4, area / 40000))          -- (a 200 x 200 m map = 1)
	local s = math.sqrt(a)
	local function c(x, lo) return math.max(lo or 1, math.floor(x * mult + 0.5)) end
	return {gun = c(n * 0.25 * s), knife = c(n * 0.3 * s), walkie = c(math.max(2, n * 0.5), 2), speaker = c(s),
		medkit = c(n * 0.35 * s), journal = c(1.5 + a * 1.5, 2), flamer = c(n >= 9 and 2 or 1), cross = c(n * 0.2 * s),
		sensor = c(n >= 8 and 2 or 1)}
end

local function clearWorld()
	for b, it in pairs(IS.world) do
		for _, e in ipairs(it.ents or {}) do if IsHandleValid(e) then Delete(e) end end
		if IsHandleValid(b) then Delete(b) end
	end
	IS.world = {}
end

local function stripTools(p)
	for _, id in ipairs(WH_TOOLS) do if id ~= "wh_fists" then SetToolEnabled(id, false, p); SetToolAmmo(id, 0, p) end end
	SetToolEnabled("gun", false, p)
	SetToolAmmo("gun", 0, p)
end

function whItemsBeginRound(nPlayers, mult)
	clearWorld()
	IS.h, IS.named, IS.reading = {}, {}, {}
	local area = GetBoundaryArea and GetBoundaryArea() or 0
	if not area or area <= 0 then area = 40000 end
	IS.stock = stockFor(nPlayers, area, mult or 1)
	local spots, indoor = findSpots(360)
	IS.spots = spots
	local total = 0
	for _, k in ipairs(ITEM_KINDS) do
		local first = math.max(1, math.floor(IS.stock[k] * 0.7 + 0.5))
		for i = 1, first do
			local pos = pickSpot(8)
			if pos and spawnAt(k, pos) then total = total + 1 end
		end
	end
	IS.nextSpawn = GetTime() + SPAWN_EVERY
	whLog("items area=" .. math.floor(area) .. " spots=" .. #spots .. " indoor=" .. indoor .. " spawned=" .. total)
end

local function setDevice(name, value, seen)
	seen[name] = true
	if IS.devices[name] ~= value then
		IS.devices[name] = value
		SetString("proxchat.device." .. name, value)
	end
end

local function clearDevices()
	for name in pairs(IS.devices) do SetString("proxchat.device." .. name, "") end
	IS.devices = {}
	for p in Players() do SetString("proxchat.tx." .. p, "") end
end

function whItemsEndRound()
	clearDevices()
	for p in Players() do stripTools(p) end
	IS.reading = {}
end

local function note(p, text) ClientCall(p, "client.whNote", text) end

-- a journal names a living witch, the one named least so far (the same witch twice only when there are no others) -
-- or, JOURNAL_HUMAN of the time, clears a living human other than its reader ("<name> is a human!" - the user)
JOURNAL_HUMAN = 0.4
local function journalHuman(reader)
	local pool = {}
	for q in Players() do
		if q ~= reader and whInRound(q) and not whIsWitch(q) and GetPlayerHealth(q) > 0 then pool[#pool + 1] = q end
	end
	if #pool == 0 then return nil end
	return pool[math.random(1, #pool)]
end

local function journalWitch()
	local alive, all = {}, whWitchList()
	for _, w in ipairs(all) do if IsPlayerValid(w) and GetPlayerHealth(w) > 0 then alive[#alive + 1] = w end end
	local pool = #alive > 0 and alive or all
	local best, bn = nil, 999
	for _, w in ipairs(pool) do
		local n = (IS.named[w] or 0) + math.random() * 0.5
		if n < bn then best, bn = w, n end
	end
	if best then IS.named[best] = (IS.named[best] or 0) + 1 end
	return best
end

-- the dead (and late joiners) see the journal of whoever they spectate
local function tellDead(reader, name, seed, what)
	for p in Players() do
		if IsPlayerValid(p) and (GetPlayerHealth(p) <= 0 or not whInRound(p)) then
			if name then ClientCall(p, "client.whJournalOf", reader, name, seed, what) else ClientCall(p, "client.whJournalOf", reader, "", 0, "") end
		end
	end
end

local function give(p, kind, ammo)
	local d = ITEM_DEF[kind]
	local tool = d.tool
	if kind == "cross" and whIsWitch(p) then                     -- (the cross throws her out of her human shape)
		note(p, "The cross sears your hand!")
		whCrossTouch(p)
		return false
	end
	if IsToolEnabled(tool, p) then
		if kind == "gun" or kind == "flamer" then
			SetToolAmmo(tool, GetToolAmmo(tool, p) + (ammo or 0), p)
			whFx("pickup", p)
			return true
		end
		if not WH_PICKUP_ANY then
			note(p, "You already carry a " .. d.label:lower() .. ".")
			return false
		end
		SetToolEnabled(tool, false, p)                           -- (the sandbox: taken anyway - full again, a new page)
	end
	SetToolEnabled(tool, true, p)
	SetToolAmmo(tool, whNoAmmo(kind) and 1 or (ammo or 0), p)   -- (1: selectable - whHideToolCounts)
	SetPlayerTool(tool, p)
	if kind == "journal" then
		local w = math.random() < JOURNAL_HUMAN and journalHuman(p) or nil
		local what = w and "human" or "witch"
		w = w or journalWitch()
		local seed = math.random(1, 9999)
		local name = w and GetPlayerName(w) or "?"
		hs(p).journal = {name = name, seed = seed, seen = false, t = GetTime()}
		IS.reading[p] = {name = name, seed = seed, what = what}
		ClientCall(p, "client.whJournal", name, seed, what)
		tellDead(p, name, seed, what)
		whFx("journal_open", p)
		whLog("journal p=" .. p .. " names=" .. tostring(w) .. " " .. what)
	else
		whFx("pickup", p)
	end
	return true
end

-- (the sandbox TEST mod: hand an item over the way a pickup does - a journal opens with its page)
function whGiveItem(p, kind) return give(p, kind, defaultAmmo(kind)) end

local function burnJournal(p)
	local h = hs(p)
	if not h.journal then return end
	h.journal = nil
	IS.reading[p] = nil
	SetToolEnabled("wh_journal", false, p)
	ClientCall(p, "client.whJournal", "", 0, "")
	tellDead(p, nil)
	whFx("journal_burn", p)
end

local function eye(p) return GetPlayerEyeTransform(p) end
local function fwdOf(t) return TransformToParentVec(t, Vec(0, 0, -1)) end

-- E: the item the engine shows under the crosshair, else the nearest of ours in reach and in view
local function tryPickup(p)
	local b = GetPlayerInteractBody(p)
	if not (b and IS.world[b]) then
		b = nil
		local e = eye(p)
		local f = fwdOf(e)
		local feet = GetPlayerTransform(p).pos
		local best = 999
		for wb in pairs(IS.world) do
			if IsHandleValid(wb) then
				local pos = GetBodyTransform(wb).pos
				local to = VecSub(pos, e.pos)
				local d = VecLength(to)
				local nearFeet = VecLength(VecSub(pos, feet)) < 1.2
				if (d < PICK_RANGE and VecDot(VecScale(to, 1 / math.max(d, 0.01)), f) > 0.5 or nearFeet) and d < best then
					best, b = d, wb
				end
			end
		end
	end
	if not b then return end
	local it = IS.world[b]
	if give(p, it.kind, it.ammo) then
		for _, e in ipairs(it.ents or {}) do if IsHandleValid(e) then Delete(e) end end
		if IsHandleValid(b) then Delete(b) end
		IS.world[b] = nil
	end
end

local function dropTool(p, tool, throw)
	local kind = KIND_OF[tool]
	if not kind then return end
	if kind == "journal" then burnJournal(p); return end
	local ammo = GetToolAmmo(tool, p)
	SetToolEnabled(tool, false, p)
	SetToolAmmo(tool, 0, p)
	if not whNoAmmo(kind) and ammo <= 0 then return end         -- (spent: gone)
	local e = eye(p)
	local pos = throw and VecAdd(e.pos, VecScale(fwdOf(e), 0.6)) or VecAdd(GetPlayerTransform(p).pos, Vec((math.random() - 0.5) * 0.8, 0.6, (math.random() - 0.5) * 0.8))
	local body = spawnItem(kind, Transform(pos, QuatEuler(0, math.random() * 360, 0)), ammo)
	if body and throw then SetBodyVelocity(body, VecScale(fwdOf(e), 2.5)) end
	whFx("drop", p)
end

function server.whDrop(p)
	if not IsPlayerValid(p) or not whInRound(p) or GetPlayerHealth(p) <= 0 or whServerIsSpirit(p) then return end
	local tool = GetPlayerTool(p)
	if KIND_OF[tool] then
		dropTool(p, tool, true)
		SetPlayerTool("wh_fists", p)
	end
end

function whItemsOnDeath(p)
	for _, k in ipairs(ITEM_KINDS) do
		local tool = ITEM_DEF[k].tool
		if IsToolEnabled(tool, p) then dropTool(p, tool, false) end
	end
	SetString("proxchat.tx." .. p, "")
	-- the newly dead see the journals being read
	for reader, r in pairs(IS.reading) do ClientCall(p, "client.whJournalOf", reader, r.name, r.seed, r.what) end
end

-- a melee hit: the first player along the aim within range (not a spirit: blades and fists pass through them)
local function melee(p, range, damage, cause, fxMiss, fxHit)
	local e = eye(p)
	local f = fwdOf(e)
	local hit, dist, shape, q = QueryShot(e.pos, f, range, 0.25, p)
	if hit and q and q ~= 0 and q ~= p and IsPlayerValid(q) and GetPlayerHealth(q) > 0 and not whServerIsSpirit(q) then
		whHurt(q, damage, p, cause)
		whFx(fxHit, q, VecAdd(e.pos, VecScale(f, dist)))
		whLog(cause .. " p=" .. p .. " hit=" .. q .. " hp=" .. string.format("%.2f", GetPlayerHealth(q)))
	else
		whFx(fxMiss, p, VecAdd(e.pos, VecScale(f, 0.8)))
	end
end

local flameT = {}
flameLogT = -100
local function flamer(p, h, dt)
	local fuel = GetToolAmmo("wh_flamer", p)
	local firing = InputDown("usetool", p) and fuel > 0
	if firing and not h.flame then whFx("flame_start", p) end
	if not firing and h.flame and fuel <= 0 then whFx("flame_empty", p) end
	h.flame = firing
	if not firing then
		if fuel <= 0 and InputPressed("usetool", p) then whFx("flame_empty", p) end
		return
	end
	fuel = math.max(0, fuel - dt)
	SetToolAmmo("wh_flamer", fuel, p)
	local e = eye(p)
	local f = fwdOf(e)
	local m = GetToolLocationWorldTransform("muzzle", p)
	local from = (m and m.pos) or VecAdd(e.pos, VecScale(f, 0.6))
	-- the stream sets what it reaches on fire (a few fires a second)
	flameT[p] = (flameT[p] or 0) + dt
	if flameT[p] >= 0.12 then
		flameT[p] = 0
		for i = 1, 2 do
			local dir = VecNormalize(VecAdd(f, Vec((math.random() - 0.5) * 0.25, (math.random() - 0.5) * 0.2, (math.random() - 0.5) * 0.25)))
			QueryRequire("physical")
			local hit, d = QueryRaycast(from, dir, FLAMER_RANGE)
			if hit then SpawnFire(VecAdd(from, VecScale(dir, d - 0.05))) end
		end
	end
	-- players in the stream's cone, in sight
	for q in Players() do
		if q ~= p and whInRound(q) and GetPlayerHealth(q) > 0 then
			for _, hgt in ipairs({1.2, 0.5}) do
				local c = VecAdd(GetPlayerTransform(q).pos, Vec(0, hgt, 0))
				local to = VecSub(c, from)
				local along = VecDot(to, f)
				if along > 0 and along < FLAMER_RANGE then
					local perp = VecLength(VecSub(to, VecScale(f, along)))
					local clear = perp < 0.6 + along * 0.12 and whClear(from, c)
					if WH_TEST and GetTime() - (flameLogT or -100) > 0.5 then
						flameLogT = GetTime()
						whLog("flamecone q=" .. q .. " along=" .. string.format("%.2f", along) .. " perp=" .. string.format("%.2f", perp) .. " clear=" .. tostring(clear))
					end
					if clear then whFlameHit(q, dt, p); break end
				end
			end
		end
	end
end

local function cross(p, h)
	if not InputDown("usetool", p) or GetTime() < h.crossCd then return end
	local e = eye(p)
	local f = fwdOf(e)
	local used = false
	for q in Players() do
		if q ~= p and whServerIsSpirit(q) and GetPlayerHealth(q) > 0 then
			local c = VecAdd(GetPlayerTransform(q).pos, Vec(0, 1.3, 0))
			local to = VecSub(c, e.pos)
			local d = VecLength(to)
			if d <= CROSS_RANGE and d > 0.01 and VecDot(VecScale(to, 1 / d), f) >= CROSS_COS and whClear(e.pos, c) then
				if whStun(q, CROSS_STUN, p) then
					h.crossCd = GetTime() + CROSS_CD
					if not used then whFx("crossflash", p, VecAdd(e.pos, VecScale(f, 0.5))) end
					used = true
				end
			end
		end
	end
	if not used then return end                                -- (a charge per raise that stuns - one or more wraiths)
	local left = math.max(0, GetToolAmmo("wh_cross", p) - 1)
	SetToolAmmo("wh_cross", left, p)
	if left > 0 then return end
	SetToolEnabled("wh_cross", false, p)                        -- (its last: it cracks and crumbles)
	SetPlayerTool("wh_fists", p)
	whFx("crosscrack", p, VecAdd(e.pos, VecScale(f, 0.5)))
	note(p, "The cross cracks and crumbles to dust.")
	whLog("cross cracked p=" .. p)
end

local function sensor(p, h)
	if not InputPressed("usetool", p) then return end
	local t = GetTime()
	if t < h.sensorCd then return end
	h.sensorCd = t + SENSOR_CD
	local parts = {}
	for q in Players() do
		if q ~= p and whInRound(q) and IsPlayerValid(q) and GetPlayerHealth(q) > 0 then
			local pos = GetPlayerTransform(q).pos
			parts[#parts + 1] = string.format("%.1f,%.1f,%.1f", pos[1], pos[2], pos[3])
		end
	end
	ClientCall(p, "client.whSensor", table.concat(parts, ";"))
	whFx("sensor", p)
end

local function grabbing(p)
	local b = GetPlayerGrabBody(p)
	if b and b ~= 0 then return true end
	b = GetPlayerPickBody(p)
	return b and b ~= 0 and IsBodyDynamic(b) or false               -- (RMB is the game's grab: a loose thing in reach)
end

-- the medkit: LMB held MEDKIT_TIME s heals its holder; RMB held as long heals the living player in front within
-- MEDKIT_REACH m (the user) - losing them on the way starts over. Used up either way.
local function medTarget(p)
	local e = eye(p)
	local hit, _, _, q = QueryShot(e.pos, fwdOf(e), MEDKIT_REACH, 0.3, p)
	if hit and q and q ~= 0 and q ~= p and IsPlayerValid(q) and GetPlayerHealth(q) > 0 and not whServerIsSpirit(q) then return q end
	return nil
end

-- (the user: on someone else it must take as long as on yourself - so a moment off them (their animation, a step,
-- a frame's miss) doesn't start over, only MEDKIT_GRACE s of it; and only a thing really held blocks RMB: the
-- one in front may count as "pickable")
local function medkit(p, h, dt)
	local who = nil
	if InputDown("usetool", p) then who = p
	elseif InputDown("rmb", p) and (GetPlayerGrabBody(p) or 0) == 0 then
		who = medTarget(p)
		if who then h.medSeen = GetTime()
		elseif h.medWho and h.medWho ~= p and GetTime() - (h.medSeen or -100) < MEDKIT_GRACE then who = h.medWho end
	end
	if not who or who ~= h.medWho then h.med = 0 end
	h.medWho = who
	if not who then return nil end
	SetPlayerParam("walkingSpeed", 0, p)                       -- (the user: crouched at it, not moving - one frame each)
	SetPlayerParam("jumpSpeed", 0, p)
	h.med = h.med + dt
	if h.med >= MEDKIT_TIME then
		h.med, h.medWho = 0, nil
		SetPlayerHealth(math.min(1, GetPlayerHealth(who) + MEDKIT_HEAL), who)
		SetToolEnabled("wh_medkit", false, p)
		SetPlayerTool("wh_fists", p)
		whLog("medkit p=" .. p .. " healed=" .. who)
		return nil
	end
	return who                                                  -- (still at it: shared.whMed - crouched, the bandage sound)
end

-- walkie-talkies and the speakerphone through Proximity Comms' devices: every walkie (carried, or lying anywhere)
-- plays the one channel, in hand or not. A player talks into theirs while it is in their hand and switched on - voice
-- and typed lines alike (the user: a typer can't type with a mouse button held) - RMB switches it off and on (on at
-- first; h.walkieOff). The speakerphone the same: in hand and on, its holder's voice carries far (h.speakerOff).
local function devices()
	local seen = {}
	for p in Players() do
		local alive = whInRound(p) and GetPlayerHealth(p) > 0
		local tx = ""
		if alive and IsToolEnabled("wh_walkie", p) then
			setDevice("whw" .. p, "radio channel=whwalkie at=player:" .. p, seen)
		end
		if alive and IsToolEnabled("wh_speaker", p) then
			setDevice("whsp" .. p, "loudspeaker channel=whsp" .. p .. " at=player:" .. p, seen)
		end
		if alive and not whServerIsSpirit(p) then
			local tool, typing = GetPlayerTool(p), GetBool("proxchat.typing." .. p)
			local key = tool == "wh_walkie" and "walkieOff" or tool == "wh_speaker" and "speakerOff" or nil
			if key then
				local h = hs(p)
				if InputPressed("rmb", p) and not typing and not grabbing(p) then h[key] = not h[key] end
				if not h[key] then tx = tool == "wh_walkie" and "whwalkie" or "whsp" .. p end
			end
		end
		SetString("proxchat.tx." .. p, tx)
	end
	for b, it in pairs(IS.world) do
		if it.kind == "walkie" and IsHandleValid(b) then setDevice("whwb" .. b, "radio channel=whwalkie at=body:" .. b, seen) end
	end
	for name in pairs(IS.devices) do
		if not seen[name] then
			SetString("proxchat.device." .. name, "")
			IS.devices[name] = nil
		end
	end
	SetString("proxchat.ranges", "private=6 megaphone=70 reach=0")
end

local function topUp(t)
	if t < IS.nextSpawn then return end
	IS.nextSpawn = t + SPAWN_EVERY * (0.7 + math.random() * 0.6)
	local short = {}
	for _, k in ipairs(ITEM_KINDS) do
		local missing = (IS.stock[k] or 0) - itemCount(k)
		for i = 1, math.max(0, missing) do short[#short + 1] = k end
		if k == "journal" and missing > 0 then short[#short + 1] = k end   -- (journals keep coming)
	end
	if #short == 0 then return end
	local k = short[math.random(1, #short)]
	local pos = pickSpot(SPAWN_AWAY)
	if pos then spawnAt(k, pos) end
	whLog("topup " .. k)
end

function whItemsTick(dt, playing)
	local t = GetTime()
	if not playing then
		if next(IS.devices) then clearDevices() end
		if type(shared.whMed) == "table" and next(shared.whMed) then shared.whMed = {} end
		return
	end
	local med = {}                                              -- [healer] = who they heal, this tick
	for b, it in pairs(IS.world) do                             -- (a destroyed or fallen-away item)
		if not IsHandleValid(b) or GetBodyTransform(b).pos[2] < -100 then IS.world[b] = nil end
	end
	for p in Players() do
		if whInRound(p) and GetPlayerHealth(p) > 0 then
			local h = hs(p)
			if t - IS.regenT > 0.5 and GetPlayerParam("healthRegeneration", p) ~= false then SetPlayerRegenerationState(false, p) end
			if not whServerIsSpirit(p) then
				if not IsToolEnabled("wh_fists", p) then SetToolEnabled("wh_fists", true, p) end
				if GetToolAmmo("wh_fists", p) < 1 then SetToolAmmo("wh_fists", 1, p) end   -- (selectable: whHideToolCounts)
				local tool = GetPlayerTool(p)
				if InputPressed("interact", p) then tryPickup(p) end
				if h.journal then                                    -- (put down: switched to something else)
					if tool == "wh_journal" then h.journal.seen = true
					elseif h.journal.seen or t - h.journal.t > 1.5 then burnJournal(p) end
				end
				if tool == "wh_knife" then
					if InputPressed("usetool", p) and t >= h.knifeT then h.knifeT = t + KNIFE_CD; melee(p, KNIFE_RANGE, KNIFE_DAMAGE, "knife", "knife", "knifehit") end
				elseif tool == "wh_fists" then
					if InputPressed("usetool", p) and t >= h.punchT then h.punchT = t + PUNCH_CD; melee(p, PUNCH_RANGE, PUNCH_DAMAGE, "punch", "punch", "punchhit") end
				elseif tool == "wh_flamer" then flamer(p, h, dt)
				elseif tool == "wh_cross" then cross(p, h)
				elseif tool == "wh_sensor" then sensor(p, h)
				elseif tool == "wh_medkit" then med[p] = medkit(p, h, dt) end
				if tool ~= "wh_flamer" then h.flame = false end
				if tool ~= "wh_medkit" then h.med = 0 end
				if t - h.stateT >= 0.25 then
					h.stateT = t
					ClientCall(p, "client.whItemState", math.max(0, h.sensorCd - t), math.max(0, h.crossCd - t), h.med, not h.walkieOff, not h.speakerOff)
				end
			end
		end
	end
	if t - IS.regenT > 0.5 then IS.regenT = t end
	local was = type(shared.whMed) == "table" and shared.whMed or {}   -- (published only when it changes)
	local same = true
	for q, w in pairs(med) do if was[q] ~= w then same = false end end
	for q in pairs(was) do if not med[q] then same = false end end
	if not same then shared.whMed = med end
	devices()
	topUp(t)
end

function whItemsPostUpdate() end

----- client -----

local CI = {snd = {}, anims = {}, journal = nil, readers = {}, marks = {}, markT = -100, note = "", noteT = -100,
	state = {sensor = 0, cross = 0, med = 0, walkie = true, speaker = true, t = -100}, flameLoop = nil,
	crouched = {}, bandageT = {}}

local function sl(name, n)
	local l = {}
	for i = 0, n - 1 do l[#l + 1] = LoadSound("MOD/snd/" .. name .. i .. ".ogg") end
	return l
end
local function pk(l) return l[math.random(1, #l)] end

function whItemsClientInit()
	whHideToolCounts()                                         -- (each machine's HUD reads its own registry)
	CI.snd.knife = sl("knife_swing", 2)
	CI.snd.knifehit = sl("knife_hit", 2)
	CI.snd.punch = sl("punch", 3)
	CI.snd.pickup = LoadSound("MOD/snd/pickup.ogg")
	CI.snd.medkit = LoadSound("MOD/snd/medkit.ogg")
	CI.snd.sensor = LoadSound("MOD/snd/sensor_ping.ogg")
	CI.snd.jopen = LoadSound("MOD/snd/journal_open.ogg")
	CI.snd.jburn = LoadSound("MOD/snd/journal_burn.ogg")
	CI.snd.fstart = LoadSound("MOD/snd/flame_start.ogg")
	CI.snd.fempty = LoadSound("MOD/snd/flame_empty.ogg")
	CI.snd.stun = LoadSound("MOD/snd/cross_stun.ogg")
	CI.snd.crack = {LoadSound("wood/break-m0.ogg"), LoadSound("wood/break-m2.ogg")}   -- (the game's own)
	CI.flameLoop = LoadLoop("MOD/snd/flame_loop.ogg")
	WH_FX.pickup = function(p, pos) PlaySound(CI.snd.pickup, pos, 0.7) end
	WH_FX.drop = function(p, pos) PlaySound(CI.snd.pickup, pos, 0.5, false, 0.8) end
	WH_FX.knife = function(p, pos) PlaySound(pk(CI.snd.knife), pos, 0.8) end
	WH_FX.knifehit = function(p, pos) PlaySound(pk(CI.snd.knifehit), pos, 1.0) end
	WH_FX.punch = function(p, pos) PlaySound(pk(CI.snd.punch), pos, 0.5, false, 1.2) end
	WH_FX.punchhit = function(p, pos) PlaySound(pk(CI.snd.punch), pos, 0.9) end
	WH_FX.sensor = function(p, pos) PlaySound(CI.snd.sensor, pos, 0.8) end
	WH_FX.journal_open = function(p, pos) PlaySound(CI.snd.jopen, pos, 0.6) end
	WH_FX.journal_burn = function(p, pos)
		PlaySound(CI.snd.jburn, pos, 0.8)
		for i = 1, 12 do
			ParticleReset()
			ParticleType("plain")
			ParticleColor(1, 0.5, 0.1, 0.2, 0.2, 0.2)
			ParticleRadius(0.05, 0.02)
			ParticleEmissive(5, 0)
			ParticleGravity(1.5)
			SpawnParticle(VecAdd(pos, Vec(0, 1.2, 0)), Vec((math.random() - 0.5), math.random(), (math.random() - 0.5)), 1.2)
		end
	end
	WH_FX.flame_start = function(p, pos) PlaySound(CI.snd.fstart, pos, 0.9) end
	WH_FX.flame_empty = function(p, pos) PlaySound(CI.snd.fempty, pos, 0.8) end
	WH_FX.crosscrack = function(p, pos)                         -- (its last charge: cracks and crumbles to dust)
		PlaySound(CI.snd.crack[math.random(1, #CI.snd.crack)], pos, 0.9)
		for i = 1, 40 do
			ParticleReset()
			ParticleType("plain")
			local g = 0.45 + math.random() * 0.2
			ParticleColor(g, g * 0.8, g * 0.6)
			ParticleRadius(0.03 + math.random() * 0.05, 0.01)
			ParticleGravity(-4)
			ParticleDrag(0.3)
			SpawnParticle(pos, Vec((math.random() - 0.5) * 2, math.random() * 1.5, (math.random() - 0.5) * 2), 1.2 + math.random())
		end
	end
	WH_FX.crossflash = function(p, pos)
		PointLight(pos, 1, 0.95, 0.7, 8)
		for i = 1, 30 do
			ParticleReset()
			ParticleType("plain")
			ParticleColor(1, 0.95, 0.7)
			ParticleRadius(0.04, 0.01)
			ParticleEmissive(8, 0)
			ParticleGravity(0)
			ParticleDrag(0.5)
			SpawnParticle(pos, Vec((math.random() - 0.5) * 6, (math.random() - 0.5) * 6, (math.random() - 0.5) * 6), 0.7)
		end
	end
end

function client.whNote(text) CI.note, CI.noteT = text, GetTime() end
function client.whLocalFx(kind)
	if kind == "refuse" then PlaySound(CI.snd.stun, GetPlayerTransform(GetLocalPlayer()).pos, 0.35, false, 1.4) end
end
function client.whJournal(name, seed, what)
	if name == "" then CI.journal = nil else CI.journal = {name = name, seed = seed, what = what} end
end
function client.whJournalOf(reader, name, seed, what)
	if name == "" then CI.readers[reader] = nil else CI.readers[reader] = {name = name, seed = seed, what = what} end
end
function client.whItemState(sensorCd, crossCd, med, walkieOn, speakerOn)
	CI.state = {sensor = sensorCd, cross = crossCd, med = med, walkie = walkieOn ~= false, speaker = speakerOn ~= false, t = GetTime()}
end
function client.whSensor(list)
	CI.marks, CI.markT = {}, GetTime()
	for x, y, z in string.gmatch(list or "", "([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)") do
		CI.marks[#CI.marks + 1] = Vec(tonumber(x), tonumber(y), tonumber(z))
	end
	whLog("sensor marks=" .. #CI.marks)
end

-- the tools in the hands (the game's toolanimation.lua, as its minigun does): the cross raised while LMB is held, the
-- knife and fists jab forward
local function animFor(p, tool)
	CI.anims[p] = CI.anims[p] or {}
	local a = CI.anims[p][tool]
	if not a then
		a = {anim = ToolAnimator(), raise = 0, jab = 0, lastPress = -100}
		CI.anims[p][tool] = a
	end
	return a
end

local function flameFx(p)
	local m = GetToolLocationWorldTransform("muzzle", p)
	local e = GetPlayerEyeTransform(p)
	local f = TransformToParentVec(e, Vec(0, 0, -1))
	local from = (m and m.pos) or VecAdd(e.pos, VecScale(f, 0.6))
	PlayLoop(CI.flameLoop, from, 1.0)
	PointLight(VecAdd(from, VecScale(f, 1.5)), 1, 0.55, 0.15, 4 + math.random() * 2)
	for i = 1, 6 do
		ParticleReset()
		ParticleType("plain")
		ParticleColor(1, 0.75, 0.3, 1, 0.15, 0.02)
		ParticleRadius(0.06, 0.45, "easein")
		ParticleAlpha(1, 0)
		ParticleEmissive(9, 1)
		ParticleGravity(1.5)
		ParticleDrag(0.15)
		ParticleCollide(1)
		local dir = VecNormalize(VecAdd(f, Vec((math.random() - 0.5) * 0.18, (math.random() - 0.5) * 0.15, (math.random() - 0.5) * 0.18)))
		SpawnParticle(from, VecScale(dir, 11 + math.random() * 4), 0.55 + math.random() * 0.15)
	end
	ParticleReset()
	ParticleType("smoke")
	ParticleColor(0.15, 0.12, 0.1)
	ParticleRadius(0.3, 1.0)
	ParticleAlpha(0.4, 0)
	ParticleGravity(2)
	SpawnParticle(VecAdd(from, VecScale(f, 3 + math.random() * 3)), Vec(0, 1, 0), 1.5)
end

-- a medkit being applied (shared.whMed: [healer] = who): the healer crouches (the game's crouch_idle clip, every
-- machine - as Humans vs Clickers' revive) and the bandage sound plays over them until it is done (the user); their
-- own camera at crouch height. The server holds them still.
MED_CAMERA_DROP = 0.6
local function medClient(playing)
	local med = playing and type(shared.whMed) == "table" and shared.whMed or {}
	local t = GetTime()
	for q in pairs(CI.crouched) do
		if not med[q] then
			CI.crouched[q], CI.bandageT[q] = nil, nil
			SetString("game.override.animation." .. q, "")
			SetFloat("game.override.animation." .. q .. ".weight", 0)
		end
	end
	for q in pairs(med) do
		if IsPlayerValid(q) then
			CI.crouched[q] = true
			SetString("game.override.animation." .. q, "crouch_idle")
			SetFloat("game.override.animation." .. q .. ".weight", 1)
			if t >= (CI.bandageT[q] or 0) then                     -- (back to back: the clip is 1.25 s)
				CI.bandageT[q] = t + 1.2
				PlaySound(CI.snd.medkit, VecAdd(GetPlayerTransform(q).pos, Vec(0, 0.6, 0)), 0.8, false, 0.92 + math.random() * 0.16)
			end
		end
	end
	if med[GetLocalPlayer()] then SetPlayerCameraOffsetTransform(Transform(Vec(0, -MED_CAMERA_DROP, 0))) end
end

function whItemsClientTick(dt)
	local e = shared.wh
	medClient(e and e.phase == "play")
	if not e or e.phase ~= "play" then return end
	local me = GetLocalPlayer()
	for p in Players() do
		local tool = GetPlayerTool(p)
		if KIND_OF[tool] and tool ~= "gun" or tool == "wh_fists" then
			local a = animFor(p, tool)
			local down = InputDown("usetool", p)
			if InputPressed("usetool", p) then a.lastPress = GetTime() end
			a.raise = a.raise + ((tool == "wh_cross" and down) and 1 - a.raise or -a.raise) * math.min(1, dt * 10)
			local since = GetTime() - a.lastPress
			a.jab = (tool == "wh_knife" or tool == "wh_fists") and math.max(0, 1 - since / 0.25) or 0
			a.anim.offsetTransform = Transform(Vec(0, 0.18 * a.raise, -0.22 * a.raise - 0.25 * a.jab), QuatEuler(25 * a.raise, 0, 0))
			tickToolAnimator(a.anim, dt, nil, p)
			if tool == "wh_flamer" and down and GetToolAmmo("wh_flamer", p) > 0 and GetPlayerHealth(p) > 0 then flameFx(p) end
			if tool == "wh_cross" and a.raise > 0.5 then
				local m = GetToolBody(p)
				if m and m ~= 0 then PointLight(GetBodyTransform(m).pos, 1, 0.92, 0.7, 0.6 * a.raise) end
			end
		end
	end
	if GetPlayerHealth(me) > 0 and not whChatTyping() and InputPressed("g") and not whIsSpirit(me) then ServerCall("server.whDrop", me) end
end

function whItemsClientPostUpdate(dt) end

local function hint(y, text, a)
	whBigText(y, 19, text, 0.9, 0.9, 0.9, a or 0.8)
end

-- the journal's page: a hurried scrawl, "<name> is a witch!" or "<name> is a human!" (the user), in a scribbly handwriting font (OFL, fonts/OFL.txt);
-- a name with letters outside plain ASCII in the game's own font (the handwriting has no glyphs for them)
JOURNAL_FONT = "MOD/fonts/NothingYouCouldDo.ttf"

local function drawJournal(j)
	local text = j.name .. (j.what == "human" and " is a human!" or " is a wraith!")
	local font = (HasFile(JOURNAL_FONT) and not j.name:find("[\128-\255]")) and JOURNAL_FONT or "bold.ttf"
	UiPush()
	UiTranslate(UiCenter(), UiMiddle() - 20)
	UiAlign("center middle")
	UiColor(0.78, 0.7, 0.55, 0.97)
	UiRect(660, 260)
	UiColor(0.55, 0.45, 0.32, 1)
	UiRectOutline(660, 260, 4)
	UiTextDisableWildcards(true)
	UiRotate(-3 + ((j.seed or 0) % 5) * 0.8)                       -- (scrawled at a slant, a little different each time)
	UiFont(font, font == JOURNAL_FONT and 64 or 40)
	local w = UiGetTextSize(text)
	if w > 600 then UiScale(600 / w) end
	UiColor(0.35, 0.05, 0.04, 1)
	UiText(text)
	UiPop()
end

local function drawMarks()
	local age = GetTime() - CI.markT
	if age > SENSOR_SHOW then return end
	local a = 1 - age / SENSOR_SHOW
	for _, pos in ipairs(CI.marks) do
		local x, y, dist = UiWorldToPixel(VecAdd(pos, Vec(0, 1.0, 0)))
		local w, h, m = UiWidth(), UiHeight(), 50
		if dist < 0 or x < m or x > w - m or y < m or y > h - m then
			local cx, cy = w / 2, h / 2
			local dx, dy = x - cx, y - cy
			if dist < 0 then dx, dy = -dx, -dy end
			if math.abs(dx) < 1 and math.abs(dy) < 1 then dy = 1 end
			local k = math.min((w / 2 - m) / math.max(math.abs(dx), 1e-3), (h / 2 - m) / math.max(math.abs(dy), 1e-3))
			x, y = cx + dx * k, cy + dy * k
		end
		local d = VecLength(VecSub(pos, GetCameraTransform().pos))
		UiPush()
		UiTranslate(x, y)
		UiAlign("center middle")
		UiColor(0.3, 1, 0.45, 0.85 * a)
		UiRotate(45)
		UiRect(16, 16)
		UiRotate(-45)
		UiColor(0, 0, 0, 0.8 * a)
		UiRect(7, 7)
		UiTranslate(0, 22)
		UiFont("bold.ttf", 15)
		UiColor(0.6, 1, 0.65, 0.85 * a)
		UiText(string.format("%d m", math.floor(d + 0.5)))
		UiPop()
	end
end

function whItemsClientDraw()
	local me = GetLocalPlayer()
	local t = GetTime()
	local sp = whSpectating and whSpectating() or nil
	if sp and CI.readers[sp] and GetPlayerTool(sp) == "wh_journal" then   -- (the dead read along)
		drawJournal(CI.readers[sp])
		return
	end
	if GetPlayerHealth(me) <= 0 then return end
	drawMarks()
	if t - CI.noteT < 3.5 then whBigText(UiMiddle() + 120, 24, CI.note, 1, 0.85, 0.7, math.min(1, (3.5 - (t - CI.noteT)) / 0.6)) end
	if whIsSpirit(me) then return end
	local tool = GetPlayerTool(me)
	local el = t - CI.state.t
	local y = UiHeight() - 120
	if tool == "wh_journal" and CI.journal then
		drawJournal(CI.journal)
		hint(y, "Put it away and it crumbles to ash.")
	elseif tool == "wh_knife" then hint(y, "LMB: stab")
	elseif tool == "wh_fists" then hint(y, "LMB: punch   E: pick up items")
	elseif tool == "wh_walkie" then
		hint(y, CI.state.walkie and "WALKIE ON: everyone with one hears you   RMB: off" or "Walkie off   RMB: on (in hand, it carries what you say)")
		if GetFloat("proxchat.alive") < t - 2 then hint(y + 24, "(needs the Proximity Comms mod)", 0.6) end
	elseif tool == "wh_speaker" then
		hint(y, CI.state.speaker and "SPEAKERPHONE ON: your voice carries far   RMB: off" or "Speakerphone off   RMB: on (in hand, your voice carries far)")
		if GetFloat("proxchat.alive") < t - 2 then hint(y + 24, "(needs the Proximity Comms mod)", 0.6) end
	elseif tool == "wh_medkit" then
		local frac = (InputDown("usetool") or InputDown("rmb")) and math.min(1, (CI.state.med + el) / MEDKIT_TIME) or 0
		hint(y, "Hold LMB: heal yourself   Hold RMB: heal the one in front of you")
		if frac > 0 then
			UiPush(); UiTranslate(UiCenter() - 100, y + 18); UiColor(0, 0, 0, 0.5); UiRect(200, 8)
			UiColor(0.4, 1, 0.5, 0.9); UiRect(200 * frac, 8); UiPop()
		end
	elseif tool == "wh_flamer" then hint(y, "Hold LMB: fire   (" .. string.format("%.1f", GetToolAmmo("wh_flamer", me)) .. " s of fuel)")
	elseif tool == "wh_cross" then
		local cd = math.max(0, CI.state.cross - el)
		local n = math.floor(GetToolAmmo("wh_cross", me) + 0.5)
		local uses = n == 1 and "   (its last use: then it cracks)" or ("   (" .. n .. " uses)")
		hint(y, (cd > 0 and ("the cross recovers in " .. math.ceil(cd) .. " s") or "Hold LMB: raise the cross - a wraith in wraith form close in front is stunned") .. uses)
	elseif tool == "wh_sensor" then
		local cd = math.max(0, CI.state.sensor - el)
		hint(y, cd > 0 and ("sensor recharging: " .. math.ceil(cd) .. " s") or "LMB: scan for everyone nearby")
	end
	if KIND_OF[tool] then hint(y + 48, "G: drop", 0.55) end
end
