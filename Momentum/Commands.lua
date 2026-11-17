-- Commands.lua: applying settings, list editing, reset, debug output and the slash commands.

---@type Momentum
local Momentum = select(2, ...)
local Util = Momentum.Util
local isSecret = Util.isSecret

local abs = math.abs
local ipairs, pairs, pcall, select, tonumber, tostring, type = ipairs, pairs, pcall, select, tonumber, tostring, type

_G.Momentum = Momentum -- for /dump and other addons

---Applies all settings to the HUD (look, sizes, positions, unlock state).
function Momentum.ApplyAll()
  if not Momentum.settings then return end
  Momentum.Resource.Apply()
  Momentum.Swing.Apply()
  Momentum.Row.Layout()
  Momentum.Look.SetUnlocked(Momentum.unlocked)
end

---Unlocks (drag with the mouse) or locks the HUD elements.
---@param unlocked boolean
function Momentum.SetUnlocked(unlocked)
  Momentum.Look.SetUnlocked(unlocked)
end

---Spell name from user input: a name, a spell ID or a spell link.
---@param input string|nil
---@return string|nil
function Momentum.ResolveSpellName(input)
  input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" then return nil end
  local spellID = tonumber(input) or tonumber(input:match("spell:(%d+)"))
  if spellID then return Util.spellName(spellID) end
  return input:match("%[(.-)%]") or input
end

---Adds a spell to one of the lists (no duplicates).
---@param list string[] one of the lists in the icon row settings
---@param input string name, spell ID or spell link
function Momentum.ListAdd(list, input)
  local spellName = Momentum.ResolveSpellName(input)
  if not spellName then
    Momentum.Print("spell not found: " .. tostring(input), true)
    return
  end
  for _, entry in ipairs(list) do if entry == spellName then return end end
  list[#list + 1] = spellName
  Momentum.Spells.LatchCooldowns()
  Momentum.Row.Invalidate()
  Momentum.Options.Refresh()
end

---Removes a spell from one of the lists.
---@param list string[]
---@param spellName string|nil
function Momentum.ListRemove(list, spellName)
  for position, entry in ipairs(list) do
    if entry == spellName then
      table.remove(list, position)
      break
    end
  end
  Momentum.Row.Invalidate()
  Momentum.Options.Refresh()
end

-- Settings that make up the look of the bars (restored by "classic look").
local LOOK_SETTINGS = {
  resourceBar = { "width", "height", "texture", "colorByPowerType", "fillColor", "backgroundColor",
    "backgroundFromFill", "backgroundBrightness", "gradient", "spark", "fillEnd", "bevelLines", "border", "glow",
    "showText", "fontSize", "fontFile", "fontOutline", "textColor", "textPosition" },
  swingBar = { "width", "height", "texture", "fillColor", "backgroundColor", "backgroundFromFill",
    "backgroundBrightness", "gradient", "spark", "fillEnd", "bevelLines", "border", "glow", "showText",
    "idleLook", "empties" },
}

---Restores the classic look: bar looks, the swing bar centred below the resource bar and the green
---energy threshold. Lists and the positions of the resource bar and the icon row stay.
function Momentum.RestoreClassicLook()
  local settings = Momentum.settings
  for section, keys in pairs(LOOK_SETTINGS) do
    local lookDefaults = {}
    for _, key in ipairs(keys) do lookDefaults[key] = Momentum.defaults[section][key] end
    Util.overwrite(settings[section], lookDefaults)
  end
  local defaults = Momentum.defaults
  settings.swingBar.positionX = settings.resourceBar.positionX
  settings.swingBar.positionY = settings.resourceBar.positionY
    + defaults.swingBar.positionY - defaults.resourceBar.positionY
  local energy = Momentum.Resource.GetThresholds("ENERGY")
  local energyDefaults = Momentum.Resource.thresholdDefaults.ENERGY
  energy.valuesInPercent = energyDefaults.valuesInPercent
  local colorChange = energyDefaults.colorChange
  Util.overwrite(energy.colorChange, { enabled = colorChange.enabled, threshold = colorChange.threshold,
    fadeRange = colorChange.fadeRange, color = colorChange.color, endColor = colorChange.endColor })
  Momentum.ApplyAll()
  Momentum.Options.Refresh()
end

---Resets the settings of the player's class: default look, class presets, nothing learned.
function Momentum.ResetClass()
  local settings = Momentum.settings
  for key in pairs(settings) do settings[key] = nil end
  Util.fillMissing(settings, Momentum.defaults)
  Momentum.Spells.AddClassPresets()
  Momentum.Buffs.ClearClocks()
  Momentum.Spells.LatchCooldowns()
  Momentum.ApplyAll()
  Momentum.Options.Refresh()
end

---Value of an API call for the debug output.
---@param apiFunction function|nil
---@param ... any arguments
---@return string
local function describeCall(apiFunction, ...)
  if type(apiFunction) ~= "function" then return "n/a" end
  local success, value = pcall(apiFunction, ...)
  if not success then return "error" end
  return isSecret(value) and "secret" or tostring(value)
end

---All lines of /mom debug.
---@return string[]
function Momentum.DebugLines()
  local lines = {}
  local now = GetTime()
  local powerType = UnitPowerType("player")
  local current = UnitPower("player", powerType)
  local Secrets = C_Secrets or {}
  local comboPointType = (Enum and Enum.PowerType and Enum.PowerType.ComboPoints) or 4
  local swingState, rowStats = Momentum.Swing.state, Momentum.Row.stats
  lines[#lines + 1] = "version " .. Momentum.VERSION .. "  | interface: " .. tostring((select(4, GetBuildInfo())))
    .. "  | in combat: " .. tostring(UnitAffectingCombat("player"))
  lines[#lines + 1] = "UnitPower secret: " .. tostring(isSecret(current)) .. "  | thresholds via: "
    .. tostring(Momentum.Resource.gateMethod)
  lines[#lines + 1] = "game says: auras hidden=" .. describeCall(Secrets.ShouldAurasBeSecret)
    .. "  secrecy (0 never, 1 always, 2 in combat): power=" .. describeCall(Secrets.GetPowerTypeSecrecy, powerType)
    .. " combo points=" .. describeCall(Secrets.GetPowerTypeSecrecy, comboPointType)
  lines[#lines + 1] = string.format("buffs: %s | read=%s shown=%s | texture failures=%s lastError=%s",
    tostring(Momentum.Buffs.auraMethod), tostring(rowStats.aurasRead), tostring(rowStats.iconsShown),
    tostring(rowStats.textureFailures), tostring(rowStats.lastIconError))
  lines[#lines + 1] = string.format(
    "swing: native API=%s hand=%s events=%d ignored=%d secretDurations=%d duration=%.2f rescaled=%d",
    tostring(C_SwingTimer ~= nil), tostring(Momentum.settings.swingBar.hand), swingState.eventsUsed,
    swingState.eventsIgnored, swingState.secretDurations, swingState.duration, swingState.swingsRescaled)
  local factors = {}
  for spellID, factor in pairs(Momentum.settings.swingBar.learnedHasteFactors) do
    factors[#factors + 1] = spellID .. "=" .. factor
  end
  local haste = swingState.haste
  lines[#lines + 1] = "swing haste: "
    .. (haste and string.format("running (spell %d, factor %.3f)", haste.spellID, haste.factor) or "none")
    .. "  | measured factors: " .. (#factors > 0 and table.concat(factors, " ") or "none yet")
  local errorCount, errorSum = #swingState.timingErrors, 0
  for _, timingError in ipairs(swingState.timingErrors) do errorSum = errorSum + abs(timingError) end
  lines[#lines + 1] = string.format("swing accuracy (last %d swings): avg |error| %s s, last %s s", errorCount,
    errorCount > 0 and string.format("%.3f", errorSum / errorCount) or "-",
    errorCount > 0 and string.format("%+.3f", swingState.timingErrors[errorCount]) or "-")
  for _, line in ipairs(Momentum.Buffs.DebugLines(now)) do lines[#lines + 1] = line end
  for _, line in ipairs(Momentum.Spells.DebugLines()) do lines[#lines + 1] = "spell " .. line end
  lines[#lines + 1] = "native swing timer (showSwingTimer): " .. tostring(GetCVar and GetCVar("showSwingTimer"))
  for step, message in pairs(Momentum.errors) do lines[#lines + 1] = "error [" .. step .. "]: " .. message end
  return lines
end

---Prints the debug information to the chat.
function Momentum.Debug()
  Momentum.Print("debug (run it in combat too!)")
  for _, line in ipairs(Momentum.DebugLines()) do print("  " .. line) end
end

---Turns Blizzard's own swing timer on or off.
---@param shown boolean
function Momentum.SetBlizzardSwingTimer(shown)
  pcall(SetCVar, "showSwingTimer", shown and "1" or "0")
  Momentum.Print("showSwingTimer = " .. tostring(GetCVar and GetCVar("showSwingTimer")))
end

---Handler of /mom and /momentum.
---@param message string|nil everything after the command
local function handleSlashCommand(message)
  local command, argument = (message or ""):match("^(%S*)%s*(.-)$")
  command = (command or ""):lower()
  local rowSettings = Momentum.settings.iconRow
  if command == "unlock" then
    Momentum.SetUnlocked(true)
    Momentum.Print("unlocked, drag the elements with the left mouse button.")
  elseif command == "lock" then
    Momentum.SetUnlocked(false)
    Momentum.Print("locked.")
  elseif command == "reset" then Momentum.ResetClass()
  elseif command == "debug" then Momentum.Debug()
  elseif command == "auras" then Momentum.Buffs.PrintAuras()
  elseif command == "swingtest" then Momentum.Swing.Test()
  elseif command == "add" and argument ~= "" then Momentum.ListAdd(rowSettings.whitelist, argument)
  elseif command == "proc" and argument ~= "" then Momentum.ListAdd(rowSettings.procs, argument)
  elseif command == "cd" and argument ~= "" then Momentum.ListAdd(rowSettings.cooldowns, argument)
  elseif command == "remove" and argument ~= "" then
    Momentum.ListRemove(rowSettings.whitelist, Momentum.ResolveSpellName(argument))
  else
    Momentum.Options.Toggle()
  end
end

SLASH_MOMENTUM1 = "/mom"
SLASH_MOMENTUM2 = "/momentum"
SlashCmdList["MOMENTUM"] = function(message)
  if Momentum.settings then handleSlashCommand(message) end
end

Momentum.OnEvent("PLAYER_LOGIN", Momentum.ApplyAll)
Momentum.OnEvent("PLAYER_ENTERING_WORLD", Momentum.ApplyAll)
