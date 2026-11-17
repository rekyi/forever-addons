-- Swing.lua: the swing timer.
--
-- Driven by Forever's native swing event PLAYER_SWING(duration, swingType). Blizzard's own bar
-- (Blizzard_SwingTimer.lua) is exactly this: on the event the timer restarts and runs for the duration
-- in the payload; a weapon change restarts a running timer; nothing else moves it.
-- One thing Blizzard's bar does not do is added on top (measured by LibClassicSwingTimerAPI on Forever):
-- Slice and Dice changes the swing that is already in flight, see "dynamic haste" below.

---@type Momentum
local Momentum = select(2, ...)
local Look = Momentum.Look
local isSecret = Momentum.Util.isSecret

local abs, floor, max, min = math.abs, math.floor, math.max, math.min
local pcall, type = pcall, type

---@class MomentumHaste
---@field spellID number spell of the running haste buff
---@field baseFactor number factor from the HASTE_FACTORS table
---@field factor number factor in use (learned from the swing events if possible)
---@field lastCastTime number
---@field expectedEnd number|nil expected end of the buff
---@field durationBefore number|nil swing duration before the buff (to learn the factor from the next swing)
---@field shortestDuration number|nil shortest swing seen while the buff ran

---@class MomentumSwingState
---@field startTime number start of the current swing
---@field duration number
---@field endTime number
---@field eventsUsed number PLAYER_SWING events used (diagnostics)
---@field eventsIgnored number PLAYER_SWING events of another hand
---@field secretDurations number events whose duration was secret
---@field swingsRescaled number swings changed by dynamic haste
---@field lastDurationByType table<number, number> last readable duration per swing type
---@field haste MomentumHaste|nil running dynamic haste buff
---@field timingErrors number[] actual minus expected time of recent swings (diagnostics)
---@field autoAttacking boolean melee auto attack on (PLAYER_ENTER_COMBAT / PLAYER_LEAVE_COMBAT)
---@field autoShooting boolean auto shot on (START/STOP_AUTOREPEAT_SPELL)

---@class MomentumSwing
---@field frame MomentumBarFrame
---@field state MomentumSwingState
local Swing = {}
Momentum.Swing = Swing

local frame = CreateFrame("Frame", "MomentumSwing", UIParent) --[[@as MomentumBarFrame]]
frame:SetFrameLevel(Look.LEVEL_SWING_BAR)
frame.background = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
frame.background:SetAllPoints()
frame.bar = CreateFrame("StatusBar", nil, frame) --[[@as MomentumBar]]
frame.bar:SetAllPoints()
frame.bar:SetStatusBarTexture(Momentum.WHITE_TEXTURE)
frame.text = frame.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
frame.text:SetPoint("CENTER")
Swing.frame = frame

Look.MakeMovable(frame, "Swing", function() return Momentum.settings.swingBar end)

local LINGER_SECONDS = 1.2 -- keep a finished swing visible this long

---@type MomentumSwingState
local state = {
  startTime = 0, duration = 0, endTime = 0,
  eventsUsed = 0, eventsIgnored = 0, secretDurations = 0, swingsRescaled = 0,
  lastDurationByType = {}, timingErrors = {}, autoAttacking = false, autoShooting = false,
}
Swing.state = state

---Swing type of the configured hand (Enum.PlayerSwingType).
---@param hand "MAIN"|"OFF"|"RANGED"
---@return number
local function swingTypeOf(hand)
  local SwingType = Enum and Enum.PlayerSwingType
  if hand == "OFF" then return (SwingType and SwingType.OffHand) or 1 end
  if hand == "RANGED" then return (SwingType and SwingType.Ranged) or 2 end
  return (SwingType and SwingType.MainHand) or 0
end

---Attack speed of a hand, or nil while it is secret (in combat).
---@param hand "MAIN"|"OFF"|"RANGED"
---@return number|nil
local function readAttackSpeed(hand)
  local success, mainHand, offHand, ranged = pcall(UnitAttackSpeed, "player")
  if not success then return nil end
  local speed = (hand == "OFF" and offHand) or (hand == "RANGED" and ranged) or mainHand
  if speed == nil or isSecret(speed) or type(speed) ~= "number" or speed <= 0 then return nil end
  return speed
end

---Is the value a usable swing duration?
---@param duration any
---@return boolean
local function isUsableDuration(duration)
  if duration == nil or isSecret(duration) or type(duration) ~= "number" then return false end
  return duration > 0 and duration < 60
end

---Starts a swing.
---@param startTime number
---@param duration number
local function startSwing(startTime, duration)
  state.startTime, state.duration, state.endTime = startTime, duration, startTime + duration
end

---Multiplies the remaining time of the running swing, as of a given time.
---@param atTime number
---@param factor number
---@return boolean changed
local function rescaleSwing(atTime, factor)
  if state.duration <= 0 or atTime >= state.endTime or atTime < state.startTime then return false end
  local doneFraction = (atTime - state.startTime) / state.duration
  local newDuration = state.duration * factor
  startSwing(atTime - doneFraction * newDuration, newDuration)
  state.swingsRescaled = state.swingsRescaled + 1
  return true
end

-- Dynamic haste. Measured on Forever (LibClassicSwingTimerAPI, docs/HASTE_APPLICATION_FINDINGS.md):
--   * applying Slice and Dice shortens the swing in flight: remaining time / factor
--   * recasting it while it runs changes nothing
--   * when it runs out the swing in flight is lengthened again
--   * attack speed is secret in combat, so the only usable trigger is the player's own cast
-- [spell ID] = factor. Rank 1 is measured (+20%); rank 2 is the Classic value until the swing events
-- of this client have shown the real one (see learnHasteFactor).
local HASTE_FACTORS = { [5171] = 1.2, [6774] = 1.3 }
local HASTE_MAX_AGE = 35 -- seconds after the last cast at which the buff is certainly gone

---Is the tracked haste buff still running? (It outlives "cast + duration" by a few tenths of a
---second: the server applies it a little later.)
---@param haste MomentumHaste|nil
---@param now number
---@return boolean
local function hasteRunning(haste, now)
  return haste ~= nil and now - haste.lastCastTime < HASTE_MAX_AGE
    and not (haste.expectedEnd and now > haste.expectedEnd + 0.4)
end

---The player cast a spell; a haste buff shortens the swing in flight.
---@param spellID number
---@param now number
---@param buffDuration number|nil duration of the buff in seconds, if known
function Swing.OnHasteCast(spellID, now, buffDuration)
  local settings = Momentum.settings.swingBar
  local baseFactor = HASTE_FACTORS[spellID]
  if not baseFactor or not settings.hasteCorrection or settings.hand == "RANGED" then return end
  local expectedEnd = buffDuration and (now + buffDuration) or nil
  local haste = state.haste
  if haste and hasteRunning(haste, now) then
    haste.lastCastTime, haste.expectedEnd = now, expectedEnd -- a refresh: the engine leaves the swing alone
    return
  end
  local factor = settings.learnedHasteFactors[spellID] or baseFactor
  state.haste = { spellID = spellID, baseFactor = baseFactor, factor = factor, lastCastTime = now,
    expectedEnd = expectedEnd, durationBefore = state.lastDurationByType[swingTypeOf(settings.hand)] }
  -- a swing younger than 50 ms was started by an event that already carried the hasted speed
  if now - state.startTime > 0.05 then rescaleSwing(now, 1 / factor) end
end

---The first swing under a haste buff teaches its factor; a slower swing later shows that the buff
---has run out.
---@param duration number readable duration of the new swing
---@param now number
local function learnHasteFactor(duration, now)
  local haste = state.haste
  if not haste then return end
  if now - haste.lastCastTime >= HASTE_MAX_AGE or (haste.expectedEnd and now > haste.expectedEnd + 1) then
    state.haste = nil
  elseif haste.durationBefore then
    local ratio = haste.durationBefore / duration
    if abs(ratio - haste.baseFactor) / haste.baseFactor <= 0.15 then
      haste.factor = ratio
      Momentum.settings.swingBar.learnedHasteFactors[haste.spellID] = floor(ratio * 1000 + 0.5) / 1000
    end
    haste.durationBefore, haste.shortestDuration = nil, duration
  elseif haste.shortestDuration and duration > haste.shortestDuration * 1.02 then
    state.haste = nil -- the speed is back up: the buff has run out
  else
    haste.shortestDuration = min(haste.shortestDuration or duration, duration)
  end
end

---PLAYER_SWING: a swing of one hand starts.
---@param duration number|nil duration of the new swing (may be secret)
---@param swingType number|nil Enum.PlayerSwingType (may be secret)
local function onPlayerSwing(duration, swingType)
  if isSecret(swingType) or swingType ~= swingTypeOf(Momentum.settings.swingBar.hand) then
    state.eventsIgnored = state.eventsIgnored + 1
    return
  end
  ---@cast swingType number
  local now = GetTime()
  local swingDuration
  if isUsableDuration(duration) then
    ---@cast duration number
    swingDuration = duration
    learnHasteFactor(swingDuration, now)
    state.lastDurationByType[swingType] = swingDuration
  else
    state.secretDurations = state.secretDurations + 1
    swingDuration = state.lastDurationByType[swingType] or readAttackSpeed(Momentum.settings.swingBar.hand) or 2.0
  end
  -- diagnostics: how far off was the previous bar?
  if state.endTime > 0 and abs(now - state.endTime) < 1.0 then
    state.timingErrors[#state.timingErrors + 1] = now - state.endTime
    if #state.timingErrors > 20 then table.remove(state.timingErrors, 1) end
  end
  startSwing(now, swingDuration)
  state.eventsUsed = state.eventsUsed + 1
end

---UNIT_ATTACK_SPEED fires when the speed really changes (its values are secret in combat). If that
---happens where a tracked haste buff is expected to end, the swing in flight gets its time back.
local function onAttackSpeed()
  local haste = state.haste
  if not (haste and haste.expectedEnd and Momentum.settings.swingBar.hasteCorrection) then return end
  local now = GetTime()
  if now - haste.lastCastTime < 0.5 then return end -- the application fires this event as well
  if now >= haste.expectedEnd - 0.25 and now <= haste.expectedEnd + 0.75 then
    rescaleSwing(min(now, haste.expectedEnd), haste.factor)
    state.haste = nil
  end
end

---Blizzard's bar restarts a running swing when a weapon slot changes (WEAPON_SLOT_CHANGED).
---@param inventorySlot number
local function onEquipmentChanged(inventorySlot)
  local settings = Momentum.settings.swingBar
  local isMyWeapon
  if settings.hand == "RANGED" then
    isMyWeapon = (inventorySlot == 18)
  else
    isMyWeapon = (inventorySlot == 16 or inventorySlot == 17)
  end
  if not isMyWeapon then return end
  local now = GetTime()
  if state.duration > 0 and now < state.endTime then
    startSwing(now, readAttackSpeed(settings.hand) or state.duration)
  end
  if state.haste then state.haste.durationBefore, state.haste.shortestDuration = nil, nil end
end

---Ends everything: death or a loading screen stop the attack without an event of their own.
function Swing.Stop()
  state.autoAttacking, state.autoShooting = false, false
  state.startTime, state.duration, state.endTime = 0, 0, 0
  state.haste = nil
end

---Applies the settings to the bar.
function Swing.Apply()
  local settings = Momentum.settings.swingBar
  local fill = settings.fillColor
  Look.ApplyBarLook(frame, settings)
  Look.PaintFill(frame.bar, settings, fill[1], fill[2], fill[3], fill[4] or 1)
  frame.background:SetColorTexture(Look.BackgroundColor(settings, fill[1], fill[2], fill[3]))
  frame.bar:SetReverseFill(false)
end

---Runs four 2-second test swings.
function Swing.Test()
  for swingNumber = 0, 3 do
    C_Timer.After(swingNumber * 2, function() startSwing(GetTime(), 2.0) end)
  end
end

---Per-frame update of the bar.
---@param now number
function Swing.Update(now)
  local settings = Momentum.settings.swingBar
  if not settings.enabled then frame:Hide() return end
  local attacking = (settings.hand == "RANGED") and state.autoShooting or state.autoAttacking
  local visible = state.duration > 0 and (now < state.endTime + LINGER_SECONDS or attacking)
  if visible then
    local duration = state.duration
    local elapsed = min(max(now - state.startTime, 0), duration)
    frame:Show()
    frame.bar:SetMinMaxValues(0, duration)
    frame.bar:SetValue(settings.empties and (duration - elapsed) or elapsed)
    if settings.showText then frame.text:SetFormattedText("%.1f", duration - elapsed) else frame.text:SetText("") end
    Look.SetFillEndAlpha(frame.bar, (elapsed > 0 and elapsed < duration) and 1 or 0)
  elseif Momentum.unlocked or settings.idleLook ~= "HIDE" then
    frame:Show()
    frame.bar:SetMinMaxValues(0, 1)
    frame.bar:SetValue((settings.idleLook == "EMPTY") and 0 or 1)
    frame.text:SetText("")
    Look.SetFillEndAlpha(frame.bar, 0)
  else
    frame:Hide()
  end
end

Momentum.OnEveryFrame("swing bar", Swing.Update)
Momentum.OnEvent("PLAYER_SWING", onPlayerSwing)
Momentum.OnEvent("PLAYER_ENTER_COMBAT", function() state.autoAttacking = true end)
Momentum.OnEvent("PLAYER_LEAVE_COMBAT", function() state.autoAttacking = false end)
Momentum.OnEvent("START_AUTOREPEAT_SPELL", function() state.autoShooting = true end)
Momentum.OnEvent("STOP_AUTOREPEAT_SPELL", function() state.autoShooting = false end)
Momentum.OnEvent("UNIT_ATTACK_SPEED", onAttackSpeed, "player")
Momentum.OnEvent("PLAYER_EQUIPMENT_CHANGED", onEquipmentChanged)
Momentum.OnEvent("PLAYER_DEAD", Swing.Stop)
Momentum.OnEvent("PLAYER_ENTERING_WORLD", Swing.Stop)
