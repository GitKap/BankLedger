"""Runs BankLedger.lua against a stubbed WoW 1.12 API (lupa) and checks the report pages.

usage: python tests/sim.py [--print] [--dump pages.json]     (needs `pip install lupa`)
"""
import json
import os
import sys

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "BankLedger", "BankLedger.lua")

STUB = r'''
table.getn = function(t) return #t end
math.mod = math.fmod
getglobal = function(n) return _G[n] end
UISpecialFrames = {}
CHAT = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self, m) table.insert(CHAT, m) end }
ITEM_SOULBOUND = "Soulbound"
ERR_TRADE_COMPLETE = "Trade complete."
NOW = 1792000000
CLOCK = 0
time = function() return NOW end
GetTime = function() return CLOCK end
date = function(f, t) return os.date(f, t or NOW) end

-- generic frame: remembers scripts and events, swallows every other method
FRAMES = {}
local function newFrame(kind, name)
  local f = { kind = kind, scripts = {}, events = {}, visible = true, text = "" }
  setmetatable(f, { __index = function(t, k) return function() end end })
  f.SetScript = function(self, s, fn) self.scripts[s] = fn end
  f.RegisterEvent = function(self, e) self.events[e] = true end
  f.Show = function(self) self.visible = true end
  f.Hide = function(self) self.visible = false end
  f.IsVisible = function(self) return self.visible end
  f.SetText = function(self, t) self.text = t end
  f.GetText = function(self) return self.text end
  f.CreateFontString = function(self) return newFrame("FontString") end
  if name then _G[name] = f end
  table.insert(FRAMES, f)
  return f
end
CreateFrame = function(kind, name, parent, template)
  local f = newFrame(kind, name)
  if kind == "GameTooltip" then
    f.lines = {}
    f.NumLines = function(self) return #self.lines end
    f.ClearLines = function(self) self.lines = {} end
    local function fill(self, lines)
      self.lines = lines or {}
      for i, t in ipairs(self.lines) do
        _G[name .. "TextLeft" .. i] = { GetText = function() return t end }
      end
    end
    f.SetBagItem = function(self, bag, slot) local it = BAGS[bag] and BAGS[bag][slot]; fill(self, it and it.tip) end
    f.SetInventoryItem = function(self, unit, inv) local it = BAGS[-1][inv - 39]; fill(self, it and it.tip) end
    f.SetInboxItem = function(self, i) local m = MAILS[i]; fill(self, m and m.tip) end
  end
  return f
end

ITEMS = {}  -- id -> { name, quality, type, subtype, equipLoc }
function GetItemInfo(s)
  local id = tonumber(string.match(s, "item:(%d+)"))
  local i = ITEMS[id]
  if not i then return nil end
  return i[1], s, i[2], 0, i[3], i[4], 20, i[5] or "", "tex"
end
function link(id) return "|cffffffff|Hitem:" .. id .. ":0:0:0|h[" .. ITEMS[id][1] .. "]|h|r" end

BAGS = { [0] = {}, {}, {}, {}, {}, [-1] = {}, [5] = {}, [6] = {} }
BANK_OPEN = false
function GetContainerNumSlots(bag)
  if (bag == -1 or bag >= 5) and not BANK_OPEN then return 0 end
  if bag == -1 then return 24 end
  if bag >= 5 then return 100 end
  return 16
end
function GetContainerItemLink(bag, slot)
  if (bag == -1 or bag >= 5) and not BANK_OPEN then return nil end
  local it = BAGS[bag] and BAGS[bag][slot]
  return it and link(it.id)
end
function GetContainerItemInfo(bag, slot)
  local it = BAGS[bag] and BAGS[bag][slot]
  if not it then return nil end
  return "tex", it.c
end
function put(bag, slot, id, c, tip) BAGS[bag][slot] = { id = id, c = c, tip = tip or ITEMS[id].tip } end

MONEY = 1395200
function GetMoney() return MONEY end
function UnitName(u) if u == "NPC" then return TRADE_WITH end return "Amberbank" end
function GetRealmName() return "Kronos V" end
function CheckInbox() end

MAILS = {}
function GetInboxNumItems() return #MAILS end
function GetInboxHeaderInfo(i)
  local m = MAILS[i]
  return "pkg", "st", m.from, "subj", m.money or 0, 0, m.days or 30, m.item ~= nil
end
function GetInboxItem(i)
  local m = MAILS[i]
  if not m.item then return nil end
  return m.item, "tex", m.c, 1, 1
end
TAKEN = {}
function TakeInboxItem(i) table.insert(TAKEN, i) end
function TakeInboxMoney(i) table.insert(TAKEN, -i) end
SEND = nil
function SendMail(to, subj, body) SENT_TO = to end
function GetSendMailItem() if SEND then return SEND[1], "tex", SEND[2], 1 end end
function GetSendMailMoney() return 0 end
TRADE_WITH = nil
TRADE_GIVE, TRADE_GET = {}, {}
function GetTradePlayerItemInfo(i) local e = TRADE_GIVE[i]; if e then return e[1], "tex", e[2] end end
function GetTradeTargetItemInfo(i) local e = TRADE_GET[i]; if e then return e[1], "tex", e[2] end end
function GetPlayerTradeMoney() return 0 end
function GetTargetTradeMoney() return 0 end
SlashCmdList = {}

function fire(ev, a1, a2)
  for _, f in ipairs(FRAMES) do
    if f.events[ev] and f.scripts.OnEvent then
      this, event, arg1, arg2 = f, ev, a1, a2
      f.scripts.OnEvent()
    end
  end
end
function tick(sec)
  for _ = 1, math.floor(sec / 0.25) do
    CLOCK = CLOCK + 0.25
    for _, f in ipairs(FRAMES) do
      if f.scripts.OnUpdate and f.kind == "Frame" and f.events.PLAYER_LOGIN then
        this, arg1 = f, 0.25
        f.scripts.OnUpdate()
      end
    end
  end
end
function slash(msg) SlashCmdList.BANKLEDGER(msg) end
'''

SCENARIO = r'''
local function it(id, name, q, t, st, loc, tip) ITEMS[id] = { name, q, t, st, loc, tip = tip or { name } } end
it(7076, "Essence of Earth", 2, "Trade Goods", "Trade Goods")
it(7077, "Heart of Fire", 2, "Trade Goods", "Trade Goods")
it(7068, "Elemental Fire", 1, "Reagent", "Reagent")
it(11024, "Evergreen Herb Casing", 1, "Quest", "Quest")
it(6948, "Hearthstone", 1, "Miscellaneous", "Junk")
it(2915, "Taran Icebreaker", 3, "Weapon", "Two-Handed Maces", "INVTYPE_2HWEAPON",
  { "Taran Icebreaker", "Binds when equipped", "Two-Hand", "+21 Strength", "Requires Level 59" })
it(14637, "Earthborn Kilt", 3, "Armor", "Leather", "INVTYPE_LEGS",
  { "Earthborn Kilt", "Binds when equipped", "Legs Leather", "+15 Stamina", "+14 Spirit", "Requires Level 55" })
it(10055, "Dreamweave Gloves", 2, "Armor", "Cloth", "INVTYPE_HAND",
  { "Dreamweave Gloves", "+10 Intellect", "+10 Spirit", "Requires Level 40" })
it(18803, "Finkle's Lava Dredger", 4, "Weapon", "Two-Handed Maces", "INVTYPE_2HWEAPON",
  { "Finkle's Lava Dredger", "Soulbound", "Requires Level 60" })
it(2802, "Blazing Emblem", 3, "Armor", "Miscellaneous", "INVTYPE_TRINKET",
  { "Blazing Emblem", "+15 Fire Resistance", "Requires Level 43", "Classes: Warrior, Paladin" })
it(20025, "Formula: Enchant Chest - Greater Stats", 4, "Recipe", "Enchanting", nil,
  { "Formula: Enchant Chest - Greater Stats", "Requires Enchanting (300)" })
it(14274, "Gaea's Leggings of Healing", 2, "Armor", "Cloth", "INVTYPE_LEGS",
  { "Gaea's Leggings of Healing", "Legs Cloth", "+22 Healing Spells", "Requires Level 46" })
it(10172, "Mystical Mantle of Shadow Wrath", 2, "Armor", "Cloth", "INVTYPE_SHOULDER",
  { "Mystical Mantle of Shadow Wrath", "+12 Shadow Spell Damage", "Requires Level 50" })
it(14468, "Pattern: Runecloth Bag", 2, "Recipe", "Tailoring", nil,
  { "Pattern: Runecloth Bag", "Requires Tailoring (260)", "Runecloth Bag", "Requires Level 55" })
it(8007, "Tome of Conjure Food", 1, "Recipe", "Book")
it(14046, "Runecloth Bag", 2, "Container", "Bag", "INVTYPE_BAG")

-- pfQuest's item names (id -> name), used for mail attachments that have no link in 1.12
it(8394, "Basilisk Brain", 1, "Trade Goods", "Trade Goods")
it(10061, "Duskwoven Turban", 2, "Armor", "Cloth", "INVTYPE_HEAD")
pfDB = { items = { enUS = { [8394] = "Basilisk Brain", [10061] = "Duskwoven Turban" } } }

-- bags: some stock plus a hearthstone and a soulbound weapon that must not be listed
put(0, 1, 6948, 1)
put(0, 2, 7076, 4)
put(0, 3, 18803, 1)
put(0, 4, 2915, 1)
put(1, 1, 7068, 6)
fire("PLAYER_LOGIN")
tick(1)

-- bank visit: lots of recipes to force page splits
put(-1, 1, 14637, 1)
put(-1, 2, 10055, 2)
put(-1, 3, 2802, 1)
put(-1, 4, 20025, 1)
put(-1, 5, 14468, 1)
put(-1, 6, 8007, 1)
put(-1, 7, 14046, 2)
put(-1, 8, 7076, 6)
put(-1, 9, 11024, 3)
put(6, 1, 14274, 1)
put(6, 2, 10172, 1)
for i = 1, 110 do
  local id = 30000 + i
  it(id, "Formula: Enchant Test Item Number " .. i, 2, "Recipe", "Enchanting", nil,
    { "Formula: Enchant Test Item Number " .. i, "Requires Enchanting (" .. (100 + i) .. ")" })
  put(i <= 15 and -1 or 5, i <= 15 and (9 + i) or (i - 15), id, 1)
end
BAGS[5] = BAGS[5]
BANK_OPEN = true
fire("BANKFRAME_OPENED")
tick(1)
BANK_OPEN = false
fire("BANKFRAME_CLOSED")
tick(1)
slash("mark")

-- after the post: mail from a player with an item, an AH sale with money, one unknown item
MAILS = {
  { from = "Aldren", item = "Heart of Fire", c = 2, tip = { "Heart of Fire" } },
  { from = "Auction House", money = 50000 },
  { from = "Brisa", item = "Basilisk Brain", c = 2, tip = { "Basilisk Brain" } },
  { from = "Brisa", item = "Duskwoven Turban of Fiery Wrath", c = 1,
    tip = { "Duskwoven Turban of Fiery Wrath", "Head Cloth", "+11 Fire Spell Damage", "Requires Level 48" } },
  { from = "Corwyn", item = "Pattern: Mooncloth Robe", c = 1, days = 2,
    tip = { "Pattern: Mooncloth Robe", "Requires Tailoring (285)" } },
}
fire("MAIL_SHOW")
fire("MAIL_INBOX_UPDATE")
tick(1)
MAIL_PAGES_BEFORE_TAKE = true
TakeInboxItem(1)
put(1, 2, 7077, 2)          -- the attachment lands in the bags
table.remove(MAILS, 1)
fire("BAG_UPDATE", 1)
fire("MAIL_INBOX_UPDATE")
tick(1)
TakeInboxMoney(1)
MONEY = MONEY + 50000
fire("PLAYER_MONEY")
table.remove(MAILS, 1)
fire("MAIL_INBOX_UPDATE")
tick(1)

-- send a request out by mail
SEND = { "Taran Icebreaker", 1 }
SendMail("Dunmar", "", "")
BAGS[0][4] = nil
SEND = nil
fire("MAIL_SEND_SUCCESS")
fire("BAG_UPDATE", 0)
tick(1)
fire("MAIL_CLOSED")

-- trade: Elwyn gives 5 Elemental Fire
TRADE_WITH = "Elwyn"
fire("TRADE_SHOW")
TRADE_GET = { { "Elemental Fire", 5 } }
fire("TRADE_TARGET_ITEM_CHANGED")
fire("TRADE_ACCEPT_UPDATE", 1, 1)
fire("UI_INFO_MESSAGE", "Trade complete.")
BAGS[1][1].c = 11
fire("BAG_UPDATE", 1)
tick(1)

slash("cat Evergreen Herb Casing = TRADE GOODS")
slash("status")
fire("PLAYER_LOGOUT")
'''


def main():
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(STUB)
    with open(ADDON) as f:
        rt.execute(f.read())
    rt.execute(SCENARIO)
    g = rt.globals()
    cdb = g.BankLedgerDB.chars["Kronos V:Amberbank"]
    pages = [cdb.pages[i] for i in range(1, len(cdb.pages) + 1)]
    log = [dict(cdb.log[i]) for i in range(1, len(cdb.log) + 1)]
    chat = [g.CHAT[i] for i in range(1, len(g.CHAT) + 1)]
    if "--print" in sys.argv:
        for p in pages:
            print(p, "\n" + "=" * 60)
        for c in chat:
            print("CHAT", c)
    text = "\n".join(pages)
    ok = True

    def check(cond, what):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + what)
        ok = ok and cond

    check(all(len(p) <= 2000 for p in pages), "every page fits a Discord message (%s)" % [len(p) for p in pages])
    check("Hearthstone" not in text, "hearthstone hidden")
    check("Finkle" not in text, "soulbound item skipped")
    check("Essence of Earth x10" in text, "bags + bank merged (4 + 6)")
    check("- Earthborn Kilt (lvl 55 leather legs, sta/spi)" in text, "gear description")
    check("- Taran Icebreaker" not in text.split("**NEW IN")[0], "item mailed out is gone from stock")
    check("Blazing Emblem (lvl 43 trinket, fire res, Warrior, Paladin only)" in text, "trinket with class restriction")
    check("Gaea's Leggings of Healing (lvl 46 cloth legs, healing)" in text, "suffix healing")
    check("Mystical Mantle of Shadow Wrath (lvl 50 cloth shoulders, shadow dmg)" in text, "suffix school damage")
    check("- Enchant Chest - Greater Stats (300)" in text, "recipe prefix stripped, skill shown")
    check("**RECIPES - ENCHANTING** (1/" in text, "enchanting split over pages")
    check("Mooncloth Robe (285)" in text and "**RECIPES - TAILORING**" in text, "mailbox recipe categorised from tooltip")
    check("Tome of Conjure Food" in text.split("**BOOKS & TOMES**")[1], "book category")
    check("**RECIPES - ALCHEMY**\nNothing in stock." in text, "empty category kept")
    check("144g 52s" in text, "gold incl. AH money: %s" % [p for p in pages if p.startswith("**GOLD")])
    check("Evergreen Herb Casing x3" in text.split("**WEAPONS")[0], "category override")
    new = [p for p in pages if p.startswith("**NEW IN")][0]
    check("Heart of Fire x2" in new and "Elemental Fire x5" in new, "new since mark")
    check("Thanks to Aldren and Elwyn for the donations!" in new, "donors (no AH, no Corwyn: their mail not taken)")
    check("Formula: Enchant Test" not in new, "old stock not in 'new'")
    dirs = [(l["d"], l["via"], l["who"], l.get("n"), l.get("c"), l.get("m")) for l in log]
    check(("IN", "mail", "Aldren", "Heart of Fire", 2, None) in dirs, "ledger: mail in")
    check(("IN", "mail", "Auction House", None, None, 50000) in dirs, "ledger: money in")
    check(("OUT", "mail", "Dunmar", "Taran Icebreaker", 1, None) in dirs, "ledger: mail out")
    check(("IN", "trade", "Elwyn", "Elemental Fire", 5, None) in dirs, "ledger: trade in")
    check(len(dirs) == 4, "no duplicate ledger entries (%d)" % len(dirs))
    rt.execute('slash("style inline")')
    rt.execute('fire("PLAYER_LOGOUT")')
    inl = "\n".join(cdb.pages[i] for i in range(1, len(cdb.pages) + 1))
    check("__Cloth__: Dreamweave Gloves (lvl 40 cloth gloves, int/spi) x2" in inl, "inline style groups")
    if "--print" in sys.argv:
        print(inl)
    rt.execute('slash("style list")')
    rt.execute('slash("links on")')
    rt.execute('fire("PLAYER_LOGOUT")')
    lp = [cdb.pages[i] for i in range(1, len(cdb.pages) + 1)]
    lt = "\n".join(lp)
    check("- [Earthborn Kilt](<https://www.wowhead.com/classic/item=14637>) (lvl 55 leather legs, sta/spi)" in lt,
          "wowhead link on the name only")
    check("- [Enchant Chest - Greater Stats](<https://www.wowhead.com/classic/item=20025>) (300)" in lt, "recipe link")
    check("[Mooncloth Robe]" not in lt and "- Mooncloth Robe (285)" in lt, "mail item without id stays plain")
    check("- [Basilisk Brain](<https://www.wowhead.com/classic/item=8394>) x2" in lt.split("**WEAPONS")[0],
          "mail item linked via pfQuest, trade goods")
    check("- [Duskwoven Turban of Fiery Wrath](<https://www.wowhead.com/classic/item=10061>) (lvl 48 cloth head, fire dmg)" in lt,
          "mail suffix item linked to base item, stats from the mail tooltip")
    check(all(len(p) <= 2000 for p in lp), "linked pages still fit (%s)" % [len(p) for p in lp])
    if "--print" in sys.argv:
        print("\n".join(p for p in lp if p.startswith(("**WEAPONS", "**TRADE"))))
    if "--dump" in sys.argv:   # pages with wowhead links, as input for poster/bank_post.py --pages
        json.dump(lp, open(sys.argv[sys.argv.index("--dump") + 1], "w"), indent=1)
    sys.exit(0 if ok else 1)


main()
