--========================================================
-- Plenilune | Auto PB
-- Sections: Auto PB + Timing | Range | Debug
--========================================================

--------------------------------------------------------
-- CONFIG
--------------------------------------------------------
local DATA_URL = "https://raw.githubusercontent.com/4sigils/deep/refs/heads/main/strikeanims.lua"
local PB_KEY   = 0x46 -- F

-- Repo list of animation IDs to ignore (idle / walk / etc). Any digits on a
-- non-comment line are treated as an ID, so ["123"] = true, or plain 123, both work.
local IGNORE_URL = "https://raw.githubusercontent.com/4sigils/deep/refs/heads/main/ignoredanims.lua"

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

-- Scan workspace.Characters. Only models whose name is also in game.Players
-- are treated as enemies (NPCs are ignored). Respects the PB Players toggle.
-- Returns { {model=, name=, isPlayer=true}, ... }
local function GetEnemies()
    local list = {}
    local characters = workspace:FindFirstChild("Characters")
    if not characters then return list end

    if not UI.GetValue("sb_pb_players") then return list end

    local lp = game.Players.LocalPlayer
    local myName = lp and lp.Name

    local names = {}
    for _, p in ipairs(game.Players:GetChildren()) do names[p.Name] = true end

    for _, model in ipairs(characters:GetChildren()) do
        local name = model.Name
        if name ~= myName and names[name] then
            list[#list + 1] = {model = model, name = name, isPlayer = true}
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
local Releases = {}
local function PressKey(vk, holdSeconds)
    local ok = pcall(function() keypress(vk) end)
    if not ok then
        print("[Plenilune] keypress() failed - your executor may name it differently")
        return
    end
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

local function Log(msg) print("[Plenilune] " .. tostring(msg)) end

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

    local src = HttpGet(IGNORE_URL)
    if not src then
        Log("Failed to download ignore list from " .. IGNORE_URL)
        return
    end

    for line in src:gmatch("[^\r\n]+") do
        line = line:gsub("%-%-.*$", "")
        for id in line:gmatch("%d+") do IgnoredIds[id] = true end
    end

    local n = 0
    for _ in pairs(IgnoredIds) do n = n + 1 end
    Status.ignored = n
    Log("Ignoring " .. n .. " animations")
end

--------------------------------------------------------
-- ANIM TRACKER (Debug)
-- Prints new animations on TRACKER_PATH and how long after the animation
-- started you took damage.
--------------------------------------------------------
local TrackerActive = false
local TrackerWarned = false
local TrackerSeen   = {}   -- [track address] = true while it is playing
local TLastHealth, TLastHumanoid = nil, nil
local TAnimTime, TAnimId = nil, nil

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
end

local function TrackerReset()
    TrackerSeen = {}
    TLastHealth, TLastHumanoid = nil, nil
    TrackerResetDamage()
end

local function TrackerCheckDamage()
    local lp   = game.Players.LocalPlayer
    local char = lp and lp.Character
    local hum  = char and char:FindFirstChild("Humanoid")

    if not hum then
        TLastHealth, TLastHumanoid = nil, nil
        TrackerResetDamage()
        return
    end

    -- new humanoid / respawn
    if hum ~= TLastHumanoid then
        TLastHumanoid, TLastHealth = hum, hum.Health
        TrackerResetDamage()
        return
    end

    local hp = hum.Health
    if TLastHealth and hp < TLastHealth then
        local now = os.clock()
        if TAnimTime and TAnimId then
            Log(string.format("[DAMAGE] %s -> %.4fs", TAnimId, now - TAnimTime))
            TAnimTime, TAnimId = nil, nil
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
            Log("Anim Tracker: target not found: " .. TRACKER_PATH)
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
                -- start time = now minus how far into the animation it already is
                local el = anim.elapsed
                if type(el) ~= "number" or el ~= el or el < 0 or el > 10 then el = 0 end
                local start = os.clock() - el

                TAnimTime, TAnimId = start, anim.id
                Log(string.format("[%s] %s", TRACKER_PATH, anim.id))
            end
        end
    end

    -- forget tracks that stopped so a replay is reported again
    for k in pairs(TrackerSeen) do
        if not seenNow[k] then TrackerSeen[k] = nil end
    end
end

--------------------------------------------------------
-- UI
--------------------------------------------------------
UI.AddTab("Plenilune", function(tab)

    ------------------------------------------------
    -- Auto PB + Timing
    ------------------------------------------------
    local pb = tab:Section("Auto PB + Timing", "Left", {"Main", "Timing"})

    if pb.page == 0 then
        pb:Toggle("sb_pb_on", "Enabled")
        pb:Toggle("sb_pb_players", "PB Players", true)
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
    local delay  = UI.GetValue("sb_t_delay")
    local jitter = UI.GetValue("sb_t_jitter")
    local ping   = UI.GetValue("sb_t_ping")
    local hold   = UI.GetValue("sb_t_hold") / 1000
    local pbs    = info.pbs or {0}

    for _, t in ipairs(pbs) do
        local ms = delay + math.random(0, jitter) - ping
        local at = startTime + t + (ms / 1000)
        Queue[#Queue + 1] = {at = at, hold = hold}
        if UI.GetValue("sb_d_fires") then
            Log(string.format("Scheduled pb @ %.3fs, fires in %.3fs", t, at - os.clock()))
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
    -- Anim Tracker (Debug)
    if UI.GetValue("sb_d_tracker") then
        TrackerActive = true
        TrackerStep()
    elseif TrackerActive then
        TrackerActive = false
        TrackerReset()
    end

    task.wait()
end
