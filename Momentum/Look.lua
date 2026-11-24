-- Look.lua: shared drawing helpers (position, dragging, border, glow, fill, spark, text).

---@type Momentum
local Momentum = select(2, ...)

local floor, max, min = math.floor, math.max, math.min
local ipairs, pairs, pcall = ipairs, pairs, pcall

---@class MomentumLook
---@field movableFrames MomentumMovable[] frames that follow /mom unlock
local Look = { movableFrames = {} }
Momentum.Look = Look

-- Frame levels of the three HUD elements. The resource bar's decorations (threshold layer, pulse
-- rings, text) use up to its level + 6; the swing bar and the icon row sit above that, so a glow of
-- the resource bar runs behind them instead of over them.
Look.LEVEL_RESOURCE_BAR = 10
Look.LEVEL_SWING_BAR = 20
Look.LEVEL_ICON_ROW = 20

---@class MomentumRing
---@field top Texture
---@field bottom Texture
---@field left Texture
---@field right Texture

---@class MomentumDecoration
---@field borderRing MomentumRing
---@field glowRings MomentumRing[] innermost first
---@field glowFrame Frame holds the glow (it pulses as a whole)
---@field glowPulse AnimationGroup|nil

---@class MomentumDecorated : Frame
---@field decoration MomentumDecoration|nil

---@class MomentumMovable : MomentumDecorated
---@field unlockOverlay Frame shown while unlocked

---@class MomentumBar : StatusBar
---@field spark Texture|nil
---@field fillEnd Texture|nil soft bright end of the fill
---@field bevelTop Texture|nil light line on top of the fill
---@field bevelBottom Texture|nil light line at the bottom of the fill

---@class MomentumBarFrame : MomentumMovable
---@field background Texture
---@field bar MomentumBar
---@field text FontString

---------------------------------------------------------------------------
-- Position and dragging
---------------------------------------------------------------------------

---Puts a frame at its configured offset from the screen centre.
---@param frame Frame
---@param position { positionX: number, positionY: number }
function Look.ApplyPosition(frame, position)
  frame:ClearAllPoints()
  frame:SetPoint("CENTER", UIParent, "CENTER", position.positionX, position.positionY)
end

---Stores where a dragged frame was dropped (whole pixels from the screen centre).
---@param frame Frame
---@param position { positionX: number, positionY: number }
local function savePosition(frame, position)
  local frameX, frameY = frame:GetCenter()
  local screenX, screenY = UIParent:GetCenter()
  if frameX and screenX then
    position.positionX = floor(frameX - screenX + 0.5)
    position.positionY = floor(frameY - screenY + 0.5)
  end
  Look.ApplyPosition(frame, position)
  Momentum.Options.Refresh()
end

---Makes a HUD element draggable while unlocked and gives it the blue unlock overlay.
---@param frame MomentumMovable
---@param label string shown on the overlay
---@param getPosition fun(): { positionX: number, positionY: number } settings that store the position
function Look.MakeMovable(frame, label, getPosition)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(dragged) if Momentum.unlocked then dragged:StartMoving() end end)
  frame:SetScript("OnDragStop", function(dragged)
    dragged:StopMovingOrSizing()
    savePosition(dragged, getPosition())
  end)
  -- own frame above all children (bars and icons would cover a texture of the frame itself)
  local overlay = CreateFrame("Frame", nil, frame)
  overlay:SetAllPoints()
  overlay:SetFrameLevel(frame:GetFrameLevel() + 30)
  local tint = overlay:CreateTexture(nil, "OVERLAY")
  tint:SetAllPoints()
  tint:SetColorTexture(0.2, 0.6, 1, 0.35)
  local caption = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  caption:SetPoint("CENTER")
  caption:SetText(label)
  overlay:Hide()
  frame.unlockOverlay = overlay
  Look.movableFrames[#Look.movableFrames + 1] = frame
end

---Shows or hides the unlock overlays and lets the HUD elements take the mouse while unlocked.
---@param unlocked boolean
function Look.SetUnlocked(unlocked)
  Momentum.unlocked = unlocked and true or false
  for _, frame in ipairs(Look.movableFrames) do
    frame:EnableMouse(Momentum.unlocked)
    frame.unlockOverlay:SetShown(Momentum.unlocked)
  end
end

---------------------------------------------------------------------------
-- Rings: border and glow are made of four textures around a frame
---------------------------------------------------------------------------

---Creates the four textures of a ring.
---@param parent Frame
---@return MomentumRing
function Look.MakeRing(parent)
  local ring = {}
  for _, side in ipairs({ "top", "bottom", "left", "right" }) do
    ring[side] = parent:CreateTexture(nil, "BACKGROUND", nil, -3)
  end
  return ring
end

---Lays out a ring whose outer edge sits a distance outside of a frame.
---@param frame Frame
---@param ring MomentumRing
---@param outerDistance number from the frame edge to the outer edge of the ring
---@param thickness number
function Look.LayoutRing(frame, ring, outerDistance, thickness)
  local outer, inner = outerDistance, outerDistance - thickness
  ring.top:ClearAllPoints()
  ring.top:SetPoint("TOPLEFT", frame, "TOPLEFT", -outer, outer)
  ring.top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", outer, inner)
  ring.bottom:ClearAllPoints()
  ring.bottom:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", -outer, -inner)
  ring.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", outer, -outer)
  ring.left:ClearAllPoints()
  ring.left:SetPoint("TOPLEFT", frame, "TOPLEFT", -outer, inner)
  ring.left:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", -inner, -inner)
  ring.right:ClearAllPoints()
  ring.right:SetPoint("TOPLEFT", frame, "TOPRIGHT", inner, inner)
  ring.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", outer, -inner)
end

---Colours and shows a ring.
---@param ring MomentumRing
---@param color MomentumColor
---@param alpha? number overrides the colour's alpha
function Look.ColorRing(ring, color, alpha)
  for _, texture in pairs(ring) do
    texture:SetColorTexture(color[1], color[2], color[3], alpha or color[4] or 1)
    texture:Show()
  end
end

---Hides a ring.
---@param ring MomentumRing
function Look.HideRing(ring)
  for _, texture in pairs(ring) do texture:Hide() end
end

---Creates a looping fade (alpha 1 -> lowestAlpha -> 1) on a frame.
---@param frame Frame|Region
---@param lowestAlpha number
---@param seconds number for one direction
---@return AnimationGroup group
---@return Animation fade the alpha animation (its duration can be changed later)
function Look.NewPulse(frame, lowestAlpha, seconds)
  local group = frame:CreateAnimationGroup()
  group:SetLooping("BOUNCE")
  local fade = group:CreateAnimation("Alpha") --[[@as Alpha]]
  if fade.SetFromAlpha then
    fade:SetFromAlpha(1)
    fade:SetToAlpha(lowestAlpha)
  else
    fade:SetChange(lowestAlpha - 1) -- older clients
  end
  fade:SetDuration(seconds)
  return group, fade
end

---Space the border takes around an element (0 if it has none).
---@param border MomentumBorderSettings|nil
---@return number
function Look.BorderWidth(border)
  if border and border.enabled then return (border.gap or 0) + border.thickness end
  return 0
end

---Draws the border and the glow of a frame.
---@param frame MomentumDecorated
---@param border MomentumBorderSettings|nil
---@param glow MomentumGlowSettings|nil
function Look.ApplyDecoration(frame, border, glow)
  local decoration = frame.decoration
  if not decoration then
    decoration = { borderRing = Look.MakeRing(frame), glowRings = {}, glowFrame = CreateFrame("Frame", nil, frame) }
    decoration.glowFrame:SetAllPoints()
    frame.decoration = decoration
  end
  local borderWidth = Look.BorderWidth(border)
  if borderWidth > 0 then
    ---@cast border MomentumBorderSettings
    Look.LayoutRing(frame, decoration.borderRing, borderWidth, border.thickness)
    Look.ColorRing(decoration.borderRing, border.color)
  else
    Look.HideRing(decoration.borderRing)
  end
  -- glow: concentric 1 px rings with fading alpha (no texture files needed)
  local ringCount = (glow and glow.enabled) and min(floor(glow.width), 12) or 0
  local rings = decoration.glowRings
  for ringIndex = 1, ringCount do
    ---@cast glow MomentumGlowSettings
    rings[ringIndex] = rings[ringIndex] or Look.MakeRing(decoration.glowFrame)
    Look.LayoutRing(frame, rings[ringIndex], borderWidth + ringIndex, 1)
    Look.ColorRing(rings[ringIndex], glow.color, (glow.color[4] or 1) * (1 - (ringIndex - 1) / ringCount) ^ 2)
  end
  for ringIndex = ringCount + 1, #rings do Look.HideRing(rings[ringIndex]) end
  if ringCount > 0 and glow and glow.pulsing then
    decoration.glowPulse = decoration.glowPulse or Look.NewPulse(decoration.glowFrame, 0.2, 0.7)
    if not decoration.glowPulse:IsPlaying() then decoration.glowPulse:Play() end
  else
    if decoration.glowPulse then decoration.glowPulse:Stop() end
    decoration.glowFrame:SetAlpha(1)
  end
end

---------------------------------------------------------------------------
-- Bars
---------------------------------------------------------------------------

---Paints the fill of a bar, with the gradient if enabled.
---@param bar StatusBar
---@param settings MomentumBarSettings
---@param red number
---@param green number
---@param blue number
---@param alpha number
---@param endColor? MomentumColor second gradient colour (default: the configured one)
function Look.PaintFill(bar, settings, red, green, blue, alpha, endColor)
  bar:SetStatusBarColor(red, green, blue, alpha)
  local fillTexture = bar:GetStatusBarTexture()
  if not fillTexture then return end
  local gradient = settings.gradient
  local second = (gradient.enabled and (endColor or gradient.endColor)) or { red, green, blue, alpha }
  local success = pcall(function()
    fillTexture:SetGradient(gradient.direction, CreateColor(red, green, blue, alpha),
      CreateColor(second[1], second[2], second[3], second[4] or alpha))
  end)
  if not success then
    pcall(fillTexture.SetGradientAlpha, fillTexture, gradient.direction, red, green, blue, alpha,
      second[1], second[2], second[3], second[4] or alpha)
  end
end

---Background colour of a bar: the fill colour made darker, or the fixed background colour.
---@param settings MomentumBarSettings
---@param red number fill colour
---@param green number
---@param blue number
---@return number red, number green, number blue, number alpha
function Look.BackgroundColor(settings, red, green, blue)
  if settings.backgroundFromFill then
    local brightness = settings.backgroundBrightness or 0.25
    return red * brightness, green * brightness, blue * brightness, settings.backgroundColor[4] or 1
  end
  local color = settings.backgroundColor
  return color[1], color[2], color[3], color[4] or 1
end

---Shows or hides the spark at the end of the fill.
---@param bar MomentumBar
---@param settings MomentumBarSettings
function Look.ApplySpark(bar, settings)
  if not bar.spark then
    bar.spark = bar:CreateTexture(nil, "OVERLAY", nil, 2)
    bar.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    bar.spark:SetBlendMode("ADD")
  end
  local spark = settings.spark
  if spark.enabled then
    bar.spark:ClearAllPoints()
    bar.spark:SetPoint("CENTER", bar:GetStatusBarTexture(), "RIGHT", 0, 0)
    bar.spark:SetSize(spark.width or 12, settings.height * 2)
    bar.spark:Show()
  else
    bar.spark:Hide()
  end
end

---Soft bright end of the fill and light bevel lines, all anchored to the fill itself.
---@param bar MomentumBar
---@param settings MomentumBarSettings
function Look.DecorateFill(bar, settings)
  local fill = bar:GetStatusBarTexture()
  if not fill then return end
  if not bar.fillEnd then
    bar.fillEnd = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    bar.bevelTop = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    bar.bevelBottom = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    for _, texture in ipairs({ bar.fillEnd, bar.bevelTop, bar.bevelBottom }) do texture:SetBlendMode("ADD") end
  end
  local fillEnd, bevelTop, bevelBottom = bar.fillEnd, bar.bevelTop, bar.bevelBottom
  ---@cast fillEnd -nil
  ---@cast bevelTop -nil
  ---@cast bevelBottom -nil
  local endSettings = settings.fillEnd
  fillEnd:ClearAllPoints()
  fillEnd:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, 0)
  fillEnd:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
  fillEnd:SetWidth(max(endSettings.width or 5, 1))
  fillEnd:SetColorTexture(1, 1, 1, 1)
  local success = pcall(function()
    fillEnd:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, endSettings.strength or 0.28))
  end)
  if not success then fillEnd:SetColorTexture(1, 1, 1, (endSettings.strength or 0.28) / 2) end
  fillEnd:SetShown(endSettings.enabled)

  local bevel = settings.bevelLines
  bevelTop:ClearAllPoints()
  bevelTop:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
  bevelTop:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, 0)
  bevelBottom:ClearAllPoints()
  bevelBottom:SetPoint("BOTTOMLEFT", fill, "BOTTOMLEFT", 0, 0)
  bevelBottom:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
  for _, line in ipairs({ bevelTop, bevelBottom }) do
    line:SetHeight(1)
    line:SetColorTexture(1, 1, 1, bevel.strength or 0.1)
    line:SetShown(bevel.enabled)
  end
end

---Hides the end-of-fill decorations while the bar is empty or full.
---@param bar MomentumBar
---@param alpha number possibly secret
function Look.SetFillEndAlpha(bar, alpha)
  if bar.fillEnd then bar.fillEnd:SetAlpha(alpha) end
  if bar.spark then bar.spark:SetAlpha(alpha) end
end

---Font, colour and position of the text on a bar.
---@param text FontString
---@param bar Frame
---@param settings MomentumBarSettings
function Look.ApplyText(text, bar, settings)
  local flags = (settings.fontOutline ~= "NONE" and settings.fontOutline or "") --[[@as ""|"OUTLINE"|"THICKOUTLINE"]]
  local success, result = pcall(text.SetFont, text, settings.fontFile or STANDARD_TEXT_FONT, settings.fontSize, flags)
  if not success or result == false then text:SetFont(STANDARD_TEXT_FONT, settings.fontSize, flags) end
  local color = settings.textColor
  text:SetTextColor(color[1], color[2], color[3], color[4] or 1)
  local position = settings.textPosition
  text:ClearAllPoints()
  text:SetPoint(position, bar, position, position == "LEFT" and 4 or (position == "RIGHT" and -4 or 0), 0)
  text:SetJustifyH(position)
end

---Shared look of the resource and the swing bar (the colours are painted by each bar).
---@param frame MomentumBarFrame
---@param settings MomentumBarSettings
function Look.ApplyBarLook(frame, settings)
  frame:SetSize(settings.width, settings.height)
  Look.ApplyPosition(frame, settings)
  frame.bar:SetStatusBarTexture(settings.texture or Momentum.WHITE_TEXTURE)
  Look.ApplyDecoration(frame, settings.border, settings.glow)
  Look.ApplySpark(frame.bar, settings)
  Look.DecorateFill(frame.bar, settings)
  Look.ApplyText(frame.text, frame.bar, settings)
end
