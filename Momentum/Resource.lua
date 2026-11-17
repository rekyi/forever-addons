-- Resource.lua: the resource bar (energy, rage, mana, ...) with thresholds.
--
-- The power value is secret on Forever, so a threshold can not be compared in Lua. Instead a gate
-- (see Gates.lua) is evaluated by the client and its alpha goes to SetAlpha:
--   * colour change: a second bar (fill + tinted background) on top, faded in from the threshold
--   * pulse: a pulsing glow around the bar from the threshold

---@type Momentum
local Momentum = select(2, ...)
local Util, Gates, Look = Momentum.Util, Momentum.Gates, Momentum.Look
local isSecret, Point = Util.isSecret, Gates.Point

local floor, max, min = math.floor, math.max, math.min
local tostring = tostring

---@class MomentumUpToSettings
---@field enabled boolean
---@field limit number the colour applies up to and including this value

---@class MomentumColorChangeSettings
---@field enabled boolean
---@field threshold number
---@field color MomentumColor
---@field endColor MomentumColor second gradient colour
---@field fadeRange number blend in over this much below the threshold (0 = hard switch)
---@field upTo MomentumUpToSettings

---@class MomentumThresholdPulseSettings
---@field enabled boolean
---@field threshold number
---@field color MomentumColor
---@field width number number of 1 px rings
---@field fadeSeconds number seconds for one fade

---@class MomentumThresholdSettings
---@field valuesInPercent boolean thresholds are percent of the maximum (else points)
---@field colorChange MomentumColorChangeSettings
---@field pulse MomentumThresholdPulseSettings

---@class MomentumResource
---@field frame MomentumResourceFrame
---@field powerType number|nil current power type (Enum.PowerType)
---@field powerToken string|nil current power token, e.g. "ENERGY"
---@field gateMethod string how the last threshold alpha was obtained (for /mom debug)
---@field previewUntil number|nil thresholds are shown as reached until this time
local Resource = { gateMethod = "-" }
Momentum.Resource = Resource

---@class MomentumPulseFrame : Frame
---@field rings MomentumRing[]
---@field animation AnimationGroup|nil
---@field fade Animation|nil

---@class MomentumGateFrame : Frame
---@field gate MomentumGate|nil

---@class MomentumResourceFrame : MomentumBarFrame
---@field thresholdLayer Frame alpha = colour gate
---@field thresholdBackground Texture
---@field thresholdBar MomentumBar
---@field pulseGateFrame MomentumGateFrame alpha = pulse gate
---@field pulseFrame MomentumPulseFrame
---@field textLayer Frame holds the text above all layers

---@class MomentumResourceGates
---@field colorGate MomentumGate|nil
---@field fillEndGate MomentumGate|nil
---@field builtForMaximum number|nil maximum the gates were built for
---@field builtForPowerType number|nil power type the gates were built for
---@field outdated boolean

---@type MomentumResourceGates
local gates = { outdated = true }

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "MomentumResource", UIParent) --[[@as MomentumResourceFrame]]
frame:SetFrameLevel(Look.LEVEL_RESOURCE_BAR)
local baseLevel = frame:GetFrameLevel()
frame.background = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
frame.background:SetAllPoints()
frame.bar = CreateFrame("StatusBar", nil, frame) --[[@as MomentumBar]]
frame.bar:SetAllPoints()
frame.bar:SetFrameLevel(baseLevel + 1)
frame.bar:SetStatusBarTexture(Momentum.WHITE_TEXTURE)
frame.bar:SetMinMaxValues(0, 100)
frame.bar:SetValue(0)
-- threshold layer: own background + fill in the threshold colour, gated by alpha
frame.thresholdLayer = CreateFrame("Frame", nil, frame)
frame.thresholdLayer:SetAllPoints()
frame.thresholdLayer:SetFrameLevel(baseLevel + 2)
frame.thresholdLayer:SetAlpha(0)
frame.thresholdBackground = frame.thresholdLayer:CreateTexture(nil, "BACKGROUND")
frame.thresholdBackground:SetAllPoints()
frame.thresholdBar = CreateFrame("StatusBar", nil, frame.thresholdLayer) --[[@as MomentumBar]]
frame.thresholdBar:SetAllPoints()
frame.thresholdBar:SetFrameLevel(baseLevel + 3)
frame.thresholdBar:SetStatusBarTexture(Momentum.WHITE_TEXTURE)
frame.thresholdBar:SetMinMaxValues(0, 100)
frame.thresholdBar:SetValue(0)
-- threshold pulse: gate frame (alpha from the curve) > pulsing frame > glow rings
frame.pulseGateFrame = CreateFrame("Frame", nil, frame) --[[@as MomentumGateFrame]]
frame.pulseGateFrame:SetAllPoints()
frame.pulseGateFrame:SetFrameLevel(baseLevel + 4)
frame.pulseGateFrame:SetAlpha(0)
frame.pulseFrame = CreateFrame("Frame", nil, frame.pulseGateFrame) --[[@as MomentumPulseFrame]]
frame.pulseFrame:SetAllPoints()
frame.pulseFrame.rings = {}
-- text on top of everything
frame.textLayer = CreateFrame("Frame", nil, frame)
frame.textLayer:SetAllPoints()
frame.textLayer:SetFrameLevel(baseLevel + 6)
frame.text = frame.textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
frame.text:SetPoint("CENTER")
Resource.frame = frame

Look.MakeMovable(frame, "Resource", function() return Momentum.settings.resourceBar end)

---------------------------------------------------------------------------
-- Thresholds
---------------------------------------------------------------------------

-- Defaults per power token; anything without its own entry uses DEFAULT (percent based).
---@type table<string, MomentumThresholdSettings>
Resource.thresholdDefaults = {
  RAGE = {
    valuesInPercent = false,
    colorChange = { enabled = false, threshold = 80, color = { 0.85, 0.15, 0.15, 1 }, endColor = { 0.6, 0.1, 0.1, 1 },
      fadeRange = 0, upTo = { enabled = false, limit = 100 } },
    pulse = { enabled = true, threshold = 80, color = { 1, 0.1, 0.1, 1 }, width = 6, fadeSeconds = 0.5 },
  },
  ENERGY = {
    valuesInPercent = false,
    colorChange = { enabled = true, threshold = 50, color = { 0.169, 0.620, 0.424, 1 },
      endColor = { 0.133, 0.490, 0.333, 1 }, fadeRange = 3, upTo = { enabled = false, limit = 80 } },
    pulse = { enabled = false, threshold = 100, color = { 1, 0.85, 0.2, 1 }, width = 6, fadeSeconds = 0.5 },
  },
  DEFAULT = {
    valuesInPercent = true,
    colorChange = { enabled = false, threshold = 50, color = { 0.169, 0.620, 0.424, 1 },
      endColor = { 0.133, 0.490, 0.333, 1 }, fadeRange = 0, upTo = { enabled = false, limit = 80 } },
    pulse = { enabled = false, threshold = 80, color = { 1, 0.85, 0.2, 1 }, width = 6, fadeSeconds = 0.5 },
  },
}

---Thresholds of a power type (created from the defaults on first use).
---@param powerToken? string default: the current one
---@return MomentumThresholdSettings thresholds
---@return string powerToken
function Resource.GetThresholds(powerToken)
  powerToken = powerToken or Resource.powerToken or select(2, UnitPowerType("player")) or "DEFAULT"
  local all = Momentum.settings.resourceBar.thresholds
  all[powerToken] = all[powerToken] or {}
  Util.fillMissing(all[powerToken], Resource.thresholdDefaults[powerToken] or Resource.thresholdDefaults.DEFAULT)
  return all[powerToken], powerToken
end

---A threshold value as a fraction (0..1) of the current maximum.
---@param thresholds MomentumThresholdSettings
---@param value number in points or percent
---@param maximum number|nil maximum power (may be secret)
---@return number
local function asFraction(thresholds, value, maximum)
  if thresholds.valuesInPercent then return value / 100 end
  if maximum and not isSecret(maximum) and maximum > 0 then return value / maximum end
  return value / 100
end

---Gate of one threshold: 0 below, 1 from the threshold (faded in, optionally only up to a limit).
---@param thresholds MomentumThresholdSettings
---@param threshold number
---@param fadeRange number 0 = hard switch
---@param upTo MomentumUpToSettings|nil
---@param maximum number|nil
---@return MomentumGate
local function thresholdGate(thresholds, threshold, fadeRange, upTo, maximum)
  local fromFraction = asFraction(thresholds, threshold, maximum) - 0.0001 -- tolerate float rounding at the threshold
  local fadeFraction = fadeRange > 0 and asFraction(thresholds, fadeRange, maximum) or 0
  local upToFraction = upTo and upTo.enabled and asFraction(thresholds, upTo.limit, maximum) or nil
  if upToFraction and upToFraction <= fromFraction then upToFraction = nil end
  fromFraction = max(fromFraction, 0.00002)
  if fadeFraction > 0 then
    local points = { Point(0, 0) }
    if fromFraction - fadeFraction > 0.00001 then points[#points + 1] = Point(fromFraction - fadeFraction, 0) end
    points[#points + 1] = Point(fromFraction, 1)
    if upToFraction then
      points[#points + 1] = Point(upToFraction, 1)
      points[#points + 1] = Point(upToFraction + fadeFraction, 0)
    end
    return Gates.Build(points, false)
  end
  local points = { Point(0, 0), Point(fromFraction, 1) }
  if upToFraction then
    points[#points + 1] = Point(upToFraction + 0.0001 + Gates.RAMP_WIDTH, 0) -- the limit itself still counts
  end
  return Gates.Build(points, true)
end

---Builds the gates for the current power type and maximum.
---@param maximum number|nil
local function rebuildGates(maximum)
  local thresholds = Resource.GetThresholds(Resource.powerToken)
  local colorChange, pulse = thresholds.colorChange, thresholds.pulse
  gates.colorGate = colorChange.enabled
    and thresholdGate(thresholds, colorChange.threshold, colorChange.fadeRange or 0, colorChange.upTo, maximum) or nil
  frame.pulseGateFrame.gate = pulse.enabled and thresholdGate(thresholds, pulse.threshold, 0, nil, maximum) or nil
  -- end-of-fill decorations: hidden when the bar is empty or full
  gates.fillEndGate = Gates.Build({ Point(0, 0), Point(0.01, 1), Point(0.995, 0) }, true)
  gates.builtForMaximum = (not isSecret(maximum)) and maximum or nil
  gates.builtForPowerType = Resource.powerType
  gates.outdated = false
end

---Alpha of a gate for the current power; may be secret (only ever passed to SetAlpha).
---@param gate MomentumGate|nil
---@param current number|nil current power (may be secret)
---@param maximum number|nil maximum power (may be secret)
---@param record? boolean record for /mom debug how the value was obtained
---@return number
local function gateAlpha(gate, current, maximum, record)
  if not gate then return 0 end
  local alpha, found = Gates.ClientAlpha(gate, Resource.powerType)
  if found then
    if record then Resource.gateMethod = "curve (" .. tostring(gate.curveKind) .. ")" end
    return alpha
  end
  if current and maximum and not isSecret(current) and not isSecret(maximum) and maximum > 0 then
    if record then Resource.gateMethod = "direct" end
    return Gates.Evaluate(gate, current / maximum)
  end
  if record then Resource.gateMethod = "unavailable" end
  return 0
end

---Paints both layers and the pulse rings for the current power type.
local function paintResource()
  local settings = Momentum.settings.resourceBar
  local fill = settings.fillColor
  local red, green, blue, alpha = fill[1], fill[2], fill[3], fill[4] or 1
  if settings.colorByPowerType and Resource.powerToken then
    local powerColor = PowerBarColor and (PowerBarColor[Resource.powerToken] or PowerBarColor[Resource.powerType])
    if powerColor then red, green, blue = powerColor.r, powerColor.g, powerColor.b end
  end
  Look.PaintFill(frame.bar, settings, red, green, blue, alpha)
  frame.background:SetColorTexture(Look.BackgroundColor(settings, red, green, blue))

  local thresholds = Resource.GetThresholds(Resource.powerToken)
  local thresholdColor = thresholds.colorChange.color
  Look.PaintFill(frame.thresholdBar, settings, thresholdColor[1], thresholdColor[2], thresholdColor[3],
    thresholdColor[4] or 1, thresholds.colorChange.endColor)
  frame.thresholdBackground:SetColorTexture(Look.BackgroundColor(settings, thresholdColor[1], thresholdColor[2],
    thresholdColor[3]))

  -- pulse rings: concentric 1 px rings outside the border, fading outwards
  local pulse = thresholds.pulse
  local borderWidth = Look.BorderWidth(settings.border)
  local ringCount = min(max(floor(pulse.width), 1), 16)
  local rings = frame.pulseFrame.rings
  for ringIndex = 1, ringCount do
    rings[ringIndex] = rings[ringIndex] or Look.MakeRing(frame.pulseFrame)
    Look.LayoutRing(frame, rings[ringIndex], borderWidth + ringIndex, 1)
    Look.ColorRing(rings[ringIndex], pulse.color, (pulse.color[4] or 1) * (1 - (ringIndex - 1) / ringCount) ^ 1.5)
  end
  for ringIndex = ringCount + 1, #rings do Look.HideRing(rings[ringIndex]) end
  if not frame.pulseFrame.animation then
    frame.pulseFrame.animation, frame.pulseFrame.fade = Look.NewPulse(frame.pulseFrame, 0.15, 0.5)
  end
  local animation, fade = frame.pulseFrame.animation, frame.pulseFrame.fade
  ---@cast animation -nil
  ---@cast fade -nil
  animation:Stop()
  fade:SetDuration(max(pulse.fadeSeconds or 0.5, 0.1))
  animation:Play()
  gates.outdated = true
end

---Applies the settings to the bar (look, size, position) and forces new colours and gates.
function Resource.Apply()
  local settings = Momentum.settings.resourceBar
  Look.ApplyBarLook(frame, settings)
  frame.thresholdBar:SetStatusBarTexture(settings.texture or Momentum.WHITE_TEXTURE)
  Look.ApplySpark(frame.thresholdBar, settings)
  Look.DecorateFill(frame.thresholdBar, settings)
  Resource.powerType = nil
  gates.outdated = true
end

---Shows the thresholds as reached for a few seconds (to see colours and pulse).
---@param seconds? number default 5
function Resource.Preview(seconds)
  Resource.previewUntil = GetTime() + (seconds or 5)
end

---Per-frame update: values go straight to the widgets, thresholds through the gates.
---@param now number
function Resource.Update(now)
  local settings = Momentum.settings.resourceBar
  if not settings.enabled then frame:Hide() return end
  local previewing = Resource.previewUntil and now < Resource.previewUntil
  if settings.onlyInCombat and not Momentum.unlocked and not UnitAffectingCombat("player") and not previewing then
    frame:Hide()
    return
  end
  frame:Show()
  local powerType, powerToken = UnitPowerType("player")
  if powerType ~= Resource.powerType then
    Resource.powerType, Resource.powerToken = powerType, powerToken
    paintResource()
    Momentum.Options.Refresh()
  end
  local maximum = UnitPowerMax("player", powerType)
  local current = UnitPower("player", powerType)
  -- values may be secret: pass them to widgets only
  frame.bar:SetMinMaxValues(0, maximum)
  frame.bar:SetValue(current)
  frame.thresholdBar:SetMinMaxValues(0, maximum)
  frame.thresholdBar:SetValue(current)
  if settings.showText then
    frame.text:SetFormattedText("%d", current)
  else
    frame.text:SetText("")
  end

  if gates.outdated or gates.builtForPowerType ~= powerType
    or (not isSecret(maximum) and maximum ~= gates.builtForMaximum) then
    rebuildGates(maximum)
  end
  local thresholds = Resource.GetThresholds(powerToken)
  if previewing then
    frame.thresholdLayer:SetAlpha(thresholds.colorChange.enabled and 1 or 0)
    frame.pulseGateFrame:SetAlpha(thresholds.pulse.enabled and 1 or 0)
  else
    frame.thresholdLayer:SetAlpha(gateAlpha(gates.colorGate, current, maximum, true))
    frame.pulseGateFrame:SetAlpha(gateAlpha(frame.pulseGateFrame.gate, current, maximum, true))
  end
  local fillEndAlpha = gateAlpha(gates.fillEndGate, current, maximum)
  Look.SetFillEndAlpha(frame.bar, fillEndAlpha)
  Look.SetFillEndAlpha(frame.thresholdBar, fillEndAlpha)
end

Momentum.OnEveryFrame("resource bar", Resource.Update)
Momentum.OnEvent("UNIT_DISPLAYPOWER", function() Resource.powerType = nil end, "player")
Momentum.OnEvent("UNIT_MAXPOWER", function() gates.outdated = true end, "player")
