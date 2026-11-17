-- Row.lua: the icon row. Procs in front, then buffs (real or on clocks), then cooldowns.

---@type Momentum
local Momentum = select(2, ...)
local Look, Spells, Buffs = Momentum.Look, Momentum.Spells, Momentum.Buffs

local ceil, floor, max, min = math.ceil, math.floor, math.max, math.min
local ipairs, pairs, pcall, tostring = ipairs, pairs, pcall, tostring

---@class MomentumIconPart : MomentumDecorated
---@field texture Texture
---@field cooldown Cooldown swipe
---@field textLayer Frame holds the time text above the swipe
---@field timeText FontString
---@field endTime number|nil end of the time shown (nil = no time text)

---@class MomentumIcon : Frame
---@field mainPart MomentumIconPart
---@field texture Texture the main part's texture
---@field cooldown Cooldown the main part's swipe
---@field candidateParts MomentumIconPart[] one complete icon per possible combo point count
---@field stackLayer Frame holds the stack count
---@field stackText FontString
---@field procPulse AnimationGroup|nil

---@class MomentumRowStats
---@field iconsShown integer
---@field aurasRead integer|nil nil while the game hides them
---@field procIcons integer
---@field cooldownIcons integer
---@field textureFailures integer textures the client refused
---@field lastIconError string|nil last error while drawing an icon

---@class MomentumRow
---@field frame MomentumMovable
---@field icons MomentumIcon[]
---@field stats MomentumRowStats
local Row = { icons = {}, stats = { iconsShown = 0, procIcons = 0, cooldownIcons = 0, textureFailures = 0 } }
Momentum.Row = Row

local icons, stats = Row.icons, Row.stats
local needsRebuild = true

local frame = CreateFrame("Frame", "MomentumIcons", UIParent) --[[@as MomentumMovable]]
frame:SetFrameLevel(Look.LEVEL_ICON_ROW)
Row.frame = frame

Look.MakeMovable(frame, "Icons", function() return Momentum.settings.iconRow end)

---Marks the row for a rebuild on the next frame.
function Row.Invalidate()
  needsRebuild = true
end

---Remaining time as text. Same thresholds as Blizzard's SecondsToTimeAbbrev: seconds below 1.5
---minutes (rounded down like the buff frame), then minutes and from 1.5 hours hours (rounded up).
---TENTHS_BELOW_10 shows tenths below 10 seconds.
---@param secondsLeft number
---@param format MomentumTimeFormat
---@return string
function Row.TimeText(secondsLeft, format)
  if format == "HIDDEN" or secondsLeft <= 0 then return "" end
  if secondsLeft >= 5400 then return string.format("%dh", ceil(secondsLeft / 3600)) end
  if secondsLeft >= 90 then return string.format("%dm", ceil(secondsLeft / 60)) end
  if format == "TENTHS_BELOW_10" and secondsLeft < 10 then
    return string.format("%.1f", floor(secondsLeft * 10) / 10)
  end
  return string.format("%d", floor(secondsLeft))
end
local timeText = Row.TimeText

---Font, crop and decoration of one icon part.
---@param part MomentumIconPart
---@param rowSettings MomentumIconRowSettings
local function styleIconPart(part, rowSettings)
  part.timeText:SetFont(STANDARD_TEXT_FONT, rowSettings.timeFontSize or 14, "OUTLINE")
  if rowSettings.cropEdges then
    part.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  else
    part.texture:SetTexCoord(0, 1, 0, 1)
  end
  Look.ApplyDecoration(part, rowSettings.border, rowSettings.glow)
end

---Creates an icon part: texture, cooldown swipe and time text.
---@param parent Frame
---@return MomentumIconPart
local function newIconPart(parent)
  local part = CreateFrame("Frame", nil, parent) --[[@as MomentumIconPart]]
  part:SetAllPoints()
  part.texture = part:CreateTexture(nil, "ARTWORK")
  part.texture:SetAllPoints()
  part.cooldown = CreateFrame("Cooldown", nil, part, "CooldownFrameTemplate") --[[@as Cooldown]]
  part.cooldown:SetAllPoints()
  part.cooldown:SetReverse(true)
  part.cooldown:SetDrawEdge(false)
  -- the Cooldown frame's own numbers round up (11.2 s reads "12"), Blizzard's buff frame rounds down:
  -- so the time of buffs is written by Momentum itself
  part.cooldown:SetHideCountdownNumbers(true)
  part.textLayer = CreateFrame("Frame", nil, part)
  part.textLayer:SetAllPoints()
  part.textLayer:SetFrameLevel(part.cooldown:GetFrameLevel() + 2)
  part.timeText = part.textLayer:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  part.timeText:SetPoint("CENTER")
  return part
end

---Creates an icon of the row.
---@return MomentumIcon
local function newIcon()
  local icon = CreateFrame("Frame", nil, frame) --[[@as MomentumIcon]]
  icon.mainPart = newIconPart(icon)
  icon.texture, icon.cooldown = icon.mainPart.texture, icon.mainPart.cooldown
  icon.candidateParts = {}
  icon.stackLayer = CreateFrame("Frame", nil, icon)
  icon.stackLayer:SetAllPoints()
  icon.stackLayer:SetFrameLevel(icon.cooldown:GetFrameLevel() + 4)
  icon.stackText = icon.stackLayer:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  icon.stackText:SetPoint("BOTTOMRIGHT", -1, 1)
  icon:Hide()
  return icon
end

---Candidate part of an icon for a number of combo points (created on first use).
---@param icon MomentumIcon
---@param comboPoints integer
---@param rowSettings MomentumIconRowSettings
---@return MomentumIconPart
local function candidatePart(icon, comboPoints, rowSettings)
  local part = icon.candidateParts[comboPoints]
  if not part then
    part = newIconPart(icon)
    styleIconPart(part, rowSettings)
    icon.candidateParts[comboPoints] = part
  end
  return part
end

---Writes the remaining time on every visible icon (each frame).
---@param now number
local function updateTimes(now)
  local format = Momentum.settings.iconRow.timeFormat
  for _, icon in ipairs(icons) do
    if icon:IsShown() then
      local mainPart = icon.mainPart
      mainPart.timeText:SetText(mainPart.endTime and timeText(mainPart.endTime - now, format) or "")
      for _, part in pairs(icon.candidateParts) do
        part.timeText:SetText(part.endTime and timeText(part.endTime - now, format) or "")
      end
    end
  end
end

---Shows the main part (and hides the candidates) or hides it.
---@param icon MomentumIcon
---@param shown boolean
local function showMainPart(icon, shown)
  if shown then
    icon.mainPart:Show()
    for _, part in pairs(icon.candidateParts) do part:Hide() end
  else
    icon.mainPart:Hide()
  end
end

---Sets a texture; counts the files the client refuses.
---@param texture Texture
---@param file number|string|nil
local function setTexture(texture, file)
  if not pcall(texture.SetTexture, texture, file) then stats.textureFailures = stats.textureFailures + 1 end
end

---Starts or stops the pulse of a usable proc.
---@param icon MomentumIcon
---@param pulsing boolean
local function setProcPulse(icon, pulsing)
  if pulsing then
    icon.procPulse = icon.procPulse or Look.NewPulse(icon.mainPart, 0.45, 0.45)
    if not icon.procPulse:IsPlaying() then icon.procPulse:Play() end
  elseif icon.procPulse then
    icon.procPulse:Stop()
    icon.mainPart:SetAlpha(1)
  end
end

---Draws a proc or a cooldown.
---@param icon MomentumIcon
---@param item MomentumRowItem
---@param rowSettings MomentumIconRowSettings
local function drawSpell(icon, item, rowSettings)
  showMainPart(icon, true)
  icon.stackText:SetText("")
  setTexture(icon.texture, item.icon)
  icon.mainPart.endTime = nil
  if item.isCooldown then
    -- like an action button: dark swipe that shrinks; the time is the Cooldown frame's own text,
    -- because the cooldown's numbers are secret in combat (Blizzard's action bars show the same text)
    icon.cooldown:SetReverse(false)
    icon.cooldown:SetDrawSwipe(true)
    icon.cooldown:SetHideCountdownNumbers(rowSettings.timeFormat == "HIDDEN")
    local spellID = item.spellID
    if not (spellID and Spells.ShowCooldown(icon.cooldown, spellID)) then icon.cooldown:Clear() end
    return
  end
  icon.texture:SetDesaturated(item.notEnoughPower and true or false) -- usable, but not enough energy/rage yet
  if item.startTime and item.duration then
    icon.cooldown:SetDrawSwipe(rowSettings.expirySwipe)
    icon.cooldown:SetCooldown(item.startTime, item.duration)
    icon.mainPart.endTime = item.startTime + item.duration
  else
    icon.cooldown:Clear()
  end
  setProcPulse(icon, rowSettings.pulseUsableProcs and not item.notEnoughPower)
end

---Draws a buff clock whose combo points were secret: one candidate per count, the hidden count
---picks the visible one.
---@param icon MomentumIcon
---@param clock MomentumClock
---@param rowSettings MomentumIconRowSettings
---@param now number
local function drawCandidates(icon, clock, rowSettings, now)
  local candidates = clock.candidates
  ---@cast candidates -nil
  icon.stackText:SetText("")
  showMainPart(icon, false)
  for comboPoints, candidate in ipairs(candidates) do
    local part = candidatePart(icon, comboPoints, rowSettings)
    if now < clock.startTime + candidate.duration then
      setTexture(part.texture, clock.icon)
      part.cooldown:SetDrawSwipe(rowSettings.expirySwipe)
      part.cooldown:SetCooldown(clock.startTime, candidate.duration)
      part.endTime = clock.startTime + candidate.duration
      part:SetAlpha(candidate.alpha)
      part:Show()
    else
      part:Hide()
    end
  end
  for comboPoints = #candidates + 1, #icon.candidateParts do icon.candidateParts[comboPoints]:Hide() end
end

---Draws one item of the row.
---@param icon MomentumIcon
---@param item MomentumRowItem
---@param rowSettings MomentumIconRowSettings
---@param now number
local function drawItem(icon, item, rowSettings, now)
  -- every kind of item starts from the same state
  icon.cooldown:SetReverse(true)
  icon.cooldown:SetHideCountdownNumbers(true)
  icon.texture:SetDesaturated(false)
  setProcPulse(icon, false)

  if item.spellName then
    drawSpell(icon, item, rowSettings)
    return
  end
  local clock = item.clock
  if clock and clock.candidates then
    drawCandidates(icon, clock, rowSettings, now)
    return
  end
  showMainPart(icon, true)
  icon.cooldown:SetDrawSwipe(rowSettings.expirySwipe)
  icon.stackText:SetText("")
  if clock then
    setTexture(icon.texture, clock.icon)
    icon.cooldown:SetCooldown(clock.startTime, clock.duration)
    icon.mainPart.endTime = clock.startTime + clock.duration
    return
  end
  setTexture(icon.texture, item.icon)
  if (item.duration or 0) > 0 and item.expirationTime then
    icon.cooldown:SetCooldown(item.expirationTime - item.duration, item.duration)
    icon.mainPart.endTime = item.expirationTime
  else
    icon.cooldown:Clear()
    icon.mainPart.endTime = nil
  end
  if (item.stacks or 0) > 1 then icon.stackText:SetText(tostring(item.stacks)) end
end

---Size and position of the row and the style of its icons.
function Row.Layout()
  local rowSettings = Momentum.settings.iconRow
  local iconCount = rowSettings.maxIcons
  frame:SetSize(max(1, iconCount * (rowSettings.iconSize + rowSettings.spacing) - rowSettings.spacing),
    rowSettings.iconSize)
  Look.ApplyPosition(frame, rowSettings)
  for iconIndex = 1, iconCount do
    icons[iconIndex] = icons[iconIndex] or newIcon()
    local icon = icons[iconIndex]
    icon:SetSize(rowSettings.iconSize, rowSettings.iconSize)
    icon.stackText:SetFont(STANDARD_TEXT_FONT, rowSettings.stackFontSize, "OUTLINE")
    styleIconPart(icon.mainPart, rowSettings)
    for _, part in pairs(icon.candidateParts) do styleIconPart(part, rowSettings) end
  end
  for iconIndex = iconCount + 1, #icons do icons[iconIndex]:Hide() end
  needsRebuild = true
end

---Left edge of the first icon for a number of icons.
---@param rowSettings MomentumIconRowSettings
---@param iconCount integer
---@return number
local function firstIconOffset(rowSettings, iconCount)
  local usedWidth = iconCount * (rowSettings.iconSize + rowSettings.spacing) - rowSettings.spacing
  if rowSettings.growDirection == "LEFT" then return frame:GetWidth() - usedWidth end
  if rowSettings.growDirection == "RIGHT" then return 0 end
  return (frame:GetWidth() - usedWidth) / 2
end

---Rebuilds the row: procs, buffs and clocks, cooldowns.
function Row.Refresh()
  needsRebuild = false
  local rowSettings = Momentum.settings.iconRow
  if not rowSettings.enabled then frame:Hide() return end
  frame:Show()

  local now = GetTime()
  local buffItems, aurasRead = Buffs.Items(now, rowSettings)
  local procItems, cooldownItems = Spells.Items(now, rowSettings)
  local items = {}
  for _, item in ipairs(procItems) do items[#items + 1] = item end
  for _, item in ipairs(buffItems) do items[#items + 1] = item end
  for _, item in ipairs(cooldownItems) do items[#items + 1] = item end

  local shownCount = min(#items, rowSettings.maxIcons)
  local firstOffset = firstIconOffset(rowSettings, shownCount)
  for iconIndex = 1, rowSettings.maxIcons do
    local icon = icons[iconIndex]
    if icon then
      if iconIndex <= shownCount then
        icon:ClearAllPoints()
        icon:SetPoint("LEFT", frame, "LEFT", firstOffset + (iconIndex - 1) * (rowSettings.iconSize + rowSettings.spacing), 0)
        local success, message = pcall(drawItem, icon, items[iconIndex], rowSettings, now)
        if not success then stats.lastIconError = tostring(message) end
        icon:Show()
      else
        icon:Hide()
      end
    end
  end
  stats.iconsShown, stats.aurasRead, stats.procIcons, stats.cooldownIcons =
    shownCount, aurasRead, #procItems, #cooldownItems
end

---Per-frame step: rebuild when needed, then the times.
---@param now number
local function updateRow(now)
  if needsRebuild then Momentum.Safe("icon row rebuild", Row.Refresh) end
  updateTimes(now)
end

Momentum.OnEveryFrame("icon row", updateRow)
