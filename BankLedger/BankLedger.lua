-- BankLedger: turns a guild bank alt's bags, bank and mailbox into Discord-ready text.
-- Bags are scanned all the time, the bank whenever it is open (the last bank visit is kept),
-- the mailbox whenever it is open. Taking mail, sending mail and finished trades go into an
-- in/out ledger, so the report can thank donors and show what is new since the last post.
-- /bl opens the report: one page per category, each under Discord's 2000 character limit.
-- Lua 5.0 (WoW 1.12): no # operator, no % operator, no string methods, varargs via arg.

local VERSION = 2         -- bump to re-read cached item tooltips
local LIMIT = 1900        -- characters per page; Discord allows 2000 per message
local LOG_MAX = 500
local TAKE_TIMEOUT = 10   -- seconds to see a taken mail attachment arrive in the bags

local ORDER = {
  "TRADE GOODS", "WEAPONS & ARMOR",
  "RECIPES - ALCHEMY", "RECIPES - BLACKSMITHING", "RECIPES - ENGINEERING",
  "RECIPES - LEATHERWORKING", "RECIPES - TAILORING", "RECIPES - ENCHANTING",
  "RECIPES - COOKING", "RECIPES - FIRST AID", "RECIPES - FISHING",
  "BOOKS & TOMES", "BAGS & CONTAINERS", "CONSUMABLES", "OTHER", "GOLD",
}
-- shown even when empty ("Nothing in stock."), like the guild's existing posts
local ALWAYS = {
  ["TRADE GOODS"] = true, ["WEAPONS & ARMOR"] = true, ["RECIPES - ALCHEMY"] = true,
  ["RECIPES - BLACKSMITHING"] = true, ["RECIPES - ENGINEERING"] = true,
  ["RECIPES - LEATHERWORKING"] = true, ["RECIPES - TAILORING"] = true,
  ["RECIPES - ENCHANTING"] = true, ["BAGS & CONTAINERS"] = true, ["GOLD"] = true,
}
local HIDE_DEFAULT = { ["6948"] = true }  -- Hearthstone

local WEAPON = {
  ["One-Handed Axes"] = "1H axe", ["Two-Handed Axes"] = "2H axe",
  ["One-Handed Maces"] = "1H mace", ["Two-Handed Maces"] = "2H mace",
  ["One-Handed Swords"] = "1H sword", ["Two-Handed Swords"] = "2H sword",
  ["Polearms"] = "polearm", ["Staves"] = "staff", ["Daggers"] = "dagger",
  ["Fist Weapons"] = "fist weapon", ["Bows"] = "bow", ["Crossbows"] = "crossbow",
  ["Guns"] = "gun", ["Thrown"] = "thrown", ["Wands"] = "wand",
  ["Fishing Pole"] = "fishing pole", ["Fishing Poles"] = "fishing pole",
}
local SLOT = {
  INVTYPE_HEAD = "head", INVTYPE_NECK = "neck", INVTYPE_SHOULDER = "shoulders",
  INVTYPE_CLOAK = "cloak", INVTYPE_CHEST = "chest", INVTYPE_ROBE = "chest",
  INVTYPE_BODY = "shirt", INVTYPE_TABARD = "tabard", INVTYPE_WRIST = "wrists",
  INVTYPE_HAND = "gloves", INVTYPE_WAIST = "belt", INVTYPE_LEGS = "legs",
  INVTYPE_FEET = "boots", INVTYPE_FINGER = "ring", INVTYPE_TRINKET = "trinket",
  INVTYPE_SHIELD = "shield", INVTYPE_HOLDABLE = "off-hand", INVTYPE_RELIC = "relic",
}
local GEAR_GROUPS = { "Plate", "Mail", "Leather", "Cloth", "Cloaks", "Shields & off-hands",
  "Jewelry & trinkets", "Weapons", "Other gear" }
local STATS = {
  { "Strength", "str" }, { "Agility", "agi" }, { "Stamina", "sta" },
  { "Intellect", "int" }, { "Spirit", "spi" },
}
-- first match per tooltip line wins; random suffixes ("of Healing") use the short "+N ..." forms
local SPECIAL = {
  { "Damage and Healing Spells", "spell power" }, { "Healing Spells", "healing" },
  { "Shadow Spell Damage", "shadow dmg" }, { "Fire Spell Damage", "fire dmg" },
  { "Frost Spell Damage", "frost dmg" }, { "Nature Spell Damage", "nature dmg" },
  { "Arcane Spell Damage", "arcane dmg" }, { "Holy Spell Damage", "holy dmg" },
  { "damage and healing done by magical spells", "spell power" },
  { "healing done by spells", "healing" },
  { "chance to hit by", "hit" },
  { "critical strike", "crit" },
  { "Fire Resistance", "fire res" }, { "Nature Resistance", "nature res" },
  { "Frost Resistance", "frost res" }, { "Shadow Resistance", "shadow res" },
  { "Arcane Resistance", "arcane res" },
}
local RECIPE_PREFIX = { "Recipe: ", "Pattern: ", "Plans: ", "Formula: ", "Schematic: ", "Manual: " }

local ev = CreateFrame("Frame", "BankLedgerEvents")
local tip = CreateFrame("GameTooltip", "BankLedgerTip", nil, "GameTooltipTemplate")
local db, cdb
local bankOpen, mailOpen = false, false
local dirty = {}
local wait = 0
local slots = {}          -- "bag:slot" -> { link, bound } so tooltips are read only when a slot changes
local takes = {}          -- mail attachments taken, waiting to show up in the bags
local moneyTake, sendMail, trade

local function say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffe0b050BankLedger:|r " .. msg)
end

local function money(c)
  local g = math.floor(c / 10000)
  local s = math.floor(math.mod(c, 10000) / 100)
  if s > 0 then return g .. "g " .. s .. "s" end
  return g .. "g"
end

local function joinAnd(list)
  local n = table.getn(list)
  if n == 0 then return "" end
  if n == 1 then return list[1] end
  local head = {}
  for i = 1, n - 1 do head[i] = list[i] end
  return table.concat(head, ", ") .. " and " .. list[n]
end

-- "|cff...|Hitem:2589:0:0:0|h[Linen Cloth]|h|r" -> key "2589:0" (id:random suffix), id, name
local function parseLink(link)
  if not link then return end
  local _, _, id, suffix, name = string.find(link, "item:(%d+):%d+:(%d+):%d+|h%[(.-)%]|h")
  if not id then return end
  return id .. ":" .. suffix, id, name
end

local function idOf(key)
  local _, _, id = string.find(key, "^(%d+):")
  return id
end

-- ---------- tooltip scanning ----------
local function tipLines(set)
  tip:SetOwner(WorldFrame, "ANCHOR_NONE")
  tip:ClearLines()
  set()
  local out = {}
  for i = 1, tip:NumLines() do
    local fs = getglobal("BankLedgerTipTextLeft" .. i)
    local t = fs and fs:GetText()
    if t then table.insert(out, t) end
  end
  tip:Hide()
  return out
end

local function readTip(info, lines)
  local stats, seen = {}, {}
  for i = 1, table.getn(lines) do
    local t = lines[i]
    if not info.lvl then
      local _, _, l = string.find(t, "^Requires Level (%d+)")
      if l then info.lvl = tonumber(l) end
    end
    if not info.skill then
      local _, _, prof, l = string.find(t, "^Requires ([%a ]+) %((%d+)%)")
      if prof then info.prof, info.skill = prof, tonumber(l) end
    end
    local _, _, cls = string.find(t, "^Classes: (.+)")
    if cls and not info.cls then info.cls = cls end
    -- recipe tooltips repeat the crafted item's tooltip below; its stats are not ours
    if not info.recipe then
      for _, s in ipairs(STATS) do
        if not seen[s[2]] and string.find(t, "^%+%d+ " .. s[1]) then
          seen[s[2]] = true
          table.insert(stats, s[2])
        end
      end
      for _, s in ipairs(SPECIAL) do
        if string.find(t, s[1], 1, true) then
          if not seen[s[2]] then
            seen[s[2]] = true
            table.insert(stats, s[2])
          end
          break
        end
      end
    end
  end
  if table.getn(stats) > 0 then info.stats = table.concat(stats, "/") end
end

local function isBound(lines)
  for i = 1, table.getn(lines) do
    if lines[i] == (ITEM_SOULBOUND or "Soulbound") then return true end
  end
end

-- item facts, cached account-wide by key; `lines` is the tooltip of one copy of the item
local function itemInfo(key, name, lines)
  local info = db.info[key]
  if info and info.t then return info end
  info = { n = name }
  local id = idOf(key)
  if id then
    local _, _, suffix = string.find(key, ":(%d+)$")
    local iname, _, q, _, itype, isub, _, loc = GetItemInfo("item:" .. id .. ":0:" .. (suffix or "0") .. ":0")
    if iname then
      info.q, info.t, info.st, info.loc = q, itype, isub, loc
    end
  end
  for _, p in ipairs(RECIPE_PREFIX) do
    if string.find(name, p, 1, true) == 1 then info.recipe = true end
  end
  if info.t == "Recipe" then info.recipe = true end
  if lines then readTip(info, lines) end
  db.info[key] = info
  if name and string.find(key, "^%d+:%d+$") then db.byName[name] = key end
  return info
end

-- ---------- scanning ----------
local function bankSlotTip(slot)
  local inv = BankButtonIDToInvSlotID and BankButtonIDToInvSlotID(slot) or (39 + slot)
  return function() tip:SetInventoryItem("player", inv) end
end

local function scanContainers(bags, into)
  for _, bag in ipairs(bags) do
    local n = GetContainerNumSlots(bag) or 0
    for slot = 1, n do
      local id = bag .. ":" .. slot
      local link = GetContainerItemLink(bag, slot)
      local key, _, name = parseLink(link)
      if key then
        local _, count = GetContainerItemInfo(bag, slot)
        local s = slots[id]
        if not s or s.link ~= link or not (db.info[key] and db.info[key].t) then
          local lines = tipLines(bag == -1 and bankSlotTip(slot) or function() tip:SetBagItem(bag, slot) end)
          s = { link = link, bound = isBound(lines) }
          slots[id] = s
          itemInfo(key, name, lines)
        end
        if not s.bound then
          local e = into[key] or { n = name, c = 0 }
          e.c = e.c + (count or 1)
          into[key] = e
        end
      else
        slots[id] = nil
      end
    end
  end
end

local function scanBags()
  local t = {}
  scanContainers({ 0, 1, 2, 3, 4 }, t)
  cdb.bags, cdb.bagsT = t, time()
end

local function scanBank()
  if not bankOpen or (GetContainerNumSlots(-1) or 0) == 0 then return end
  local t = {}
  scanContainers({ -1, 5, 6, 7, 8, 9, 10 }, t)
  cdb.bank, cdb.bankT = t, time()
end

-- 1.12 mail gives only the item name; pfQuest, when installed, knows every item id by name
local pfIndex
local function idByName(name)
  if not (pfDB and pfDB.items and pfDB.items.enUS) then return end
  if not pfIndex then
    pfIndex = {}
    for id, n in pairs(pfDB.items.enUS) do
      if not pfIndex[n] or id < pfIndex[n] then pfIndex[n] = id end
    end
  end
  return pfIndex[name]
end

local function mailKey(i, name)
  if GetInboxItemLink then
    local ok, link = pcall(GetInboxItemLink, i, 1)
    local key = ok and parseLink(link)
    if key then return key end
  end
  local key = db.byName[name]
  if key and string.find(key, "^%d") then return key end
  local id = idByName(name)
  if id then return id .. ":0" end
  -- random suffix ("Duskwoven Turban of Fiery Wrath"): link the base item, keep the full name
  local _, _, base = string.find(name, "^(.-) of .+$")
  id = base and idByName(base)
  if id then return id .. ":0:" .. name end
  return "name:" .. name
end

local function scanMail()
  if not mailOpen then return end
  local t, gold, expiring = {}, 0, 0
  local n = GetInboxNumItems() or 0
  for i = 1, n do
    local _, _, _, _, m, cod, days, hasItem = GetInboxHeaderInfo(i)
    if (m or 0) > 0 then gold = gold + m end
    local name, _, count = GetInboxItem(i)
    if hasItem and name then
      if days and days < 3 then expiring = expiring + 1 end
      if not cod or cod == 0 then
        local key = mailKey(i, name)
        if not db.info[key] then
          local idx = i
          itemInfo(key, name, tipLines(function() tip:SetInboxItem(idx) end))
        end
        local e = t[key] or { n = name, c = 0 }
        e.c = e.c + (count or 1)
        t[key] = e
      end
    end
  end
  cdb.mail, cdb.mailGold, cdb.mailN, cdb.mailExpiring, cdb.mailT = t, gold, n, expiring, time()
end

-- ---------- ledger ----------
local function log(dir, via, who, name, count, m)
  table.insert(cdb.log, { t = time(), d = dir, via = via, who = who, n = name, c = count, m = m })
  while table.getn(cdb.log) > LOG_MAX do table.remove(cdb.log, 1) end
end

local function countInBags(name)
  local c = 0
  for bag = 0, 4 do
    for slot = 1, (GetContainerNumSlots(bag) or 0) do
      local _, _, n = parseLink(GetContainerItemLink(bag, slot))
      if n == name then
        local _, k = GetContainerItemInfo(bag, slot)
        c = c + (k or 1)
      end
    end
  end
  return c
end

local function checkTakes()
  local now, keep, used = GetTime(), {}, {}
  for _, p in ipairs(takes) do
    local got = countInBags(p.n) - p.before - (used[p.n] or 0)
    if got > 0 then
      local c = math.min(p.c, got)
      used[p.n] = (used[p.n] or 0) + c
      log("IN", "mail", p.who, p.n, c)
    elseif now - p.at < TAKE_TIMEOUT then
      table.insert(keep, p)
    end
  end
  takes = keep
end

local origTakeItem = TakeInboxItem
TakeInboxItem = function(a1, a2)
  if cdb and not cdb.off then
    local _, _, sender = GetInboxHeaderInfo(a1)
    local name, _, count = GetInboxItem(a1)
    if name then
      table.insert(takes, { who = sender, n = name, c = count or 1, before = countInBags(name), at = GetTime() })
    end
  end
  return origTakeItem(a1, a2)
end

local origTakeMoney = TakeInboxMoney
TakeInboxMoney = function(a1)
  if cdb and not cdb.off then
    local _, _, sender, _, m = GetInboxHeaderInfo(a1)
    if m and m > 0 then moneyTake = { who = sender, m = m, before = GetMoney() } end
  end
  return origTakeMoney(a1)
end

local origSendMail = SendMail
SendMail = function(to, subject, body)
  if cdb and not cdb.off then
    local name, _, count = GetSendMailItem()
    sendMail = { who = to, n = name, c = count, m = GetSendMailMoney(), at = GetTime() }
  end
  return origSendMail(to, subject, body)
end

local function commitSend()
  if not sendMail then return end
  local p = sendMail
  sendMail = nil
  if p.n then log("OUT", "mail", p.who, p.n, p.c or 1) end
  if p.m and p.m > 0 then log("OUT", "mail", p.who, nil, nil, p.m) end
end

local function snapTrade()
  if not trade then return end
  trade.give, trade.get = {}, {}
  for i = 1, 6 do
    local n, _, c = GetTradePlayerItemInfo(i)
    if n then table.insert(trade.give, { n = n, c = c or 1 }) end
    n, _, c = GetTradeTargetItemInfo(i)
    if n then table.insert(trade.get, { n = n, c = c or 1 }) end
  end
  trade.giveM, trade.getM = GetPlayerTradeMoney(), GetTargetTradeMoney()
end

local function commitTrade()
  if not trade or trade.done or not trade.give then return end
  trade.done = true
  for _, e in ipairs(trade.get) do log("IN", "trade", trade.who, e.n, e.c) end
  for _, e in ipairs(trade.give) do log("OUT", "trade", trade.who, e.n, e.c) end
  if trade.getM > 0 then log("IN", "trade", trade.who, nil, nil, trade.getM) end
  if trade.giveM > 0 then log("OUT", "trade", trade.who, nil, nil, trade.giveM) end
end

-- ---------- report ----------
local function category(key, info)
  local over = db.cat[key] or db.cat[idOf(key) or ""]
  if over then return over end
  local t, st = info.t, info.st
  if t == "Recipe" or (not t and info.recipe) then
    if st == "Book" then return "BOOKS & TOMES" end
    local prof = st or info.prof
    if prof then return "RECIPES - " .. string.upper(prof) end
    return "OTHER"
  end
  if t == "Weapon" or t == "Armor" then return "WEAPONS & ARMOR" end
  if t == "Container" or t == "Quiver" then return "BAGS & CONTAINERS" end
  if t == "Trade Goods" or t == "Reagent" then return "TRADE GOODS" end
  if t == "Consumable" or t == "Projectile" then return "CONSUMABLES" end
  return "OTHER"
end

local function gearGroup(info)
  if info.t == "Weapon" then return "Weapons" end
  local loc, st = info.loc, info.st
  if loc == "INVTYPE_SHIELD" or loc == "INVTYPE_HOLDABLE" then return "Shields & off-hands" end
  if loc == "INVTYPE_CLOAK" then return "Cloaks" end
  if loc == "INVTYPE_FINGER" or loc == "INVTYPE_NECK" or loc == "INVTYPE_TRINKET" then return "Jewelry & trinkets" end
  if st == "Plate" or st == "Mail" or st == "Leather" or st == "Cloth" then return st end
  return "Other gear"
end

local function gearDesc(info)
  local parts = {}
  if info.lvl and info.lvl > 1 then table.insert(parts, "lvl " .. info.lvl) end
  if info.q == 4 then table.insert(parts, "epic") end
  local what
  if info.t == "Weapon" then
    what = WEAPON[info.st] or string.lower(info.st or "weapon")
    if info.loc == "INVTYPE_WEAPONMAINHAND" then what = what .. " main hand"
    elseif info.loc == "INVTYPE_WEAPONOFFHAND" then what = what .. " off hand" end
  else
    what = SLOT[info.loc] or ""
    local st = info.st
    if (st == "Plate" or st == "Mail" or st == "Leather" or st == "Cloth") and info.loc ~= "INVTYPE_CLOAK" then
      what = string.lower(st) .. " " .. what
    end
  end
  if what ~= "" then table.insert(parts, what) end
  local s = table.concat(parts, " ")
  if info.stats then s = s .. (s ~= "" and ", " or "") .. info.stats end
  if info.cls then s = s .. (s ~= "" and ", " or "") .. info.cls .. " only" end
  return s
end

local function shortRecipe(name)
  for _, p in ipairs(RECIPE_PREFIX) do
    if string.find(name, p, 1, true) == 1 then return string.sub(name, string.len(p) + 1) end
  end
  return name
end

local function hidden(key)
  local id = idOf(key) or ""
  if db.hide[key] ~= nil then return db.hide[key] end
  if db.hide[id] ~= nil then return db.hide[id] end
  return HIDE_DEFAULT[id]
end

local function totals(c)
  c = c or cdb
  local all = {}
  local function add(src)
    for key, e in pairs(src or {}) do
      if not hidden(key) then
        local a = all[key] or { n = e.n, c = 0 }
        a.c = a.c + e.c
        all[key] = a
      end
    end
  end
  add(c.bags)
  add(c.bank)
  if db.opt.mail ~= false then add(c.mail) end
  return all
end

local function stamp(c)
  if db.opt.stamp == false then return nil end
  local s = "-# Updated " .. date("%d %b %Y", c.bagsT or time())
  if not c.bankT then s = s .. " (bank not scanned yet)" end
  return s
end

local function entryLine(cat, key, e, info)
  local inline = db.opt.style == "inline"
  local name, after = e.n, ""
  if cat == "WEAPONS & ARMOR" then
    local d = gearDesc(info)
    if d ~= "" then after = " (" .. d .. ")" end
    if e.c > 1 then after = after .. " x" .. e.c end
  elseif string.find(cat, "^RECIPES") or cat == "BOOKS & TOMES" then
    name = shortRecipe(name)
    if info.skill then after = " (" .. info.skill .. ")" end
    if e.c > 1 then after = after .. " x" .. e.c end
  else
    after = " x" .. e.c
  end
  -- only the name is the link; <> stops Discord from adding an embed for every item
  if db.opt.links and idOf(key) then
    name = "[" .. name .. "](<https://www.wowhead.com/classic/item=" .. idOf(key) .. ">)"
  end
  if inline then return name .. after end
  return "- " .. name .. after
end

local function sortedEntries(cat, list)
  table.sort(list, function(a, b)
    if cat == "WEAPONS & ARMOR" then
      if a.g ~= b.g then return a.g < b.g end
      local la, lb = a.info.lvl or 0, b.info.lvl or 0
      if la ~= lb then return la < lb end
    elseif string.find(cat, "^RECIPES") then
      local sa, sb = a.info.skill or 0, b.info.skill or 0
      if sa ~= sb then return sa < sb end
    end
    return a.e.n < b.e.n
  end)
end

-- a line is an item string, or { raw = text } for headings and notes;
-- { raw = "__Plate__", head = true } starts a group. Inline style puts a group's items on one line.
local function raw(text, head) return { raw = text, head = head } end

local function render(lines)
  local out = {}
  if db.opt.style ~= "inline" then
    for _, l in ipairs(lines) do table.insert(out, type(l) == "table" and l.raw or l) end
    return table.concat(out, "\n")
  end
  local seg, items = nil, 0
  local function flush()
    if seg then table.insert(out, seg) end
    seg, items = nil, 0
  end
  for _, l in ipairs(lines) do
    if type(l) == "table" then
      flush()
      if l.head then seg = l.raw .. ": " else table.insert(out, l.raw) end
    else
      if not seg then seg = "" end
      seg = seg .. (items > 0 and ", " or "") .. l
      items = items + 1
    end
  end
  flush()
  return table.concat(out, "\n")
end

-- split lines into pages of at most LIMIT characters, each with the heading
local function paginate(title, lines, foot, out)
  local chunks, cur, len = {}, {}, 0
  local budget = LIMIT - string.len(title) - 12 - (foot and string.len(foot) + 1 or 0)
  for _, l in ipairs(lines) do
    local add = string.len(type(l) == "table" and l.raw or l) + 2
    if len + add > budget and table.getn(cur) > 0 then
      table.insert(chunks, cur)
      cur, len = {}, 0
    end
    table.insert(cur, l)
    len = len + add
  end
  if table.getn(cur) > 0 or table.getn(chunks) == 0 then table.insert(chunks, cur) end
  local n = table.getn(chunks)
  for i, ch in ipairs(chunks) do
    local head = "**" .. title .. "**"
    if n > 1 then head = head .. " (" .. i .. "/" .. n .. ")" end
    local text = head .. "\n" .. render(ch)
    if foot then text = text .. "\n" .. foot end
    table.insert(out, { title = title, part = i, parts = n, text = text })
  end
end

local function changesPage(c, all, out)
  local foot = stamp(c)
  local mark = c.mark
  if not mark then
    paginate("NEW IN THE GUILD BANK", { raw("No baseline yet: press \"Mark posted\" after updating Discord.") }, nil, out)
    return
  end
  local new = {}
  for key, e in pairs(all) do
    local was = mark.items[key] or 0
    if e.c > was then
      local info = db.info[key] or { n = e.n }
      local cat = category(key, info)
      table.insert(new, { cat = cat, key = key, e = { n = e.n, c = e.c - was }, info = info })
    end
  end
  local rank = {}
  for i, cat in ipairs(ORDER) do rank[cat] = i end
  table.sort(new, function(a, b)
    if a.cat ~= b.cat then return (rank[a.cat] or 99) < (rank[b.cat] or 99) end
    return a.e.n < b.e.n
  end)
  local lines = {}
  for _, x in ipairs(new) do table.insert(lines, entryLine(x.cat, x.key, x.e, x.info)) end
  if table.getn(lines) == 0 then table.insert(lines, raw("Nothing new yet.")) end
  -- donors: players who mailed or traded something in since the mark
  local donors, seen = {}, {}
  for _, l in ipairs(c.log) do
    if l.t >= mark.t and l.d == "IN" and l.who and not string.find(l.who, " ")
        and l.who ~= c.name and not seen[l.who] then
      seen[l.who] = true
      table.insert(donors, l.who)
    end
  end
  if table.getn(donors) > 0 then
    table.insert(lines, raw(""))
    table.insert(lines, raw("Thanks to " .. joinAnd(donors) .. " for the donations!"))
  end
  paginate("NEW IN THE GUILD BANK (since " .. date("%d %b", mark.t) .. ")", lines, foot, out)
end

local function ledgerPage(c, out)
  local lines = {}
  local since = c.mark and c.mark.t or 0
  for i = table.getn(c.log), 1, -1 do
    local l = c.log[i]
    if l.t < since then break end
    local what = l.n and (l.n .. " x" .. (l.c or 1)) or money(l.m or 0)
    local dir = l.d == "IN" and "from" or "to"
    table.insert(lines, raw(date("%d %b %H:%M", l.t) .. " " .. l.d .. " " .. dir .. " " .. (l.who or "?") ..
      " (" .. l.via .. "): " .. what))
  end
  if table.getn(lines) == 0 then table.insert(lines, raw("No mail or trades recorded since the last mark.")) end
  paginate("LEDGER (officer view, newest first)", lines, nil, out)
end

local function buildPages(c)
  c = c or cdb
  local all = totals(c)
  local byCat = {}
  for key, e in pairs(all) do
    local info = db.info[key] or { n = e.n }
    local cat = category(key, info)
    byCat[cat] = byCat[cat] or {}
    local g = cat == "WEAPONS & ARMOR" and gearGroup(info) or ""
    table.insert(byCat[cat], { key = key, e = e, info = info, g = g })
  end
  local grank = {}
  for i, g in ipairs(GEAR_GROUPS) do grank[g] = string.format("%02d", i) end
  local out, foot = {}, stamp(c)
  for _, cat in ipairs(ORDER) do
    if cat == "GOLD" then
      local s = money(c.money or 0)
      if db.opt.mail ~= false and (c.mailGold or 0) > 0 then
        s = s .. " (+" .. money(c.mailGold) .. " waiting in the mailbox)"
      end
      paginate(cat, { raw(s) }, foot, out)
    else
      local list = byCat[cat]
      if list then
        for _, x in ipairs(list) do if x.g ~= "" then x.g = grank[x.g] .. x.g end end
        sortedEntries(cat, list)
        local lines, lastG = {}, nil
        for _, x in ipairs(list) do
          if cat == "WEAPONS & ARMOR" and x.g ~= lastG then
            if lastG and db.opt.style ~= "inline" then table.insert(lines, raw("")) end
            table.insert(lines, raw("__" .. string.sub(x.g, 3) .. "__", true))
            lastG = x.g
          end
          table.insert(lines, entryLine(cat, x.key, x.e, x.info))
        end
        paginate(cat, lines, foot, out)
      elseif ALWAYS[cat] then
        paginate(cat, { raw("Nothing in stock.") }, foot, out)
      end
    end
  end
  changesPage(c, all, out)
  ledgerPage(c, out)
  return out
end

-- ---------- window ----------
local win, edit, titleText, infoText, pages, page, shown
local markPosted

local function showPage()
  if not pages or table.getn(pages) == 0 then return end
  if page > table.getn(pages) then page = table.getn(pages) end
  if page < 1 then page = 1 end
  local p = pages[page]
  shown = p.text
  titleText:SetText("BankLedger - " .. page .. "/" .. table.getn(pages) .. ": " .. p.title ..
    (p.parts > 1 and (" (" .. p.part .. "/" .. p.parts .. ")") or ""))
  local warn = ""
  if not cdb.bankT then warn = "  |cffff6060Open the bank once to include it.|r"
  elseif (cdb.mailExpiring or 0) > 0 then warn = "  |cffff6060" .. cdb.mailExpiring .. " mail(s) with items expire within 3 days!|r" end
  infoText:SetText(string.len(shown) .. "/2000 characters. Ctrl+C copies the selection; paste it into the Discord message." .. warn)
  edit:SetText(shown)
  edit:SetFocus()
  edit:HighlightText()
end

local function button(parent, text, w, point, x, y, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetWidth(w)
  b:SetHeight(22)
  b:SetPoint(point, parent, point, x, y)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

-- a checkbox bound to db.opt[key]; get/set translate when the stored value is not a plain boolean
local function checkbox(name, text, x, get, set)
  local cb = CreateFrame("CheckButton", name, win, "UICheckButtonTemplate")
  cb:SetWidth(24)
  cb:SetHeight(24)
  cb:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", x, 44)
  local label = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("LEFT", cb, "RIGHT", 0, 1)
  label:SetText(text)
  cb:SetScript("OnShow", function() this:SetChecked(get()) end)
  cb:SetScript("OnClick", function()
    set(this:GetChecked() and true or false)
    pages = buildPages()
    showPage()
  end)
  cb:SetChecked(get())
  return cb
end

local function makeWindow()
  win = CreateFrame("Frame", "BankLedgerWindow", UIParent)
  win:SetWidth(620)
  win:SetHeight(500)
  win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  win:SetFrameStrata("DIALOG")
  win:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  win:EnableMouse(true)
  win:SetMovable(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", function() this:StartMoving() end)
  win:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  table.insert(UISpecialFrames, "BankLedgerWindow")

  titleText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  titleText:SetPoint("TOP", win, "TOP", 0, -18)
  infoText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  infoText:SetPoint("TOPLEFT", win, "TOPLEFT", 22, -40)
  infoText:SetWidth(576)
  infoText:SetJustifyH("LEFT")

  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -6, -6)

  local scroll = CreateFrame("ScrollFrame", "BankLedgerScroll", win, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", win, "TOPLEFT", 22, -60)
  scroll:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -42, 76)

  edit = CreateFrame("EditBox", "BankLedgerEdit", scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject(GameFontHighlightSmall)
  edit:SetWidth(550)
  edit:SetHeight(360)
  edit.cursorOffset, edit.cursorHeight = 0, 0
  edit:SetScript("OnEscapePressed", function() this:ClearFocus() win:Hide() end)
  -- read-only: put the page back if a key press changed it
  edit:SetScript("OnTextChanged", function()
    if shown and this:GetText() ~= shown then
      this:SetText(shown)
      this:HighlightText()
    end
    scroll:UpdateScrollChildRect()
  end)
  if ScrollingEdit_OnCursorChanged then
    edit:SetScript("OnCursorChanged", function() ScrollingEdit_OnCursorChanged(arg1, arg2, arg3, arg4) end)
  end
  if ScrollingEdit_OnUpdate then edit:SetScript("OnUpdate", ScrollingEdit_OnUpdate) end
  scroll:SetScrollChild(edit)
  scroll:EnableMouse(true)
  scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)

  button(win, "< Prev", 80, "BOTTOMLEFT", 20, 18, function() page = page - 1 showPage() end)
  button(win, "Next >", 80, "BOTTOMLEFT", 104, 18, function() page = page + 1 showPage() end)
  button(win, "Select all", 90, "BOTTOMLEFT", 196, 18, function() edit:SetFocus() edit:HighlightText() end)
  button(win, "Rescan", 80, "BOTTOMRIGHT", -214, 18, function()
    dirty.bags, dirty.bank, dirty.mail, wait = true, true, true, 0
  end)
  button(win, "Mark posted", 110, "BOTTOMRIGHT", -100, 18, function() markPosted() end)
  checkbox("BankLedgerOptLinks", "Wowhead links", 20,
    function() return db.opt.links end, function(v) db.opt.links = v end)
  checkbox("BankLedgerOptInline", "Compact (comma-separated)", 150,
    function() return db.opt.style == "inline" end, function(v) db.opt.style = v and "inline" or "list" end)
  checkbox("BankLedgerOptMail", "Count unopened mail", 340,
    function() return db.opt.mail ~= false end, function(v) db.opt.mail = v end)
  checkbox("BankLedgerOptStamp", "\"Updated\" line", 490,
    function() return db.opt.stamp ~= false end, function(v) db.opt.stamp = v end)
  win:Hide()
end

-- the current stock becomes the baseline for "New in the guild bank" and the ledger page
markPosted = function()
  local m = { t = time(), items = {} }
  for key, e in pairs(totals()) do m.items[key] = e.c end
  cdb.mark = m
  say("marked as posted. \"New in the guild bank\" now counts from " .. date("%d %b %H:%M", m.t) .. ".")
  if win and win:IsVisible() then
    pages = buildPages()
    showPage()
  end
end

local function openReport(at)
  if not win then makeWindow() end
  pages = buildPages()
  page = at or page or 1
  win:Show()
  showPage()
end

-- ---------- minimap button ----------
local mmButton

local function placeMinimapButton()
  local a = math.rad(db.opt.mmAngle or 200)
  mmButton:ClearAllPoints()
  mmButton:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 52 - 80 * math.cos(a), 80 * math.sin(a) - 52)
end

local function makeMinimapButton()
  mmButton = CreateFrame("Button", "BankLedgerMinimapButton", Minimap)
  mmButton:SetWidth(31)
  mmButton:SetHeight(31)
  mmButton:SetFrameStrata("MEDIUM")
  mmButton:SetFrameLevel(8)
  mmButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local icon = mmButton:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
  icon:SetWidth(20)
  icon:SetHeight(20)
  icon:SetPoint("TOPLEFT", mmButton, "TOPLEFT", 7, -5)
  local border = mmButton:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetWidth(53)
  border:SetHeight(53)
  border:SetPoint("TOPLEFT", mmButton, "TOPLEFT", 0, 0)
  mmButton:RegisterForDrag("LeftButton")
  mmButton:SetScript("OnClick", function()
    if win and win:IsVisible() then win:Hide() else openReport() end
  end)
  mmButton:SetScript("OnDragStart", function()
    this:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local px, py = GetCursorPosition()
      local sc = Minimap:GetEffectiveScale()
      db.opt.mmAngle = math.deg(math.atan2(py / sc - my, px / sc - mx))
      placeMinimapButton()
    end)
  end)
  mmButton:SetScript("OnDragStop", function() this:SetScript("OnUpdate", nil) end)
  mmButton:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:AddLine("BankLedger")
    GameTooltip:AddLine("Click: bank pages for Discord", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
    GameTooltip:Show()
  end)
  mmButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  placeMinimapButton()
  if db.opt.minimap == false then mmButton:Hide() end
end

-- ---------- events ----------
local hinted = false

local function rescan()
  if dirty.bags then scanBags() end
  if dirty.bank then scanBank() end
  if dirty.mail then scanMail() end
  dirty.bags, dirty.bank, dirty.mail = false, false, false
  cdb.money = GetMoney()
  checkTakes()
  if win and win:IsVisible() then
    pages = buildPages()
    showPage()
  end
end

local tick = 0
ev:SetScript("OnUpdate", function()
  tick = tick + arg1
  if tick >= 0.5 then
    tick = 0
    if table.getn(takes) > 0 then checkTakes() end
    if sendMail and GetTime() - sendMail.at > 5 then
      -- no MAIL_SEND_SUCCESS: trust the send if the attachment slot has been cleared
      if not GetSendMailItem() then commitSend() else sendMail = nil end
    end
  end
  if not (dirty.bags or dirty.bank or dirty.mail) then return end
  wait = wait - arg1
  if wait <= 0 and cdb and not cdb.off then rescan() end
end)

local function mark(what)
  dirty[what] = true
  if wait <= 0 then wait = 0.5 end
end

ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:RegisterEvent("BAG_UPDATE")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("BANKFRAME_OPENED")
ev:RegisterEvent("BANKFRAME_CLOSED")
ev:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
ev:RegisterEvent("MAIL_SHOW")
ev:RegisterEvent("MAIL_CLOSED")
ev:RegisterEvent("MAIL_INBOX_UPDATE")
ev:RegisterEvent("MAIL_SEND_SUCCESS")
ev:RegisterEvent("MAIL_FAILED")
ev:RegisterEvent("TRADE_SHOW")
ev:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
ev:RegisterEvent("TRADE_TARGET_ITEM_CHANGED")
ev:RegisterEvent("TRADE_MONEY_CHANGED")
ev:RegisterEvent("TRADE_ACCEPT_UPDATE")
ev:RegisterEvent("UI_INFO_MESSAGE")

ev:SetScript("OnEvent", function()
  if event == "PLAYER_LOGIN" then
    BankLedgerDB = BankLedgerDB or {}
    db = BankLedgerDB
    db.opt = db.opt or {}
    if db.v ~= VERSION then db.info = nil end
    db.v = VERSION
    db.info = db.info or {}
    db.byName = db.byName or {}
    db.cat = db.cat or {}
    db.hide = db.hide or {}
    db.chars = db.chars or {}
    local id = GetRealmName() .. ":" .. UnitName("player")
    db.chars[id] = db.chars[id] or {}
    cdb = db.chars[id]
    cdb.name = UnitName("player")
    cdb.log = cdb.log or {}
    makeMinimapButton()
    mark("bags")
    return
  end
  if not cdb or cdb.off then return end
  if event == "PLAYER_LOGOUT" then
    -- rendered pages for tools outside the game (e.g. a Discord webhook poster)
    local texts = {}
    for _, p in ipairs(buildPages()) do table.insert(texts, p.text) end
    cdb.pages, cdb.pagesT = texts, time()
  elseif event == "BAG_UPDATE" then
    if arg1 and (arg1 < 0 or arg1 > 4) then mark("bank") else mark("bags") end
    if bankOpen then mark("bank") end
  elseif event == "PLAYER_MONEY" then
    if moneyTake and GetMoney() > moneyTake.before then
      log("IN", "mail", moneyTake.who, nil, nil, moneyTake.m)
      moneyTake = nil
    end
    cdb.money = GetMoney()
  elseif event == "BANKFRAME_OPENED" then
    if not hinted then
      hinted = true
      say("bank scanned. Click the bag button on the minimap (or type /bl) for the Discord pages.")
    end
    bankOpen = true
    mark("bank")
    mark("bags")
  elseif event == "BANKFRAME_CLOSED" then
    if dirty.bank then scanBank() end
    bankOpen = false
  elseif event == "PLAYERBANKSLOTS_CHANGED" then
    mark("bank")
  elseif event == "MAIL_SHOW" then
    mailOpen = true
    CheckInbox()
  elseif event == "MAIL_INBOX_UPDATE" then
    mark("mail")
    mark("bags")
  elseif event == "MAIL_CLOSED" then
    if dirty.mail then scanMail() end
    mailOpen = false
  elseif event == "MAIL_SEND_SUCCESS" then
    commitSend()
  elseif event == "MAIL_FAILED" then
    sendMail = nil
  elseif event == "TRADE_SHOW" then
    trade = { who = UnitName("NPC") }
  elseif event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_TARGET_ITEM_CHANGED"
      or event == "TRADE_MONEY_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
    snapTrade()
  elseif event == "UI_INFO_MESSAGE" then
    if arg1 == (ERR_TRADE_COMPLETE or "Trade complete.") then commitTrade() end
  end
end)

-- ---------- slash ----------
local function itemFromArg(s)
  local key = parseLink(s)
  if key then return key end
  s = string.gsub(s, "^%s*(.-)%s*$", "%1")
  return db.byName[s]
end

local function valid(cat)
  for _, c in ipairs(ORDER) do if c == cat then return true end end
end

SLASH_BANKLEDGER1 = "/bl"
SLASH_BANKLEDGER2 = "/bankledger"
SlashCmdList["BANKLEDGER"] = function(msg)
  if not cdb then return end
  local _, _, cmd, rest = string.find(msg or "", "^%s*(%S*)%s*(.-)%s*$")
  cmd = string.lower(cmd or "")
  if cmd == "" or cmd == "show" then
    openReport()
  elseif cmd == "mark" then
    markPosted()
  elseif cmd == "scan" then
    dirty.bags, dirty.bank, dirty.mail, wait = true, true, true, 0
    rescan()
    say("scanned bags" .. (bankOpen and ", bank" or "") .. (mailOpen and ", mailbox" or "") .. ".")
  elseif cmd == "cat" then
    -- /bl cat <item link or exact name> = TRADE GOODS    (or "= reset")
    local _, _, what, cat = string.find(rest, "^(.-)%s*=%s*(.-)$")
    local key = what and itemFromArg(what)
    if not key then say("usage: /bl cat <item link or name> = CATEGORY  (or = reset)") return end
    cat = string.upper(cat or "")
    if cat == "RESET" then db.cat[key] = nil say("category reset.") return end
    if not valid(cat) then say("unknown category. Use one of: " .. table.concat(ORDER, ", ")) return end
    db.cat[key] = cat
    say((db.info[key] and db.info[key].n or key) .. " -> " .. cat)
  elseif cmd == "hide" or cmd == "unhide" then
    local key = itemFromArg(rest)
    if not key then say("usage: /bl " .. cmd .. " <item link or name>") return end
    db.hide[key] = cmd == "hide"
    say((db.info[key] and db.info[key].n or key) .. (cmd == "hide" and " hidden from the report." or " shown again."))
  elseif cmd == "style" then
    if rest ~= "list" and rest ~= "inline" then say("usage: /bl style list|inline") return end
    db.opt.style = rest
    say("style: " .. rest)
  elseif cmd == "links" or cmd == "stamp" or cmd == "mail" then
    if rest ~= "on" and rest ~= "off" then say("usage: /bl " .. cmd .. " on|off") return end
    db.opt[cmd] = rest == "on"
    say(cmd .. ": " .. rest)
  elseif cmd == "minimap" then
    if rest ~= "on" and rest ~= "off" then say("usage: /bl minimap on|off") return end
    db.opt.minimap = rest == "on"
    if rest == "on" then mmButton:Show() else mmButton:Hide() end
  elseif cmd == "off" or cmd == "on" then
    cdb.off = cmd == "off"
    say(cmd == "off" and "disabled on this character." or "enabled on this character.")
  elseif cmd == "status" then
    local n = 0
    for _ in pairs(totals()) do n = n + 1 end
    say(n .. " different items. Bags " .. (cdb.bagsT and date("%d %b %H:%M", cdb.bagsT) or "-") ..
      ", bank " .. (cdb.bankT and date("%d %b %H:%M", cdb.bankT) or "never") ..
      ", mailbox " .. (cdb.mailT and (date("%d %b %H:%M", cdb.mailT) .. " (" .. (cdb.mailN or 0) .. " mails)") or "never") ..
      ". Ledger: " .. table.getn(cdb.log) .. " entries." ..
      (cdb.mark and (" Last post mark " .. date("%d %b %H:%M", cdb.mark.t) .. ".") or ""))
  else
    say("/bl - report window | /bl mark (after posting) | /bl scan | /bl status | /bl cat <item> = CATEGORY | /bl hide|unhide <item>")
    say("/bl style list|inline | /bl links on|off (wowhead links) | /bl stamp on|off | /bl mail on|off | /bl minimap on|off | /bl off|on")
  end
end
