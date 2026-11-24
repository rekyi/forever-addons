-- Buffs.lua: the player's buffs for the icon row, and the clocks that stand in for them in combat.
--
-- What the Forever client allows (C_Secrets / UnitAura documentation, confirmed in game by several
-- addons): out of combat the player's auras are readable data. In combat every aura query is refused
-- ("Auras cannot be accessed when secret"), by index, by spell ID and by name alike. So:
--   * out of combat the real auras are shown, and they teach icon and duration
--   * in combat the row runs on clocks of its own: carried over from before the pull and
--     restarted by the player's own casts (UNIT_SPELLCAST_SUCCEEDED is readable)
--   * Slice and Dice lasts (6 + 3 x combo points) seconds x talent factor; the combo points are
--     read when the cast is sent

---@type Momentum
local Momentum = select(2, ...)
local Util, Gates = Momentum.Util, Momentum.Gates
local isSecret, Point = Util.isSecret, Gates.Point

local abs, floor, max = math.abs, math.floor, math.max
local ipairs, pairs, pcall, select, tonumber, tostring, type = ipairs, pairs, pcall, select, tonumber, tostring, type

---@class MomentumClockCandidate
---@field duration number for this number of combo points
---@field alpha number|nil 1 for the count that applies (secret)

---@class MomentumClock
---@field startTime number
---@field duration number
---@field icon number|string|nil
---@field createdAt number
---@field candidates MomentumClockCandidate[]|nil one per combo point count (combo points were secret)
---@field isGuess boolean|nil combo points unknown: the longest run is assumed

---@class MomentumComboPointSnapshot
---@field takenAt number|nil
---@field comboPoints number|nil readable combo points
---@field alphas (number|nil)[]|nil one secret alpha per count (1 for the count that applies)

---@class MomentumBuffs
---@field clocks table<string, MomentumClock> buff name -> own timer (kept across fights)
---@field finisherNames table<string, boolean>
---@field auraMethod string how the auras were read (for /mom debug)
---@field comboPointMethod string how the combo points were read (for /mom debug)
---@field aurasHidden boolean the game hid the auras on the last read
---@field checkClocksUntil number keep checking the clocks until this time (after a cast)
local Buffs = {
  clocks = {}, finisherNames = {},
  auraMethod = "none", comboPointMethod = "-", aurasHidden = false, checkClocksUntil = 0,
}
Momentum.Buffs = Buffs

local clocks, finisherNames = Buffs.clocks, Buffs.finisherNames
---@type table<string, { time: number, comboPoints: number|nil }>
local lastCasts = {}          -- buff name -> last own cast (combo points if they were readable)
---@type table<string, MomentumComboPointSnapshot|nil>
local comboPointSnapshots = {} -- buff name -> combo points captured when the cast was sent

-- Finishers whose buff lasts (base + perComboPoint x combo points) seconds x talent factor.
local FINISHER_SPELL_IDS = { [5171] = true, [6774] = true } -- Slice and Dice, rank 1 and 2
local FINISHER_SECONDS = { base = 6, perComboPoint = 3 }
local TALENT_FACTORS = { 1, 1.15, 1.30, 1.45 }              -- Improved Slice and Dice, 0 to 3 points
-- Durations of buffs that are normally cast in combat and may never have been seen out of it.
-- A duration learned from the real buff always wins.
local BUILT_IN_DURATIONS = { [5277] = 15, [13750] = 15, [13877] = 15, [2983] = 15, [8696] = 15, [11305] = 15,
  [14278] = 7 } -- Evasion, Adrenaline Rush, Blade Flurry, Sprint (3 ranks), Ghostly Strike
---@type table<string, number>
local builtInDurationByName = {}

local COMBO_POINTS = (Enum and Enum.PowerType and Enum.PowerType.ComboPoints) or 4

---Marks the icon row for a rebuild.
local function invalidateRow()
  Momentum.Row.Invalidate()
end

---Fills the name lookups. Names are localized and may not be loaded yet at login, so this runs more
---than once.
function Buffs.InitNames()
  for spellID in pairs(FINISHER_SPELL_IDS) do
    local name = Util.spellName(spellID)
    if name then finisherNames[name] = true end
  end
  for spellID, seconds in pairs(BUILT_IN_DURATIONS) do
    local name = Util.spellName(spellID)
    if name then builtInDurationByName[name] = seconds end
  end
end

---Built-in duration of a buff that is usually cast in combat.
---@param buffName string
---@return number|nil
function Buffs.BuiltInDuration(buffName)
  return builtInDurationByName[buffName]
end

---Most combo points the player can have.
---@return number
function Buffs.MaxComboPoints()
  local success, maximum = pcall(UnitPowerMax, "player", COMBO_POINTS)
  if success and not isSecret(maximum) and type(maximum) == "number" and maximum > 0 then return maximum end
  return 5
end

---@type table<string, MomentumGate>
local comboPointGates = {}

---Combo points right now: { comboPoints = n } if readable, else { alphas = {...} } (one secret alpha
---per count), else nil. Forever keeps combo points on the target: UnitPower can still report the
---previous target's count after a target change (EllesmereUI reads GetComboPoints for that reason),
---so that one is asked first.
---@return MomentumComboPointSnapshot|nil
local function snapshotComboPoints()
  local comboPoints, method
  if GetComboPoints then
    comboPoints, method = Util.readableNumber(pcall(GetComboPoints, "player", "target")), "GetComboPoints"
  end
  if not comboPoints then
    comboPoints, method = Util.readableNumber(pcall(UnitPower, "player", COMBO_POINTS)), "UnitPower"
  end
  if comboPoints then
    Buffs.comboPointMethod = method .. " (readable)"
    if comboPoints >= 1 then return { comboPoints = comboPoints } end
    return nil -- readable, but none (already spent)
  end
  local maximum = Buffs.MaxComboPoints()
  local alphas = {}
  for count = 1, maximum do
    local key = count .. "/" .. maximum
    comboPointGates[key] = comboPointGates[key]
      or Gates.Build({ Point(0, 0), Point((count - 0.5) / maximum, 1), Point((count + 0.5) / maximum, 0) }, true)
    local alpha, found = Gates.ClientAlpha(comboPointGates[key], COMBO_POINTS)
    if not found then
      Buffs.comboPointMethod = "unavailable"
      return nil
    end
    alphas[count] = alpha
  end
  Buffs.comboPointMethod = "curve (secret; can lag behind after a target change)"
  return { alphas = alphas }
end

---What was learned about a buff (created on first use).
---@param buffName string
---@return MomentumLearnedBuff
local function learnedEntry(buffName)
  local learned = Momentum.settings.learnedBuffs[buffName]
  if not learned then
    learned = {}
    Momentum.settings.learnedBuffs[buffName] = learned
  end
  return learned
end

---Duration of a finisher's buff for a number of combo points.
---@param buffName string
---@param comboPoints number
---@return number seconds
function Buffs.FinisherDuration(buffName, comboPoints)
  local learned = Momentum.settings.learnedBuffs[buffName]
  return (FINISHER_SECONDS.base + FINISHER_SECONDS.perComboPoint * comboPoints) * ((learned and learned.talentFactor) or 1)
end

---Learns the talent factor of a finisher from its real (readable) buff.
---@param buffName string
---@param duration number of the real buff
---@param startTime number of the real buff
local function learnTalentFactor(buffName, duration, startTime)
  local lastCast = lastCasts[buffName]
  if not lastCast or abs(startTime - lastCast.time) > 1.5 then return end
  local learned = learnedEntry(buffName)
  if lastCast.comboPoints and lastCast.comboPoints >= 1 then
    -- the combo points were readable when it was cast: exact
    local factor = duration / (FINISHER_SECONDS.base + FINISHER_SECONDS.perComboPoint * lastCast.comboPoints)
    if factor > 0.9 and factor < 2.1 then learned.talentFactor = floor(factor * 1000 + 0.5) / 1000 end
    return
  end
  -- combo points unknown: only an unambiguous fit to the known talent steps counts
  local found
  for _, factor in ipairs(TALENT_FACTORS) do
    for comboPoints = 1, 5 do
      if abs((FINISHER_SECONDS.base + FINISHER_SECONDS.perComboPoint * comboPoints) * factor - duration) < 0.06 then
        if found and found ~= factor then return end
        found = factor
      end
    end
  end
  if found then learned.talentFactor = found end
end

---Can aura data be read right now? (In combat it can not, and asking would only raise errors.)
---@return boolean
local function aurasReadable()
  if C_Secrets and C_Secrets.ShouldAurasBeSecret then
    local success, hidden = pcall(C_Secrets.ShouldAurasBeSecret)
    if success and not isSecret(hidden) and type(hidden) == "boolean" then return not hidden end
  end
  return not UnitAffectingCombat("player")
end

---Continuation token, number of slots and the slots of one GetAuraSlots call.
---@param continuationToken any
---@param ... number slots
---@return any continuationToken, integer slotCount, number[] slots
local function collectSlots(continuationToken, ...)
  return continuationToken, select("#", ...), { ... }
end

---The player's buffs as readable tables, or nil while the client keeps them hidden.
---@return table[]|nil
function Buffs.ReadAuras()
  if not aurasReadable() then
    Buffs.auraMethod = "hidden by the game (combat)"
    return nil
  end
  local UnitAuras = C_UnitAuras
  if UnitAuras and UnitAuras.GetUnitAuras then
    local success, auras = pcall(UnitAuras.GetUnitAuras, "player", "HELPFUL")
    if success and type(auras) == "table" then
      Buffs.auraMethod = "GetUnitAuras"
      return auras
    end
  end
  if UnitAuras and UnitAuras.GetAuraSlots and UnitAuras.GetAuraDataBySlot then
    local auras, allAnswered, continuationToken, rounds = {}, true, nil, 0
    repeat
      rounds = rounds + 1
      local success, nextToken, slotCount, slots = pcall(function()
        return collectSlots(UnitAuras.GetAuraSlots("player", "HELPFUL", nil, continuationToken))
      end)
      if not success then
        allAnswered = false
        break
      end
      continuationToken = nextToken
      for slotIndex = 1, slotCount do
        local found, aura = pcall(UnitAuras.GetAuraDataBySlot, "player", slots[slotIndex])
        if found and aura then auras[#auras + 1] = aura end
      end
    until not continuationToken or rounds > 5
    if allAnswered then
      Buffs.auraMethod = "GetAuraSlots"
      return auras
    end
  end
  if UnitAuras and UnitAuras.GetBuffDataByIndex then
    local auras, allAnswered = {}, true
    for auraIndex = 1, 40 do
      local success, aura = pcall(UnitAuras.GetBuffDataByIndex, "player", auraIndex)
      if not success then
        allAnswered = false
        break
      end
      if not aura then break end
      auras[#auras + 1] = aura
    end
    if allAnswered then
      Buffs.auraMethod = "GetBuffDataByIndex"
      return auras
    end
  end
  Buffs.auraMethod = "no aura API answered"
  return nil
end

---@class MomentumReadableAura
---@field name string
---@field icon number|string|nil
---@field duration number 0 = no duration
---@field expirationTime number
---@field stacks number

---Name, icon, duration, expiration time and stacks of an aura, or nil if any of it is hidden.
---@param aura table aura data of the client
---@return MomentumReadableAura|nil
function Buffs.ReadableAura(aura)
  local name, icon, duration, expirationTime, stacks =
    aura.name, aura.icon, aura.duration, aura.expirationTime, aura.applications
  if isSecret(name) or isSecret(icon) or isSecret(duration) or isSecret(expirationTime) or isSecret(stacks) then
    return nil
  end
  if type(name) ~= "string" then return nil end
  return { name = name, icon = icon, duration = tonumber(duration) or 0, expirationTime = tonumber(expirationTime) or 0,
    stacks = tonumber(stacks) or 0 }
end

---Was the aura cast by the player (or the player's pet)?
---@param aura table aura data of the client
---@return boolean
local function castByPlayer(aura)
  local fromPlayer, sourceUnit = aura.isFromPlayerOrPlayerPet, aura.sourceUnit
  if not isSecret(fromPlayer) and fromPlayer == true then return true end
  return not isSecret(sourceUnit) and sourceUnit == "player"
end

---When does a clock run out? (With candidates: the longest one.)
---@param clock MomentumClock
---@return number
local function clockEnd(clock)
  if clock.candidates then
    local latest = clock.startTime
    for _, candidate in ipairs(clock.candidates) do latest = max(latest, clock.startTime + candidate.duration) end
    return latest
  end
  return clock.startTime + clock.duration
end

---Decides which buffs the row shows.
---@param rowSettings MomentumIconRowSettings
---@return fun(buffName: string): boolean
local function buffFilter(rowSettings)
  local whitelistOnly = (rowSettings.buffFilter == "WHITELIST_ONLY")
  local whitelist, blacklist = Util.listToSet(rowSettings.whitelist), Util.listToSet(rowSettings.blacklist)
  return function(buffName)
    if whitelistOnly then return whitelist[buffName] == true end
    return not blacklist[buffName]
  end
end

---The buff items of the row: readable buffs, then clocks for the wanted buffs the client hides.
---Readable buffs also correct the clocks and teach icon, duration and talent factor.
---@param now number
---@param rowSettings MomentumIconRowSettings
---@return MomentumRowItem[] items
---@return integer|nil aurasRead number of auras read (nil while hidden)
function Buffs.Items(now, rowSettings)
  local isWanted = buffFilter(rowSettings)
  local items, present = {}, {}
  local auras = Buffs.ReadAuras()
  Buffs.aurasHidden = (auras == nil)
  if auras then
    for _, aura in ipairs(auras) do
      local readable = Buffs.ReadableAura(aura)
      if readable and isWanted(readable.name) then
        local name, duration, expirationTime = readable.name, readable.duration, readable.expirationTime
        present[name] = true
        items[#items + 1] = { icon = readable.icon, duration = duration, expirationTime = expirationTime,
          stacks = readable.stacks }
        if duration > 0 and expirationTime > 0 then
          -- the real buff is the truth for its clock ...
          local startTime = expirationTime - duration
          local clock = clocks[name]
          if not clock or clock.candidates or clock.isGuess or abs(clock.startTime - startTime) > 0.05
            or abs(clock.duration - duration) > 0.05 then
            clocks[name] = { startTime = startTime, duration = duration, icon = readable.icon, createdAt = now }
          end
          -- ... and teaches what a cast in combat will need
          if finisherNames[name] then
            learnedEntry(name).icon = readable.icon
            learnTalentFactor(name, duration, startTime)
          elseif rowSettings.buffFilter == "WHITELIST_ONLY" or castByPlayer(aura) then
            local learned = learnedEntry(name)
            learned.icon, learned.duration = readable.icon, duration
          end
        else
          clocks[name] = nil -- no duration: nothing that could be carried into a fight
        end
      end
    end
    -- the list is complete: a clock without its buff is over (unless the buff was cast a moment ago)
    for name, clock in pairs(clocks) do
      if not present[name] and now - (clock.createdAt or 0) > 1.5 then clocks[name] = nil end
    end
  end

  -- clocks stand in for every wanted buff the client does not show (in combat: all of them)
  local hiddenBuffs = {}
  for name, clock in pairs(clocks) do
    if now >= clockEnd(clock) then
      clocks[name] = nil
    elseif not present[name] and isWanted(name) then
      hiddenBuffs[#hiddenBuffs + 1] = clock
    end
  end
  table.sort(hiddenBuffs, function(first, second) return first.startTime < second.startTime end)
  for _, clock in ipairs(hiddenBuffs) do items[#items + 1] = { clock = clock } end
  return items, auras and #auras or nil
end

---Removes all clocks.
function Buffs.ClearClocks()
  wipe(clocks)
end

---UNIT_SPELLCAST_SENT (payload: unit, target, cast GUID, spell ID): the combo points are still
---there, so a finisher's count is taken now.
---@param castSpellID number|nil (may be secret)
local function onSpellSent(_, _, _, castSpellID)
  if isSecret(castSpellID) or type(castSpellID) ~= "number" then return end
  local name = Util.spellName(castSpellID)
  if not name or not (FINISHER_SPELL_IDS[castSpellID] or finisherNames[name]) then return end
  finisherNames[name] = true
  local snapshot = snapshotComboPoints()
  if snapshot then snapshot.takenAt = GetTime() end
  comboPointSnapshots[name] = snapshot
end

---UNIT_SPELLCAST_SUCCEEDED of the player (payload: unit, cast GUID, spell ID): finisher durations,
---dynamic haste and buff clocks.
---@param castSpellID number|nil (may be secret)
local function onSpellSucceeded(_, _, castSpellID)
  if isSecret(castSpellID) or type(castSpellID) ~= "number" then return end
  ---@cast castSpellID number
  local name = Util.spellName(castSpellID)
  if not name then return end
  local now = GetTime()
  local isFinisher = FINISHER_SPELL_IDS[castSpellID] or finisherNames[name]
  local duration, candidates
  if isFinisher then
    finisherNames[name] = true
    local snapshot = comboPointSnapshots[name]
    comboPointSnapshots[name] = nil
    if snapshot and now - (snapshot.takenAt or 0) > 2 then snapshot = nil end
    snapshot = snapshot or snapshotComboPoints() -- no SENT seen: at this instant the points are usually still readable
    lastCasts[name] = { time = now, comboPoints = snapshot and snapshot.comboPoints }
    if snapshot and snapshot.comboPoints then
      duration = Buffs.FinisherDuration(name, snapshot.comboPoints)
    elseif snapshot and snapshot.alphas then
      candidates = {}
      for count, alpha in ipairs(snapshot.alphas) do
        candidates[count] = { duration = Buffs.FinisherDuration(name, count), alpha = alpha }
      end
    end
  end

  Momentum.Swing.OnHasteCast(castSpellID, now, duration) -- the swing timer wants to know about Slice and Dice either way
  Buffs.checkClocksUntil = now + 2

  -- a clock for the icon row?
  local rowSettings = Momentum.settings.iconRow
  local learned = Momentum.settings.learnedBuffs[name]
  local wanted
  if rowSettings.buffFilter == "WHITELIST_ONLY" then
    wanted = Util.listToSet(rowSettings.whitelist)[name] == true
  else
    wanted = (isFinisher or (learned and learned.duration) or builtInDurationByName[name])
      and not Util.listToSet(rowSettings.blacklist)[name]
  end
  if not wanted then return end
  learned = learnedEntry(name)
  if not learned.icon and C_Spell and C_Spell.GetSpellTexture then
    local success, icon = pcall(C_Spell.GetSpellTexture, castSpellID)
    if success and not isSecret(icon) then learned.icon = icon end
  end
  if not learned.icon then return end
  if isFinisher then
    if duration then
      clocks[name] = { startTime = now, duration = duration, icon = learned.icon, createdAt = now }
    elseif candidates then
      clocks[name] = { startTime = now, duration = candidates[#candidates].duration, icon = learned.icon,
        createdAt = now, candidates = candidates }
    else
      -- combo points unknown: the longest possible run, marked as a guess
      clocks[name] = { startTime = now, duration = Buffs.FinisherDuration(name, Buffs.MaxComboPoints()),
        icon = learned.icon, createdAt = now, isGuess = true }
    end
  else
    local knownDuration = learned.duration or builtInDurationByName[name]
    if knownDuration then
      clocks[name] = { startTime = now, duration = knownDuration, icon = learned.icon, createdAt = now }
    end
  end
  invalidateRow()
end

---Prints the readable buffs with their spell IDs (only possible out of combat).
function Buffs.PrintAuras()
  local auras = Buffs.ReadAuras()
  if not auras then
    Momentum.Print("not possible in combat (the game hides buffs from addons).", true)
    return
  end
  Momentum.Print("active buffs:")
  for _, aura in ipairs(auras) do
    local readable = Buffs.ReadableAura(aura)
    if readable then
      local spellID = aura.spellId
      print(string.format("  %s  (ID %s)", readable.name, isSecret(spellID) and "?" or tostring(spellID)))
    end
  end
end

---Lines for /mom debug: clocks, finisher durations, whitelist entries without a duration.
---@param now number
---@return string[]
function Buffs.DebugLines(now)
  local lines = {}
  local unknown = {}
  for _, buffName in ipairs(Momentum.settings.iconRow.whitelist) do
    local learned = Momentum.settings.learnedBuffs[buffName]
    if not finisherNames[buffName] and not (learned and learned.duration) and not builtInDurationByName[buffName] then
      unknown[#unknown + 1] = buffName
    end
  end
  lines[#lines + 1] = "whitelist entries without known duration: " .. (#unknown > 0 and table.concat(unknown, ", ") or "none")
  lines[#lines + 1] = "combo points via: " .. tostring(Buffs.comboPointMethod)
  for name, clock in pairs(clocks) do
    if clock.candidates then
      local perCount = {}
      for count, candidate in ipairs(clock.candidates) do
        perCount[#perCount + 1] = string.format("%d:%.1f", count, candidate.duration)
      end
      lines[#lines + 1] = string.format("clock %s: started %.1fs ago, per combo point %s", name, now - clock.startTime,
        table.concat(perCount, " "))
    else
      lines[#lines + 1] = string.format("clock %s: %.1f of %.1fs left%s", name, clock.startTime + clock.duration - now,
        clock.duration, clock.isGuess and " (combo points unknown: longest run assumed)" or "")
    end
  end
  for name in pairs(finisherNames) do
    local learned = Momentum.settings.learnedBuffs[name]
    local perCount = {}
    for count = 1, Buffs.MaxComboPoints() do
      perCount[#perCount + 1] = string.format("%d:%.1f", count, Buffs.FinisherDuration(name, count))
    end
    lines[#lines + 1] = string.format("%s seconds per combo point (talent factor %s): %s", name,
      (learned and learned.talentFactor) and tostring(learned.talentFactor) or "not seen yet, 1 assumed",
      table.concat(perCount, " "))
  end
  return lines
end

local lastClockCheck = 0

---Per-frame step: clocks need a look now and then while they stand in for hidden buffs
---(events do the rest).
---@param now number
local function checkClocks(now)
  if next(clocks) and now - lastClockCheck > 0.25
    and (Buffs.aurasHidden or now < Buffs.checkClocksUntil or UnitAffectingCombat("player")) then
    lastClockCheck = now
    invalidateRow()
  end
end

Momentum.OnLoaded(Buffs.InitNames)
Momentum.OnEveryFrame("buff clocks", checkClocks)
Momentum.OnEvent("PLAYER_LOGIN", Buffs.InitNames)
Momentum.OnEvent("PLAYER_ENTERING_WORLD", Buffs.InitNames)
Momentum.OnEvent("SPELLS_CHANGED", Buffs.InitNames)
Momentum.OnEvent("UNIT_SPELLCAST_SENT", onSpellSent, "player")
Momentum.OnEvent("UNIT_SPELLCAST_SUCCEEDED", onSpellSucceeded, "player")
Momentum.OnEvent("UNIT_AURA", invalidateRow, "player")
-- clocks are kept across fights; readable auras correct them out of combat
Momentum.OnEvent("PLAYER_REGEN_DISABLED", invalidateRow)
Momentum.OnEvent("PLAYER_REGEN_ENABLED", invalidateRow)
