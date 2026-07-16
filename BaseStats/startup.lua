local monitor = peripheral.find("monitor")
local me = peripheral.find("me_bridge") or peripheral.find("meBridge")

if not monitor then error("No monitor found") end

monitor.setTextScale(1)
monitor.setBackgroundColor(colors.black)
monitor.clear()

local watchedItems = {
  "minecraft:iron_ingot",
  "minecraft:diamond",
  "minecraft:redstone",
}

local function findEnergyStorage()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "energy_storage") then
      return peripheral.wrap(name)
    end
  end
  return nil
end

local function findEnergyDetectors()
  local detectors = {}

  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "energyDetector") or peripheral.hasType(name, "energy_detector") then
      table.insert(detectors, peripheral.wrap(name))
    end
  end

  return detectors[1], detectors[2]
end

local fluxStorage = findEnergyStorage()
local inputDetector, outputDetector = findEnergyDetectors()

local function safeCall(obj, method, default)
  if not obj or not obj[method] then return default end
  local ok, result = pcall(obj[method])
  if ok and result ~= nil then return result end
  return default
end

local function fmt(n)
  n = tonumber(n) or 0
  local abs = math.abs(n)

  if abs >= 1000000000000 then return string.format("%.1fT", n / 1000000000000) end
  if abs >= 1000000000 then return string.format("%.1fG", n / 1000000000) end
  if abs >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if abs >= 1000 then return string.format("%.1fk", n / 1000) end

  return tostring(math.floor(n))
end

local function percent(value, max)
  value = tonumber(value) or 0
  max = tonumber(max) or 0
  if max <= 0 then return 0 end
  return math.floor((value / max) * 100)
end

local function pad(text, width)
  text = tostring(text)
  if #text > width then
    return string.sub(text, 1, width)
  end
  return text .. string.rep(" ", width - #text)
end

local function writeAt(x, y, text, color)
  local w = monitor.getSize()
  monitor.setCursorPos(x, y)
  monitor.setTextColor(color or colors.white)
  monitor.write(pad(text, w - x + 1))
end

local function drawBar(x, y, w, value, max, color)
  local p = percent(value, max)
  local filled = math.floor((p / 100) * w)

  monitor.setCursorPos(x, y)
  monitor.setTextColor(color or colors.lime)
  monitor.write(string.rep("#", filled))

  monitor.setTextColor(colors.gray)
  monitor.write(string.rep("-", w - filled))

  monitor.setTextColor(colors.white)
  monitor.write(" " .. p .. "%")
end

while true do
  local w, h = monitor.getSize()

  writeAt(1, 1, "ATM10 BASE", colors.cyan)
  writeAt(w - 7, 1, textutils.formatTime(os.time(), true), colors.lightGray)

  if fluxStorage then
    local energy = safeCall(fluxStorage, "getEnergy", 0)
    local capacity = safeCall(fluxStorage, "getEnergyCapacity", 0)

    writeAt(1, 3, "FLUX POWER", colors.lime)
    writeAt(1, 4, fmt(energy) .. " / " .. fmt(capacity) .. " FE", colors.white)
    drawBar(1, 5, w - 6, energy, capacity, colors.lime)
  else
    writeAt(1, 3, "NO FLUX STORAGE FOUND", colors.red)
    writeAt(1, 4, "Use wired modem on storage", colors.yellow)
  end

  local inputRate = safeCall(inputDetector, "getTransferRate", 0)
  local outputRate = safeCall(outputDetector, "getTransferRate", 0)

  writeAt(1, 7, "IN : " .. fmt(inputRate) .. " FE/t", colors.lime)
  writeAt(1, 8, "OUT: " .. fmt(outputRate) .. " FE/t", colors.red)

  if me then
    local meEnergy = safeCall(me, "getEnergyStorage", 0)
    local meMaxEnergy = safeCall(me, "getMaxEnergyStorage", 0)
    local meUsage = safeCall(me, "getEnergyUsage", 0)

    writeAt(1, 10, "ME POWER", colors.cyan)
    writeAt(1, 11, fmt(meEnergy) .. " / " .. fmt(meMaxEnergy) .. " AE", colors.white)
    writeAt(1, 12, "Use: " .. fmt(meUsage) .. " AE/t", colors.yellow)

    local usedItems = safeCall(me, "getUsedItemStorage", 0)
    local totalItems = safeCall(me, "getTotalItemStorage", 0)

    writeAt(1, 14, "ME STORAGE", colors.lightBlue)
    writeAt(1, 15, fmt(usedItems) .. " / " .. fmt(totalItems) .. " bytes", colors.white)
    drawBar(1, 16, w - 6, usedItems, totalItems, colors.lightBlue)

    writeAt(1, 18, "ITEMS", colors.orange)

    local y = 19
    for _, itemName in ipairs(watchedItems) do
      local amount = 0
      local label = itemName

      if me.getItem then
        local ok, item = pcall(me.getItem, { name = itemName })
        if ok and item then
          amount = item.amount or 0
          label = item.displayName or itemName
        end
      end

      writeAt(1, y, pad(label, w - 10) .. fmt(amount), colors.white)
      y = y + 1
    end
  else
    writeAt(1, 10, "NO ME BRIDGE FOUND", colors.red)
  end

  sleep(1)
end