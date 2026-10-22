-- Witch Hunt: the witches' spirit form, fire and the cross's stun. Included by witchhunt.lua (no #version line);
-- only GLOBALS are shared with the other files. Interface:
--   server: whSpiritServerInit(), whSpiritReset() (a new round / the end), whSpiritStartPlay(now), whSpiritTick(dt, playing),
--           whSpiritUpdate(dt), whSpiritOnDeath(p), whServerIsSpirit(p), whStun(p, secs, by) (the holy cross),
--           whFlameHit(p, dt, by) (in a flamethrower's stream this frame), whBurnOf(p) (seconds since p last burned)
--   client: whSpiritClientInit(), whSpiritClientTick(dt), whSpiritClientDraw(), whSpiritClientRender(dt), whIsSpirit(p),
--           whSpirits() (the list for the model), client.whFx(kind, p, x, y, z) (one-shot effects; WH_FX[kind] = function
--           (p, pos) adds more from other files), whFx(kind, p, pos) (server: send one to everyone)
--   shared: whS = {n, sp = {[p] = {pose, seq, forced}}, burn = {[p] = true}}
-- A witch presses Q (her client sends server.whQ): she becomes a white spirit for SPIRIT_TIME s (Q again ends it), then
-- recovers for SPIRIT_COOLDOWN s. A spirit flies (Space up, Crouch down, WASD where she looks: the engine's flyMode
-- param plus our velocity every tick from the server - SetPlayerVelocity is server-only, and alone it barely lifted a
-- grounded client witch, so a grounded witch is lifted 0.25 m first (autotest 2026-10-20: rose 7.4 m in 1.5 s, hovers,
-- flies 5 m forward; the engine's flyMode gave no Space-up with real keys); she collides like a player: no wall
-- passing), has no items, can't pick up, and kills a human in 3 claw strikes (LMB, CLAW_CD s apart, CLAW_REACH m, a
-- clear line). Only fire hurts a spirit: she is in godMode (the engine's damage, bullets and its fire alike, can't take;
-- DisablePlayerDamage did not stop the engine's fire damage), and her health is ours while she is a spirit (s.hp; godMode
-- also stops SetPlayerHealth lowering it): set back on the player when she turns human, or 0 if the fire burned her out.
-- Fire hurts everyone in either form: humans through the engine's own fire damage (0.06-0.28 / s measured) plus a
-- flamethrower's stream (ours), spirits by ours. A human-form witch BURN_REVEAL s in fire is forced into spirit form; she can't
-- strike until BURN_LOCK s after her last burn, and then turns back into a human. Witches don't hurt each other while
-- both are spirits; every other pairing hurts.

SPIRIT_TIME = 15
SPIRIT_COOLDOWN = 60
FIRST_COOLDOWN = 30        -- s into the round before the first spirit
CLAW_CD = 2
CLAW_REACH = 2.6           -- m from her eyes to a target's chest
CLAW_COS = 0.55            -- cos of the strike's cone (~57 degrees)
CLAW_DAMAGE = 0.34         -- of full health: 3 strikes kill
BURN_REVEAL = 3            -- s of fire that force a human-form witch out
BURN_LOCK = 5              -- s after the last burn before she can strike (a forced spirit turns back then)
FIRE_R = 0.9               -- m from the body to a fire that burns
FIRE_DPS_SPIRIT = 0.12     -- of full health per s, a spirit in fire (humans: the engine's own fire damage)
FLAME_DPS = 0.26           -- per s in a flamethrower's stream (fuel for ~2 witches: wh_items.lua FLAMER_FUEL)
FLY_SPEED = 8              -- m/s flying (a human walks 7)
FLY_RISE = 5               -- m/s up / down
HOVER_LIFT = 0.17          -- m/s up while hovering: a client witch sank ~0.17 m/s with 0 (gravity between our ticks)
STUN_IMMUNE = 1.5          -- s after a stun before the next one takes
WV_LAYER = 32              -- the model's parts' collision layer: out of every player's CollisionMask
PLAYER_MASK = 255 - WV_LAYER

----- server -----

local W = {}               -- [witch] = {form, t0, cd, forced, lastBurn, burnAcc, stunUntil, stunOk, clawReady, seq, pose, poseT0, tool}
local burnNow = {}         -- [player] = true: burning this frame
local flameHit = {}        -- [player] = {dps time this frame, by}
local SP = {n = 0, pubT = -1, maskT = -1, fireT = 0, stateT = -1, playing = false}

local function now() return GetTime() end

function whFx(kind, p, pos)
	pos = pos or (IsPlayerValid(p) and GetPlayerTransform(p).pos) or Vec()
	ClientCall(0, "client.whFx", kind, p or 0, pos[1], pos[2], pos[3])
end

local function st(p)
	local s = W[p]
	if not s then
		s = {form = "human", t0 = 0, cd = 0, forced = false, lastBurn = -100, burnAcc = 0, stunUntil = -100, stunOk = 0,
			clawReady = 0, seq = 0, pose = "float", poseT0 = 0, tool = ""}
		W[p] = s
	end
	return s
end

local function publishSpirits(force)
	local t = now()
	if not force and t - SP.pubT < 0.5 then return end
	SP.pubT = t
	SP.n = SP.n + 1
	local sp, burn = {}, {}
	for p, s in pairs(W) do
		if s.form == "spirit" and IsPlayerValid(p) then sp[p] = {pose = s.pose, seq = s.seq, forced = s.forced} end
	end
	for p in pairs(burnNow) do burn[p] = true end
	shared.whS = {n = SP.n, sp = sp, burn = burn}
end

function whServerIsSpirit(p) return W[p] ~= nil and W[p].form == "spirit" end
function whSpiritHp(p) return W[p] and W[p].form == "spirit" and W[p].hp or nil end   -- (a spirit's own health)
function whBurnOf(p) return W[p] and (now() - W[p].lastBurn) or 999 end

local function setPose(s, pose)
	s.pose, s.poseT0, s.seq = pose, now(), s.seq + 1
end

local function paramsHuman(p)
	SetPlayerParam("disableInteract", false, p)
end

local function toSpirit(p, forced)
	local s = st(p)
	if s.form == "spirit" then s.forced = s.forced or forced; return end
	s.form, s.t0, s.forced = "spirit", now(), forced and true or false
	s.hp = GetPlayerHealth(p)                                     -- (her health is ours while she is a spirit)
	s.tool = GetPlayerTool(p)
	setPose(s, "float")
	s.clawReady = math.max(s.clawReady, now() + 0.6)
	whFx("smoke_in", p)
	whLog("spirit p=" .. p .. " forced=" .. tostring(s.forced))
	publishSpirits(true)
end

local function toHuman(p, quiet)
	local s = W[p]
	if not s or s.form ~= "spirit" then return end
	s.form, s.forced = "human", false
	s.setHp, s.setHpUntil = s.hp, now() + 0.5                     -- (set over the next ticks: godMode lingers a frame)
	if s.crossTouch then s.cd = s.keepCd else s.cd = now() + SPIRIT_COOLDOWN end
	s.crossTouch = nil
	s.burnAcc = 0
	paramsHuman(p)
	if s.tool and s.tool ~= "" and s.tool ~= "none" and IsToolEnabled(s.tool, p) then SetPlayerTool(s.tool, p) end
	if not quiet then whFx("smoke_out", p) end
	whLog("human p=" .. p)
	publishSpirits(true)
end

function whSpiritServerInit()
	shared.whS = {n = 0, sp = {}, burn = {}}
end

function whSpiritReset()
	for p, s in pairs(W) do
		if s.form == "spirit" and IsPlayerValid(p) then paramsHuman(p) end
	end
	W, burnNow, flameHit = {}, {}, {}
	SP.playing = false
	publishSpirits(true)
end

function whSpiritStartPlay(t)
	SP.playing = true
	for _, p in ipairs(whWitchList()) do st(p).cd = t + FIRST_COOLDOWN end
end

function whSpiritOnDeath(p)
	local s = W[p]
	if s and s.form == "spirit" then toHuman(p) end
	burnNow[p], flameHit[p] = nil, nil
end

-- Q from a witch's client
function server.whQ(p)
	if not SP.playing or not whIsWitch(p) or not IsPlayerValid(p) or GetPlayerHealth(p) <= 0 then return end
	local s = st(p)
	local t = now()
	if s.form == "spirit" then
		if not s.forced and t >= s.stunUntil then toHuman(p) end
	elseif t >= s.cd then
		toSpirit(p, false)
	end
end

-- the holy cross: a spirit within its reach is frozen in the air for secs (pained)
function whStun(p, secs, by)
	local s = W[p]
	if not s or s.form ~= "spirit" then return false end
	local t = now()
	if t < s.stunUntil or t < s.stunOk then return false end
	s.stunUntil = t + secs
	s.stunOk = t + secs + STUN_IMMUNE
	setPose(s, "stunned")
	whFx("stun", p)
	whLog("stun p=" .. p .. " by=" .. tostring(by))
	publishSpirits(true)
	return true
end

-- a human-form witch touching a holy cross (the user): forced into spirit form in a burst of smoke, stunned, and back to
-- human as soon as the stun ends (a forced spirit turns back once nothing holds her: no burn, no stun). Her own spirit
-- form is untouched (the user): its recharge stays as it was (unless fire catches her meanwhile)
CROSS_TOUCH_STUN = 3
function whCrossTouch(p)
	local s = st(p)
	if s.form == "spirit" then return end
	s.crossTouch, s.keepCd = true, s.cd
	toSpirit(p, true)
	s.stunOk = 0
	whStun(p, CROSS_TOUCH_STUN, p)
	whLog("cross touch p=" .. p)
end

function whFlameHit(p, dt, by)
	local f = flameHit[p] or {t = 0, by = by}
	f.t, f.by = f.t + dt, by
	flameHit[p] = f
end

local function hurt(p, amount, by, cause)
	if amount <= 0 or GetPlayerHealth(p) <= 0 then return end
	if by and by ~= 0 then whNoteHurt(p, by) end
	if whServerIsSpirit(p) then                                   -- (godMode: her health is ours)
		local s = W[p]
		s.hp = math.max(0, (s.hp or 1) - amount)
	else
		ApplyPlayerDamage(p, amount, cause or "witch", by or 0)
	end
end
function whHurt(p, amount, by, cause) hurt(p, amount, by, cause) end

-- line of sight between two points, through nothing solid (the witch models and players are skipped)
function whClear(a, b)
	local d = VecSub(b, a)
	local l = VecLength(d)
	if l < 0.1 then return true end
	QueryRequire("physical large")
	for _, s in ipairs(WV_SHAPES or {}) do QueryRejectShape(s) end
	local hit = QueryRaycast(a, VecScale(d, 1 / l), l - 0.15)
	return not hit
end

local function chest(p) return VecAdd(GetPlayerTransform(p).pos, Vec(0, 1.15, 0)) end

local function claw(p, s, t)
	s.clawReady = t + CLAW_CD
	setPose(s, "attack")
	local eye = GetPlayerEyeTransform(p)
	local fwd = TransformToParentVec(eye, Vec(0, 0, -1))
	whFx("claw", p, eye.pos)
	local best, bd = nil, 999
	for q in Players() do
		if q ~= p and whInRound(q) and GetPlayerHealth(q) > 0 and not whServerIsSpirit(q) then   -- (spirit vs spirit: no)
			local c = chest(q)
			local to = VecSub(c, eye.pos)
			local d = VecLength(to)
			if d <= CLAW_REACH and d > 0.01 and VecDot(VecScale(to, 1 / d), fwd) >= CLAW_COS and d < bd and whClear(eye.pos, c) then
				best, bd = q, d
			end
		end
	end
	if best then
		hurt(best, CLAW_DAMAGE, p, "witch")
		whFx("clawhit", best, chest(best))
		whLog("claw p=" .. p .. " hit=" .. best .. " hp=" .. string.format("%.2f", GetPlayerHealth(best)))
	end
	publishSpirits(true)
end

-- a spirit's flight: where she looks with WASD, Space up, Crouch down, hovering otherwise (our velocity every tick);
-- frozen while stunned
local function fly(p, s, dt, t)
	if t < s.stunUntil then
		SetPlayerVelocity(Vec(0, 0, 0), p)
		return
	end
	local eye = GetPlayerEyeTransform(p)
	local f = (InputDown("up", p) and 1 or 0) - (InputDown("down", p) and 1 or 0)
	local r = (InputDown("right", p) and 1 or 0) - (InputDown("left", p) and 1 or 0)
	local u = (InputDown("jump", p) and 1 or 0) - (InputDown("crouch", p) and 1 or 0)
	local fw = TransformToParentVec(eye, Vec(0, 0, -1))
	local rt = TransformToParentVec(eye, Vec(1, 0, 0))
	fw[2], rt[2] = 0, 0
	local wish = VecAdd(VecScale(VecNormalize(fw), f), VecScale(VecNormalize(rt), r))
	local want = VecScale(VecLength(wish) > 0.01 and VecNormalize(wish) or Vec(0, 0, 0), FLY_SPEED)
	local v = VecLerp(GetPlayerVelocity(p), want, math.min(1, dt * 6))
	v[2] = u ~= 0 and u * FLY_RISE or HOVER_LIFT
	if u > 0 and IsPlayerGrounded(p) then                         -- (off the ground first)
		local tr = GetPlayerTransform(p)
		SetPlayerTransform(Transform(VecAdd(tr.pos, Vec(0, 0.25, 0)), tr.rot), p)
	end
	SetPlayerVelocity(v, p)
end

-- fire: the engine's fires near the body, and a flamethrower's stream
local function fireScan(dt, t)
	for p in Players() do
		burnNow[p] = nil
		if whInRound(p) and GetPlayerHealth(p) > 0 then
			local pos = GetPlayerTransform(p).pos
			local near = QueryClosestFire(VecAdd(pos, Vec(0, 0.35, 0)), FIRE_R) or QueryClosestFire(VecAdd(pos, Vec(0, 1.2, 0)), FIRE_R)
			local fl = flameHit[p]
			local dmg = (near and whServerIsSpirit(p) and FIRE_DPS_SPIRIT * dt or 0) + (fl and FLAME_DPS * math.min(fl.t, dt * 1.5) or 0)
			if near or fl then
				burnNow[p] = true
				hurt(p, dmg, fl and fl.by or nil, "fire")
				if whIsWitch(p) then
					local s = st(p)
					s.lastBurn = t
					s.crossTouch = nil                                   -- (burned: the usual recharge after)
					if s.form == "human" then
						s.burnAcc = s.burnAcc + dt
						if s.burnAcc >= BURN_REVEAL then toSpirit(p, true); whFx("pain", p) end
					end
				end
			elseif W[p] then
				W[p].burnAcc = math.max(0, W[p].burnAcc - dt)
			end
		end
	end
	flameHit = {}
end

function whSpiritTick(dt, playing)
	local t = now()
	if t - SP.maskT >= 0.25 then                                 -- (a respawn resets it: the model's parts must not lift anyone)
		SP.maskT = t
		for p in Players() do SetPlayerParam("CollisionMask", PLAYER_MASK, p) end
	end
	if not playing then publishSpirits(false); return end
	SP.fireT = SP.fireT + dt
	if SP.fireT >= 0.1 then fireScan(SP.fireT, t); SP.fireT = 0 end
	for p, s in pairs(W) do
		if s.form ~= "spirit" and s.setHp then                         -- (turned back: her spirit health onto the player)
			if t > s.setHpUntil or not IsPlayerValid(p) or GetPlayerHealth(p) <= 0 then
				s.setHp = nil
			else
				SetPlayerParam("godMode", false, p)
				SetPlayerHealth(s.setHp, p)
			end
		end
		if s.form == "spirit" then
			if not IsPlayerValid(p) or GetPlayerHealth(p) <= 0 then
				s.form = "human"
			elseif (s.hp or 1) <= 0 then                                 -- (burned out as a spirit: dead)
				toHuman(p)
				s.setHpUntil = t + 1
			else
				SetPlayerParam("godMode", true, p)
				SetPlayerParam("disableInteract", true, p)
				if GetPlayerTool(p) ~= "none" then SetPlayerTool("none", p) end
				if t < s.stunUntil then DisablePlayerInput(p) end
				local locked = t < s.lastBurn + BURN_LOCK
				if s.forced then
					if not locked and t >= s.stunUntil then toHuman(p) end
				elseif t >= s.t0 + SPIRIT_TIME and t >= s.stunUntil then
					toHuman(p)
				end
				if s.form == "spirit" then
					if s.pose ~= "float" and ((s.pose == "attack" and t - s.poseT0 > 0.6) or (s.pose == "stunned" and t >= s.stunUntil)) then
						setPose(s, "float")
						publishSpirits(true)
					end
					if InputPressed("usetool", p) and t >= s.clawReady and not locked and t >= s.stunUntil then claw(p, s, t) end
					fly(p, s, dt, t)
				end
			end
		end
	end
	-- each witch's own numbers, to her alone (4 times a second)
	if t - SP.stateT >= 0.25 then
		SP.stateT = t
		for _, p in ipairs(whWitchList()) do
			local s = W[p]
			if s and IsPlayerValid(p) and GetPlayerHealth(p) > 0 then
				local spirit = s.form == "spirit"
				ClientCall(p, "client.whMyState", spirit, s.forced, spirit and math.max(0, s.t0 + SPIRIT_TIME - t) or 0,
					math.max(0, s.cd - t), math.max(0, s.clawReady - t), math.max(0, s.lastBurn + BURN_LOCK - t),
					math.max(0, s.stunUntil - t), s.burnAcc, spirit and s.hp or GetPlayerHealth(p))
			end
		end
	end
	publishSpirits(false)
end

function whSpiritUpdate(dt) end

----- client -----

local CS = {n = -1, sp = {}, seen = {}, burn = {}, snd = {}, cackleAt = {}, whooshAt = {}, smokeT = {}, tagged = {},
	me = {spirit = false, forced = false, left = 0, cd = 0, claw = 0, lock = 0, stun = 0, burn = 0, t = -100}}
WH_FX = {}

local function sndList(name, n)
	local l = {}
	for i = 0, n - 1 do l[#l + 1] = LoadSound("MOD/snd/" .. name .. i .. ".ogg") end
	return l
end

local function pick(l) return l[math.random(1, #l)] end

function whSpiritClientInit()
	CS.snd.cackle = sndList("cackle", 8)
	CS.snd.whoosh = sndList("whoosh", 4)
	CS.snd.swing = sndList("claw_swing", 3)
	CS.snd.hit = sndList("claw_hit", 3)
	CS.snd.pain = sndList("witch_pain", 3)
	CS.snd.transform = LoadSound("MOD/snd/transform.ogg")
	CS.snd.revert = LoadSound("MOD/snd/revert.ogg")
	CS.snd.stun = LoadSound("MOD/snd/cross_stun.ogg")
	CS.snd.loop = LoadLoop("MOD/snd/spirit_loop.ogg")
	CS.snd.burn = LoadLoop("MOD/snd/burn_loop.ogg")
end

function client.whMyState(spirit, forced, left, cd, clawLeft, lock, stun, burn, hp)
	local m = CS.me
	m.spirit, m.forced, m.left, m.cd, m.claw, m.lock, m.stun, m.burn, m.t = spirit, forced, left, cd, clawLeft, lock, stun, burn, GetTime()
	m.hp = hp or 1
end

function whIsSpirit(p) return CS.sp[p] ~= nil end
function whIsBurning(p) return CS.burn[p] == true end

function whSpirits()
	local l = {}
	local t = GetTime()
	for p, s in pairs(CS.sp) do
		l[#l + 1] = {p = p, pose = s.pose, t = t - (CS.seen[p] and CS.seen[p].t or t), smoke = t - (CS.smokeT[p] or -100) < 0.4}
	end
	return l
end

-- white smoke over an area (a change of form): big soft puffs filling ~4 m around her
local function smokeBurst(pos)
	for i = 1, 70 do
		local a, e = math.random() * 6.283, (math.random() - 0.3) * 1.2
		local r = 0.5 + math.random() * 3.5
		local off = Vec(math.cos(a) * math.cos(e) * r * 0.4, 0.4 + math.sin(e) * r * 0.25 + math.random() * 1.6, math.sin(a) * math.cos(e) * r * 0.4)
		local vel = Vec(math.cos(a) * r * 0.9, 0.3 + math.random() * 0.8, math.sin(a) * r * 0.9)
		ParticleReset()
		ParticleType("smoke")
		local g = 0.85 + math.random() * 0.12
		ParticleColor(g, g, g + 0.03)
		ParticleRadius(0.5 + math.random() * 0.3, 1.0)
		ParticleAlpha(0.85, 0.0, "easeout")
		ParticleGravity(0.15)
		ParticleDrag(0.6)
		ParticleCollide(0.5)
		SpawnParticle(VecAdd(pos, off), vel, 4 + math.random() * 3)
	end
	PointLight(VecAdd(pos, Vec(0, 1, 0)), 0.8, 0.85, 1.0, 3)
end

local function blood(pos)
	for i = 1, 14 do
		ParticleReset()
		ParticleType("plain")
		ParticleColor(0.45, 0.02, 0.02)
		ParticleRadius(0.03, 0.01)
		ParticleGravity(-9)
		ParticleCollide(1)
		ParticleSticky(1)
		SpawnParticle(pos, Vec((math.random() - 0.5) * 3, math.random() * 2, (math.random() - 0.5) * 3), 2)
	end
end

function client.whFx(kind, p, x, y, z)
	local pos = Vec(x, y, z)
	if kind == "smoke_in" then
		smokeBurst(pos)
		PlaySound(CS.snd.transform, pos, 1.0)
		CS.smokeT[p] = GetTime()
	elseif kind == "smoke_out" then
		smokeBurst(pos)
		PlaySound(CS.snd.revert, pos, 1.0)
	elseif kind == "claw" then
		PlaySound(pick(CS.snd.swing), pos, 0.9)
	elseif kind == "clawhit" then
		PlaySound(pick(CS.snd.hit), pos, 1.0)
		blood(pos)
	elseif kind == "stun" then
		PlaySound(CS.snd.stun, pos, 1.0)
		PlaySound(pick(CS.snd.pain), pos, 1.0)
	elseif kind == "pain" then
		PlaySound(pick(CS.snd.pain), pos, 1.0)
	elseif WH_FX[kind] then
		WH_FX[kind](p, pos)
	end
end

-- a spirit's human body is hidden on every machine. On the HOST SetPlayerHidden would also take that player's tools on
-- every machine (HvC, verified): there the character's shapes are tagged invisible instead (HvC's walk over the bones
-- and what hangs off them); a client keeps SetPlayerHidden.
local charCache = {}
local function characterShape(b)
	for _, sh in ipairs(GetBodyShapes(b) or {}) do
		if HasTag(sh, "attachment") or HasTag(sh, "bone") then return true end
	end
	return false
end

local function characterBodies(p)
	local anim = GetPlayerAnimator(p) or 0
	local c = charCache[p]
	if c and c.anim == anim and GetTime() - c.t < 1 then return c.bodies end
	local seen, list, queue = {}, {}, {}
	local world = GetWorldBody()
	local function add(b, bone)
		if not b or b == 0 or seen[b] or b == world or not IsHandleValid(b) or GetBodyVehicle(b) ~= 0 then return end
		if not bone and not characterShape(b) then return end
		seen[b] = true
		list[#list + 1] = b
		queue[#queue + 1] = b
	end
	if anim ~= 0 then
		for _, bone in ipairs(GetBoneNames(anim) or {}) do add(GetBoneBody(anim, bone), true) end
	end
	local i = 1
	while i <= #queue and #list < 80 do
		for _, sh in ipairs(GetBodyShapes(queue[i]) or {}) do
			for _, j in ipairs(GetShapeJoints(sh) or {}) do
				local other = GetJointOtherShape(j, sh)
				if other and other ~= 0 then add(GetShapeBody(other)) end
			end
		end
		i = i + 1
	end
	charCache[p] = {t = GetTime(), anim = anim, bodies = list}
	return list
end

local function tagInvisible(p, body)
	if not body or body == 0 or not IsHandleValid(body) then return end
	local set = CS.tagged[p] or {}
	CS.tagged[p] = set
	for _, sh in ipairs(GetBodyShapes(body) or {}) do
		if not HasTag(sh, "invisible") then SetTag(sh, "invisible") end
		set[sh] = true
	end
end

local function unhide(p)
	for sh in pairs(CS.tagged[p] or {}) do if IsHandleValid(sh) then RemoveTag(sh, "invisible") end end
	CS.tagged[p] = nil
end

local function hideSpirits()
	local host = IsPlayerHost(GetLocalPlayer())
	for p in pairs(CS.sp) do
		if IsPlayerValid(p) then
			if host then
				for _, b in ipairs(characterBodies(p)) do tagInvisible(p, b) end
				tagInvisible(p, GetToolBody(p))
			else
				SetPlayerHidden(p)
			end
			local fl = GetFlashlight(p)
			if fl and fl ~= 0 and IsHandleValid(fl) then SetLightEnabled(fl, false) end
		end
	end
	for p in pairs(CS.tagged) do if not CS.sp[p] then unhide(p) end end
end

local function readShared()
	local s = shared.whS
	if not s or s.n == CS.n then return end
	CS.n = s.n
	local t = GetTime()
	local sp, burn = {}, {}
	for p, v in pairs(s.sp or {}) do
		sp[p] = {pose = v.pose, seq = v.seq, forced = v.forced}
		local seen = CS.seen[p]
		if not seen or seen.seq ~= v.seq then CS.seen[p] = {seq = v.seq, t = t} end
		if not CS.sp[p] then CS.cackleAt[p] = t + 0.8 + math.random() * 1.5 end
	end
	for p in pairs(s.burn or {}) do burn[p] = true end
	CS.sp, CS.burn = sp, burn
end

-- her cackles (medium loud, every few seconds) and whooshes (flying fast), on every machine; burning players crackle
local function spiritSounds(t)
	for p in pairs(CS.sp) do
		if IsPlayerValid(p) then
			local pos = VecAdd(GetPlayerTransform(p).pos, Vec(0, 1.6, 0))
			PlayLoop(CS.snd.loop, pos, 0.55)
			if t >= (CS.cackleAt[p] or 0) then
				PlaySound(pick(CS.snd.cackle), pos, 0.9, false, 0.94 + math.random() * 0.12)
				CS.cackleAt[p] = t + 2.5 + math.random() * 3.5
			end
			local v = GetPlayerVelocity(p)
			if VecLength(v) > 5 and t >= (CS.whooshAt[p] or 0) then
				PlaySound(pick(CS.snd.whoosh), pos, 0.85, false, 0.9 + math.random() * 0.2)
				CS.whooshAt[p] = t + 1.1 + math.random() * 0.7
			end
		end
	end
	for p in pairs(CS.burn) do
		if IsPlayerValid(p) and GetPlayerHealth(p) > 0 then
			local pos = GetPlayerTransform(p).pos
			PlayLoop(CS.snd.burn, VecAdd(pos, Vec(0, 1, 0)), 0.8)
			for i = 1, 2 do
				ParticleReset()
				ParticleType("plain")
				ParticleColor(1, 0.55, 0.15, 1, 0.2, 0.05)
				ParticleRadius(0.12, 0.02)
				ParticleEmissive(6, 0)
				ParticleGravity(3)
				SpawnParticle(VecAdd(pos, Vec((math.random() - 0.5) * 0.5, 0.2 + math.random() * 1.5, (math.random() - 0.5) * 0.5)),
					Vec(0, 1, 0), 0.5)
			end
			PointLight(VecAdd(pos, Vec(0, 1, 0)), 1, 0.5, 0.15, 1.5)
		end
	end
end

function whSpiritClientTick(dt)
	readShared()
	hideSpirits()
	local t = GetTime()
	spiritSounds(t)
	local e = shared.wh
	local me = GetLocalPlayer()
	if e and e.phase == "play" and whAmWitch() and GetPlayerHealth(me) > 0 then
		if InputPressed("q") and not whChatTyping() then ServerCall("server.whQ", me) end
	end
end

function whSpiritClientRender(dt)
	local e = shared.wh
	if e and e.phase == "play" then whVisualTick(dt, whSpirits()) else whVisualTick(dt, {}) end
end

local function bar(x, y, w, h, frac, r, g, b)
	UiPush()
	UiTranslate(x, y)
	UiColor(0, 0, 0, 0.55)
	UiRect(w, h)
	UiColor(r, g, b, 0.9)
	UiRect(w * math.max(0, math.min(1, frac)), h)
	UiPop()
end

-- the witch's own HUD: Q ready / recovering, the spirit's time, the claw, burned, stunned; anyone burning sees it
function whSpiritClientDraw()
	local me = GetLocalPlayer()
	if GetPlayerHealth(me) <= 0 then return end
	if CS.burn[me] then                                          -- (burning: an orange edge)
		UiPush()
		UiColor(1, 0.35, 0.05, 0.18 + 0.08 * math.sin(GetTime() * 12))
		UiRect(UiWidth(), UiHeight())
		UiPop()
	end
	if not whAmWitch() then return end
	local m = CS.me
	local el = GetTime() - m.t                                    -- (counted down locally between the server's updates)
	local function left(v) return math.max(0, v - el) end
	local y = UiHeight() - 150
	if m.spirit then
		local frac = m.forced and 1 or left(m.left) / SPIRIT_TIME
		bar(UiCenter() - 160, y, 320, 10, frac, 0.8, 0.9, 1.0)
		bar(UiCenter() - 160, y + 14, 320, 6, m.hp or 1, 0.9, 0.3, 0.25)   -- (her health: the game's own bar can't show it while she is a spirit)
		local txt
		if left(m.stun) > 0 then txt = "STUNNED BY THE CROSS"
		elseif m.forced then txt = "BURNED OUT OF HIDING - you turn back " .. math.ceil(left(m.lock)) .. " s after the fire"
		elseif left(m.lock) > 0 then txt = "BURNED - no strikes for " .. math.ceil(left(m.lock)) .. " s"
		elseif left(m.claw) > 0 then txt = "claw in " .. string.format("%.1f", left(m.claw)) .. " s"
		else txt = "LMB: claw   Space / Crouch: fly up / down   Q: back to human" end
		whBigText(y - 22, 20, txt, 0.85, 0.92, 1.0, 0.9)
	else
		local cd = left(m.cd)
		whBigText(y, 20, cd > 0 and ("spirit form in " .. math.ceil(cd) .. " s") or "Q: spirit form", 0.85, 0.5, 0.45, 0.85)
		if m.burn > 0.05 then bar(UiCenter() - 100, y + 18, 200, 6, m.burn / BURN_REVEAL, 1, 0.45, 0.1) end
	end
end
