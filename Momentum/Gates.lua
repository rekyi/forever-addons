-- Gates.lua: thresholds that work on secret values.
--
-- A gate maps a fraction (0..1) of a power type to an alpha. The client evaluates the gate itself
-- (UnitPowerPercent with a curve) and returns a number that may be secret; that number only ever goes
-- to SetAlpha, which accepts secret values. So a threshold works in combat without the addon ever
-- reading the power value.

---@type Momentum
local Momentum = select(2, ...)
local isSecret = Momentum.Util.isSecret

local max, ipairs, pcall, select, type = math.max, ipairs, pcall, select, type

---@class MomentumGates
local Gates = {}
Momentum.Gates = Gates

---@class MomentumGatePoint
---@field fraction number position 0..1 of the maximum power
---@field alpha number

---@class MomentumGate
---@field points MomentumGatePoint[] with increasing fraction (also used for the evaluation in Lua)
---@field curve table|nil curve object of the client
---@field curveKind "number"|"colour"|nil which curve type the client accepted

-- Width of the ramp that stands in for a hard step. Steps are built as steep linear ramps instead of
-- the Step curve type, so the result does not depend on which way the client snaps a step.
Gates.RAMP_WIDTH = 0.0005

---A gate point.
---@param fraction number
---@param alpha number
---@return MomentumGatePoint
function Gates.Point(fraction, alpha)
  return { fraction = fraction, alpha = alpha }
end
local Point = Gates.Point

---Builds a gate from points.
---@param points MomentumGatePoint[] with increasing fraction
---@param hardSteps boolean switch hard at each point (true) or blend linearly between them (false)
---@return MomentumGate
function Gates.Build(points, hardSteps)
  local curvePoints = points
  if hardSteps then
    curvePoints = {}
    for index, point in ipairs(points) do
      if index > 1 then
        local rampStart = max(point.fraction - Gates.RAMP_WIDTH, curvePoints[#curvePoints].fraction + 0.00001)
        curvePoints[#curvePoints + 1] = Point(rampStart, points[index - 1].alpha)
      end
      curvePoints[#curvePoints + 1] = point
    end
  end
  ---@type MomentumGate
  local gate = { points = curvePoints }
  local CurveUtil = C_CurveUtil
  local CurveType = Enum and Enum.LuaCurveType
  if CurveUtil and CurveUtil.CreateCurve then
    local success, curve = pcall(function()
      local newCurve = CurveUtil.CreateCurve()
      if CurveType and CurveType.Linear then newCurve:SetType(CurveType.Linear) end
      for _, point in ipairs(curvePoints) do newCurve:AddPoint(point.fraction, point.alpha) end
      return newCurve
    end)
    if success and curve then gate.curve, gate.curveKind = curve, "number" end
  end
  if not gate.curve and CurveUtil and CurveUtil.CreateColorCurve and CreateColor then
    local success, curve = pcall(function()
      local newCurve = CurveUtil.CreateColorCurve()
      if CurveType and CurveType.Linear then newCurve:SetType(CurveType.Linear) end
      for _, point in ipairs(curvePoints) do newCurve:AddPoint(point.fraction, CreateColor(1, 1, 1, point.alpha)) end
      return newCurve
    end)
    if success and curve then gate.curve, gate.curveKind = curve, "colour" end
  end
  return gate
end

---Evaluates a gate in plain Lua (only while the power value is readable).
---@param gate MomentumGate
---@param fraction number 0..1
---@return number alpha
function Gates.Evaluate(gate, fraction)
  local points = gate.points
  if fraction <= points[1].fraction then return points[1].alpha end
  for index = 2, #points do
    local before, after = points[index - 1], points[index]
    if fraction < after.fraction then
      return before.alpha + (after.alpha - before.alpha) * (fraction - before.fraction) / (after.fraction - before.fraction)
    end
  end
  return points[#points].alpha
end

---pcall results with the number of returned values in front.
---@param success boolean
---@param ... any
---@return boolean success, integer count, any ...
local function withCount(success, ...)
  return success, select("#", ...), ...
end

---Lets the client put the player's power of one type through a gate.
---@param gate MomentumGate
---@param powerType number Enum.PowerType
---@return number alpha possibly secret: only for SetAlpha (0 if not found)
---@return boolean found the client answered
function Gates.ClientAlpha(gate, powerType)
  if not (gate.curve and UnitPowerPercent) then return 0, false end
  local success, count, result = withCount(pcall(UnitPowerPercent, "player", powerType, false, gate.curve))
  if not success or count == 0 then return 0, false end
  if isSecret(result) then return result, true end
  if type(result) == "number" then return result, true end
  if type(result) == "table" and result.GetRGBA then
    local _, _, _, alpha = result:GetRGBA()
    return alpha, true -- may be secret: no test on it
  end
  return 0, false
end
