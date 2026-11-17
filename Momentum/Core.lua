-- Momentum: resource bar, swing timer and icon row (buffs, procs, cooldowns) for WoW Forever.
--
-- Core.lua: namespace, helpers, saved settings, event and frame-update dispatch.
--
-- Forever runs on the Midnight engine, where many combat values are "secret" for addons.
-- Rules followed in every file:
--   * a value that may be secret is checked with issecretvalue before it is compared or computed with
--   * secret values only go to widget methods that accept them (StatusBar:SetValue,
--     FontString:SetFormattedText, Region:SetAlpha, Cooldown:SetCooldownFromDurationObject)
--   * the facts used are taken from Blizzard's API documentation of the Forever client (1.60.1)
--     and from in-game measurements published by other Forever addons; they are named where used

local ADDON_NAME = ...

---@class Momentum
---@field settings MomentumClassSettings settings of the player's class (set on ADDON_LOADED)
---@field playerClass string class file name of the player, e.g. "ROGUE"
---@field unlocked boolean the elements can be dragged with the mouse
---@field errors table<string, string> last error message per step (shown by /mom debug)
---@field defaults MomentumClassSettings default settings of a class
---@field driver Frame receives all events and runs the per-frame steps
---@field Util MomentumUtil
---@field SettingsUpgrade MomentumSettingsUpgrade
---@field Gates MomentumGates
---@field Look MomentumLook
---@field Resource MomentumResource
---@field Swing MomentumSwing
---@field Spells MomentumSpells
---@field Buffs MomentumBuffs
---@field Row MomentumRow
---@field Options MomentumOptions
---@field ApplyAll fun() see Commands.lua
---@field SetUnlocked fun(unlocked: boolean)
---@field ResolveSpellName fun(input: string|nil): string|nil
---@field ListAdd fun(list: string[], input: string)
---@field ListRemove fun(list: string[], spellName: string|nil)
---@field RestoreClassicLook fun()
---@field ResetClass fun()
---@field DebugLines fun(): string[]
---@field Debug fun()
---@field SetBlizzardSwingTimer fun(shown: boolean)
local Momentum = select(2, ...)

Momentum.VERSION = "1.0"
-- Format of the saved settings. 2 = descriptive key names (1.0); older settings are converted on load.
Momentum.SETTINGS_VERSION = 2
Momentum.errors = {}
Momentum.unlocked = false

local pcall, type, pairs, ipairs, tostring, select = pcall, type, pairs, ipairs, tostring, select

---------------------------------------------------------------------------
-- Settings (one table per class, in the SavedVariable MomentumDB)
---------------------------------------------------------------------------

---@alias MomentumColor number[] red, green, blue, alpha (each 0..1)

---@class MomentumGradientSettings
---@field enabled boolean
---@field endColor MomentumColor colour at the end of the gradient
---@field direction "HORIZONTAL"|"VERTICAL"

---@class MomentumSparkSettings
---@field enabled boolean
---@field width number in pixels

---@class MomentumBorderSettings
---@field enabled boolean
---@field color MomentumColor
---@field thickness number in pixels
---@field gap number space between the element and the border

---@class MomentumGlowSettings
---@field enabled boolean
---@field color MomentumColor alpha = strength
---@field width number number of 1 px rings
---@field pulsing boolean

---@class MomentumFillEndSettings
---@field enabled boolean
---@field width number
---@field strength number alpha of the bright end

---@class MomentumBevelSettings
---@field enabled boolean
---@field strength number alpha of the light lines

---@class MomentumBarSettings
---@field enabled boolean
---@field fillColor MomentumColor
---@field backgroundColor MomentumColor (its alpha is used even when the colour comes from the fill)
---@field width number
---@field height number
---@field positionX number offset from the screen centre
---@field positionY number offset from the screen centre
---@field showText boolean show the number on the bar
---@field fontSize number
---@field fontFile string
---@field fontOutline "NONE"|"OUTLINE"|"THICKOUTLINE"
---@field textColor MomentumColor
---@field textPosition "LEFT"|"CENTER"|"RIGHT"
---@field texture string status bar texture
---@field gradient MomentumGradientSettings
---@field spark MomentumSparkSettings
---@field border MomentumBorderSettings
---@field glow MomentumGlowSettings
---@field backgroundFromFill boolean background = fill colour, darker
---@field backgroundBrightness number brightness of that background (0..1 of the fill colour)
---@field fillEnd MomentumFillEndSettings soft bright end of the fill
---@field bevelLines MomentumBevelSettings 1 px light lines on top and bottom of the fill

---@class MomentumResourceBarSettings : MomentumBarSettings
---@field colorByPowerType boolean
---@field onlyInCombat boolean
---@field thresholds table<string, MomentumThresholdSettings> per power token (ENERGY, RAGE, ...)

---@class MomentumSwingBarSettings : MomentumBarSettings
---@field empties boolean the bar empties instead of filling
---@field idleLook "FULL"|"EMPTY"|"HIDE" look while no swing is running
---@field hand "MAIN"|"OFF"|"RANGED"
---@field hasteCorrection boolean Slice and Dice rescales the swing in flight
---@field learnedHasteFactors table<number, number> spell ID -> measured attack speed factor

---@alias MomentumBuffFilter "ALL_EXCEPT_BLACKLIST"|"WHITELIST_ONLY"
---@alias MomentumTimeFormat "WHOLE_SECONDS"|"TENTHS_BELOW_10"|"HIDDEN"

---@class MomentumIconRowSettings
---@field enabled boolean
---@field buffFilter MomentumBuffFilter
---@field iconSize number
---@field spacing number
---@field positionX number
---@field positionY number
---@field maxIcons number
---@field growDirection "LEFT"|"RIGHT"|"CENTER"
---@field expirySwipe boolean
---@field whitelist string[] buff names
---@field blacklist string[] buff names
---@field procs string[] spells shown while usable
---@field cooldowns string[] spells shown while on cooldown
---@field pulseUsableProcs boolean
---@field border MomentumBorderSettings
---@field glow MomentumGlowSettings
---@field cropEdges boolean zoom into the icon to hide its frame
---@field stackFontSize number
---@field timeFormat MomentumTimeFormat
---@field timeFontSize number

---@class MomentumLearnedBuff
---@field icon number|string|nil
---@field duration number|nil seconds (ordinary buffs)
---@field talentFactor number|nil (finishers)

---@class MomentumClassSettings
---@field settingsVersion number format of these settings (see Momentum.SETTINGS_VERSION)
---@field resourceBar MomentumResourceBarSettings
---@field swingBar MomentumSwingBarSettings
---@field iconRow MomentumIconRowSettings
---@field learnedBuffs table<string, MomentumLearnedBuff> by buff name
---@field classPresetsAdded boolean|nil the class presets for procs and cooldowns were added

local WHITE_TEXTURE = "Interface\\Buttons\\WHITE8X8"
Momentum.WHITE_TEXTURE = WHITE_TEXTURE

-- The default look is the "classic look": rebuilt from an older addon.
---@type MomentumClassSettings
Momentum.defaults = {
  settingsVersion = Momentum.SETTINGS_VERSION,
  resourceBar = {
    enabled = true, colorByPowerType = false, onlyInCombat = false,
    fillColor = { 0.561, 0.537, 0.396, 1 }, backgroundColor = { 0, 0, 0, 0.95 },
    width = 198, height = 21, positionX = 0, positionY = -120,
    showText = true, fontSize = 19, fontFile = "Fonts\\ARIALN.TTF", fontOutline = "OUTLINE",
    textColor = { 1, 1, 1, 1 }, textPosition = "CENTER",
    texture = WHITE_TEXTURE,
    gradient = { enabled = true, endColor = { 0.345, 0.314, 0.220, 1 }, direction = "HORIZONTAL" },
    spark = { enabled = false, width = 12 },
    border = { enabled = true, color = { 0, 0, 0, 1 }, thickness = 2, gap = 0 },
    glow = { enabled = false, color = { 1, 0.85, 0.2, 0.8 }, width = 4, pulsing = false },
    backgroundFromFill = true, backgroundBrightness = 0.25,
    fillEnd = { enabled = true, width = 5, strength = 0.28 },
    bevelLines = { enabled = true, strength = 0.1 },
    thresholds = {},
  },
  swingBar = {
    enabled = true, empties = false, idleLook = "FULL", hand = "MAIN",
    hasteCorrection = true, learnedHasteFactors = {},
    fillColor = { 0.514, 0.380, 0.212, 1 }, backgroundColor = { 0, 0, 0, 0.95 },
    width = 286, height = 20, positionX = 0, positionY = -146,
    showText = false, fontSize = 11, fontFile = "Fonts\\FRIZQT__.TTF", fontOutline = "OUTLINE",
    textColor = { 1, 1, 1, 1 }, textPosition = "RIGHT",
    texture = WHITE_TEXTURE,
    gradient = { enabled = true, endColor = { 0.282, 0.204, 0.125, 1 }, direction = "HORIZONTAL" },
    spark = { enabled = false, width = 12 },
    border = { enabled = false, color = { 0, 0, 0, 1 }, thickness = 1, gap = 0 },
    glow = { enabled = false, color = { 1, 0.85, 0.2, 0.8 }, width = 4, pulsing = false },
    backgroundFromFill = true, backgroundBrightness = 0.25,
    fillEnd = { enabled = true, width = 5, strength = 0.28 },
    bevelLines = { enabled = true, strength = 0.1 },
  },
  iconRow = {
    enabled = true, buffFilter = "ALL_EXCEPT_BLACKLIST", growDirection = "CENTER", expirySwipe = true,
    iconSize = 32, spacing = 4, positionX = 0, positionY = -190, maxIcons = 8,
    whitelist = {}, blacklist = {}, procs = {}, cooldowns = {}, pulseUsableProcs = true,
    border = { enabled = true, color = { 0, 0, 0, 1 }, thickness = 1, gap = 0 },
    glow = { enabled = false, color = { 1, 0.85, 0.2, 0.8 }, width = 3, pulsing = false },
    cropEdges = true, stackFontSize = 14, timeFormat = "WHOLE_SECONDS", timeFontSize = 14,
  },
  learnedBuffs = {},
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

---@class MomentumUtil
local Util = {}
Momentum.Util = Util

---Is the value secret for addon code? Always check this before comparing or computing with a value
---that comes from a combat API.
---@param value any
---@return boolean
function Util.isSecret(value)
  return issecretvalue ~= nil and issecretvalue(value) or false
end
local isSecret = Util.isSecret

---Deep copy of a value (tables are copied recursively, other values returned as they are).
---@generic T
---@param value T
---@return T
function Util.deepCopy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, entry in pairs(value) do copy[key] = Util.deepCopy(entry) end
  return copy
end

---Fills keys that are missing in target with copies from source (recursively). Existing values stay.
---@param target table
---@param source table
function Util.fillMissing(target, source)
  for key, value in pairs(source) do
    if target[key] == nil then
      target[key] = Util.deepCopy(value)
    elseif type(value) == "table" and type(target[key]) == "table" then
      Util.fillMissing(target[key], value)
    end
  end
end

---Overwrites target with copies of source. Nested settings tables are assigned key by key,
---arrays (colours, lists) are replaced as a whole.
---@param target table
---@param source table
function Util.overwrite(target, source)
  for key, value in pairs(source) do
    if type(value) == "table" and type(target[key]) == "table" and value[1] == nil then
      Util.overwrite(target[key], value)
    else
      target[key] = Util.deepCopy(value)
    end
  end
end

---Turns a list into a lookup table: { "A", "B" } -> { A = true, B = true }.
---@param list any[]|nil
---@return table<any, boolean>
function Util.listToSet(list)
  local set = {}
  for _, entry in ipairs(list or {}) do set[entry] = true end
  return set
end

---The value if a pcall succeeded and returned a readable (not secret) number, else nil.
---@param success boolean first result of pcall
---@param value any second result of pcall
---@return number|nil
function Util.readableNumber(success, value)
  if success and not isSecret(value) and type(value) == "number" then return value end
  return nil
end

---Localized name of a spell, or nil if unknown or secret.
---@param spellID number
---@return string|nil
function Util.spellName(spellID)
  if C_Spell and C_Spell.GetSpellName then
    local success, name = pcall(C_Spell.GetSpellName, spellID)
    if success and not isSecret(name) and type(name) == "string" then return name end
  end
  return nil
end

---Prints a message in the chat with the addon prefix.
---@param message string
---@param isError? boolean red prefix
function Momentum.Print(message, isError)
  print((isError and "|cffff5555Momentum:|r " or "|cff55ff55Momentum:|r ") .. message)
end

local errorsShown = {}

---Runs a function in protected mode. An error is stored under its step name and printed once per
---step, so a bug in one step can not stop the others.
---@param step string name of the step
---@param action function
---@param ... any arguments for the action
---@return boolean success
function Momentum.Safe(step, action, ...)
  local success, message = pcall(action, ...)
  if not success then
    Momentum.errors[step] = tostring(message)
    if not errorsShown[step] then
      errorsShown[step] = true
      Momentum.Print("error (" .. step .. "): " .. tostring(message), true)
    end
  end
  return success
end

---------------------------------------------------------------------------
-- Event and update dispatch
---------------------------------------------------------------------------
local driver = CreateFrame("Frame")
Momentum.driver = driver

---@type table<string, function[]>
local eventHandlers = {}
---@type { step: string, update: fun(now: number) }[]
local frameSteps = {}
---@type function[]
local loadedCallbacks = {}

---Registers a handler for a game event. Handlers of the same event run in registration order;
---before the settings are loaded only ADDON_LOADED is delivered.
---@param event string
---@param handler fun(...: any) receives the event payload
---@param ... string units for a unit event (RegisterUnitEvent), given with the first handler only
function Momentum.OnEvent(event, handler, ...)
  local handlers = eventHandlers[event]
  if not handlers then
    handlers = {}
    eventHandlers[event] = handlers
    if select("#", ...) > 0 then
      pcall(driver.RegisterUnitEvent, driver, event, ...)
    else
      pcall(driver.RegisterEvent, driver, event)
    end
  end
  handlers[#handlers + 1] = handler
end

---Registers a step that runs on every frame (after the settings are loaded).
---@param step string name for error messages
---@param update fun(now: number)
function Momentum.OnEveryFrame(step, update)
  frameSteps[#frameSteps + 1] = { step = step, update = update }
end

---Registers a function that runs once the settings of the class are loaded.
---@param callback fun()
function Momentum.OnLoaded(callback)
  loadedCallbacks[#loadedCallbacks + 1] = callback
end

---OnEvent script of the driver frame: hands the event to its handlers.
---@param _ Frame
---@param event string
---@param ... any payload
local function dispatchEvent(_, event, ...)
  if not Momentum.settings and event ~= "ADDON_LOADED" then return end
  local handlers = eventHandlers[event]
  if not handlers then return end
  for index = 1, #handlers do Momentum.Safe(event, handlers[index], ...) end
end

---OnUpdate script of the driver frame: runs the per-frame steps.
local function runFrameSteps()
  if not Momentum.settings then return end
  local now = GetTime()
  for index = 1, #frameSteps do Momentum.Safe(frameSteps[index].step, frameSteps[index].update, now) end
end

driver:SetScript("OnEvent", dispatchEvent)
driver:SetScript("OnUpdate", runFrameSteps)

---Loads (or creates) the settings of the player's class, converts settings of older versions and
---starts the modules.
---@param loadedAddon string name of the addon that was loaded
local function onAddonLoaded(loadedAddon)
  if loadedAddon ~= ADDON_NAME or Momentum.settings then return end
  MomentumDB = MomentumDB or {}
  MomentumDB.classes = MomentumDB.classes or {}
  local _, playerClass = UnitClass("player")
  MomentumDB.classes[playerClass] = MomentumDB.classes[playerClass] or {}
  local settings = MomentumDB.classes[playerClass]
  Momentum.SettingsUpgrade.Upgrade(settings)
  Util.fillMissing(settings, Momentum.defaults)
  Momentum.settings = settings
  Momentum.playerClass = playerClass
  for index = 1, #loadedCallbacks do Momentum.Safe("loaded", loadedCallbacks[index]) end
  Momentum.ApplyAll()
end

Momentum.OnEvent("ADDON_LOADED", onAddonLoaded)
