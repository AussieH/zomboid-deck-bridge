-- Stream Deck Bridge for Project Zomboid (Build 42), the companion mod of the Zomboid Deck plugin for Stream Deck.
--
-- Once a second it writes what your survivor can see about themselves to Zomboid\Lua\StreamDeck\state.json: health,
-- what the game's Health tab lists for each body part, the moodles the game is showing, the time and weather, what is
-- in your hands, your load and the car you are in, with what the game's Vehicle Mechanics window lists for that car:
-- its overall condition and every part with its condition, in the window's colours. From 1.3.0 it also writes four tabs
-- of the game's character window: Skills (every skill with its level, progress and book multiplier), Info (profession,
-- traits, body weight and the rest of the tab), Protection (bite and scratch defence per body part) and Temperature (the
-- core temperature and body heat bars and each body part's skin temperature, body response, insulation and wind
-- resistance, as the tab shows them in a normal game). From 1.4.0 it also writes Zomboid\Lua\StreamDeck\inventory.json
-- every 2 s when it changed: what the game's inventory window lists for the main inventory and each bag you wear or
-- hold (name, count, category, weight and the line an open stack shows for each item). It also reads
-- Zomboid\Lua\StreamDeck\command.json, where the plugin leaves a key press, runs it with the game's own action and
-- empties the file.
--
-- Client-side only (media/lua/client), for the local player. It never changes a stat or spawns anything. The health
-- section repeats the game's own Health tab and nothing more, so a zombie infection the tab does not show is never
-- written; the mechanics section repeats the Mechanics window and nothing more, without its debug-mode lines, and the
-- character section repeats its tabs without theirs (the Temperature tab's raw numbers and reset button). In single
-- player it also writes how long the grid's power and the mains water have left, worked out with the game's own rule;
-- on a server (isClient()) it leaves that out and writes only whether they are on.

StreamDeckBridge = StreamDeckBridge or {}
local B = StreamDeckBridge

B.VERSION = "1.4.0"
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

-- The world's age in days as the shutoff rules count it: GameTime.getWorldAgeDaysSinceBegin() is
-- getWorldAgeHours() / 24 + (SandboxOptions.getTimeSinceApo() - 1) * 30 (javap, 42.21); the same sum by hand if that
-- getter ever goes.
local function worldDays()
    local gt = getGameTime()
    local d = num(try(function() return gt:getWorldAgeDaysSinceBegin() end))
    if d then return d end
    return gt:getWorldAgeHours() / 24 + (getSandboxOptions():getTimeSinceApo() - 1) * 30
end
B.worldDays = worldDays

-- Where you are: indoors or out, how light it is on your square, and whether the grid's power and the mains water are
-- still on. Water follows the game's own test, IsoObject.isWaterInfinite() and ParameterWaterSupply (javap, 42.21):
-- the taps run while the world's age in days is below WaterShutModifier.
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
    out.water = try(function() return worldDays() < getSandboxOptions():getWaterShutModifier() end)
    return out
end

-- How long the grid's power and the mains water have left, in single player only. The rules, read with javap from
-- Build 42.21's projectzomboid.jar:
--   power: SandboxOptions.doesPowerGridExist() is IsoWorld.getWorldAgeDays() <= ElecShutModifier, where
--          getWorldAgeDays() is GameTime.getWorldAgeDaysSinceBegin(); once it is false,
--          AmbientStreamManager.updatePowerSupply() plays the shutdown sound and its "ElectricityOff" marker turns
--          IsoWorld.isHydroPowerOn() off (AmbientSoundManager does it after a timer), so the power goes once the days
--          pass the modifier.
--   water: IsoObject.isWaterInfinite() is false once getWorldAgeDaysSinceBegin() >= WaterShutModifier.
--   Both modifiers run from -1 to 2147483647 (SandboxOptions' IntegerSandboxOptions). A new game sets them from the
--   ElecShut / WaterShut choice (SandboxOptions.randomElectricityShut / randomWaterShut, called by
--   client/OptionScreens/SandboxOptions.lua:951-952 and MainScreen.lua:1592-1596): "Instant" leaves -1, so the utility
--   is off from the first day, and the last choice gives 2147483647, so it never goes.
-- On a server (isClient()) nothing is written: knowing the day there would be an advantage over other players, so the
-- keys show only on or off. If isClient() cannot be read, it counts as a server.
B.NEVER = 2147483647
local function shutoff(modifier, days, inclusive)
    if modifier >= B.NEVER then return { never = true } end
    local left = modifier - days
    local off
    if inclusive then off = left < 0 else off = left <= 0 end
    return { hours = math.max(0, left * 24), off = off, instant = modifier < 0 or nil }
end
B.shutoff = shutoff
local function readShutoff()
    local mp = try(isClient)
    if mp ~= false then return nil end
    local days = worldDays()
    local so = getSandboxOptions()
    return {
        power = try(function() return shutoff(so:getElecShutModifier(), days, true) end),
        water = try(function() return shutoff(so:getWaterShutModifier(), days, false) end),
    }
end

-- ---------------------------------------------------------------------------------------------------------------
-- The Health tab: what media/lua/client/XpSystem/ISUI/ISHealthPanel.lua (Build 42.21) shows you about yourself, rule
-- for rule, line numbers from that file. Its debug-only lines (ISHealthPanel.cheat is getDebug(), line 5) are left out:
-- the bridge shows what a normal game shows. IsInfected() and getInfectionLevel() (a zombie infection) are never
-- read; the panel never shows them, and only the wound infection it lists as "Infected" is here.
-- ---------------------------------------------------------------------------------------------------------------
-- The panel's text colours: injuries (0.89, 0.28, 0.28), treatments (0.28, 0.89, 0.28), a dirty bandage and an infected
-- wound (1, 0.28, 0), minor muscle strain (1, 0.58, 0).
B.RED, B.GREEN, B.ORANGE, B.AMBER = "#e34747", "#47e347", "#ff4700", "#ff9400"
-- BodyPartType in index order, the order getBodyParts() and so the panel's list go in.
B.BODY_PARTS = { "Hand_L", "Hand_R", "ForeArm_L", "ForeArm_R", "UpperArm_L", "UpperArm_R", "Torso_Upper", "Torso_Lower",
    "Head", "Neck", "Groin", "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R", "Foot_L", "Foot_R" }

local function text(key)
    local t = try(getText, key)
    if type(t) == "string" and t ~= "" then return t end
    return key
end
-- " (Severe)" and the like, as the panel adds them after a wound's name.
local function grade(key) return " (" .. text(key) .. ")" end

-- Every line the panel draws under one body part, in its order, as { id, text, color }. The panel's "- " is left to
-- the plugin, and spaces are tidied (the panel joins some names with an extra " ").
function B.woundLines(bp, doctor)
    local lines = {}
    local function add(id, key, suffix, color)
        local s = string.gsub(text(key) .. (suffix or ""), "%s+", " ")
        s = string.gsub(string.gsub(s, "^ ", ""), " $", "")
        lines[#lines + 1] = { id = id, text = s, color = color }
    end
    local f = function(name) return num(try(function() return bp[name](bp) end)) or 0 end
    local yes = function(name) return try(function() return bp[name](bp) end) == true end
    local bandaged = yes("bandaged")
    -- 607-630: poultices on the part, in the treatments' green
    if f("getPlantainFactor") > 0 then add("plantain", "ContextMenu_PlantainCataplasm", nil, B.GREEN) end
    if f("getComfreyFactor") > 0 then add("comfrey", "ContextMenu_ComfreyCataplasm", nil, B.GREEN) end
    if f("getGarlicFactor") > 0 then add("garlic", "ContextMenu_GarlicCataplasm", nil, B.GREEN) end
    -- 631-641: scratched; a doctor above level 2 sees Severe over 17 scratch time, Moderate over 14
    if yes("scratched") then
        local t, s = f("getScratchTime"), nil
        if doctor > 2 then if t > 17 then s = grade("IGUI_health_Severe") elseif t > 14 then s = grade("IGUI_health_Moderate") end end
        add("scratched", "IGUI_health_Scratched", s, B.RED)
    end
    -- 649-659: cut (Laceration in English); the same grades on cut time
    if yes("isCut") then
        local t, s = f("getCutTime"), nil
        if doctor > 2 then if t > 17 then s = grade("IGUI_health_Severe") elseif t > 14 then s = grade("IGUI_health_Moderate") end end
        add("cut", "IGUI_health_Cut", s, B.RED)
    end
    -- 667-677: deep wound; a doctor above level 4 sees Severe over 10, Moderate over 8
    if yes("deepWounded") then
        local t, s = f("getDeepWoundTime"), nil
        if doctor > 4 then if t > 10 then s = grade("IGUI_health_Severe") elseif t > 8 then s = grade("IGUI_health_Moderate") end end
        add("deepWound", "IGUI_health_DeepWound", s, B.RED)
    end
    -- 683-685: bitten
    if yes("bitten") then add("bitten", "IGUI_health_Bitten", nil, B.RED) end
    -- 691-697: pain from this part over 10, heavy over 50
    local pain = f("getAdditionalPain")
    if pain > 10 then
        if pain > 50 then add("heavyPain", "IGUI_health_HeavyPain", nil, B.RED) else add("pain", "IGUI_health_Pain", nil, B.RED) end
    end
    -- 704-730: muscle strain from 5, minor (orange) under 20
    local stiff = f("getStiffness")
    if stiff >= 5 then
        if stiff < 20 then add("minorStiffness", "IGUI_health_MinorStiffness", nil, B.AMBER) else add("stiffness", "IGUI_health_Stiffness", nil, B.RED) end
    end
    -- 732-734: bleeding
    if yes("bleeding") then add("bleeding", "IGUI_health_Bleeding", nil, B.RED) end
    -- 740-750: a fracture with no splint; a doctor above level 6 sees Severe over 50, Moderate over 20
    local fracture, splint = f("getFractureTime"), f("getSplintFactor")
    if fracture > 0 and splint == 0 then
        local s = nil
        if doctor > 6 then if fracture > 50 then s = grade("IGUI_health_Severe") elseif fracture > 20 then s = grade("IGUI_health_Moderate") end end
        add("fracture", "IGUI_health_Fracture", s, B.RED)
    end
    -- 756-766: splinted; a doctor above level 4 sees Good over a splint factor of 4, else Moderate over 2 fracture time
    if splint > 0 then
        local s = nil
        if doctor > 4 then if splint > 4 then s = grade("IGUI_health_Good") elseif fracture > 2 then s = grade("IGUI_health_Moderate") end end
        add("splinted", "IGUI_health_Splinted", s, B.GREEN)
    end
    -- 772-778: bandaged, or a dirty bandage once its life is used up
    if bandaged then
        if f("getBandageLife") > 0 then add("bandaged", "IGUI_health_Bandaged", nil, B.GREEN) else add("dirtyBandage", "IGUI_health_DirtyBandage", nil, B.ORANGE) end
    end
    -- 802-811: an infected wound, not under a bandage, once doctor level 9, or the wound's infection level x 10
    -- reaches 2.5 minus the doctor level
    if yes("isInfectedWound") and not bandaged then
        if doctor > 8 or f("getWoundInfectionLevel") * 10 >= 2.5 - doctor then add("infected", "IGUI_health_Infected", nil, B.ORANGE) end
    end
    -- 812-815: a lodged bullet, not under a bandage
    if yes("haveBullet") and not bandaged then add("bullet", "IGUI_health_LodgedBullet", nil, B.RED) end
    -- 816-822: burned, not under a bandage; a doctor above level 4 sees Need Cleaning
    if f("getBurnTime") > 0 and not bandaged then
        local s = nil
        if doctor > 4 and yes("isNeedBurnWash") then s = grade("IGUI_health_NeedCleaning") end
        add("burned", "IGUI_health_Burned", s, B.RED)
    end
    -- 828-838: stitched; a doctor above level 6 sees Good over 40 stitch time, else Need Time
    if yes("stitched") then
        local s = nil
        if doctor > 6 then if f("getStitchTime") > 40 then s = grade("IGUI_health_Good") else s = grade("IGUI_health_NeedTime") end end
        add("stitched", "IGUI_health_Stitched", s, B.GREEN)
    end
    -- 844-847: lodged glass shards, not under a bandage
    if yes("haveGlass") and not bandaged then add("glass", "IGUI_health_LodgedGlassShards", nil, B.RED) end
    return lines
end

-- 523: the panel lists a part when it has an injury (BodyPart.HasInjury(): bitten, scratched, deep wound, bleeding, or
-- any bite, scratch, cut, fracture or burn time, or a bullet), a bandage, stitches, a splint, pain over 10 or muscle
-- strain over 5. (Its "isDebug and stiffness > 0" names no Lua global in 42.21, so it never applies.)
function B.isListed(bp)
    local f = function(name) return num(try(function() return bp[name](bp) end)) or 0 end
    local yes = function(name) return try(function() return bp[name](bp) end) == true end
    return yes("HasInjury") or yes("bandaged") or yes("stitched") or f("getSplintFactor") > 0 or f("getAdditionalPain") > 10 or f("getStiffness") > 5
end

-- 445-451: "Overall Body Status" in white, then NewHealthPanel.getDamageStatusString() (Java, javap 42.21): OK at 100,
-- then by BodyDamage.getHealth() over 90, 80, 70, 60, 50, 40, 20, 10 and 0, else Deceased; drawn in (1, 1 - t, 1 - t)
-- with t = (100 - health) / 100, never under 0.2.
B.STATUS = { { 90, "IGUI_health_Slight_damage" }, { 80, "IGUI_health_Very_Minor_damage" }, { 70, "IGUI_health_Minor_damage" },
    { 60, "IGUI_health_Moderate_damage" }, { 50, "IGUI_health_Severe_damage" }, { 40, "IGUI_health_Very_Severe_damage" },
    { 20, "IGUI_health_Crital_damage" }, { 10, "IGUI_health_Highly_Crital_damage" }, { 0, "IGUI_health_Terminal_damage" } }
function B.bodyStatus(health)
    local key = "IGUI_health_Deceased"
    if health == 100 then key = "IGUI_health_ok"
    else
        for _, s in ipairs(B.STATUS) do
            if health > s[1] then key = s[2]; break end
        end
    end
    local t = math.max((100 - health) / 100, 0.2)
    local gb = math.floor(math.max(0, math.min(1, 1 - t)) * 255 + 0.5)
    return { title = text("IGUI_health_Overall_Body_Status"), text = text(key), key = key,
        color = string.format("#ff%02x%02x", gb, gb), health = health }
end

local function readBody(player)
    local bd = player:getBodyDamage()
    local out = {}
    local health = num(try(function() return bd:getHealth() end))
    if health then out.status = B.bodyStatus(health) end
    -- 973: the panel's grades depend on the reader's Doctor skill, player:getPerkLevel(Perks.Doctor)
    local doctor = num(try(function() return player:getPerkLevel(Perks.Doctor) end)) or 0
    local parts = {}
    local list = bd:getBodyParts()
    for i = 1, list:size() do
        local bp = list:get(i - 1)
        if try(B.isListed, bp) then
            local id = try(function() return BodyPartType.ToString(bp:getType()) end) or B.BODY_PARTS[i]
            parts[#parts + 1] = {
                id = id,
                -- 592: the part's name as BodyPartType.getDisplayName gives it, in the player's language
                name = try(function() return BodyPartType.getDisplayName(bp:getType()) end) or id,
                health = num(try(function() return bp:getHealth() end)),
                lines = try(B.woundLines, bp, doctor) or {},
            }
        end
    end
    out.parts = parts
    return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- The Mechanics window (1.2.0): what media/lua/client/Vehicles/ISUI/ISVehicleMechanics.lua (Build 42.21) shows about a
-- vehicle, rule for rule, for the vehicle the player is sitting in, and which parts the car overlay beside its lists
-- (ISCarMechanicsOverlay.lua, same folder) draws and in what colour. Line numbers are from those two files.
-- From a seat, the vehicle's radial menu offers the window to the driver and passengers alike once the car has stopped
-- (ISVehicleMenu.lua:185-188, no isDriver test), so every seat gets it.
-- Left out: what the window shows only in debug mode or with the UnstableScriptNameSpam sandbox option (the "Vehicle
-- Script:" line, 1165-1169), the selected part's detail panel (1234-1372, with its debug-only "DBG: Gain XP" line,
-- 1334-1341), and the cheat and debug menus. The window has no Mechanics-skill rule for what it lists: the skill only
-- gates repair and configure options in its menus (325-364, 651-717), which the bridge never reads.
-- ---------------------------------------------------------------------------------------------------------------
-- 81: the door, bodywork and lights categories go in the window's right-hand list, every other in the left.
B.MECH_RIGHT = { door = true, bodywork = true, lights = true }

local function rgbOf(getter, fallback)
    local c = try(getter)
    if not c then return fallback end
    local r, g, b = num(try(function() return c:getR() end)), num(try(function() return c:getG() end)), num(try(function() return c:getB() end))
    if r and g and b then return { r, g, b } end
    return fallback
end

-- 1374-1380: getConditionRGB(condition) is the player's bad highlight colour interpolated towards the good one by
-- condition / 100 (Color.interp, javap 42.21: this + (to - this) x delta), from getCore()'s highlight colours (pure red
-- and pure green unless the player changed them).
function B.conditionColor(condition, good, bad)
    local t = condition / 100
    local c = {}
    for i = 1, 3 do c[i] = math.floor(math.max(0, math.min(1, bad[i] + (good[i] - bad[i]) * t)) * 255 + 0.5) end
    return string.format("#%02x%02x%02x", c[1], c[2], c[3])
end

-- 1154-1162: the vehicle's name, getText("IGUI_VehicleName" .. carModelName or the script's name), and for a burnt
-- script "Burnt %1" around the unburnt car's name when it has one.
local function mechanicsName(vehicle)
    local script = vehicle:getScript()
    local carName = try(function() return script:getCarModelName() end) or script:getName()
    local name = text("IGUI_VehicleName" .. carName)
    local scriptName = script:getName()
    if string.match(scriptName, "Burnt") then
        local unburnt = (string.gsub(scriptName, "Burnt", ""))
        local plain = try(getTextOrNull, "IGUI_VehicleName" .. unburnt)
        if plain then name = plain end
        name = try(getText, "IGUI_VehicleNameBurntCar", name) or name
    end
    return name
end

-- 914-916: the overlay is ISCarMechanicsOverlay.CarList[script:getCarMechanicsOverlay() or vehicle:getScriptName()];
-- with no entry the window draws no car at all.
local function overlayOf(vehicle)
    if type(ISCarMechanicsOverlay) ~= "table" or type(ISCarMechanicsOverlay.CarList) ~= "table" then return nil end
    local name = try(function() return vehicle:getScript():getCarMechanicsOverlay() end) or try(function() return vehicle:getScriptName() end)
    return name and ISCarMechanicsOverlay.CarList[name] or nil
end

-- 921-941: the images the overlay draws for a part: the part's entry in ISCarMechanicsOverlay.PartList (no entry, no
-- image), replaced by the car's own PartList entry when it has one (928-930), one image or several (multipleImg).
local function overlayImages(props, id)
    local pp = ISCarMechanicsOverlay.PartList and ISCarMechanicsOverlay.PartList[id]
    if not pp then return nil end
    if props.PartList and props.PartList[id] then pp = props.PartList[id] end
    if pp.multipleImg then
        local list = {}
        for _, img in ipairs(pp.img) do list[#list + 1] = img end
        return list
    end
    return { pp.img }
end

-- One line of the window's lists (doDrawItem, 856-894) and how the overlay colours the part.
local function readPart(part, good, bad, props)
    local id = part:getId()
    -- 52-53: the category, "Other" when there is none; "nodisplay" parts are not listed
    local category = try(function() return part:getCategory() end) or "Other"
    if category == "nodisplay" then return nil end
    local item = try(function() return part:getInventoryItem() end)
    -- a condition that cannot be read (a renamed getter) leaves the part out rather than listing it at 0
    local cond = num(part:getCondition())
    if not cond then return nil end
    local out = {
        id = id,
        -- 64, 59: the part's and the category's names, getText("IGUI_VehiclePart" .. id) and ("IGUI_VehiclePartCat" .. category)
        name = text("IGUI_VehiclePart" .. id), cat = category, catName = text("IGUI_VehiclePartCat" .. category),
        side = B.MECH_RIGHT[category] and "right" or "left", cond = cond,
    }
    if not item and try(function() return part:getTable("install") end) then
        -- 870-871: an uninstalled part is listed by name alone, in the bad highlight colour, which is also the colour of
        -- condition 0 the overlay gives it (924-926)
        out.missing = true
        out.color = B.conditionColor(0, good, bad)
    else
        -- 885-889: " (condition%)" in getConditionRGB(getCondition()); the name itself is 0.8 grey (873, partRGB 1521)
        out.color = B.conditionColor(cond, good, bad)
        if id == "Battery" then
            -- 875-878: "Battery: N% Remaining", N = floor(getCurrentUsesFloat() x 100)
            out.charge = math.floor(item:getCurrentUsesFloat() * 100)
            out.extra = out.charge .. "% " .. text("IGUI_invpanel_Remaining")
        elseif id == "GasTank" then
            -- 879-882: "Gas Tank: N% Remaining", N = floor(content / capacity x 100)
            local fuel = num(try(function() return math.floor(part:getContainerContentAmount() / part:getContainerCapacity() * 100) end))
            if fuel then out.fuel = fuel; out.extra = fuel .. "% " .. text("IGUI_invpanel_Remaining") end
        end
    end
    -- 931-934: on the overlay, alpha 0.9, pulsing when the condition is under 10 or the part is missing (the plugin
    -- repeats that rule from cond and missing)
    if props then out.ov = overlayImages(props, id) end
    return out
end

local function readMechanics(player)
    local vehicle = player:getVehicle()
    if not vehicle then return nil end
    local core = getCore()
    local bad = rgbOf(function() return core:getBadHighlitedColor() end, { 1, 0, 0 })
    local good = rgbOf(function() return core:getGoodHighlitedColor() end, { 0, 1, 0 })
    local props = try(overlayOf, vehicle)
    local out = {
        id = try(function() return vehicle:getId() end),
        name = try(mechanicsName, vehicle),
        -- 1170: "Vehicle Type: " and getText("IGUI_VehicleType_" .. script:getMechanicType())
        typeLabel = text("Tooltip_item_Mechanic"),
        type = try(function() return text("IGUI_VehicleType_" .. vehicle:getScript():getMechanicType()) end),
        -- 1175: the weight, getMass(); 1177-1179: the engine power, getEnginePower() / 10 hp, only with an Engine part
        weight = num(try(function() return vehicle:getMass() end)),
        power = try(function() if vehicle:getPartById("Engine") then return vehicle:getEnginePower() / 10 end end),
        overlay = props and type(props.imgPrefix) == "string" and (string.gsub(props.imgPrefix, "_$", "")) or nil,
        labels = { overall = text("IGUI_OverallCondition"), missing = text("IGUI_Missing") },
    }
    local parts, total, count = {}, 0, 0
    for i = 1, vehicle:getPartCount() do
        local part = vehicle:getPartByIndex(i - 1)
        local p = try(readPart, part, good, bad, props)
        if p then parts[#parts + 1] = p end
        -- 104-120: the Overall Condition the window shows is recalculGeneralCondition(), which update() runs every frame
        -- (26): every part, nodisplay ones too, at 0 when its item was taken out (getItemType() not empty and no
        -- inventory item, 112), averaged and rounded to 2 places
        local cond = num(try(function()
            local c = part:getCondition()
            local types = part:getItemType()
            if types and not types:isEmpty() and not part:getInventoryItem() then c = 0 end
            return c
        end))
        if cond then total = total + cond; count = count + 1 end
    end
    out.parts = parts
    if count > 0 then
        out.condition = math.floor(total / count * 100 + 0.5) / 100
        -- 1172-1173: "Overall Condition: " and the number in getConditionRGB(the number)
        out.color = B.conditionColor(out.condition, good, bad)
    end
    return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- The character window (1.3.0): four of the tabs of the window the game opens with J, L and P
-- (media/lua/client/XpSystem/ISUI/ISCharacterInfoWindow.lua, Build 42.21, lines 127-148): Skills (ISCharacterInfo.lua and
-- ISSkillProgressBar.lua), Info (ISCharacterScreen.lua), Protection (ISCharacterProtection.lua) and Temperature
-- (ISClothingInsPanel.lua), rule for rule, line numbers from those files. Every tab is added for every player: none is
-- debug-only. Their debug-mode extras are left out, so the deck shows what a normal game shows even when the game runs in
-- debug mode: the Temperature tab's raw numbers (core temperature, "R =" and "real:", ISClothingInsPanel.lua:624-634) and
-- its "-reset-" button (46-50); the Info tab's hair and beard debug menu options (358-364, 492-494).
-- ---------------------------------------------------------------------------------------------------------------
local function hexOf(c) return string.format("#%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5)) end

-- The Skills tab. ISCharacterInfo.loadPerk (265-285): every perk in PerkFactory.PerkList whose parent is not Perks.None,
-- grouped under its parent. createChildren (27-45): the groups sorted passive first, then by name with
-- "not string.sort(a, b)" (Kahlua's string.sort(a, b) is a:compareTo(b) > 0, javap 42.21, so a <= b; the same order is
-- asked for here as a strict a < b, which table.sort needs). 57-60: the skills in each group sorted by name (sortRecipes,
-- 10-13).
local XP_GETTERS = { "getXp1", "getXp2", "getXp3", "getXp4", "getXp5", "getXp6", "getXp7", "getXp8", "getXp9", "getXp10" }
-- ISSkillProgressBar.getPreviousXpLvl (254-288): the XP of every level below this one, xp1 to xp<level>.
function B.previousXp(perk, level)
    local total = 0
    for i = 1, math.min(level, 10) do total = total + (num(perk[XP_GETTERS[i]](perk)) or 0) end
    return total
end
local function readSkill(player, perk)
    local xp = player:getXp()
    local level = player:getPerkLevel(perk)
    -- 135-152: the name's colour by the starting XP boost: 0 is 0.54 grey, 1 is 0.8 grey, 2 white, 3 (1, 0.83, 0)
    local boost = num(try(function() return xp:getPerkBoost(perk) end)) or 0
    -- 155: the ">, >>, >>>" arrows run while the skill's multiplier (a skill book) is over 0
    local mult = num(try(function() return xp:getMultiplier(perk) end)) or 0
    local out = { id = try(function() return perk:getId() end) or perk:getName(), name = perk:getName(), level = level, boost = boost,
        mult = mult > 0 and round(mult, 2) or nil, passive = try(function() return perk:isPassiv() end) or nil }
    if level < 10 then
        -- ISSkillProgressBar 133-145, 250-252, 290-292: XP into this level, over getXpForLevel(level + 1), never above it
        local need = num(perk:getXpForLevel(level + 1))
        local have = (num(xp:getXP(perk)) or 0) - B.previousXp(perk, level)
        if need and need > 0 then
            out.need = need
            out.xp = math.max(0, math.min(have, need))
        end
    end
    return out
end
local function readSkills(player)
    local groups, byParent = {}, {}
    local list = PerkFactory.PerkList
    for i = 0, list:size() - 1 do
        local perk = list:get(i)
        local parent = perk:getParent()
        if parent ~= Perks.None then
            if not byParent[parent] then
                byParent[parent] = { perk = parent, skills = {} }
                groups[#groups + 1] = byParent[parent]
            end
            table.insert(byParent[parent].skills, perk)
        end
    end
    local sorted = type(string.sort) == "function" and function(a, b) return string.sort(b, a) end or function(a, b) return a < b end
    table.sort(groups, function(a, b)
        local pa, pb = a.perk:isPassiv(), b.perk:isPassiv()
        if pa ~= pb then return pa end
        return sorted(a.perk:getName(), b.perk:getName())
    end)
    local out = {}
    for _, g in ipairs(groups) do
        table.sort(g.skills, function(a, b) return a:getName() < b:getName() end)
        local skills = {}
        for _, perk in ipairs(g.skills) do
            local s = try(readSkill, player, perk)
            if s then skills[#skills + 1] = s end
        end
        out[#out + 1] = { name = g.perk:getName(), skills = skills }
    end
    return out
end

-- The Info tab (ISCharacterScreen.lua). Its name line is left out, as everywhere in the bridge. In 42.21 the tab works out
-- the sex text (63-66) but draws neither it nor an age, and its Survivors Killed line is commented out (230-236), so none
-- of those is sent.
local function readInfo(player, good, bad)
    local out = {}
    -- loadProfession (638-648): the profession's UI name
    out.profession = try(function()
        local def = CharacterProfessionDefinition.getCharacterProfessionDefinition(player:getDescriptor():getCharacterProfession())
        return def and def:getUIName() or nil
    end)
    -- 116-130: the body weight, round(getNutrition():getWeight(), 0), and the chevron for gaining, gaining a lot or losing
    local nutrition = try(function() return player:getNutrition() end)
    if nutrition then
        local w = num(try(function() return nutrition:getWeight() end))
        if w then out.weight = round(w, 0) end
        local lot = try(function() return nutrition:isIncWeightLot() end) == true
        local up = try(function() return nutrition:isIncWeight() end) == true
        local down = try(function() return nutrition:isDecWeight() end) == true
        if up and not lot then out.trend = "up" end
        if lot then out.trend = "upLot" end
        if down then out.trend = "down" end
    end
    -- setDisplayedTraits (575-584): every known trait whose CharacterTraitDefinition has a picture, in the list's order,
    -- shown as its label; coloured as character creation colours traits (CharacterCreationProfession.lua:973-985): a cost
    -- over 0 in the good highlight colour, under 0 in the bad one, otherwise white
    out.traits = try(function()
        local list = player:getCharacterTraits():getKnownTraits()
        local traits = {}
        for i = 0, list:size() - 1 do
            local def = CharacterTraitDefinition.getCharacterTraitDefinition(list:get(i))
            if def and def:getTexture() then
                local cost = num(def:getCost()) or 0
                traits[#traits + 1] = { label = def:getLabel(), cost = cost, color = cost > 0 and hexOf(good) or cost < 0 and hexOf(bad) or "#ffffff" }
            end
        end
        return traits
    end) or {}
    -- loadBeardAndHairStyle (618-636): the hair style's name, Bald for none; a man's beard, None for none
    local female = try(function() return player:isFemale() end) == true
    out.hair = try(function()
        local styles, model = getHairStylesInstance(), player:getHumanVisual():getHairModel()
        local style = female and styles:FindFemaleStyle(model) or styles:FindMaleStyle(model)
        if style and style:getName() ~= "" then return getText("IGUI_Hair_" .. style:getName()) end
        return getText("IGUI_Hair_Bald")
    end)
    if not female then
        out.beard = try(function()
            local style = getBeardStylesInstance():FindStyle(player:getHumanVisual():getBeardModel())
            if style and style:getName() ~= "" then return getText("IGUI_Beard_" .. style:getName()) end
            return getText("IGUI_Beard_None")
        end)
    end
    -- loadFavouriteWeapon (650-661): the "Fav:<weapon>" entry of the player's mod data with the most swings
    -- (server/XpSystem/XpUpdate.lua:65-68 counts them)
    out.favWeapon = try(function()
        local best, swing = nil, 0
        for k, v in pairs(player:getModData()) do
            local name = type(k) == "string" and string.match(k, "^Fav:(.+)")
            if name and type(v) == "number" and v > swing then best, swing = name, v end
        end
        return best
    end)
    -- 227-228: zombies killed
    out.kills = num(try(function() return player:getZombieKills() end))
    -- 237-241: "Survived For" and getTimeSurvived(), only while the clock shows the date
    if try(function() local clock = UIManager.getClock(); return clock and clock:isDateVisible() end) then
        out.survived = try(function() return player:getTimeSurvived() end)
    end
    out.labels = { weight = text("IGUI_char_Weight"), traits = text("IGUI_char_Traits"), hair = text("IGUI_char_HairStyle"),
        beard = text("IGUI_char_BeardStyle"), favWeapon = text("IGUI_char_Favourite_Weapon"), kills = text("IGUI_char_Zombies_Killed"),
        survived = text("IGUI_char_Survived_For") }
    return out
end

-- The Protection tab (ISCharacterProtection.lua). render (74-114): the 17 body parts in BodyPartType order, each with
-- its name (91), bite and scratch defence, floor(round(getBodyPartClothingDefense(i, bite, false))) (77-80), each in the
-- colour of its own value (95, 100), and the body figure coloured by bite + scratch (89). Both colours come from the
-- figure's scheme, bad highlight at 0 to good at 100 (19-22, 31), as ISBodyPartPanel:setColorForValue works it out
-- (ISUI/BodyParts/ISBodyPartPanel.lua:326-358: the value clamped to 0-100, Color.interp between the two).
function B.protectionColor(value, good, bad)
    return B.conditionColor(math.max(0, math.min(100, value)), good, bad)
end
local function readProtection(player, good, bad)
    local parts = {}
    for i = 0, BodyPartType.ToIndex(BodyPartType.MAX) - 1 do
        local t = BodyPartType.FromIndex(i)
        local id = BodyPartType.ToString(t)
        local bite = math.floor(round(player:getBodyPartClothingDefense(i, true, false), 0))
        local scratch = math.floor(round(player:getBodyPartClothingDefense(i, false, false), 0))
        parts[#parts + 1] = { id = id, name = BodyPartType.getDisplayName(t), bite = bite, scratch = scratch,
            color = B.protectionColor(bite + scratch, good, bad), biteColor = B.protectionColor(bite, good, bad),
            scratchColor = B.protectionColor(scratch, good, bad) }
    end
    return { parts = parts, labels = { part = text("IGUI_health_Part"), bite = text("IGUI_health_Bite"), scratch = text("IGUI_health_Scratch") } }
end

-- The Temperature tab (ISClothingInsPanel.lua), without its debug-only parts. prerender (614-669): the core temperature
-- and body heat bars from the thermoregulator's getCoreTemperatureUI() and getHeatGenerationUI() (621-622, each 0-1
-- along Cold-Normal-Hot and Low-Normal-High); the raw numbers beside their names are debug only (624-634) and are never
-- read. Every body part's thermal node (636-642) gives each view's value through its "UI" getter (472-477), 0-1 along
-- the view's bar: the default view's Skin Temperature, Body Response and Insulation (441-470) and the advanced view's
-- Wind Resistance (429-438). Insulation and Wind Resistance also show their number when a part is picked, in a normal game
-- too, rounded to 2 places (showValue, 426-427, 652-654; debug mode's 5 places are left out).
B.TEMP_VIEWS = {
    { "skin", "getSkinCelciusUI", "IGUI_Temp_SkinTemperature", "IGUI_Temp_Cold", "IGUI_Temp_Normal", "IGUI_Temp_Hot" },
    { "response", "getBodyResponseUI", "IGUI_Temp_BodyResponse", "IGUI_Temp_FightCold", "IGUI_Temp_Normal", "IGUI_Temp_FightHot" },
    { "insulation", "getInsulationUI", "IGUI_Temp_Insulation", "IGUI_Temp_Low", "IGUI_Temp_Med", "IGUI_Temp_High", "getInsulation" },
    { "wind", "getWindresistUI", "IGUI_Temp_WindResistance", "IGUI_Temp_Low", "IGUI_Temp_Med", "IGUI_Temp_High", "getWindresist" },
}
local function readTemperature(player)
    local thermos = player:getBodyDamage():getThermoregulator()
    if not thermos then return nil end
    local out = {
        core = num(try(function() return thermos:getCoreTemperatureUI() end)),
        heat = num(try(function() return thermos:getHeatGenerationUI() end)),
        labels = { core = text("IGUI_Temp_CoreTemp"), heat = text("IGUI_Temp_BodyHeat"), cold = text("IGUI_Temp_Cold"), normal = text("IGUI_Temp_Normal"),
            hot = text("IGUI_Temp_Hot"), low = text("IGUI_Temp_Low"), high = text("IGUI_Temp_High") },
        views = {}, parts = {},
    }
    for _, v in ipairs(B.TEMP_VIEWS) do
        out.views[#out.views + 1] = { id = v[1], title = text(v[3]), min = text(v[4]), mid = text(v[5]), max = text(v[6]) }
    end
    for i = 0, BodyPartType.ToIndex(BodyPartType.MAX) - 1 do
        local t = BodyPartType.FromIndex(i)
        local node = try(function() return thermos:getNodeForType(t) end)
        if node then
            local p = { id = BodyPartType.ToString(t), name = BodyPartType.getDisplayName(t) }
            for _, v in ipairs(B.TEMP_VIEWS) do
                p[v[1]] = num(try(function() return node[v[2]](node) end))
                if v[7] then
                    local raw = num(try(function() return node[v[7]](node) end))
                    if raw then p[v[1] .. "Value"] = round(raw, 2) end
                end
            end
            out.parts[#out.parts + 1] = p
        end
    end
    return out
end

local function readCharacter(player)
    local core = getCore()
    local bad = rgbOf(function() return core:getBadHighlitedColor() end, { 1, 0, 0 })
    local good = rgbOf(function() return core:getGoodHighlitedColor() end, { 0, 1, 0 })
    return {
        -- the good highlight colour: the skill squares of a skill that just levelled up start in it (ISSkillProgressBar.lua:8-11, 151-163)
        good = hexOf(good),
        skills = try(readSkills, player),
        info = try(readInfo, player, good, bad),
        protection = try(readProtection, player, good, bad),
        temperature = try(readTemperature, player),
    }
end
B.readCharacter = readCharacter

-- ---------------------------------------------------------------------------------------------------------------
-- The inventory window (1.4.0): what the game's own inventory window shows you about what you carry, rule for rule:
-- media/lua/client/ISUI/ISInventoryPage.lua (Build 42.21) for which containers get a button and the weight in its title
-- bar, and ISInventoryPane.lua for the rows of each container. Line numbers are from those two files. It goes to its
-- own file, Zomboid\Lua\StreamDeck\inventory.json, so state.json stays small.
-- Left out: the pane's other sort orders (the player picks them by clicking a column header or in its filter menu,
-- 185-272; the file keeps the order a new pane starts with), which rows are open or selected, the item tooltip, the
-- icons' textures, the read tick (2327-2329), the skull for bleach or tainted water in a fluid container (2330-2333),
-- the craft stars (2336-2340) and the hot and cold row tints (2438-2451). Nothing is read that the window does not show.
-- ---------------------------------------------------------------------------------------------------------------
B.INVENTORY_FILE = "StreamDeck/inventory.json"
B.INVENTORY_MS = 2000            -- read every 2 s (real time), written only when something changed
B.INVENTORY_REFRESH_MS = 10000   -- and rewritten unchanged after 10 s, so a reader that starts late gets a whole file
B.INVENTORY_CAP = 65536          -- bytes: a bigger inventory is cut down (B.capInventory) and the file says so
-- 12, 2578-2580: an open stack lists at most ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER (50) of its items
B.STACK_ROWS = 50
B.CUT_BARS = 5                   -- what B.capInventory leaves of a stack's bars before it drops rows

-- 2646-2701, drawItemDetails: the line an open stack shows for each of its items, as { kind, fraction } (the bar's
-- fill, which drawProgressBar clamps to 0-1, 2630-2631), or { kind } for burnt food, which gets no bar (2683), or nil
-- where the line is only the item's name.
function B.itemBar(item)
    local f = function(name) return num(try(function() return item[name](item) end)) or 0 end
    local yes = function(name) return try(function() return item[name](item) end) == true end
    local frac = function(v) return round(math.max(0, math.min(1, v)), 2) end
    -- 2657-2659: a weapon's condition over its maximum
    if instanceof(item, "HandWeapon") then
        local max = f("getConditionMax")
        return { "condition", max > 0 and frac(f("getCondition") / max) or 0 }
    end
    -- 2660-2662: what is left of a drainable, unless its script hides it
    if instanceof(item, "Drainable") and not try(function() return item:hasTag(ItemTag.HIDE_REMAINING) end) then
        return { "remaining", frac(f("getCurrentUsesFloat")) }
    end
    -- 2663-2665: melting, out of 100
    if f("getMeltingTime") > 0 then return { "melting", frac(f("getMeltingTime") / 100) } end
    if instanceof(item, "Food") then
        -- 2667-2685: cooking, once a cookable food that is not frozen is over 1.6 heat; burning past its minutes to cook
        -- (the bar in the bad colour), burnt past its minutes to burn; no bar for food that is burnt
        if yes("isIsCookable") and not yes("isFrozen") and f("getHeat") > 1.6 then
            local ct, mtc, mtb = f("getCookingTime"), f("getMinutesToCook"), f("getMinutesToBurn")
            local kind, v = "cooking", mtc > 0 and ct / mtc or 0
            if ct > mtb then kind = "burnt"
            elseif ct > mtc then kind = "burning"; v = mtb > mtc and (ct - mtc) / (mtb - mtc) or 1 end
            if yes("isBurnt") then return { kind } end
            return { kind, frac(v) }
        end
        -- 2686-2688: freezing, out of 100
        if f("getFreezingTime") > 0 then return { "freezing", frac(f("getFreezingTime") / 100) } end
        -- 2690-2693: how filling it is, minus its hunger change; none when it has none (2694-2695)
        local hunger = f("getHungerChange")
        if hunger ~= 0 then return { "nutrition", frac(-hunger) } end
    end
    return nil
end

-- 2052-2073: what the pane marks on the player's own inventory window (self.parent.onCharacter): everything worn and
-- what is in either hand is "equipped", and the hotbar's attached items are "in the hotbar" (getPlayerHotbar,
-- ISPlayerData.lua:105-109).
local function marksOf(player)
    local equipped, hotbar = {}, {}
    try(function()
        local worn = player:getWornItems()
        for i = 1, worn:size() do equipped[worn:get(i - 1):getItem()] = true end
    end)
    local primary, secondary = try(function() return player:getPrimaryHandItem() end), try(function() return player:getSecondaryHandItem() end)
    if primary then equipped[primary] = true end
    if secondary then equipped[secondary] = true end
    try(function()
        local bar = getPlayerHotbar(player:getPlayerNum())
        if bar and bar.attachedItems then for _, item in pairs(bar.attachedItems) do hotbar[item] = true end end
    end)
    return equipped, hotbar
end

-- 226-232, itemSortByNameInc, the order a new pane starts in (2878): equipped rows last, rows in the hotbar first, then by
-- the row's key with "not string.sort(a, b)" (a <= b in Kahlua, see the Skills tab above; asked here as the strict a < b
-- table.sort needs).
local function sortRows(rows)
    local before = type(string.sort) == "function" and function(a, b) return string.sort(b, a) end or function(a, b) return a < b end
    table.sort(rows, function(a, b)
        if a.eq ~= b.eq then return b.eq end
        if a.hb ~= b.hb then return a.hb end
        if a.k == b.k then return a.i < b.i end
        return before(a.k, b.k)
    end)
end

-- refreshContainer (2032-2201): one row per stack, as the pane groups a container's items.
function B.inventoryRows(player, container, equipped, hotbar)
    local rows, byKey = {}, {}
    local items = container:getItems()
    local mainInv = try(function() return player:getInventory() end)
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        -- 2096: hidden items (the models of what is equipped) are not listed
        if not try(function() return item:isHidden() end) then
            -- 2100: the name the pane groups by, item:getName(player). (2101-2121: the pane renames berries and mushrooms
            -- for the Herbalist recipe with item:setName; the bridge changes nothing, so it reads the name the pane gave.)
            local name = try(function() return item:getName(player) end) or try(function() return item:getDisplayName() end) or "?"
            local key, eq, hb = name, false, false
            -- 2124-2138: worn or held items stack apart as "equipped:", key rings in the main inventory as "keyring:",
            -- and other items in the hotbar as "hotbar:"
            local keyring = false
            if equipped[item] then key = "equipped:" .. key; eq = true
            elseif (try(function() return item:isItemType(ItemType.KEY_RING) end) or try(function() return item:hasTag(ItemTag.KEY_RING) end))
                and try(function() return mainInv:contains(item) end) then key = "keyring:" .. key; eq = true; keyring = true end
            if hotbar[item] then
                hb = true
                if not eq then key = "hotbar:" .. key end
            end
            local row = byKey[key]
            if not row then
                row = { k = key, i = #rows, eq = eq, hb = hb, keyring = keyring, first = item, items = {}, weight = 0 }
                byKey[key] = row
                rows[#rows + 1] = row
            end
            row.items[#row.items + 1] = item
            -- 2164: the stack's weight, each item's getUnequippedWeight()
            row.weight = row.weight + (num(try(function() return item:getUnequippedWeight() end)) or 0)
        end
    end
    sortRows(rows)
    local out = {}
    for _, row in ipairs(rows) do
        local item = row.first
        -- 2170, 2546-2550: the category the row shows and sorts by, the item's display category or else its category,
        -- shown as getText("IGUI_ItemCat_" .. it)
        local catKey = try(function() return item:getDisplayCategory() end) or try(function() return item:getCategory() end) or "Item"
        local r = {
            -- 2493: the row's name, item:getName(player); 2509-2513: " (n)" after it when the stack holds more than one
            name = try(function() return item:getName(player) end) or "?",
            count = #row.items > 1 and #row.items or nil,
            cat = text("IGUI_ItemCat_" .. catKey), catKey = catKey,
            weight = round(row.weight, 2),
            equipped = (row.eq and not row.keyring) or nil, keyring = row.keyring or nil, hotbar = row.hb or nil,
            -- the marks on the row's icon (2318-2335) and its text colour (2496)
            broken = try(function() return item:isBroken() end) or nil,
            frozen = (instanceof(item, "Food") and try(function() return item:isFrozen() end)) or nil,
            -- 2324: tainted food while the sandbox shows tainted water, or a poison the player knows of
            poison = ((instanceof(item, "Food") and try(function() return item:isTainted() end)
                and try(function() return getSandboxOptions():getOptionByName("EnableTaintedWaterText"):getValue() end))
                or try(function() return player:isKnownPoison(item) end)) or nil,
            favorite = try(function() return item:isFavorite() end) or nil,
            unwanted = try(function() return item:isUnwanted(player) end) or nil,
        }
        -- 2553: the line each item of the open stack shows, the first B.STACK_ROWS of them
        local bars, any = {}, false
        for n = 1, math.min(#row.items, B.STACK_ROWS) do
            local b = try(B.itemBar, row.items[n])
            if b then any = true end
            bars[n] = b or false
        end
        if any then r.bars = bars end
        out[#out + 1] = r
    end
    return out
end

-- ISInventoryPage.refreshBackpacks (1537-1580) on the player's own window: the main inventory, then every container
-- the player wears or holds, and every key ring, in the order they sit in the main inventory; each with its weight as
-- the title bar shows it (630-632: round(getCapacityWeight(), 2), 1163-1167) out of its capacity (637: the player's
-- getMaxWeight() for the main inventory; 1494: getEffectiveCapacity(player) for the others).
function B.readInventory(player)
    local inv = player:getInventory()
    local equipped, hotbar = marksOf(player)
    local list = { { name = text("IGUI_InventoryTooltip"), weight = round(num(try(function() return inv:getCapacityWeight() end)) or 0, 2),
        capacity = num(try(function() return player:getMaxWeight() end)), container = inv } }
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        -- 1572, as the game writes it: a "Container" item the player has equipped (IsoGameCharacter.isEquipped: worn or in
        -- a hand, javap 42.21), or any key ring
        local isBag = try(function()
            return item:getCategory() == "Container" and player:isEquipped(item) or item:isItemType(ItemType.KEY_RING) or item:hasTag(ItemTag.KEY_RING)
        end)
        local bag = isBag and try(function() return item:getInventory() end)
        if bag then
            list[#list + 1] = { name = try(function() return item:getName() end) or "?", weight = round(num(try(function() return bag:getCapacityWeight() end)) or 0, 2),
                capacity = num(try(function() return bag:getEffectiveCapacity(player) end)), container = bag }
        end
    end
    local containers = {}
    for _, c in ipairs(list) do
        local rows = try(B.inventoryRows, player, c.container, equipped, hotbar)
        if rows then containers[#containers + 1] = { name = c.name, weight = c.weight, capacity = c.capacity, rows = #rows, items = rows } end
    end
    local core = getCore()
    return {
        containers = containers,
        -- 2653-2654: the bars in the good highlight colour; 2678-2680: burning in the bad one
        good = hexOf(rgbOf(function() return core:getGoodHighlitedColor() end, { 0, 1, 0 })),
        bad = hexOf(rgbOf(function() return core:getBadHighlitedColor() end, { 1, 0, 0 })),
        labels = { item = text("IGUI_invpanel_Type"), category = text("IGUI_invpanel_Category"), condition = text("IGUI_invpanel_Condition"),
            remaining = text("IGUI_invpanel_Remaining"), melting = text("IGUI_invpanel_Melting"), cooking = text("IGUI_invpanel_Cooking"),
            burning = text("IGUI_invpanel_Burning"), burnt = text("IGUI_invpanel_Burnt"), freezing = text("IGUI_invpanel_FreezingTime"),
            nutrition = text("IGUI_invpanel_Nutrition") },
    }
end

-- The size cap. An inventory that encodes to more than B.INVENTORY_CAP bytes is cut down in two steps, and the file
-- says what was done in "trimmed": first every stack keeps only its first B.CUT_BARS bars (trimmed.bars), then, if it
-- is still too big, the lightest rows that are not equipped, key rings or in the hotbar go, lightest first, and each
-- container lists what went by category in "rest" ({ cat, catKey, rows, count, weight }, heaviest first) (trimmed.rows).
function B.capInventory(inv, cap)
    cap = cap or B.INVENTORY_CAP
    local size = string.len(encode(inv))
    if size <= cap then return inv end
    inv.trimmed = { cap = cap }
    for _, c in ipairs(inv.containers) do
        for _, r in ipairs(c.items) do
            if r.bars and #r.bars > B.CUT_BARS then
                local keep = {}
                for n = 1, B.CUT_BARS do keep[n] = r.bars[n] end
                r.bars = keep
                inv.trimmed.bars = B.CUT_BARS
            end
        end
    end
    size = string.len(encode(inv))
    if size <= cap then return inv end
    local pool = {}
    for ci, c in ipairs(inv.containers) do
        for ri, r in ipairs(c.items) do
            if not (r.equipped or r.keyring or r.hotbar) then pool[#pool + 1] = { ci = ci, ri = ri, r = r, len = string.len(encode(r)) + 1 } end
        end
    end
    table.sort(pool, function(a, b)
        if a.r.weight ~= b.r.weight then return a.r.weight < b.r.weight end
        if a.ci ~= b.ci then return a.ci > b.ci end
        return a.ri > b.ri
    end)
    local drop, dropped = {}, 0
    -- each category's summary costs about as much as a short row, so a margin is kept for them
    local margin = math.min(120 * 40, math.floor(cap / 8))
    for _, p in ipairs(pool) do
        if size + margin <= cap then break end
        drop[p.r] = p.ci
        size = size - p.len
        dropped = dropped + 1
    end
    for ci, c in ipairs(inv.containers) do
        local keep, rest, byCat = {}, {}, {}
        for _, r in ipairs(c.items) do
            if drop[r] == ci then
                local g = byCat[r.catKey]
                if not g then g = { cat = r.cat, catKey = r.catKey, rows = 0, count = 0, weight = 0 }; byCat[r.catKey] = g; rest[#rest + 1] = g end
                g.rows = g.rows + 1
                g.count = g.count + (r.count or 1)
                g.weight = round(g.weight + r.weight, 2)
            else
                keep[#keep + 1] = r
            end
        end
        if #rest > 0 then
            table.sort(rest, function(a, b) if a.weight ~= b.weight then return a.weight > b.weight end return a.catKey < b.catKey end)
            c.rest = rest
        end
        c.items = keep
    end
    inv.trimmed.rows = dropped
    -- the last resort: no bars at all
    if string.len(encode(inv)) > cap then
        for _, c in ipairs(inv.containers) do for _, r in ipairs(c.items) do r.bars = nil end end
        inv.trimmed.bars = 0
    end
    return inv
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
    -- Kept as it was for older plugins; the body section below has the whole Health tab.
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
    s.mechanics = try(readMechanics, player)
    s.weather = try(readWeather, player)
    s.place = try(readPlace, player)
    s.shutoff = try(readShutoff)
    s.body = try(readBody, player)
    s.character = try(readCharacter, player)
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

-- The inventory file, written the same way (one whole file, "end": true last in the reader's eyes), only when what it
-- holds changed or B.INVENTORY_REFRESH_MS have passed. It has its own seq; "at" is the same clock as state.json's.
B.invSeq = 0
B.lastInventory = nil
B.lastInventoryAt = 0
function B.writeInventory(inv, now)
    inv.protocol = B.PROTOCOL
    inv.mod = B.VERSION
    local core = encode(inv)
    if core == B.lastInventory and now - B.lastInventoryAt < B.INVENTORY_REFRESH_MS then return false end
    B.invSeq = B.invSeq + 1
    inv.at = now
    inv.seq = B.invSeq
    inv["end"] = true
    local w = getFileWriter(B.INVENTORY_FILE, true, false)
    if not w then
        if not B.inventoryFailed then log("cannot write Zomboid/Lua/" .. B.INVENTORY_FILE); B.inventoryFailed = true end
        return false
    end
    w:write(encode(inv))
    w:close()
    B.lastInventory = core
    B.lastInventoryAt = now
    return true
end

-- Read, cut to size and written, for a live survivor (not at the menu, loading or dead: the reader goes by state.json).
function B.inventoryTick(now)
    local player = getSpecificPlayer(0)
    if not player or try(function() return player:isDead() end) then return false end
    local inv = try(B.readInventory, player)
    if not inv then return false end
    inv = try(B.capInventory, inv) or inv
    return try(B.writeInventory, inv, now) or false
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
B.nextWrite, B.nextCommand, B.nextMenu, B.nextInventory = 0, 0, 0, 0

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
    if now >= B.nextInventory then
        B.nextInventory = now + B.INVENTORY_MS
        try(B.inventoryTick, now)
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
