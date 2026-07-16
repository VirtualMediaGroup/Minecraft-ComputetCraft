local monitor = peripheral.find("monitor")
local me = peripheral.find("me_bridge") or peripheral.find("meBridge")

if not monitor then error("No monitor found") end
if not me then error("No ME Bridge found") end

monitor.setTextScale(0.5)

local watchedItems = {
  "minecraft:iron_ingot",
  "minecraft:gold_ingot",
  "minecraft:diamond",
  "minecraft:redstone",
  "ae2:certus_quartz_crystal",
}

local function fmt(n)
  n = tonumber(n) or 0
  if n >= 1000000000 then return string.format("%.2fG", n / 1000000000) end
  if n >= 1000000 then return string.format("%.2fM", n / 1000000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

local function pct(a, b)
  if not b or b <= 0 then return 0 end
  return math.floor((a / b) * 100)
end

local function box(x, y, w, h, title, color)
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

local function writeAt(x, y, text, color)
  monitor.setCursorPos(x, y)
  monitor.setTextColor(color or colors.white)
  monitor.write(text)
end

local function bar(x, y, w, value, max, color)
  local p = pct(value, max)
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
  monitor.setBackgroundColor(colors.black)
  monitor.clear()

  local width, height = monitor.getSize()

  writeAt(2, 1, "ATM10 BASE DASHBOARD", colors.cyan)
  writeAt(width - 12, 1, textutils.formatTime(os.time(), true), colors.lightGray)

  local meEnergy = me.getEnergyStorage and me.getEnergyStorage() or 0
  local meMaxEnergy = me.getMaxEnergyStorage and me.getMaxEnergyStorage() or 0
  local meUsage = me.getEnergyUsage and me.getEnergyUsage() or 0

  local usedItems = me.getUsedItemStorage and me.getUsedItemStorage() or 0
  local totalItems = me.getTotalItemStorage and me.getTotalItemStorage() or 0

  box(1, 3, width, 6, "ME POWER", colors.cyan)
  writeAt(3, 5, "Stored: " .. fmt(meEnergy) .. " / " .. fmt(meMaxEnergy) .. " AE", colors.white)
  bar(3, 6, width - 12, meEnergy, meMaxEnergy, colors.lime)
  writeAt(3, 7, "Usage:  " .. fmt(meUsage) .. " AE/t", colors.yellow)

  box(1, 10, width, 5, "ME STORAGE", colors.lightBlue)
  writeAt(3, 12, "Items:  " .. fmt(usedItems) .. " / " .. fmt(totalItems) .. " bytes", colors.white)
  bar(3, 13, width - 12, usedItems, totalItems, colors.lightBlue)

  box(1, 16, width, 8, "WATCHED ITEMS", colors.orange)

  local y = 18
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

    writeAt(3, y, label, colors.white)
    writeAt(width - 10, y, fmt(amount), colors.lime)
    y = y + 1
  end

  local cpus = {}
  if me.getCraftingCPUs then
    local ok, result = pcall(me.getCraftingCPUs)
    if ok and type(result) == "table" then cpus = result end
  end

  local totalCpu = 0
  local busyCpu = 0

  for _, cpu in pairs(cpus) do
    totalCpu = totalCpu + 1
    if cpu.isBusy then busyCpu = busyCpu + 1 end
  end

  writeAt(2, height, "CPUs: " .. busyCpu .. "/" .. totalCpu .. " busy", colors.magenta)

  sleep(1)
end