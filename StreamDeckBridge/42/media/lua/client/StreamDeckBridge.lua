-- Stream Deck Bridge for Project Zomboid (Build 42), the companion mod of the Zomboid Deck plugin for Stream Deck.
--
-- Once a second it writes what your survivor can see about themselves to Zomboid\Lua\StreamDeck\state.json: health,
-- what the game's Health tab lists for each body part, the moodles the game is showing, the time and weather, what is
-- in your hands, your load and the car you are in, with what the game's Vehicle Mechanics window lists for that car:
-- its overall condition and every part with its condition, in the window's colours. It also reads
-- Zomboid\Lua\StreamDeck\command.json, where the plugin leaves a key press, runs it with the game's own action and
-- empties the file.
--
-- Client-side only (media/lua/client), for the local player. It never changes a stat or spawns anything. The health
-- section repeats the game's own Health tab and nothing more, so a zombie infection the tab does not show is never
-- written; the mechanics section repeats the Mechanics window and nothing more, without its debug-mode lines. In single
-- player it also writes how long the grid's power and the mains water have left, worked out with the game's own rule;
-- on a server (isClient()) it leaves that out and writes only whether they are on.

StreamDeckBridge = StreamDeckBridge or {}
local B = StreamDeckBridge

B.VERSION = "1.2.0"
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
