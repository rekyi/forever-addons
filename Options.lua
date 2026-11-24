-- Options.lua: the options window (/mom).
--
-- Every page is laid out in three columns of fixed width. Widgets stack downwards in their column and
-- every text gets a fixed width, so nothing can run into a neighbour: a text that is too long is cut
-- by the client instead of overlapping. Each placed widget is recorded in Options.layout, which the
-- tests use to check for overlaps and texts that would not fit.

---@type Momentum
local Momentum = select(2, ...)

local floor, max, min = math.floor, math.max, math.min
local ipairs, select, setmetatable, tonumber, tostring = ipairs, select, setmetatable, tonumber, tostring

---@class MomentumLayoutText
---@field text string
---@field font string font object name (decides the size)
---@field width number available for the text

---@class MomentumLayoutRect
---@field page string
---@field left number from the page's left edge
---@field top number downwards from the page's top edge (positive)
---@field width number
---@field height number
---@field kind string widget type
---@field texts MomentumLayoutText[]

---@class MomentumOptions
---@field built boolean
---@field window Frame|nil
---@field layout MomentumLayoutRect[] every placed widget (for the layout tests)
---@field pageNames string[]
---@field pageHeight number height of the tallest page
local Options = { built = false, layout = {}, pageNames = {}, pageHeight = 0 }
Momentum.Options = Options

-- Window geometry
Options.COLUMN_WIDTH = 250
Options.COLUMN_GAP = 21
Options.PAGE_WIDTH = 3 * Options.COLUMN_WIDTH + 2 * Options.COLUMN_GAP
Options.MARGIN = 14          -- window edge to page
Options.PAGE_TOP = 74        -- window top to page (title and tabs above)
Options.TAB_WIDTH = 100

local ROW_HEIGHT = 24
local ROW_GAP = 4
local HEADER_HEIGHT = 20
local SPACE_ABOVE_HEADER = 8 -- unless the header is the first row
local NOTE_LINE_HEIGHT = 13
local NUMBER_BOX_WIDTH = 56
local COLOR_BUTTON_SIZE = 22
local CHOICE_BUTTON_WIDTH = 140
local LIST_ROW_HEIGHT = 19

---@type fun()[]
local refreshers = {}

---Registers a function that shows the current settings in a widget, and runs it once.
---@param refresher fun()
local function addRefresher(refresher)
  refreshers[#refreshers + 1] = refresher
  refresher()
end

---Applies the settings after a change.
local function applySettings()
  Momentum.ApplyAll()
end

---Creates a single-line text of fixed width (a longer text is cut by the client).
---@param parent Frame
---@param text string
---@param font string font object name
---@param left number
---@param top number
---@param width number
---@param justify? "LEFT"|"CENTER"|"RIGHT"
---@return FontString
local function newLabel(parent, text, font, left, top, width, justify)
  local label = parent:CreateFontString(nil, "OVERLAY", font)
  label:SetPoint("TOPLEFT", left, top)
  label:SetWidth(width)
  label:SetJustifyH(justify or "LEFT")
  label:SetWordWrap(false)
  label:SetText(text)
  return label
end

---------------------------------------------------------------------------
-- Columns
---------------------------------------------------------------------------

---@class MomentumColumn
---@field page Frame
---@field pageName string (for the layout record)
---@field left number left edge
---@field top number top of the next row (0 or negative)
---@field width number
local Column = {}
Column.__index = Column

---A column of a page.
---@param page Frame
---@param pageName string
---@param columnNumber integer 1..3
---@return MomentumColumn
local function newColumn(page, pageName, columnNumber)
  return setmetatable({ page = page, pageName = pageName,
    left = (columnNumber - 1) * (Options.COLUMN_WIDTH + Options.COLUMN_GAP), top = 0,
    width = Options.COLUMN_WIDTH }, Column)
end

---Reserves the next row of the column and records it.
---@param height number
---@param kind string
---@param texts MomentumLayoutText[]
---@return number left
---@return number top of the row (negative)
function Column:Place(height, kind, texts)
  local left, top = self.left, self.top
  Options.layout[#Options.layout + 1] = { page = self.pageName, left = left, top = -top, width = self.width,
    height = height, kind = kind, texts = texts }
  self.top = top - height - ROW_GAP
  Options.pageHeight = max(Options.pageHeight, -top + height)
  return left, top
end

---Leaves some space.
---@param height number
function Column:Space(height)
  self.top = self.top - height
end

---A section title.
---@param text string
---@return FontString
function Column:Header(text)
  if self.top < 0 then self:Space(SPACE_ABOVE_HEADER) end
  local left, top = self:Place(HEADER_HEIGHT, "header", { { text = text, font = "GameFontNormalLarge", width = self.width } })
  return newLabel(self.page, text, "GameFontNormalLarge", left, top - 2, self.width)
end

---A note in small grey text; lines are separated by "\n".
---@param text string
function Column:Note(text)
  local lineCount = select(2, text:gsub("\n", "\n")) + 1
  local height = lineCount * NOTE_LINE_HEIGHT
  local left, top = self:Place(height, "note", { { text = text, font = "GameFontDisableSmall", width = self.width } })
  local note = self.page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", left, top)
  note:SetSize(self.width, height)
  note:SetJustifyH("LEFT")
  note:SetJustifyV("TOP")
  note:SetSpacing(NOTE_LINE_HEIGHT - 10)
  note:SetText(text)
end

---A check box.
---@param text string
---@param getValue fun(): boolean
---@param setValue fun(value: boolean)
function Column:Check(text, getValue, setValue)
  local textWidth = self.width - 28
  local left, top = self:Place(ROW_HEIGHT, "check", { { text = text, font = "GameFontHighlight", width = textWidth } })
  local checkBox = CreateFrame("CheckButton", nil, self.page, "UICheckButtonTemplate")
  checkBox:SetPoint("TOPLEFT", left, top)
  checkBox:SetSize(24, 24)
  newLabel(self.page, text, "GameFontHighlight", left + 28, top - 6, textWidth)
  checkBox:SetScript("OnClick", function(clicked)
    setValue(clicked:GetChecked() and true or false)
    applySettings()
  end)
  addRefresher(function() checkBox:SetChecked(getValue()) end)
end

---A number box: commits on Enter and when the focus leaves, Escape restores.
---@param text string
---@param getValue fun(): number
---@param setValue fun(value: number)
---@param lowest? number
---@param highest? number
function Column:Number(text, getValue, setValue, lowest, highest)
  local textWidth = self.width - NUMBER_BOX_WIDTH - 12
  local left, top = self:Place(ROW_HEIGHT, "number", { { text = text, font = "GameFontHighlight", width = textWidth } })
  newLabel(self.page, text, "GameFontHighlight", left, top - 6, textWidth)
  local numberBox = CreateFrame("EditBox", nil, self.page, "InputBoxTemplate")
  numberBox:SetSize(NUMBER_BOX_WIDTH, 20)
  numberBox:SetPoint("TOPLEFT", left + self.width - NUMBER_BOX_WIDTH, top - 2)
  numberBox:SetAutoFocus(false)
  numberBox:SetJustifyH("CENTER")
  ---Takes the typed number (kept within its limits), or shows the stored one again if it is no number.
  ---@param box EditBox
  local function commit(box)
    local typed = tonumber(box:GetText())
    if typed then
      if lowest then typed = max(lowest, typed) end
      if highest then typed = min(highest, typed) end
      if typed ~= getValue() then
        setValue(typed)
        applySettings()
      end
    end
    box:SetText(tostring(getValue()))
    box:ClearFocus()
  end
  numberBox:SetScript("OnEnterPressed", commit)
  numberBox:SetScript("OnEditFocusLost", commit) -- clicking elsewhere keeps the typed value as well
  numberBox:SetScript("OnEscapePressed", function(box)
    box:SetText(tostring(getValue()))
    box:ClearFocus()
  end)
  addRefresher(function() numberBox:SetText(tostring(getValue())) end)
end

---A colour button (with opacity).
---@param text string
---@param getColor fun(): MomentumColor the colour table (changed in place)
function Column:Color(text, getColor)
  local textWidth = self.width - COLOR_BUTTON_SIZE - 12
  local left, top = self:Place(ROW_HEIGHT, "color", { { text = text, font = "GameFontHighlight", width = textWidth } })
  newLabel(self.page, text, "GameFontHighlight", left, top - 6, textWidth)
  local button = CreateFrame("Button", nil, self.page)
  button:SetSize(COLOR_BUTTON_SIZE, COLOR_BUTTON_SIZE)
  button:SetPoint("TOPLEFT", left + self.width - COLOR_BUTTON_SIZE, top - 1)
  local edge = button:CreateTexture(nil, "BACKGROUND")
  edge:SetAllPoints()
  edge:SetColorTexture(1, 1, 1, 1)
  local swatch = button:CreateTexture(nil, "ARTWORK")
  swatch:SetPoint("TOPLEFT", 1, -1)
  swatch:SetPoint("BOTTOMRIGHT", -1, 1)
  ---Shows the stored colour on the button.
  local function paintSwatch()
    local color = getColor()
    swatch:SetColorTexture(color[1], color[2], color[3], 1)
  end
  button:SetScript("OnClick", function()
    local color = getColor()
    local before = { color[1], color[2], color[3], color[4] or 1 }
    if not (ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow) then
      Momentum.Print("colour picker not available.", true)
      return
    end
    ---Stores the colour of the picker.
    local function takePickedColor()
      local red, green, blue = ColorPickerFrame:GetColorRGB()
      local alpha = ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha() or before[4]
      color[1], color[2], color[3], color[4] = red, green, blue, alpha
      paintSwatch()
      applySettings()
    end
    ColorPickerFrame:SetupColorPickerAndShow({
      r = before[1], g = before[2], b = before[3], opacity = before[4], hasOpacity = true,
      swatchFunc = takePickedColor,
      opacityFunc = takePickedColor,
      ---Restores the colour from before the picker was opened.
      cancelFunc = function()
        color[1], color[2], color[3], color[4] = before[1], before[2], before[3], before[4]
        paintSwatch()
        applySettings()
      end,
    })
  end)
  addRefresher(paintSwatch)
end

---@class MomentumChoice
---@field value any stored value
---@field label string text on the button

---A value that cycles through choices on click.
---@param text string
---@param choices MomentumChoice[]
---@param getValue fun(): any
---@param setValue fun(value: any)
function Column:Choice(text, choices, getValue, setValue)
  local textWidth = self.width - CHOICE_BUTTON_WIDTH - 8
  local texts = { { text = text, font = "GameFontHighlight", width = textWidth } }
  for _, choice in ipairs(choices) do
    texts[#texts + 1] = { text = choice.label, font = "GameFontNormal", width = CHOICE_BUTTON_WIDTH - 16 }
  end
  local left, top = self:Place(ROW_HEIGHT, "choice", texts)
  newLabel(self.page, text, "GameFontHighlight", left, top - 6, textWidth)
  local button = CreateFrame("Button", nil, self.page, "UIPanelButtonTemplate")
  button:SetSize(CHOICE_BUTTON_WIDTH, 22)
  button:SetPoint("TOPLEFT", left + self.width - CHOICE_BUTTON_WIDTH, top - 1)
  ---Shows the current choice on the button.
  local function showChoice()
    local current = getValue()
    for _, choice in ipairs(choices) do
      if choice.value == current then
        button:SetText(choice.label)
        return
      end
    end
    button:SetText("?")
  end
  button:SetScript("OnClick", function()
    local current, position = getValue(), 1
    for index, choice in ipairs(choices) do if choice.value == current then position = index end end
    setValue(choices[(position % #choices) + 1].value)
    showChoice()
    applySettings()
  end)
  addRefresher(showChoice)
end

---A push button over the whole column width.
---@param text string
---@param onClick fun()
function Column:Button(text, onClick)
  local left, top = self:Place(ROW_HEIGHT, "button", { { text = text, font = "GameFontNormal", width = self.width - 20 } })
  local button = CreateFrame("Button", nil, self.page, "UIPanelButtonTemplate")
  button:SetSize(self.width, 22)
  button:SetPoint("TOPLEFT", left, top - 1)
  button:SetText(text)
  button:SetScript("OnClick", onClick)
end

---A free text field (e.g. a texture path) below its label; commits on Enter.
---@param text string
---@param getValue fun(): string|nil
---@param setValue fun(value: string)
function Column:TextInput(text, getValue, setValue)
  local left, top = self:Place(ROW_HEIGHT + 18, "text", { { text = text, font = "GameFontHighlight", width = self.width } })
  newLabel(self.page, text, "GameFontHighlight", left, top - 2, self.width)
  local textBox = CreateFrame("EditBox", nil, self.page, "InputBoxTemplate")
  textBox:SetSize(self.width - 8, 20)
  textBox:SetPoint("TOPLEFT", left + 6, top - 20)
  textBox:SetAutoFocus(false)
  textBox:SetScript("OnEnterPressed", function(box)
    setValue(box:GetText())
    applySettings()
    box:ClearFocus()
  end)
  textBox:SetScript("OnEditFocusLost", function(box) box:SetText(getValue() or "") end)
  textBox:SetScript("OnEscapePressed", function(box)
    box:SetText(getValue() or "")
    box:ClearFocus()
  end)
  addRefresher(function() textBox:SetText(getValue() or "") end)
end

---A list of spell names: input box with "Add", one row per entry with a remove button.
---The mouse wheel scrolls lists that are longer than the rows.
---@param title string
---@param getList fun(): string[]
---@param visibleRows integer
function Column:List(title, getList, visibleRows)
  local height = 18 + 26 + visibleRows * LIST_ROW_HEIGHT
  local left, top = self:Place(height, "list", { { text = title .. " (99)", font = "GameFontNormal", width = self.width } })
  local heading = newLabel(self.page, title, "GameFontNormal", left, top - 2, self.width)
  local inputBox = CreateFrame("EditBox", nil, self.page, "InputBoxTemplate")
  inputBox:SetSize(self.width - 86, 20)
  inputBox:SetPoint("TOPLEFT", left + 6, top - 20)
  inputBox:SetAutoFocus(false)
  ---Adds the typed spell to the list.
  local function addTypedSpell()
    local typed = inputBox:GetText()
    if typed and typed ~= "" then Momentum.ListAdd(getList(), typed) end
    inputBox:SetText("")
    inputBox:ClearFocus()
  end
  inputBox:SetScript("OnEnterPressed", addTypedSpell)
  inputBox:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
  local addButton = CreateFrame("Button", nil, self.page, "UIPanelButtonTemplate")
  addButton:SetSize(70, 22)
  addButton:SetPoint("TOPLEFT", left + self.width - 70, top - 19)
  addButton:SetText("Add")
  addButton:SetScript("OnClick", addTypedSpell)

  local rowArea = CreateFrame("Frame", nil, self.page)
  rowArea:SetPoint("TOPLEFT", left, top - 44)
  rowArea:SetSize(self.width, visibleRows * LIST_ROW_HEIGHT)
  local scrollOffset = 0
  local rows = {}
  for rowNumber = 1, visibleRows do
    local row = CreateFrame("Frame", nil, rowArea)
    row:SetSize(self.width, LIST_ROW_HEIGHT - 1)
    row:SetPoint("TOPLEFT", 0, -(rowNumber - 1) * LIST_ROW_HEIGHT)
    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, (rowNumber % 2 == 0) and 0.04 or 0)
    local nameText = newLabel(row, "", "GameFontHighlight", 4, -3, self.width - 30)
    local removeButton = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    removeButton:SetSize(20, 20)
    removeButton:SetPoint("RIGHT", 0, 0)
    rows[rowNumber] = { frame = row, nameText = nameText, removeButton = removeButton }
    row:Hide()
  end
  ---Shows the visible part of the list.
  local function showEntries()
    local list = getList()
    scrollOffset = max(0, min(scrollOffset, #list - visibleRows))
    heading:SetText(#list > 0 and (title .. " (" .. #list .. ")") or title)
    for rowNumber = 1, visibleRows do
      local spellName = list[rowNumber + scrollOffset]
      local row = rows[rowNumber]
      if spellName then
        row.nameText:SetText(spellName)
        row.removeButton:SetScript("OnClick", function() Momentum.ListRemove(list, spellName) end)
        row.frame:Show()
      else
        row.frame:Hide()
      end
    end
  end
  rowArea:EnableMouseWheel(true)
  rowArea:SetScript("OnMouseWheel", function(_, direction)
    scrollOffset = scrollOffset - direction
    showEntries()
  end)
  addRefresher(showEntries)
end

---------------------------------------------------------------------------
-- Choices
---------------------------------------------------------------------------

---Builds a list of choices from { value, label } pairs.
---@param pairsList any[][]
---@return MomentumChoice[]
local function choicesOf(pairsList)
  local choices = {}
  for _, pair in ipairs(pairsList) do choices[#choices + 1] = { value = pair[1], label = pair[2] } end
  return choices
end

local TEXTURES = choicesOf({
  { "Interface\\Buttons\\WHITE8X8", "Flat" },
  { "Interface\\TargetingFrame\\UI-StatusBar", "Blizzard" },
  { "Interface\\RaidFrame\\Raid-Bar-Hp-Fill", "Raid" },
  { "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar", "Skills" },
})
local DIRECTIONS = choicesOf({ { "HORIZONTAL", "horizontal" }, { "VERTICAL", "vertical" } })
local TEXT_POSITIONS = choicesOf({ { "LEFT", "left" }, { "CENTER", "centre" }, { "RIGHT", "right" } })
local FONTS = choicesOf({
  { "Fonts\\FRIZQT__.TTF", "Friz Quadrata" },
  { "Fonts\\ARIALN.TTF", "Arial Narrow" },
  { "Fonts\\skurri.ttf", "Skurri" },
  { "Fonts\\MORPHEUS.ttf", "Morpheus" },
})
local OUTLINES = choicesOf({ { "NONE", "none" }, { "OUTLINE", "thin" }, { "THICKOUTLINE", "thick" } })

---------------------------------------------------------------------------
-- Blocks shared by several pages
---------------------------------------------------------------------------

---Border settings.
---@param column MomentumColumn
---@param getBorder fun(): MomentumBorderSettings
local function borderBlock(column, getBorder)
  column:Header("Border")
  column:Check("Border", function() return getBorder().enabled end, function(value) getBorder().enabled = value end)
  column:Color("Border colour", function() return getBorder().color end)
  column:Number("Thickness", function() return getBorder().thickness end,
    function(value) getBorder().thickness = floor(value) end, 1, 12)
  column:Number("Gap", function() return getBorder().gap end, function(value) getBorder().gap = floor(value) end, 0, 20)
end

---Glow settings.
---@param column MomentumColumn
---@param getGlow fun(): MomentumGlowSettings
---@param maximumWidth number
local function glowBlock(column, getGlow, maximumWidth)
  column:Header("Glow")
  column:Check("Glow", function() return getGlow().enabled end, function(value) getGlow().enabled = value end)
  column:Color("Colour / strength", function() return getGlow().color end)
  column:Number("Size", function() return getGlow().width end,
    function(value) getGlow().width = floor(value) end, 1, maximumWidth)
  column:Check("Pulse", function() return getGlow().pulsing end, function(value) getGlow().pulsing = value end)
end

---Look of a bar: fill and border in one column, glow, text and details in another.
---@param fillColumn MomentumColumn
---@param detailColumn MomentumColumn
---@param getBar fun(): MomentumBarSettings
local function barLookBlocks(fillColumn, detailColumn, getBar)
  fillColumn:Header("Fill")
  fillColumn:Choice("Texture", TEXTURES, function() return getBar().texture end,
    function(value) getBar().texture = value end)
  fillColumn:TextInput("Custom texture path", function() return getBar().texture end,
    function(value) getBar().texture = (value ~= "" and value) or Momentum.WHITE_TEXTURE end)
  fillColumn:Check("Gradient", function() return getBar().gradient.enabled end,
    function(value) getBar().gradient.enabled = value end)
  fillColumn:Color("Gradient colour 2", function() return getBar().gradient.endColor end)
  fillColumn:Choice("Direction", DIRECTIONS, function() return getBar().gradient.direction end,
    function(value) getBar().gradient.direction = value end)
  fillColumn:Check("Spark", function() return getBar().spark.enabled end,
    function(value) getBar().spark.enabled = value end)
  fillColumn:Number("Spark width", function() return getBar().spark.width end,
    function(value) getBar().spark.width = value end, 2, 60)
  borderBlock(fillColumn, function() return getBar().border end)

  glowBlock(detailColumn, function() return getBar().glow end, 12)
  detailColumn:Header("Text")
  detailColumn:Color("Text colour", function() return getBar().textColor end)
  detailColumn:Choice("Position", TEXT_POSITIONS, function() return getBar().textPosition end,
    function(value) getBar().textPosition = value end)
  detailColumn:Choice("Outline", OUTLINES, function() return getBar().fontOutline end,
    function(value) getBar().fontOutline = value end)
  detailColumn:Choice("Font", FONTS, function() return getBar().fontFile end,
    function(value) getBar().fontFile = value end)
  detailColumn:Header("Details")
  detailColumn:Check("Bright end of the fill", function() return getBar().fillEnd.enabled end,
    function(value) getBar().fillEnd.enabled = value end)
  detailColumn:Number("End strength", function() return getBar().fillEnd.strength end,
    function(value) getBar().fillEnd.strength = value end, 0, 1)
  detailColumn:Check("Light lines top / bottom", function() return getBar().bevelLines.enabled end,
    function(value) getBar().bevelLines.enabled = value end)
  detailColumn:Check("Background from fill colour", function() return getBar().backgroundFromFill end,
    function(value) getBar().backgroundFromFill = value end)
  detailColumn:Number("Background brightness", function() return getBar().backgroundBrightness end,
    function(value) getBar().backgroundBrightness = value end, 0, 1)
end

---Size and position of a bar.
---@param column MomentumColumn
---@param getBar fun(): MomentumBarSettings
local function barSizeBlock(column, getBar)
  column:Number("Width", function() return getBar().width end, function(value) getBar().width = value end, 20, 1000)
  column:Number("Height", function() return getBar().height end, function(value) getBar().height = value end, 4, 200)
  column:Number("Font size", function() return getBar().fontSize end,
    function(value) getBar().fontSize = value end, 6, 40)
  column:Number("Position X", function() return getBar().positionX end, function(value) getBar().positionX = value end)
  column:Number("Position Y", function() return getBar().positionY end, function(value) getBar().positionY = value end)
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

---Page "Resource": basics, size and look of the resource bar.
---@param basicsColumn MomentumColumn
---@param fillColumn MomentumColumn
---@param detailColumn MomentumColumn
local function resourcePage(basicsColumn, fillColumn, detailColumn)
  ---Settings shown on this page.
  ---@return MomentumResourceBarSettings
  local function bar() return Momentum.settings.resourceBar end
  basicsColumn:Header("Basics")
  basicsColumn:Check("Enabled", function() return bar().enabled end, function(value) bar().enabled = value end)
  basicsColumn:Check("Colour by resource type", function() return bar().colorByPowerType end,
    function(value) bar().colorByPowerType = value end)
  basicsColumn:Check("Show value", function() return bar().showText end, function(value) bar().showText = value end)
  basicsColumn:Check("Only show in combat", function() return bar().onlyInCombat end,
    function(value) bar().onlyInCombat = value end)
  basicsColumn:Color("Fill colour", function() return bar().fillColor end)
  basicsColumn:Color("Background", function() return bar().backgroundColor end)
  barSizeBlock(basicsColumn, bar)
  basicsColumn:Note("Move with the mouse: General > Unlock.")
  barLookBlocks(fillColumn, detailColumn, bar)
end

---Page "Thresholds": colour change and pulse of the current power type.
---@param basicsColumn MomentumColumn
---@param colorColumn MomentumColumn
---@param pulseColumn MomentumColumn
local function thresholdPage(basicsColumn, colorColumn, pulseColumn)
  ---Settings shown on this page.
  ---@return MomentumThresholdSettings
  local function thresholds() return (Momentum.Resource.GetThresholds()) end
  local heading = basicsColumn:Header("Thresholds: Runic Power")
  addRefresher(function()
    local _, powerToken = Momentum.Resource.GetThresholds()
    heading:SetText("Thresholds: " .. tostring(_G[powerToken] or powerToken))
  end)
  basicsColumn:Note("Kept per resource type. Druids: change\nform to edit rage, energy or mana.")
  basicsColumn:Choice("Values in", choicesOf({ { false, "points" }, { true, "% of maximum" } }),
    function() return thresholds().valuesInPercent end, function(value) thresholds().valuesInPercent = value end)
  basicsColumn:Button("Preview (5 s)", function() Momentum.Resource.Preview(5) end)
  basicsColumn:Note("Example: warrior rage pulses red from\n80, rogue energy turns green from 50.\n\n"
    .. "\"Fade over\" blends the colour in over\nthat many points below the threshold.\n\n"
    .. "Works in combat: the game checks the\nthreshold itself, the addon never reads\nthe number.")

  ---Colour change settings.
  ---@return MomentumColorChangeSettings
  local function colorChange() return thresholds().colorChange end
  colorColumn:Header("Colour change")
  colorColumn:Check("Recolour from the threshold", function() return colorChange().enabled end,
    function(value) colorChange().enabled = value end)
  colorColumn:Number("Threshold", function() return colorChange().threshold end,
    function(value) colorChange().threshold = value end, 0, 100000)
  colorColumn:Color("Colour", function() return colorChange().color end)
  colorColumn:Color("Colour 2 (gradient)", function() return colorChange().endColor end)
  colorColumn:Number("Fade over", function() return colorChange().fadeRange end,
    function(value) colorChange().fadeRange = value end, 0, 1000)
  colorColumn:Check("Only up to", function() return colorChange().upTo.enabled end,
    function(value) colorChange().upTo.enabled = value end)
  colorColumn:Number("Up to", function() return colorChange().upTo.limit end,
    function(value) colorChange().upTo.limit = value end, 0, 100000)

  ---Pulse settings.
  ---@return MomentumThresholdPulseSettings
  local function pulse() return thresholds().pulse end
  pulseColumn:Header("Pulse")
  pulseColumn:Check("Pulse from the threshold", function() return pulse().enabled end,
    function(value) pulse().enabled = value end)
  pulseColumn:Number("Threshold", function() return pulse().threshold end,
    function(value) pulse().threshold = value end, 0, 100000)
  pulseColumn:Color("Colour / strength", function() return pulse().color end)
  pulseColumn:Number("Size", function() return pulse().width end,
    function(value) pulse().width = floor(value) end, 1, 16)
  pulseColumn:Number("Speed (seconds)", function() return pulse().fadeSeconds end,
    function(value) pulse().fadeSeconds = value end, 0.1, 3)
end

---Page "Swing": basics, size and look of the swing bar.
---@param basicsColumn MomentumColumn
---@param fillColumn MomentumColumn
---@param detailColumn MomentumColumn
local function swingPage(basicsColumn, fillColumn, detailColumn)
  ---Settings shown on this page.
  ---@return MomentumSwingBarSettings
  local function bar() return Momentum.settings.swingBar end
  basicsColumn:Header("Basics")
  basicsColumn:Check("Enabled", function() return bar().enabled end, function(value) bar().enabled = value end)
  basicsColumn:Check("Show remaining time", function() return bar().showText end,
    function(value) bar().showText = value end)
  basicsColumn:Check("Bar empties", function() return bar().empties end, function(value) bar().empties = value end)
  basicsColumn:Check("Slice and Dice haste", function() return bar().hasteCorrection end,
    function(value) bar().hasteCorrection = value end)
  basicsColumn:Choice("When idle", choicesOf({ { "FULL", "full bar" }, { "EMPTY", "empty bar" }, { "HIDE", "hidden" } }),
    function() return bar().idleLook end, function(value) bar().idleLook = value end)
  basicsColumn:Choice("Hand", choicesOf({ { "MAIN", "main hand" }, { "OFF", "off hand" }, { "RANGED", "ranged" } }),
    function() return bar().hand end, function(value) bar().hand = value end)
  basicsColumn:Color("Colour", function() return bar().fillColor end)
  basicsColumn:Color("Background", function() return bar().backgroundColor end)
  barSizeBlock(basicsColumn, bar)
  basicsColumn:Note("Runs on the game's own swing event.\nSlice and Dice haste: casting it speeds\n"
    .. "up the swing already in flight.")
  barLookBlocks(fillColumn, detailColumn, bar)
end

---Page "Icons": the icon row.
---@param basicsColumn MomentumColumn
---@param iconColumn MomentumColumn
---@param glowColumn MomentumColumn
local function iconPage(basicsColumn, iconColumn, glowColumn)
  ---Settings shown on this page.
  ---@return MomentumIconRowSettings
  local function row() return Momentum.settings.iconRow end
  basicsColumn:Header("Basics")
  basicsColumn:Check("Enabled", function() return row().enabled end, function(value) row().enabled = value end)
  basicsColumn:Choice("Buffs",
    choicesOf({ { "ALL_EXCEPT_BLACKLIST", "all but blacklist" }, { "WHITELIST_ONLY", "whitelist only" } }),
    function() return row().buffFilter end, function(value) row().buffFilter = value end)
  basicsColumn:Choice("Grow",
    choicesOf({ { "CENTER", "centred" }, { "RIGHT", "to the right" }, { "LEFT", "to the left" } }),
    function() return row().growDirection end, function(value) row().growDirection = value end)
  basicsColumn:Check("Expiry swipe", function() return row().expirySwipe end,
    function(value) row().expirySwipe = value end)
  basicsColumn:Check("Usable procs pulse", function() return row().pulseUsableProcs end,
    function(value) row().pulseUsableProcs = value end)
  basicsColumn:Number("Icon size", function() return row().iconSize end,
    function(value) row().iconSize = value end, 12, 128)
  basicsColumn:Number("Spacing", function() return row().spacing end, function(value) row().spacing = value end, 0, 40)
  basicsColumn:Number("Max icons", function() return row().maxIcons end,
    function(value) row().maxIcons = floor(value) end, 1, 16)
  basicsColumn:Number("Position X", function() return row().positionX end, function(value) row().positionX = value end)
  basicsColumn:Number("Position Y", function() return row().positionY end, function(value) row().positionY = value end)
  basicsColumn:Button("Print active buffs to chat", function() Momentum.Buffs.PrintAuras() end)
  basicsColumn:Note("(only possible out of combat)")

  iconColumn:Header("Icons")
  iconColumn:Choice("Time",
    choicesOf({ { "WHOLE_SECONDS", "whole seconds" }, { "TENTHS_BELOW_10", "tenths below 10 s" }, { "HIDDEN", "hidden" } }),
    function() return row().timeFormat end, function(value) row().timeFormat = value end)
  iconColumn:Number("Time font size", function() return row().timeFontSize end,
    function(value) row().timeFontSize = value end, 6, 40)
  iconColumn:Number("Stack font size", function() return row().stackFontSize end,
    function(value) row().stackFontSize = value end, 6, 40)
  iconColumn:Check("Crop icon edges", function() return row().cropEdges end, function(value) row().cropEdges = value end)
  borderBlock(iconColumn, function() return row().border end)

  glowBlock(glowColumn, function() return row().glow end, 8)
  glowColumn:Header("In combat")
  glowColumn:Note("The game hides buffs from addons in\ncombat. Timed buffs then run on\n"
    .. "Momentum's own clocks: carried over\nfrom before the fight and restarted by\n"
    .. "your casts. Buffs without a duration\npause until the fight is over.")
end

---Page "Lists": whitelist, blacklist, procs and cooldowns.
---@param leftColumn MomentumColumn
---@param middleColumn MomentumColumn
---@param helpColumn MomentumColumn
local function listPage(leftColumn, middleColumn, helpColumn)
  ---Settings shown on this page.
  ---@return MomentumIconRowSettings
  local function row() return Momentum.settings.iconRow end
  leftColumn:List("Buff whitelist", function() return row().whitelist end, 8)
  leftColumn:List("Procs (while usable)", function() return row().procs end, 8)
  middleColumn:List("Buff blacklist", function() return row().blacklist end, 8)
  middleColumn:List("Cooldowns (while cooling down)", function() return row().cooldowns end, 8)
  helpColumn:Header("How the lists work")
  helpColumn:Note("Whitelist: used in mode \"whitelist only\".\nBlacklist: used in mode \"all but\nblacklist\".\n\n"
    .. "Input: spell name, spell ID or spell\nlink. The name is stored, so all ranks\nmatch. "
    .. "Scroll a list with the mouse\nwheel.\n\n"
    .. "Order in the icon row:\nprocs - buffs - cooldowns.\n\n"
    .. "Procs show while the game says the\nspell is usable, with a 5 s timer after\n"
    .. "a parry or dodge where that opens it\n(Riposte, Revenge, Overpower, Mongoose\n"
    .. "Bite, Counterattack). Grey: not enough\nenergy or rage yet.\n\n"
    .. "Cooldowns show the game's own\ncooldown text, like the action bars.")
end

---Page "General": moving, tools, Blizzard's swing timer, reset.
---@param toolsColumn MomentumColumn
---@param resetColumn MomentumColumn
local function generalPage(toolsColumn, resetColumn)
  toolsColumn:Header("Position")
  toolsColumn:Button("Unlock / lock (drag to move)", function() Momentum.SetUnlocked(not Momentum.unlocked) end)
  toolsColumn:Header("Tools")
  toolsColumn:Button("Swing test (8 s)", function() Momentum.Swing.Test() end)
  toolsColumn:Button("Debug info to chat", function() Momentum.Debug() end)
  toolsColumn:Header("Blizzard's swing timer")
  toolsColumn:Button("Turn off", function() Momentum.SetBlizzardSwingTimer(false) end)
  toolsColumn:Button("Turn on", function() Momentum.SetBlizzardSwingTimer(true) end)

  resetColumn:Header("Reset")
  resetColumn:Button("Restore classic look", function() Momentum.RestoreClassicLook() end)
  resetColumn:Button("Reset this class", function() Momentum.ResetClass() end)
  resetColumn:Note("Classic look: sizes and colours of an\nolder addon, swing bar below the\n"
    .. "resource bar, energy green from 50.\n\nReset: everything of this class back to\n"
    .. "the defaults (classic look, preset\nprocs and cooldowns, nothing learned).\n\n"
    .. "Settings are stored per class: all\ncharacters of a class share them.")
end

---@type { name: string, fill: fun(first: MomentumColumn, second: MomentumColumn, third: MomentumColumn) }[]
local PAGES = {
  { name = "Resource", fill = resourcePage },
  { name = "Thresholds", fill = thresholdPage },
  { name = "Swing", fill = swingPage },
  { name = "Icons", fill = iconPage },
  { name = "Lists", fill = listPage },
  { name = "General", fill = generalPage },
}

---Builds the window (on first use).
local function buildWindow()
  local window = CreateFrame("Frame", "MomentumOptions", UIParent)
  window:SetPoint("CENTER")
  window:SetFrameStrata("DIALOG")
  window:SetMovable(true)
  window:EnableMouse(true)
  window:SetClampedToScreen(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  local background = window:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints()
  background:SetColorTexture(0.05, 0.05, 0.08, 0.94)
  local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", Options.MARGIN, -10)
  title:SetText("Momentum " .. Momentum.VERSION .. " - " .. (Momentum.playerClass or ""))
  local closeButton = CreateFrame("Button", nil, window, "UIPanelCloseButton")
  closeButton:SetPoint("TOPRIGHT", -2, -2)
  tinsert(UISpecialFrames, "MomentumOptions")
  window:SetScript("OnShow", Options.Refresh)

  wipe(Options.layout)
  wipe(Options.pageNames)
  Options.pageHeight = 0
  local pages = {}
  for pageNumber, definition in ipairs(PAGES) do
    local page = CreateFrame("Frame", nil, window)
    page:SetPoint("TOPLEFT", Options.MARGIN, -Options.PAGE_TOP)
    page:SetWidth(Options.PAGE_WIDTH)
    page:Hide()
    pages[pageNumber] = page
    Options.pageNames[pageNumber] = definition.name
    local tab = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    tab:SetSize(Options.TAB_WIDTH, 24)
    tab:SetPoint("TOPLEFT", Options.MARGIN + (pageNumber - 1) * (Options.TAB_WIDTH + 4), -40)
    tab:SetText(definition.name)
    tab:SetScript("OnClick", function()
      for otherNumber, otherPage in ipairs(pages) do otherPage:SetShown(otherNumber == pageNumber) end
    end)
    definition.fill(newColumn(page, definition.name, 1), newColumn(page, definition.name, 2),
      newColumn(page, definition.name, 3))
  end
  for _, page in ipairs(pages) do page:SetHeight(Options.pageHeight) end
  window:SetSize(Options.PAGE_WIDTH + 2 * Options.MARGIN, Options.PAGE_TOP + Options.pageHeight + Options.MARGIN)

  pages[1]:Show()
  window:Hide() -- freshly built frames are visible; Toggle opens it
  Options.window = window
  Options.built = true
end

---Shows the current settings in all widgets (no-op until the window was built).
function Options.Refresh()
  if not Options.built then return end
  for _, refresher in ipairs(refreshers) do refresher() end
end

---Opens or closes the window.
function Options.Toggle()
  if not Momentum.settings then return end
  if not Options.built then buildWindow() end
  local window = Options.window
  ---@cast window -nil
  window:SetShown(not window:IsShown())
end
