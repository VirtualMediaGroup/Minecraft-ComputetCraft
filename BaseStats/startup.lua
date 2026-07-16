local monitor = peripheral.find("monitor")
local me = peripheral.find("me_bridge") or peripheral.find("meBridge")

if not monitor then error("No monitor found") end

monitor.setTextScale(0.5)
monitor.setBackgroundColor(colors.black)
monitor.clear()

local watchedItems = {
  "minecraft:iron_ingot",
  "minecraft:gold_ingot",
  "minecraft:diamond",
  "minecraft:redstone",
  "ae2:certus_quartz_crystal",
  "minecraft:coal",
  "minecraft:emerald",
  "minecraft:netherite_ingot",
}

local function findEnergyStorage()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "energy_storage") then
      return peripheral.wrap(name), name
    end
  end
  return nil, nil
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

  if abs >= 1000000000000 then return string.format("%.2fT", n / 1000000000000) end
  if abs >= 1000000000 then return string.format("%.2fG", n / 1000000000) end
  if abs >= 1000000 then return string.format("%.2fM", n / 1000000) end
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
  if #text > width then return string.sub(text, 1, width) end
  return text .. string.rep(" ", width - #text)
end

local function writeAt(x, y, text, color)
  local w = monitor.getSize()
  monitor.setCursorPos(x, y)
  monitor.setTextColor(color or colors.white)
  monitor.write(pad(text, w - x + 1))
end

local function drawBox(x, y, w, h, title, color)
  monitor.setTextColor(color or colors.white)

  monitor.setCursorPos(x, y)
  monitor.write("+" .. string.rep("-", w - 2) .. "+")

  for i = 1, h - 2 do
    monitor.setCursorPos(x, y + i)
    monitor.write("|" .. string.rep(" ", w - 2) .. "|")
  end

  monitor.setCursorPos(x, y + h - 1)
  monitor.write("+" .. string.rep("-", w - 2) .. "+")

  if title then
    monitor.setCursorPos(x + 2, y)
    monitor.write(" " .. title .. " ")
  end
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

local function drawStaticLayout()
  local w, h = monitor.getSize()

  monitor.clear()
  writeAt(2, 1, "ATM10 BASE DASHBOARD", colors.cyan)

  drawBox(1, 3, w, 6, "ME POWER", colors.cyan)
  drawBox(1, 10, w, 6, "FLUX POWER", colors.lime)
  drawBox(1, 17, w, 6, "ME STORAGE", colors.lightBlue)
  drawBox(1, 24, w, 5, "CRAFTING CPUs", colors.magenta)
  drawBox(1, 30, w, math.max(6, h - 30), "WATCH LIST", colors.orange)
end

drawStaticLayout()

while true do
  local w, h = monitor.getSize()

  writeAt(w - 10, 1, textutils.formatTime(os.time(), true), colors.lightGray)

  if me then
    local meEnergy = safeCall(me, "getEnergyStorage", 0)
    local meMaxEnergy = safeCall(me, "getMaxEnergyStorage", 0)
    local meUsage = safeCall(me, "getEnergyUsage", 0)

    writeAt(3, 5, "Stored: " .. fmt(meEnergy) .. " / " .. fmt(meMaxEnergy) .. " AE", colors.white)
    drawBar(3, 6, w - 12, meEnergy, meMaxEnergy, colors.lime)
    writeAt(3, 7, "Usage:  " .. fmt(meUsage) .. " AE/t", colors.yellow)

    local usedItems = safeCall(me, "getUsedItemStorage", 0)
    local totalItems = safeCall(me, "getTotalItemStorage", 0)
    local usedFluids = safeCall(me, "getUsedFluidStorage", 0)
    local totalFluids = safeCall(me, "getTotalFluidStorage", 0)

    writeAt(3, 19, "Items:  " .. fmt(usedItems) .. " / " .. fmt(totalItems) .. " bytes", colors.white)
    drawBar(3, 20, w - 12, usedItems, totalItems, colors.lightBlue)
    writeAt(3, 21, "Fluids: " .. fmt(usedFluids) .. " / " .. fmt(totalFluids) .. " bytes", colors.white)

    local cpus = safeCall(me, "getCraftingCPUs", {})
    local totalCpu = 0
    local busyCpu = 0

    if type(cpus) == "table" then
      for _, cpu in pairs(cpus) do
        totalCpu = totalCpu + 1
        if cpu.isBusy then busyCpu = busyCpu + 1 end
      end
    end

    writeAt(3, 26, "Busy: " .. busyCpu .. " / " .. totalCpu, colors.white)

    local cpuLine = ""
    local index = 1
    if type(cpus) == "table" then
      for _, cpu in pairs(cpus) do
        if index <= 4 then
          cpuLine = cpuLine .. "CPU " .. index .. ": "
          if cpu.isBusy then
            cpuLine = cpuLine .. "BUSY   "
          else
            cpuLine = cpuLine .. "IDLE   "
          end
        end
        index = index + 1
      end
    end
    writeAt(3, 27, cpuLine, colors.magenta)

    local y = 32
    for _, itemName in ipairs(watchedItems) do
      if y < h then
        local amount = 0
        local label = itemName

        if me.getItem then
          local ok, item = pcall(me.getItem, { name = itemName })
          if ok and item then
            amount = item.amount or 0
            label = item.displayName or itemName
          end
        end

        local line = pad(label, math.max(10, w - 16)) .. fmt(amount)
        writeAt(3, y, line, colors.white)
        y = y + 1
      end
    end
  else
    writeAt(3, 5, "No ME Bridge found", colors.red)
  end

  if fluxStorage then
    local energy = safeCall(fluxStorage, "getEnergy", 0)
    local capacity = safeCall(fluxStorage, "getEnergyCapacity", 0)

    writeAt(3, 12, "Stored: " .. fmt(energy) .. " / " .. fmt(capacity) .. " FE", colors.white)
    drawBar(3, 13, w - 12, energy, capacity, colors.lime)
  else
    writeAt(3, 12, "No Flux/Energy storage found", colors.red)
  end

  local inputRate = safeCall(inputDetector, "getTransferRate", 0)
  local outputRate = safeCall(outputDetector, "getTransferRate", 0)

  writeAt(3, 14, "Input:  " .. fmt(inputRate) .. " FE/t", colors.lime)
  writeAt(math.floor(w / 2), 14, "Output: " .. fmt(outputRate) .. " FE/t", colors.red)

  sleep(1)
end