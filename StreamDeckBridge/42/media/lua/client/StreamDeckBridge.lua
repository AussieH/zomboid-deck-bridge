-- Stream Deck Bridge for Project Zomboid (Build 42), the companion mod of the Zomboid Deck plugin for Stream Deck.
--
-- Once a second it writes what your survivor can see about themselves to Zomboid\Lua\StreamDeck\state.json: health,
-- the moodles the game is showing, the time and weather, what is in your hands, your load and the car you are in. It
-- also reads Zomboid\Lua\StreamDeck\command.json, where the plugin leaves a key press, runs it with the game's own
-- action and empties the file.
--
-- Client-side only (media/lua/client), for the local player. It never changes a stat, spawns anything or reads what
-- the character cannot know: no hidden infection, no exact power or water shutoff date.

StreamDeckBridge = StreamDeckBridge or {}
local B = StreamDeckBridge

B.VERSION = "1.0.0"
B.PROTOCOL = 1
B.STATE_FILE = "StreamDeck/state.json"
B.COMMAND_FILE = "StreamDeck/command.json"
B.WRITE_MS = 1000
B.COMMAND_MS = 250
B.MENU_MS = 2000
B.COMMAND_MAX_AGE_MS = 5000

-- One line in the game's console.txt (Zomboid\console.txt) when the mod loads, when it first writes the state file,
-- and if the file cannot be written, so a player can tell whether it is running. Nothing is printed every second.
local function log(text) print("[StreamDeckBridge] " .. text) end
B.log = log

-- ---------------------------------------------------------------------------------------------------------------
-- JSON, just enough of it: numbers are rounded and never NaN or infinite, strings are escaped, nil fields are left out
-- ---------------------------------------------------------------------------------------------------------------
local function round(x, places)
    local m = 10 ^ (places or 3)
    return math.floor(x * m + 0.5) / m
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function quote(s)
    s = string.gsub(tostring(s), '[%c"\\]', function(c)
        return ESC[c] or string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. s .. '"'
end

local encode
local function isArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n > 0 and t[1] ~= nil and n == #t
end
encode = function(v)
    local kind = type(v)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return v and "true" or "false" end
    if kind == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(round(v, 3))
    end
    if kind == "string" then return quote(v) end
    if kind == "table" then
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[#parts + 1] = encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do parts[#parts + 1] = quote(k) .. ":" .. encode(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end
B.encode = encode

-- ---------------------------------------------------------------------------------------------------------------
-- Reading the game. Every part is read under pcall: if an update renames a method, that part goes missing from the
-- file and the rest still arrives.
-- ---------------------------------------------------------------------------------------------------------------
local function try(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function num(x)
    if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge then return nil end
    return x
end

-- Moodles, by the names on MoodleType in B42 (zombie.scripting.objects.MoodleType), and the id the plugin knows each by.
B.MOODLES = {
    { "HUNGRY", "hungry" }, { "THIRST", "thirst" }, { "TIRED", "tired" }, { "ENDURANCE", "endurance" },
    { "PANIC", "panic" }, { "STRESS", "stress" }, { "BORED", "bored" }, { "UNHAPPY", "unhappy" },
    { "SICK", "sick" }, { "PAIN", "pain" }, { "INJURED", "injured" }, { "BLEEDING", "bleeding" },
    { "WET", "wet" }, { "HAS_A_COLD", "hasCold" }, { "HYPOTHERMIA", "hypothermia" }, { "HYPERTHERMIA", "hyperthermia" },
    { "WINDCHILL", "windchill" }, { "HEAVY_LOAD", "heavyLoad" }, { "DRUNK", "drunk" }, { "ANGRY", "angry" },
    { "UNCOMFORTABLE", "uncomfortable" }, { "NOXIOUS_SMELL", "noxiousSmell" }, { "FOOD_EATEN", "foodEaten" },
    { "CANT_SPRINT", "cantSprint" }, { "ZOMBIE", "zombie" }, { "DEAD", "dead" },
}
local KIND = { [1] = "good", [2] = "bad" }

local function readMoodles(player)
    local moodles = player:getMoodles()
    local out = {}
    for _, pair in ipairs(B.MOODLES) do
        local mt = MoodleType[pair[1]]
        if mt then
            local level = try(function() return moodles:getMoodleLevel(mt) end)
            if level and level > 0 then
                out[pair[2]] = {
                    level = level,
                    kind = KIND[try(function() return moodles:getGoodBadNeutral(mt) end)] or "neutral",
                    name = try(function() return moodles:getMoodleDisplayString(mt) end),
                }
            end
        end
    end
    return out
end

-- Stats the moodles are made from, as fractions of each stat's own range. Only ones the moodles already show; never
-- ZOMBIE_INFECTION, ZOMBIE_FEVER or SICKNESS, which would give away an infection the character does not know about.
B.STATS = {
    { "ENDURANCE", "endurance" }, { "HUNGER", "hunger" }, { "THIRST", "thirst" }, { "FATIGUE", "fatigue" },
    { "STRESS", "stress" }, { "PANIC", "panic" }, { "BOREDOM", "boredom" }, { "UNHAPPINESS", "unhappiness" },
}
local function readStats(player)
    local stats = player:getStats()
    local out = {}
    for _, pair in ipairs(B.STATS) do
        local cs = CharacterStat[pair[1]]
        if cs then
            local v = num(try(function() return stats:get(cs) end))
            local lo = num(try(function() return cs:getMinimumValue() end)) or 0
            local hi = num(try(function() return cs:getMaximumValue() end)) or 1
            if v and hi > lo then out[pair[2]] = math.max(0, math.min(1, (v - lo) / (hi - lo))) end
        end
    end
    return out
end

local function readItem(item)
    if not item then return nil end
    local out = {
        name = try(function() return item:getDisplayName() end),
        type = try(function() return item:getFullType() end),
        condition = num(try(function() return item:getCondition() end)),
        conditionMax = num(try(function() return item:getConditionMax() end)),
        broken = try(function() return item:isBroken() end) or nil,
    }
    if try(function() return item:hasSharpness() end) then
        local s = num(try(function() return item:getSharpness() end))
        local m = num(try(function() return item:getMaxSharpness() end))
        if s and m and m > 0 then out.sharpness = s / m end
    end
    if instanceof(item, "HandWeapon") then
        out.weapon = true
        if try(function() return item:isRanged() end) then
            out.ranged = true
            out.ammo = num(try(function() return item:getCurrentAmmoCount() end))
            out.ammoMax = num(try(function() return item:getMaxAmmo() end))
            if try(function() return item:haveChamber() end) then out.chambered = try(function() return item:isRoundChambered() end) or false end
            if try(function() return item:getMagazineType() end) then out.magazine = try(function() return item:isContainsClip() end) or false end
            out.jammed = try(function() return item:isJammed() end) or nil
        end
    end
    if try(function() return item:canEmitLight() end) then
        out.light = { on = try(function() return item:isActivated() end) or false }
        if instanceof(item, "DrainableComboItem") then out.light.battery = num(try(function() return item:getCurrentUsesFloat() end)) end
    end
    return out
end

-- Sitting on the ground or on furniture. Build 42.21's own SitOnGround key asks player:isSitting(); the two older
-- getters stay as the fallback if a later build renames it.
local function isSitting(player)
    local v = try(function() return player:isSitting() end)
    if v ~= nil then return v end
    return (try(function() return player:isSitOnGround() end) or try(function() return player:isSittingOnFurniture() end)) and true or false
end
B.isSitting = isSitting

local function vehicleName(vehicle)
    local script = vehicle:getScript()
    if not script then return nil end
    local carName = try(function() return script:getCarModelName() end) or script:getName()
    return try(function() return getTextOrNull("IGUI_VehicleName" .. carName) end) or carName
end

local function readVehicle(player)
    local vehicle = player:getVehicle()
    if not vehicle then return nil end
    local out = {
        name = try(vehicleName, vehicle),
        driver = try(function() return vehicle:isDriver(player) end) or false,
        speed = num(try(function() return math.abs(vehicle:getCurrentSpeedKmHour()) end)),
        engine = try(function() return vehicle:isEngineRunning() end) or false,
        engineCondition = num(try(function() return vehicle:getEngineCondition() end)),
        headlights = try(function() return vehicle:getHeadlightsOn() end) or false,
        hasHeadlights = try(function() return vehicle:hasHeadlights() end) or false,
        gear = try(function() return vehicle:getTransmissionNumberLetter() end),
    }
    local tank = try(function() return vehicle:getPartById("GasTank") end)
    if tank and try(function() return tank:isContainer() end) then
        local cap = num(try(function() return tank:getContainerCapacity() end))
        local amount = num(try(function() return tank:getContainerContentAmount() end))
        if cap and cap > 0 and amount then out.fuel = math.max(0, math.min(1, amount / cap)) end
    end
    return out
end

local function readTime()
    local gt = getGameTime()
    return {
        hour = gt:getHour(), minute = gt:getMinutes(),
        day = gt:getDay() + 1, month = gt:getMonth() + 1, year = gt:getYear(),
        speed = try(getGameSpeed),
        season = try(function() return getClimateManager():getSeasonName() end),
    }
end

local function readWeather(player)
    local cm = getClimateManager()
    return {
        temp = num(try(function() return cm:getAirTemperatureForCharacter(player) end)),
        rain = num(try(function() return cm:getRainIntensity() end)),
        snow = num(try(function() return cm:getSnowIntensity() end)),
        fog = num(try(function() return cm:getFogIntensity() end)),
        cloud = num(try(function() return cm:getCloudIntensity() end)),
        wind = num(try(function() return cm:getWindspeedKph() end)),
        raining = try(function() return cm:isRaining() end) or false,
        snowing = try(function() return cm:isSnowing() end) or false,
        thunder = try(function() return cm:getIsThunderStorming() end) or false,
    }
end

-- Where you are: indoors or out, how light it is on your square, and whether the grid's power and the mains water are
-- still on. Those two are only on or off, as a lamp or a tap would show; the day they stop stays the game's secret.
local function readPlace(player)
    local sq = player:getCurrentSquare()
    local out = {
        outside = try(function() return player:isOutside() end),
        grid = try(function() return getWorld():isHydroPowerOn() end),
    }
    if sq then
        out.light = num(try(function() return sq:getLightLevel(player:getPlayerNum()) end))
        out.power = try(function() return sq:haveElectricity() end)
    end
    out.water = try(function()
        local days = getGameTime():getWorldAgeHours() / 24 + (getSandboxOptions():getTimeSinceApo() - 1) * 30
        return days < getSandboxOptions():getWaterShutModifier()
    end)
    return out
end

function B.readState()
    local player = getSpecificPlayer(0)
    local s = {
        protocol = B.PROTOCOL, mod = B.VERSION,
        game = try(function() return getCore():getVersionNumber() end),
        at = getTimestampMs(), seq = B.seq,
        mp = try(isClient) or false,
        clock24 = try(function() return getCore():getOptionClock24Hour() end),
        celsius = try(function() return getCore():getOptionDisplayAsCelsius() end),
        ack = B.ack,
    }
    if not player then
        s.state = "loading"
        return s
    end
    s.time = try(readTime)
    s.survived = num(try(function() return player:getHoursSurvived() end))
    s.kills = num(try(function() return player:getZombieKills() end))
    if try(function() return player:isDead() end) then
        s.state = "dead"
        return s
    end
    s.state = (try(isGamePaused) and "paused") or "ingame"
    s.health = num(try(function() return player:getBodyDamage():getOverallBodyHealth() end))
    s.moodles = try(readMoodles, player) or {}
    s.stats = try(readStats, player)
    s.wounds = try(function()
        local bd = player:getBodyDamage()
        return { bitten = bd:getNumPartsBitten(), scratched = bd:getNumPartsScratched(), bleeding = bd:getNumPartsBleeding() }
    end)
    s.weight = try(function() return { carried = player:getInventoryWeight(), max = player:getMaxWeight() } end)
    s.hands = try(function()
        local primary, secondary = player:getPrimaryHandItem(), player:getSecondaryHandItem()
        local out = { primary = try(readItem, primary), secondary = try(readItem, secondary) }
        if out.primary and primary == secondary then out.twoHanded = true end
        return out
    end) or {}
    s.vehicle = try(readVehicle, player)
    s.weather = try(readWeather, player)
    s.place = try(readPlace, player)
    s.zombies = try(function()
        local st = player:getStats()
        return { visible = st:getNumVisibleZombies(), chasing = st:getNumChasingZombies() }
    end)
    s.sitting = try(isSitting, player) or false
    s.asleep = try(function() return player:isAsleep() end) or false
    return s
end

-- ---------------------------------------------------------------------------------------------------------------
-- The state file. Lua cannot rename or delete in the Zomboid folder, so each write is one complete file in one write
-- call; the plugin uses it only when it parses and carries "end": true, and otherwise keeps the last good one.
-- ---------------------------------------------------------------------------------------------------------------
B.seq = 0
function B.writeState(s)
    B.seq = B.seq + 1
    s.seq = B.seq
    s["end"] = true
    local text = encode(s)
    local w = getFileWriter(B.STATE_FILE, true, false)
    if not w then
        if not B.writeFailed then log("cannot write Zomboid/Lua/" .. B.STATE_FILE); B.writeFailed = true end
        return false
    end
    w:write(text)
    w:close()
    if not B.wroteOnce and s.state ~= "menu" and s.state ~= "loading" then
        B.wroteOnce = true
        log("writing Zomboid/Lua/" .. B.STATE_FILE .. " (state " .. tostring(s.state) .. ", game " .. tostring(s.game) .. ")")
    end
    return true
end

function B.writeMenu()
    B.writeState({ protocol = B.PROTOCOL, mod = B.VERSION, state = "menu", at = getTimestampMs(),
        game = try(function() return getCore():getVersionNumber() end) })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Commands: the game's own actions, for the local player only, each checked the way the game's own key or menu does
-- ---------------------------------------------------------------------------------------------------------------
B.COMMANDS = {}

-- Sit on the ground, or get up: what the game's SitOnGround key does (ISSitOnGround.lua), which has no default key.
B.COMMANDS.sit = function(player)
    if player:getVehicle() then return false, "in a vehicle" end
    if isSitting(player) then
        player:StopAllActionQueue()
        player:setVariable("forceGetUp", true)
        return true, "standing up"
    end
    player:setAutoWalk(false)
    player:reportEvent("EventSitOnGround")
    return true, "sitting down"
end

-- The car's headlights, as the vehicle menu switches them (ISVehicleMenu.onToggleHeadlights), for the driver only.
B.COMMANDS.headlights = function(player)
    local vehicle = player:getVehicle()
    if not vehicle then return false, "not in a vehicle" end
    if not vehicle:isDriver(player) then return false, "not the driver" end
    if not vehicle:hasHeadlights() then return false, "no headlights" end
    local wasOn = vehicle:getHeadlightsOn()
    ISVehicleMenu.onToggleHeadlights(player)
    return true, wasOn and "lights off" or "lights on"
end

-- The light in your hands or on your belt, as the game's light key does on foot (ItemBindingHandler.toggleLight),
-- including equipping your best light when nothing is lit. Not while driving: there the same key means headlights.
B.COMMANDS.light = function(player)
    local vehicle = player:getVehicle()
    if vehicle and vehicle:isDriver(player) then return false, "driving" end
    if not (ItemBindingHandler and ItemBindingHandler.toggleLight) then return false, "not available" end
    -- The key only matters to toggleLight when it is also the headlights key and you drive, refused above.
    local key = try(function() return getCore():getKey(KeybindId.LIGHT_SOURCE) end)
        or try(function() return getCore():getKey("Equip/Turn On/Off Light Source") end) or 0
    ItemBindingHandler.toggleLight(key)
    return true, "light"
end

-- Start or stop the engine, as the game's StartVehicleEngine key does (ISVehicleMenu.onKeyPressed).
B.COMMANDS.engine = function(player)
    local vehicle = player:getVehicle()
    if not vehicle then return false, "not in a vehicle" end
    if not vehicle:isDriver(player) then return false, "not the driver" end
    if vehicle:isEngineRunning() then
        ISVehicleMenu.onShutOff(player)
        return true, "engine off"
    end
    ISVehicleMenu.onStartEngine(player)
    return true, "starting"
end

-- Stop what you are doing: clear the queue of timed actions (ISTimedActionQueue.clear), without the pause menu that
-- Escape opens when there is nothing to cancel.
B.COMMANDS.cancel = function(player)
    ISTimedActionQueue.clear(player)
    return true, "stopped"
end

B.lastId = nil
B.ack = nil
function B.run(id, cmd)
    local player = getSpecificPlayer(0)
    local fn = B.COMMANDS[cmd]
    local ok, msg
    if not fn then ok, msg = false, "unknown command"
    elseif not player or player:isDead() then ok, msg = false, "no survivor"
    elseif try(isGamePaused) then ok, msg = false, "game paused"
    else
        local okCall, a, b = pcall(fn, player)
        if okCall then ok, msg = a, b else ok, msg = false, "failed" end
    end
    B.ack = { id = id, cmd = cmd, ok = ok and true or false, msg = msg }
    return B.ack
end

-- The plugin writes command.json whole (it renames a finished file into place). Read it, empty it, and run it once:
-- the id stops a command that is read twice from running twice.
function B.checkCommand()
    local r = getFileReader(B.COMMAND_FILE, false)
    if not r then return false end
    local text = {}
    local line = r:readLine()
    while line do
        text[#text + 1] = line
        line = r:readLine()
    end
    r:close()
    text = table.concat(text, "\n")
    if text == "" then return false end
    local w = getFileWriter(B.COMMAND_FILE, true, false)
    if w then w:close() end
    local id = string.match(text, '"id"%s*:%s*"([%w%-_]+)"')
    local cmd = string.match(text, '"cmd"%s*:%s*"([%w_]+)"')
    local at = tonumber(string.match(text, '"at"%s*:%s*(%d+)'))
    if not id or not cmd or id == B.lastId then return false end
    B.lastId = id
    -- A press older than a few seconds (left over from before the game started) is dropped, not run late.
    if at and getTimestampMs() - at > B.COMMAND_MAX_AGE_MS then return false end
    B.run(id, cmd)
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Timing: real time, not game time, so the deck keeps up at any game speed and while paused
-- ---------------------------------------------------------------------------------------------------------------
B.nextWrite, B.nextCommand, B.nextMenu = 0, 0, 0

function B.onTick()
    local now = getTimestampMs()
    local wrote = false
    if now >= B.nextCommand then
        B.nextCommand = now + B.COMMAND_MS
        if try(B.checkCommand) then B.nextWrite = 0 end
    end
    if now >= B.nextWrite then
        B.nextWrite = now + B.WRITE_MS
        local s = try(B.readState)
        if s then wrote = try(B.writeState, s) end
    end
    return wrote
end

function B.onMenuTick()
    local now = getTimestampMs()
    if now < B.nextMenu then return end
    B.nextMenu = now + B.MENU_MS
    try(B.writeMenu)
end

function B.onDeath(character)
    if character == getSpecificPlayer(0) then
        B.nextWrite = 0
    end
end

if not isServer() then
    log("Stream Deck Bridge " .. B.VERSION .. " loaded (protocol " .. B.PROTOCOL .. ")")
    Events.OnTickEvenPaused.Add(B.onTick)
    Events.OnPlayerDeath.Add(B.onDeath)
    Events.OnMainMenuEnter.Add(B.writeMenu)
    Events.OnFETick.Add(B.onMenuTick)
end
