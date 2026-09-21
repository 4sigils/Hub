--========================================================
-- Strikeborn | Auto PB
-- Sections: Auto PB + Timing | Range | Debug
--========================================================

--------------------------------------------------------
-- CONFIG
--------------------------------------------------------
local DATA_URL = "https://raw.githubusercontent.com/4sigils/deep/refs/heads/main/strikeanims.lua"
local PB_KEY   = 0x46 -- F

local IGNORE_URL = "https://raw.githubusercontent.com/4sigils/deep/refs/heads/main/ignoredanims.lua"

-- Used even if the repo can't be reached (move these into the repo file when you can)
local LocalIgnored = {
    "73744451365843", "117195886801350", "91803933898647",
    "105074311921772", "140665037989542", "89977714060657",
}

-- Anim Tracker
local TRACKER_PATH = "Living/sigiltatted"

--------------------------------------------------------
-- OFFSETS / MEMORY HELPERS
--------------------------------------------------------
local offsets = game:GetService("HttpService"):JSONDecode(game:HttpGet("https://offsets.imtheo.lol/Offsets.json")).Offsets
local KnownOffsets = {
    AnimationId      = offsets.Misc.AnimationId,
    ClassDescriptor  = offsets.Instance.ClassDescriptor,
    ClassName        = offsets.Instance.ClassName,
    Name             = offsets.Instance.Name,
    TimePosition     = offsets.AnimationTrack.TimePosition or 0xD8,
    ActiveAnimations = offsets.Animator.ActiveAnimations,
    NodeNext         = 0x10,
}

local function ReadPointer(addr)
    local ok, v = pcall(function() return memory_read("uintptr_t", addr) end)
    if ok and v and v > 4096 then return v end
    return nil
end

local function ReadString(addr)
    if not addr or addr <= 4096 then return nil end
    local ok, s = pcall(function() return memory_read("string", addr) end)
    return ok and s or nil
end

local function GetClassName(addr)
    if not addr or addr <= 4096 then return "Invalid" end
    local desc = ReadPointer(addr + KnownOffsets.ClassDescriptor)
    if not desc then return "Error" end
    return ReadString(ReadPointer(desc + KnownOffsets.ClassName)) or "Unknown"
end

-- Numeric-only animation ID (handles rbxassetid://123, ?id=123, plain 123)
local function CleanId(id)
    return id and tostring(id):match("%d+")
end

--------------------------------------------------------
-- ADAPTERS  (small wrapper functions around Matcha / Roblox calls)
--------------------------------------------------------

-- Scan workspace.Living. If the model's name is in game.Players it is a
-- player, otherwise it is an NPC. Respects the PB Players / PB NPCs toggles.
-- Returns { {model=, name=, isPlayer=}, ... }
local function GetEnemies()
    local list = {}
    local living = workspace:FindFirstChild("Living")
    if not living then return list end

    local lp = game.Players.LocalPlayer
    local myName = lp and lp.Name
    local wantPlayers, wantNpcs = UI.GetValue("sb_pb_players"), UI.GetValue("sb_pb_npcs")

    local names = {}
    for _, p in ipairs(game.Players:GetChildren()) do names[p.Name] = true end

    for _, model in ipairs(living:GetChildren()) do
        local name = model.Name
        if name ~= myName then
            local isPlayer = names[name] == true
            if (isPlayer and wantPlayers) or (not isPlayer and wantNpcs) then
                list[#list + 1] = {model = model, name = name, isPlayer = isPlayer}
            end
        end
    end
    return list
end

-- Distance (studs) from local player to an enemy.
local function GetDistance(enemy)
    local lp   = game.Players.LocalPlayer
    local mine = lp and lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    local theirs = enemy.model:FindFirstChild("HumanoidRootPart")
    if not mine or not theirs then return math.huge end
    return (mine.Position - theirs.Position).Magnitude
end

-- Animations currently playing on an enemy as:
-- { {id = "123", elapsed = 0.12}, ... }
-- Animation pointer -> id is cached so each frame is only a few reads per track.
local AnimCache, AnimCacheN = {}, 0

local AnimatorCache, AnimatorCacheN = {}, 0

local function GetAnimatorAddr(model)
    local key = model.Address
    local addr = AnimatorCache[key]
    if addr then return addr end

    local hum = model:FindFirstChild("Humanoid")
    local animator = hum and hum:FindFirstChild("Animator")
    if not animator then return nil end

    if AnimatorCacheN > 200 then AnimatorCache, AnimatorCacheN = {}, 0 end
    addr = animator.Address
    AnimatorCache[key] = addr
    AnimatorCacheN = AnimatorCacheN + 1
    return addr
end

local function GetPlayingAnims(enemy)
    local out = {}
    local addr = GetAnimatorAddr(enemy.model)
    if not addr then return out end

    local listHead = ReadPointer(addr + KnownOffsets.ActiveAnimations)
    if not listHead then
        AnimatorCache[enemy.model.Address] = nil -- stale, look it up again next frame
        return out
    end

    local node, count = ReadPointer(listHead), 0
    while node and node ~= listHead and count < 50 do
        count = count + 1
        local track = ReadPointer(node + KnownOffsets.NodeNext)
        local anim = track and ReadPointer(track + offsets.AnimationTrack.Animation)
        if anim then
            local id = AnimCache[anim]
            if id == nil then
                id = false
                if GetClassName(anim) == "Animation" then
                    id = CleanId(ReadString(ReadPointer(anim + KnownOffsets.AnimationId))) or false
                end
                if AnimCacheN > 500 then AnimCache, AnimCacheN = {}, 0 end
                AnimCache[anim] = id
                AnimCacheN = AnimCacheN + 1
            end
            if id then
                local ok, t = pcall(function()
                    return memory_read("float", track + KnownOffsets.TimePosition)
                end)
                local good = ok and type(t) == "number" and t == t and t >= 0 and t < 30
                out[#out + 1] = {id = id, elapsed = good and t or 0, track = track}
            end
        end
        node = ReadPointer(node)
    end
    return out
end

-- Press a key without blocking. The release is handled by the main loop.
--
-- FIX: track whether each key is still logically "held down" from an
-- earlier PB. If two scheduled presses of the same key land in the same
-- tick (e.g. because the anim's elapsed time was already past the first
-- pb offset when we first detected it), the old code called keypress()
-- twice in a row with no keyrelease() in between - the game only sees a
-- key that's already down, so the second press was invisible. Now we
-- force a real release before re-pressing.
local Releases = {}
local KeyDown  = {}

local function ReleaseKeyNow(vk)
    pcall(function() keyrelease(vk) end)
    KeyDown[vk] = nil
    for i = #Releases, 1, -1 do
        if Releases[i].vk == vk then table.remove(Releases, i) end
    end
end

local function PressKey(vk, holdSeconds)
    if KeyDown[vk] then
        ReleaseKeyNow(vk)
    end

    local ok = pcall(function() keypress(vk) end)
    if not ok then
        print("[Strikeborn] keypress() failed - your executor may name it differently")
        return
    end
    KeyDown[vk] = true
    Releases[#Releases + 1] = {at = os.clock() + (holdSeconds or 0.05), vk = vk}
end

-- Download the raw text of a URL. Tries the common HTTP functions in order.
local function HttpGet(url)
    local attempts = {
        function() return game:HttpGet(url) end,
        function()
            local req = request or http_request or (syn and syn.request)
            local res = req and req({Url = url, Method = "GET"})
            return res and res.Body
        end,
    }
    for _, try in ipairs(attempts) do
        local ok, body = pcall(try)
        if ok and type(body) == "string" and #body > 0 then
            return body
        end
    end
    return nil
end

local function EnemyKey(enemy)
    return enemy.name
end

--------------------------------------------------------
-- STATE
--------------------------------------------------------
local AnimDB      = {}   -- [id] = {name=, range=, pbs={...}}
local Active      = {}   -- [enemyKey .. id] = start time of that animation
local Queue       = {}   -- scheduled PB presses {at=, hold=}
local SeenUnknown = {}
local Status      = {loaded = 0, ignored = 0, tracked = 0, last = "none", lastDist = 0, loopMs = 0, scanMs = 0}

local function Log(msg) print("[Strikeborn] " .. tostring(msg)) end

-- Fallback parser: reads the repo file line by line without loadstring.
local function ParseData(src)
    local data = {}
    for line in src:gmatch("[^\r\n]+") do
        if not line:match("^%s*%-%-") then
            local id = line:match('%["([^"]+)"%]')
            if id then
                local pbs = {}
                local list = line:match("pbs%s*=%s*{([^}]*)}")
                if list then
                    for n in list:gmatch("[%d%.]+") do
                        pbs[#pbs + 1] = tonumber(n)
                    end
                end
                data[id] = {
                    name  = line:match('name%s*=%s*"([^"]*)"') or id,
                    range = tonumber(line:match("range%s*=%s*([%d%.]+)")) or 15,
                    pbs   = (#pbs > 0) and pbs or {0},
                }
            end
        end
    end
    return data
end

local function LoadData()
    AnimDB = {}
    Status.loaded = 0

    local src = HttpGet(DATA_URL)
    if not src then
        Log("Failed to download anim data from " .. DATA_URL)
        Log("HttpGet failed: game:HttpGet / request / http_request were all unavailable or errored")
        return
    end

    -- Matcha's loadstring doesn't return the file's table, so parse the text directly
    local data = ParseData(src)

    local n = 0
    for id, info in pairs(data) do
        AnimDB[CleanId(id) or id] = info
        n = n + 1
    end
    Status.loaded = n

    if n == 0 then
        Log("Downloaded " .. #src .. " bytes but found 0 animations. First 80 chars: " .. src:sub(1, 80))
    else
        Log("Loaded " .. n .. " animations")
    end
end

--------------------------------------------------------
-- IGNORED ANIMS
--------------------------------------------------------
local IgnoredIds = {}

local function LoadIgnored()
    IgnoredIds = {}
    for _, id in ipairs(LocalIgnored) do IgnoredIds[id] = true end

    local src = HttpGet(IGNORE_URL)
    if not src then
        Log("Failed to download ignore list from " .. IGNORE_URL)
    else
        for line in src:gmatch("[^\r\n]+") do
            line = line:gsub("%-%-.*$", "")
            for id in line:gmatch("%d+") do IgnoredIds[id] = true end
        end
    end

    local n = 0
    for _ in pairs(IgnoredIds) do n = n + 1 end
    Status.ignored = n
    Log("Ignoring " .. n .. " animations")
end

--------------------------------------------------------
-- ANIMATION TRACKER
-- Tracks new animations on TRACKER_PATH and reports damage timing.
--------------------------------------------------------
local TrackerActive = false
local TrackerWarned = false
local TrackerSeen = {}

local TLastHealth, TLastHumanoid = nil, nil
local TAnimTime, TAnimId = nil, nil

local MultiDamageActive = false
local MultiDamageId = nil
local MultiDamageTotal = 0
local MultiDamageRemaining = 0
local MultiDamageLastTime = nil

local MULTI_DAMAGE_IDS = {
    ["7600224169"] = 3,
}

local function GetTargetFromPath(path)
    local current = workspace
    for part in string.gmatch(path, "[^/]+") do
        current = current:FindFirstChild(part)
        if not current then return nil end
    end
    return current
end

local function TrackerResetDamage()
    TAnimTime, TAnimId = nil, nil
    MultiDamageActive = false
    MultiDamageId = nil
    MultiDamageTotal = 0
    MultiDamageRemaining = 0
    MultiDamageLastTime = nil
end

local function TrackerReset()
    TrackerSeen = {}
    TLastHealth, TLastHumanoid = nil, nil
    TrackerResetDamage()
end

local function TrackerCheckDamage()
    local lp = game.Players.LocalPlayer
    local char = lp and lp.Character
    local hum = char and char:FindFirstChild("Humanoid")

    if not hum then
        TLastHealth, TLastHumanoid = nil, nil
        TrackerResetDamage()
        return
    end

    if hum ~= TLastHumanoid then
        TLastHumanoid, TLastHealth = hum, hum.Health
        TrackerResetDamage()
        return
    end

    local hp = hum.Health

    if TLastHealth ~= nil and hp < TLastHealth then
        if MultiDamageActive then
            local elapsed = os.clock() - MultiDamageLastTime
            local currentHit = MultiDamageTotal - MultiDamageRemaining + 1

            print(string.format(
                "[DAMAGE] %s hit %d/%d -> %.4fs",
                MultiDamageId,
                currentHit,
                MultiDamageTotal,
                elapsed
            ))

            MultiDamageRemaining -= 1
            MultiDamageLastTime = os.clock()

            if MultiDamageRemaining <= 0 then
                MultiDamageActive = false
                MultiDamageId = nil
                MultiDamageTotal = 0
                MultiDamageRemaining = 0
                MultiDamageLastTime = nil
            end
        elseif TAnimTime and TAnimId then
            local elapsed = os.clock() - TAnimTime

            print(string.format(
                "[DAMAGE] %s -> %.4fs",
                TAnimId,
                elapsed
            ))

            TAnimTime = nil
            TAnimId = nil
        end
    end

    TLastHealth = hp
end

local function TrackerStep()
    TrackerCheckDamage()

    local target = GetTargetFromPath(TRACKER_PATH)

    if not target then
        if not TrackerWarned then
            TrackerWarned = true
            Log("Animation Tracker: target not found: " .. TRACKER_PATH)
        end
        return
    end

    TrackerWarned = false

    local seenNow = {}

    for _, anim in ipairs(GetPlayingAnims({model = target})) do
        seenNow[anim.track] = true

        if not TrackerSeen[anim.track] then
            TrackerSeen[anim.track] = true

            if not IgnoredIds[anim.id] then
                local cleanId = CleanId(anim.id)

                if cleanId then
                    local hitCount = MULTI_DAMAGE_IDS[cleanId]

                    if hitCount then
                        MultiDamageActive = true
                        MultiDamageId = cleanId
                        MultiDamageTotal = hitCount
                        MultiDamageRemaining = hitCount
                        MultiDamageLastTime = os.clock()

                        TAnimTime = nil
                        TAnimId = nil

                        print(string.format(
                            "[%s] %s [MULTI: %d HITS]",
                            TRACKER_PATH,
                            cleanId,
                            hitCount
                        ))
                    else
                        local elapsed = anim.elapsed
                        if type(elapsed) ~= "number"
                            or elapsed ~= elapsed
                            or elapsed < 0
                            or elapsed > 10 then
                            elapsed = 0
                        end

                        TAnimTime = os.clock() - elapsed
                        TAnimId = cleanId

                        print(string.format(
                            "[%s] %s",
                            TRACKER_PATH,
                            cleanId
                        ))
                    end
                end
            end
        end
    end

    for k in pairs(TrackerSeen) do
        if not seenNow[k] then
            TrackerSeen[k] = nil
        end
    end
end

--------------------------------------------------------
-- UI
--------------------------------------------------------
UI.AddTab("Strikeborn", function(tab)

    ------------------------------------------------
    -- Auto PB + Timing
    ------------------------------------------------
    local pb = tab:Section("Auto PB + Timing", "Left", {"Main", "Timing"})

    if pb.page == 0 then
        pb:Toggle("sb_pb_on", "Enabled")
        pb:Toggle("sb_pb_players", "PB Players", true)
        pb:Toggle("sb_pb_npcs", "PB NPCs", false)
        pb:SliderInt("sb_pb_chance", "PB Chance", 1, 100, 100)

    elseif pb.page == 1 then
        pb:SliderInt("sb_t_delay", "Reaction Delay (ms)", 0, 400, 0)
        pb:SliderInt("sb_t_jitter", "Random Jitter (ms)", 0, 150, 0)
        pb:SliderInt("sb_t_hold", "Key Hold (ms)", 10, 300, 50)
        pb:SliderInt("sb_t_ping", "Ping Comp (ms)", 0, 300, 0)
        pb:Tip("Fires PBs this much earlier")
    end

    ------------------------------------------------
    -- Range
    ------------------------------------------------
    local rng = tab:Section("Range", "Right")
    rng:Toggle("sb_r_global", "Global Range")
    rng:Tip("Overrides the range set per animation in the repo")
    rng:SliderInt("sb_r_global_val", "Global Range", 0, 50, 15)
    rng:Text("Off = uses each animation's own range")

    ------------------------------------------------
    -- Debug
    ------------------------------------------------
    local dbg = tab:Section("Debug", "Right")
    dbg:Toggle("sb_d_anims", "Log Animations")
    dbg:Toggle("sb_d_unknown", "Log Unknown Only", true)
    dbg:Tip("Prints IDs that are not in the repo, once each")
    dbg:Toggle("sb_d_fires", "Log PB Fires")
    dbg:Toggle("sb_d_tracker", "Anim Tracker")
    dbg:Tip("Prints new anims + damage timing for " .. TRACKER_PATH)
    dbg:Spacing()
    dbg:Text("Loaded: " .. Status.loaded .. " anims")
    dbg:Text("Ignored: " .. Status.ignored .. " anims")
    dbg:Text("Tracking: " .. Status.tracked)
    dbg:Text("Last: " .. tostring(Status.last))
    dbg:Text("Dist: " .. string.format("%.1f", Status.lastDist))
    dbg:Text(string.format("Loop: %.0f ms | Scan: %.0f ms", Status.loopMs, Status.scanMs))
    dbg:Spacing()
    dbg:Button("Reload Anim Data", function() LoadData() end)
    dbg:Button("Reload Ignored Anims", function() LoadIgnored() end)
    dbg:Button("Reset Tracker", function() TrackerReset() end)
    dbg:Button("Clear Seen List", function() SeenUnknown = {} end)
    dbg:Button("Animation Tracker", function()
        TrackerActive = not TrackerActive
        TrackerReset()

        if TrackerActive then
            Log("Animation Tracker: ON")
        else
            Log("Animation Tracker: OFF")
        end
    end)
end)

--------------------------------------------------------
-- LOGIC
--------------------------------------------------------
local function GetRange(info)
    if UI.GetValue("sb_r_global") then
        return UI.GetValue("sb_r_global_val")
    end
    return info.range or 15
end

local function Schedule(startTime, info)
    local delay  = UI.GetValue("sb_t_delay") or 0
    local jitter = UI.GetValue("sb_t_jitter") or 0
    local ping   = UI.GetValue("sb_t_ping") or 0
    local hold   = (UI.GetValue("sb_t_hold") or 0) / 1000
    local pbs    = info.pbs or {0}

    for _, t in ipairs(pbs) do
        t = tonumber(t) or 0

        local ms = delay + math.random(0, jitter) - ping
        local at = startTime + t + (ms / 1000)

        Queue[#Queue + 1] = {
            at = at,
            hold = hold
        }

        if UI.GetValue("sb_d_fires") then
            Log(string.format(
                "Scheduled pb @ %.3fs, fires in %.3fs",
                t,
                at - os.clock()
            ))
        end
    end
end
local function FireDue()
    local t = os.clock()
    for i = #Queue, 1, -1 do
        local q = Queue[i]
        if t >= q.at then
            PressKey(PB_KEY, q.hold)
            if UI.GetValue("sb_d_fires") then Log("PB fired") end
            table.remove(Queue, i)
        end
    end
end

LoadData()
LoadIgnored()

local LastLoop = os.clock()

while true do
    local t0 = os.clock()
    Status.loopMs = Status.loopMs * 0.8 + (t0 - LastLoop) * 1000 * 0.2
    LastLoop = t0

    -- release any keys that have been held long enough
    do
        local t = os.clock()
        for i = #Releases, 1, -1 do
            if t >= Releases[i].at then
                pcall(function() keyrelease(Releases[i].vk) end)
                KeyDown[Releases[i].vk] = nil
                table.remove(Releases, i)
            end
        end
    end

    -- fire any queued PBs that are due (before the scan so scan time doesn't delay them)
    if UI.GetValue("sb_pb_on") then FireDue() end

    if UI.GetValue("sb_pb_on") then
        local now = os.clock()
        local seenNow, tracked = {}, 0
        local scanStart = os.clock()

        for _, enemy in ipairs(GetEnemies()) do
            local ekey = EnemyKey(enemy)

            for _, anim in ipairs(GetPlayingAnims(enemy)) do
                local id   = anim.id
                local info = AnimDB[id]
                local akey = ekey .. "|" .. id

                if UI.GetValue("sb_d_anims") and not IgnoredIds[id] then
                    local unknownOnly = UI.GetValue("sb_d_unknown")
                    if not unknownOnly or (not info and not SeenUnknown[id]) then
                        if not info then SeenUnknown[id] = true end
                        Log(ekey .. " -> " .. id)
                    end
                end

                if info then
                    tracked = tracked + 1
                    seenNow[akey] = true

                    if not Active[akey] then
                        local dist = GetDistance(enemy)
                        Status.last, Status.lastDist = info.name or id, dist

                        if dist <= GetRange(info)
                           and math.random(1, 100) <= UI.GetValue("sb_pb_chance") then
                            local start = os.clock() - (anim.elapsed or 0)
                            Active[akey] = start
                            Schedule(start, info)
                        else
                            Active[akey] = now -- mark so we don't re-roll every frame
                        end
                    end
                end
            end
            FireDue()
        end

        -- forget animations that stopped playing
        for k in pairs(Active) do
            if not seenNow[k] then Active[k] = nil end
        end
        Status.tracked = tracked
        Status.scanMs = Status.scanMs * 0.8 + (os.clock() - scanStart) * 1000 * 0.2

    else
        Queue, Active = {}, {}
    end
    -- Animation Tracker
    if TrackerActive then
        TrackerStep()
    end
    task.wait()
end
