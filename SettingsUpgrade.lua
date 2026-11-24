-- SettingsUpgrade.lua: converts saved settings of older versions to the current key names.
--
-- Up to the first 1.0 build the settings used short keys ("res", "w", "pct", "cds", ...). They were
-- renamed to descriptive ones. On load every class table that is not marked with the current
-- settingsVersion is converted once: keys are renamed, a few values get clearer names, settings that
-- no longer exist are dropped. Values themselves are kept as they are.

---@type Momentum
local Momentum = select(2, ...)

local pairs, type = pairs, type

---@class MomentumSettingsUpgrade
local SettingsUpgrade = {}
Momentum.SettingsUpgrade = SettingsUpgrade

---A rule for one old key: the new key name, or a table with the new name and rules for what lies
---below the key, or false to drop the key.
---@alias MomentumRenameRule string|false|MomentumNestedRenameRule

---@class MomentumNestedRenameRule
---@field name string new key
---@field keys table<string, MomentumRenameRule>|nil rules for the keys of the table under this key
---@field eachEntry table<string, MomentumRenameRule>|nil rules for every entry of a table of tables
---@field values table<any, any>|nil old value -> new value

local BORDER = { name = "border", keys = { size = "thickness" } }
local GLOW = { name = "glow", keys = { size = "width", pulse = "pulsing" } }

---Rules shared by the resource bar and the swing bar.
---@param extra table<string, MomentumRenameRule> rules of the one bar
---@return table<string, MomentumRenameRule>
local function barRules(extra)
  ---@type table<string, MomentumRenameRule>
  local rules = {
    color = "fillColor", bg = "backgroundColor", w = "width", h = "height", x = "positionX", y = "positionY",
    text = "showText", font = "fontFile", outline = "fontOutline", textPos = "textPosition", tex = "texture",
    bgFromFill = "backgroundFromFill", bgFactor = "backgroundBrightness",
    gradient = { name = "gradient", keys = { color2 = "endColor", dir = "direction" } },
    spark = { name = "spark", keys = { w = "width" } },
    border = BORDER,
    glow = GLOW,
    edge = { name = "fillEnd", keys = { alpha = "strength" } },
    bevel = { name = "bevelLines", keys = { alpha = "strength" } },
  }
  for oldKey, rule in pairs(extra) do rules[oldKey] = rule end
  return rules
end

local THRESHOLD_RULES = {
  pct = "valuesInPercent",
  color = { name = "colorChange", keys = {
    value = "threshold", rgb = "color", rgb2 = "endColor", fade = "fadeRange",
    upto = { name = "upTo", keys = { value = "limit" } },
  } },
  pulse = { name = "pulse", keys = { value = "threshold", size = "width", speed = "fadeSeconds" } },
}

---@type table<string, MomentumRenameRule>
local CLASS_RULES = {
  res = { name = "resourceBar", keys = barRules({
    auto = "colorByPowerType", combatOnly = "onlyInCombat",
    thresholds = { name = "thresholds", eachEntry = THRESHOLD_RULES },
  }) },
  swing = { name = "swingBar", keys = barRules({
    drain = "empties", idle = "idleLook", haste = "hasteCorrection", hasteLearned = "learnedHasteFactors",
    -- settings of versions before 0.9 that no longer exist
    resync = false, useHits = false, hideIdle = false, rescale = false,
  }) },
  buffs = { name = "iconRow", keys = {
    size = "iconSize", x = "positionX", y = "positionY", max = "maxIcons", grow = "growDirection",
    swipe = "expirySwipe", list = "whitelist", black = "blacklist", cds = "cooldowns",
    procPulse = "pulseUsableProcs", zoom = "cropEdges", countSize = "stackFontSize", timeSize = "timeFontSize",
    mode = { name = "buffFilter", values = { all = "ALL_EXCEPT_BLACKLIST", list = "WHITELIST_ONLY" } },
    timeText = { name = "timeFormat", values = { BLIZZ = "WHOLE_SECONDS", TENTHS = "TENTHS_BELOW_10", NONE = "HIDDEN" } },
    border = BORDER,
    glow = GLOW,
    showUnknown = false,
  } },
  learned = { name = "learnedBuffs", eachEntry = { factor = "talentFactor", cp = false } },
  spellsSeeded = "classPresetsAdded",
  lookVersion = false,
}

---Renames the keys of a table by its rules (recursively). Keys without a rule stay as they are.
---@param settingsTable table
---@param rules table<string, MomentumRenameRule>
---@return integer changed number of keys renamed or dropped
local function renameKeys(settingsTable, rules)
  local changed = 0
  for oldKey, rule in pairs(rules) do
    local value = settingsTable[oldKey]
    if value ~= nil then
      settingsTable[oldKey] = nil
      if rule == false then
        changed = changed + 1
      else
        local newKey = rule
        if type(rule) == "table" then
          newKey = rule.name
          if rule.keys and type(value) == "table" then changed = changed + renameKeys(value, rule.keys) end
          if rule.eachEntry and type(value) == "table" then
            for _, entry in pairs(value) do
              if type(entry) == "table" then changed = changed + renameKeys(entry, rule.eachEntry) end
            end
          end
          if rule.values and rule.values[value] ~= nil then value = rule.values[value] end
        end
        ---@cast newKey string
        if newKey ~= oldKey then changed = changed + 1 end
        if settingsTable[newKey] == nil then settingsTable[newKey] = value end
      end
    end
  end
  return changed
end

---Converts the settings of one class to the current format (once; marked with settingsVersion).
---@param classSettings table settings of one class as loaded from MomentumDB
---@return integer changed number of keys renamed or dropped (0 if already current)
function SettingsUpgrade.Upgrade(classSettings)
  if classSettings.settingsVersion == Momentum.SETTINGS_VERSION then return 0 end
  local changed = renameKeys(classSettings, CLASS_RULES)
  classSettings.settingsVersion = Momentum.SETTINGS_VERSION
  return changed
end
