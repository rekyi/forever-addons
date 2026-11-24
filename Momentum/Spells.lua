-- Spells.lua: spells in the icon row. Procs are shown while usable (e.g. Riposte), cooldowns while
-- cooling down (e.g. Shank).
--
-- What the client allows (API documentation of 1.60.1, confirmed in game by the probes of
-- LibClassicSwingTimerAPI and by EllesmereUI):
--   * C_Spell.IsSpellUsable is readable, in combat too
--   * C_Spell.GetSpellCooldown: start and duration are secret in combat, isActive / isOnGCD never;
--     isOnGCD is only reliable while SPELL_UPDATE_COOLDOWN is being handled, so it is latched there
--   * C_Spell.GetSpellCooldownDuration(spell, ignoreGCD) returns a duration object for
--     Cooldown:SetCooldownFromDurationObject; a hidden Cooldown frame's OnCooldownDone marks the end
--   * the action of UNIT_COMBAT ("PARRY", "DODGE", ...) is readable: it starts a reactive window
--     (5 seconds, the same model as AKForeverCombatTimers)

---@type Momentum
local Momentum = select(2, ...)
local Util = Momentum.Util
local isSecret = Util.isSecret

local ipairs, pairs, pcall, tostring, type = ipairs, pairs, pcall, tostring, type

---@class MomentumReactiveSpell
---@field unit "player"|"target" whose UNIT_COMBAT opens the window
---@field actions table<string, boolean> UNIT_COMBAT actions that open it
---@field windowSeconds number

---@class MomentumRowItem
---@field spellName string|nil procs and cooldowns
---@field spellID number|nil procs and cooldowns
---@field icon number|string|nil
---@field isCooldown boolean|nil the spell is shown because it is on cooldown
---@field notEnoughPower boolean|nil usable proc, but not enough power yet (shown grey)
---@field startTime number|nil start of a proc's reactive window
---@field duration number|nil length of the window, or of a readable buff
---@field clock MomentumClock|nil the buff runs on an own clock
---@field expirationTime number|nil end of a readable buff
---@field stacks number|nil of a readable buff

---@class MomentumSpells
---@field onCooldown table<string, boolean> spell name -> on a real cooldown (not just the global one)
---@field reactiveWindows table<string, number> spell name -> start of the reactive window
---@field cooldownWatchers table<string, Cooldown> spell name -> hidden Cooldown frame that reports the end
local Spells = { onCooldown = {}, reactiveWindows = {}, cooldownWatchers = {} }
Momentum.Spells = Spells

local onCooldown, reactiveWindows, cooldownWatchers = Spells.onCooldown, Spells.reactiveWindows, Spells.cooldownWatchers
---@type table<string, number|false>
local spellIDsByName = {} -- spell ID of the known rank (false = not known); cleared on SPELLS_CHANGED

---@type table<number, MomentumReactiveSpell>
local REACTIVE_SPELLS = {
  [14251] = { unit = "player", actions = { PARRY = true }, windowSeconds = 5 },                          -- Riposte
  [6572]  = { unit = "player", actions = { BLOCK = true, DODGE = true, PARRY = true }, windowSeconds = 5 }, -- Revenge
  [19306] = { unit = "player", actions = { PARRY = true }, windowSeconds = 5 },                          -- Counterattack
  [1495]  = { unit = "player", actions = { DODGE = true }, windowSeconds = 5 },                          -- Mongoose Bite
  [7384]  = { unit = "target", actions = { DODGE = true }, windowSeconds = 5 },                          -- Overpower
}
---@type table<string, MomentumReactiveSpell>
local reactiveByName = {}

---@class MomentumPresetSpell
---@field spellID number|nil to get the localized name
---@field name string English name (used when there is no spell ID)

-- Class presets, added once per class (and again after /mom reset).
---@type table<string, { procs: MomentumPresetSpell[], cooldowns: MomentumPresetSpell[] }>
local CLASS_PRESETS = {
  ROGUE = { procs = { { spellID = 14251, name = "Riposte" } }, cooldowns = { { name = "Shank" } } }, -- Shank: Forever ability
  WARRIOR = { procs = { { spellID = 7384, name = "Overpower" }, { spellID = 6572, name = "Revenge" } }, cooldowns = {} },
  HUNTER = { procs = { { spellID = 1495, name = "Mongoose Bite" }, { spellID = 19306, name = "Counterattack" } },
    cooldowns = {} },
}

---Marks the icon row for a rebuild.
local function invalidateRow()
  Momentum.Row.Invalidate()
end

---Fills the name lookup of the reactive spells. Names are localized and may not be loaded yet at
---login, so this runs more than once.
function Spells.InitNames()
  for spellID, reactive in pairs(REACTIVE_SPELLS) do
    local name = Util.spellName(spellID)
    if name then reactiveByName[name] = reactive end
  end
end

---Spell ID of the rank the player knows (by name, overrides included), or nil.
---@param spellName string
---@return number|nil
function Spells.ID(spellName)
  local spellID = spellIDsByName[spellName]
  if spellID ~= nil then return spellID or nil end
  spellID = false
  if C_Spell and C_Spell.GetSpellInfo then
    local success, info = pcall(C_Spell.GetSpellInfo, spellName)
    if success and type(info) == "table" then
      local found = info.spellID
      if not isSecret(found) and type(found) == "number" then spellID = found end
    end
  end
  spellIDsByName[spellName] = spellID
  return spellID or nil
end

---Icon of a spell.
---@param spellID number
---@return number|string|nil
function Spells.Icon(spellID)
  if C_Spell and C_Spell.GetSpellTexture then
    local success, icon = pcall(C_Spell.GetSpellTexture, spellID)
    if success and not isSecret(icon) then return icon end
  end
  return nil
end

---Is the spell usable right now?
---@param spellID number
---@return boolean usable
---@return boolean notEnoughPower usable except for missing energy, rage or mana
local function isUsable(spellID)
  if not (C_Spell and C_Spell.IsSpellUsable) then return false, false end
  local success, usable, notEnoughPower = pcall(C_Spell.IsSpellUsable, spellID)
  if not success or isSecret(usable) or isSecret(notEnoughPower) then return false, false end
  return usable == true, notEnoughPower == true
end

---Duration object of a spell's cooldown (global cooldown ignored), for SetCooldownFromDurationObject.
---@param spellID number
---@return table|nil
function Spells.CooldownDuration(spellID)
  if not (C_Spell and C_Spell.GetSpellCooldownDuration) then return nil end
  local success, durationObject = pcall(C_Spell.GetSpellCooldownDuration, spellID, true)
  if success and durationObject then return durationObject end
  return nil
end

---Start and duration of an active cooldown if they are readable numbers (out of combat).
---@param spellID number
---@return number|nil startTime
---@return number|nil duration
function Spells.ReadCooldown(spellID)
  if not (C_Spell and C_Spell.GetSpellCooldown) then return nil, nil end
  local success, cooldown = pcall(C_Spell.GetSpellCooldown, spellID)
  if not success or type(cooldown) ~= "table" or not cooldown.isActive then return nil, nil end
  local startTime, duration = cooldown.startTime, cooldown.duration
  if isSecret(startTime) or isSecret(duration) or type(startTime) ~= "number" or type(duration) ~= "number" then
    return nil, nil
  end
  return startTime, duration
end

---Is the spell on a real cooldown (more than the global cooldown)?
---@param spellID number
---@return boolean
local function isOnRealCooldown(spellID)
  if not (C_Spell and C_Spell.GetSpellCooldown) then return false end
  local success, cooldown = pcall(C_Spell.GetSpellCooldown, spellID)
  if not success or type(cooldown) ~= "table" or not cooldown.isActive then return false end
  local duration = cooldown.duration
  if not isSecret(duration) and type(duration) == "number" then return duration > 1.5 end -- the GCD is never longer
  return not cooldown.isOnGCD
end

---Shows a cooldown on a Cooldown frame: from the duration object (works with secret values),
---else from readable numbers.
---@param cooldownFrame Cooldown
---@param spellID number
---@return boolean shown
function Spells.ShowCooldown(cooldownFrame, spellID)
  local durationObject = Spells.CooldownDuration(spellID)
  if durationObject and pcall(cooldownFrame.SetCooldownFromDurationObject, cooldownFrame, durationObject) then
    return true
  end
  local startTime, duration = Spells.ReadCooldown(spellID)
  if startTime and duration then
    cooldownFrame:SetCooldown(startTime, duration)
    return true
  end
  return false
end

local watcherParent

---Starts the hidden Cooldown frame that reports when the cooldown of a spell is over.
---@param spellName string
---@param spellID number
local function watchCooldown(spellName, spellID)
  if not watcherParent then
    watcherParent = CreateFrame("Frame", nil, UIParent)
    watcherParent:SetSize(1, 1)
    watcherParent:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    watcherParent:SetAlpha(0)
  end
  local watcher = cooldownWatchers[spellName]
  if not watcher then
    watcher = CreateFrame("Cooldown", nil, watcherParent, "CooldownFrameTemplate") --[[@as Cooldown]]
    watcher:SetAllPoints()
    watcher:SetHideCountdownNumbers(true)
    if watcher.SetDrawBling then watcher:SetDrawBling(false) end
    watcher:SetScript("OnCooldownDone", function()
      if onCooldown[spellName] then
        onCooldown[spellName] = nil
        invalidateRow()
      end
    end)
    cooldownWatchers[spellName] = watcher
  end
  Spells.ShowCooldown(watcher, spellID)
end

---All spell names in the proc and cooldown lists.
---@param rowSettings MomentumIconRowSettings
---@return table<string, boolean>
local function trackedSpells(rowSettings)
  local tracked = {}
  for _, spellName in ipairs(rowSettings.cooldowns) do tracked[spellName] = true end
  for _, spellName in ipairs(rowSettings.procs) do tracked[spellName] = true end
  return tracked
end

---Reads which tracked spells are on a real cooldown. Called while SPELL_UPDATE_COOLDOWN is handled
---(isOnGCD is only reliable then), on login and after list changes.
function Spells.LatchCooldowns()
  local tracked = trackedSpells(Momentum.settings.iconRow)
  for spellName in pairs(tracked) do
    local spellID = Spells.ID(spellName)
    if spellID and isOnRealCooldown(spellID) then
      onCooldown[spellName] = true
      watchCooldown(spellName, spellID)
    else
      onCooldown[spellName] = nil
    end
  end
  for spellName in pairs(onCooldown) do
    if not tracked[spellName] then onCooldown[spellName] = nil end
  end
  invalidateRow()
end

---Safety net between events: a cooldown that is no longer active at all is over, and a reactive
---window whose time is up needs the row rebuilt.
function Spells.Poll()
  local now = GetTime()
  for spellName, windowStart in pairs(reactiveWindows) do
    local reactive = reactiveByName[spellName]
    if not reactive or now >= windowStart + reactive.windowSeconds then invalidateRow() end
  end
  for spellName in pairs(onCooldown) do
    local spellID = Spells.ID(spellName)
    local active = false
    if spellID then
      local success, cooldown = pcall(C_Spell.GetSpellCooldown, spellID)
      active = success and type(cooldown) == "table" and cooldown.isActive == true
    end
    if not active then
      onCooldown[spellName] = nil
      invalidateRow()
    end
  end
end

---UNIT_COMBAT: a parry, dodge or block opens the window of the reactive spells it enables.
---@param unit string|nil
---@param action string|nil
local function onUnitCombat(unit, action)
  if isSecret(unit) or isSecret(action) or type(action) ~= "string" then return end
  local procs = Util.listToSet(Momentum.settings.iconRow.procs)
  for spellName, reactive in pairs(reactiveByName) do
    if procs[spellName] and reactive.unit == unit and reactive.actions[action] then
      reactiveWindows[spellName] = GetTime()
      invalidateRow()
    end
  end
end

---UNIT_SPELLCAST_SUCCEEDED of the player (payload: unit, cast GUID, spell ID): casting a reactive
---spell closes its window.
---@param castSpellID number|nil (may be secret)
local function onSpellSucceeded(_, _, castSpellID)
  if isSecret(castSpellID) or type(castSpellID) ~= "number" then return end
  local spellName = Util.spellName(castSpellID)
  if spellName and reactiveWindows[spellName] then
    reactiveWindows[spellName] = nil
    invalidateRow()
  end
end

---Items for the row: procs go in front of the buffs, cooldowns behind them.
---@param now number
---@param rowSettings MomentumIconRowSettings
---@return MomentumRowItem[] procItems
---@return MomentumRowItem[] cooldownItems
function Spells.Items(now, rowSettings)
  local procItems, cooldownItems = {}, {}
  for _, spellName in ipairs(rowSettings.procs) do
    local spellID = Spells.ID(spellName)
    if spellID then
      local windowStart = reactiveWindows[spellName] ---@type number|nil
      local reactive = reactiveByName[spellName]
      if windowStart and (not reactive or now >= windowStart + reactive.windowSeconds) then
        reactiveWindows[spellName] = nil
        windowStart = nil
      end
      local usable, notEnoughPower = isUsable(spellID)
      if (usable or notEnoughPower) and not onCooldown[spellName] then
        procItems[#procItems + 1] = { spellName = spellName, spellID = spellID, icon = Spells.Icon(spellID),
          notEnoughPower = notEnoughPower and not usable,
          startTime = windowStart, duration = windowStart and reactive.windowSeconds }
      elseif windowStart and now - windowStart > 0.5 then
        reactiveWindows[spellName] = nil -- not usable any more: used, or the target is gone
      end
    end
  end
  for _, spellName in ipairs(rowSettings.cooldowns) do
    local spellID = Spells.ID(spellName)
    if spellID and onCooldown[spellName] then
      cooldownItems[#cooldownItems + 1] = { spellName = spellName, spellID = spellID, icon = Spells.Icon(spellID),
        isCooldown = true }
    end
  end
  return procItems, cooldownItems
end

---Usable state of all procs as one string: the row is only rebuilt when it changes.
---@return string
function Spells.UsableSignature()
  local parts = {}
  for _, spellName in ipairs(Momentum.settings.iconRow.procs) do
    local spellID = Spells.ID(spellName)
    local usable, notEnoughPower = false, false
    if spellID then usable, notEnoughPower = isUsable(spellID) end
    parts[#parts + 1] = (usable and "usable" or "-") .. (notEnoughPower and "+power" or "") .. ";"
  end
  return table.concat(parts)
end

---One line per tracked spell for /mom debug.
---@return string[]
function Spells.DebugLines()
  local lines = {}
  for spellName in pairs(trackedSpells(Momentum.settings.iconRow)) do
    local spellID = Spells.ID(spellName)
    local usable, notEnoughPower = false, false
    if spellID then usable, notEnoughPower = isUsable(spellID) end
    lines[#lines + 1] = string.format("%s (ID %s): usable=%s%s onCooldown=%s%s", spellName, tostring(spellID),
      tostring(usable), notEnoughPower and " (not enough power)" or "", tostring(onCooldown[spellName] == true),
      reactiveWindows[spellName] and " window open" or "")
  end
  table.sort(lines)
  return lines
end

---Adds the class presets to the proc and cooldown lists (once per class).
function Spells.AddClassPresets()
  local settings = Momentum.settings
  if settings.classPresetsAdded then return end
  settings.classPresetsAdded = true
  local presets = CLASS_PRESETS[Momentum.playerClass]
  if not presets then return end
  for _, listName in ipairs({ "procs", "cooldowns" }) do
    local list = settings.iconRow[listName]
    for _, preset in ipairs(presets[listName]) do
      local name = (preset.spellID and Util.spellName(preset.spellID)) or preset.name
      if not Util.listToSet(list)[name] then list[#list + 1] = name end
    end
  end
end

---Forgets the cached spell IDs (the player learned or lost spells).
local function onSpellsChanged()
  wipe(spellIDsByName)
  Spells.InitNames()
  invalidateRow()
end

---Login or loading screen: names may be available now, cooldowns may be running.
local function onEnterWorld()
  Spells.InitNames()
  Spells.LatchCooldowns()
end

-- usable procs and running cooldowns: a cheap look five times a second (events do most of it)
local lastCheckTime, lastSignature = 0, nil

---Per-frame step: polls procs and cooldowns every 0.2 seconds.
---@param now number
local function pollEveryFifthSecond(now)
  local procs = Momentum.settings.iconRow.procs
  if not ((#procs > 0 or next(onCooldown)) and now - lastCheckTime > 0.2) then return end
  lastCheckTime = now
  Spells.Poll()
  if #procs > 0 then
    local success, signature = pcall(Spells.UsableSignature)
    if success and signature ~= lastSignature then
      lastSignature = signature
      invalidateRow()
    end
  end
end

Momentum.OnLoaded(function()
  Spells.AddClassPresets()
  Spells.InitNames()
end)
Momentum.OnEveryFrame("procs and cooldowns", pollEveryFifthSecond)
Momentum.OnEvent("PLAYER_LOGIN", onEnterWorld)
Momentum.OnEvent("PLAYER_ENTERING_WORLD", onEnterWorld)
Momentum.OnEvent("SPELL_UPDATE_COOLDOWN", Spells.LatchCooldowns)
Momentum.OnEvent("SPELL_UPDATE_USABLE", invalidateRow)
Momentum.OnEvent("ACTIONBAR_UPDATE_USABLE", invalidateRow)
Momentum.OnEvent("SPELLS_CHANGED", onSpellsChanged)
Momentum.OnEvent("UNIT_COMBAT", onUnitCombat, "player", "target")
Momentum.OnEvent("UNIT_SPELLCAST_SUCCEEDED", onSpellSucceeded, "player")
