-- Well Fed Button (WoW Forever)
-- Groups every "Well Fed" food in your bags into one button.
--   Left-click        : eat the food shown on the button
--   Right-click       : expand / collapse the list of all Well Fed food
--   Shift-drag        : move the button
--   Gear (end of list): options menu

local ADDON_NAME = ...

-- Key Bindings (Options > Keybindings > AddOns > Well Fed Button)
local EAT_BINDING = "CLICK WellFedButtonMain:LeftButton"
BINDING_HEADER_WELLFEDBUTTON = "Well Fed Button"
_G["BINDING_NAME_" .. EAT_BINDING] = "Eat Well Fed food"
BINDING_NAME_WELLFEDBUTTON_TOGGLE = "Expand / collapse food list"

---------------------------------------------------------------------------
-- Config / constants
---------------------------------------------------------------------------
local SIZE        = 36      -- same as a Blizzard action button
local GAP         = 6       -- between buttons in the expanded list
local FIRST_GAP   = 12      -- between the main button and the list
local TRAY_PAD    = 7       -- panel padding around the expanded list
local EMPTY_ICON  = 133950  -- inv_misc_food_15 (generic food icon)
local GEAR_ICON   = "Interface\\Icons\\INV_Misc_Gear_01"

-- Forever's palette (as used by Forever's own addons)
local TRAY_BG     = { 0.14, 0.085, 0.035, 0.92 }
local TRAY_BORDER = { 0.95, 0.76, 0.43, 0.95 }

-- WoW Forever's "Nutritious Drink" also gives Well Fed (food is detected by its tooltip).
local NUTRITIOUS_SPELLS = { [1249906] = true }
local NUTRITIOUS_NAMES  = { ["Nutritious Drink"] = true }

local GLOW_COLORS = {
    { key = "blue",  label = "Blue",  rgb = { 0.2, 0.55, 1 } },
    { key = "gold",  label = "Gold",                        rgb = { 1, 0.85, 0.2 } },
    { key = "green", label = "Green",                       rgb = { 0.3, 1, 0.3 } },
    { key = "white", label = "White",                       rgb = { 1, 1, 1 } },
}

local DEFAULTS = {
    mode      = "smallest", -- smallest | recent | value
    direction = "UP",       -- UP | DOWN | LEFT | RIGHT
    expanded  = false,
    glow      = true,
    glowColor = "blue",
    locked    = false,
    scale     = 1,
    point     = nil,        -- { point, relPoint, x, y }
    lastEaten = {},         -- [itemID] = time()
}

local MODES = {
    { key = "smallest", label = "Smallest stack" },
    { key = "recent",   label = "Most recently eaten" },
    { key = "value",    label = "Lowest value (vendor price)" },
}

-- point on new button, point on previous button, x/y sign
local DIRECTIONS = {
    UP    = { "BOTTOM", "TOP",    0,  1 },
    DOWN  = { "TOP",    "BOTTOM", 0, -1 },
    LEFT  = { "RIGHT",  "LEFT",  -1,  0 },
    RIGHT = { "LEFT",   "RIGHT",  1,  0 },
}

local WELL_FED = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(19705))
    or (GetSpellInfo and GetSpellInfo(19705)) or "Well Fed"
local WELL_FED_LOWER = WELL_FED:lower()

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local db
local foodCache   = {}  -- [itemID] = true/false (is Well Fed food)
local spellToItem = {}  -- [spellID] = { [itemID] = true }
local items       = {}  -- sorted list of { itemID, icon, count, sell }
local pendingLayout = false
local retryQueued   = false
local checkAttempts = {}  -- [itemID] = times we looked and saw no "Well Fed"
local MAX_CHECK_ATTEMPTS = 15
local inCombat = UnitAffectingCombat("player") and true or false
local wellFedState  = nil
local lastClicked   = { itemID = nil, t = 0 }

local main          -- the collapsed button
local tray          -- panel behind the expanded list
local gear          -- settings button at the end of the expanded list
local expandButtons = {}

local function Print(msg)
    print("|cffffcc33Well Fed Button:|r " .. msg)
end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function GlowRGB()
    for _, c in ipairs(GLOW_COLORS) do
        if c.key == db.glowColor then return unpack(c.rgb) end
    end
    return unpack(GLOW_COLORS[1].rgb)
end

---------------------------------------------------------------------------
-- Food detection
---------------------------------------------------------------------------
-- Returns true/false, or nil if the item data isn't loaded yet.
local function IsWellFedFood(itemID)
    local cached = foodCache[itemID]
    if cached ~= nil then return cached end

    local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
    if classID ~= 0 then
        foodCache[itemID] = false
        return false
    end

    -- Right after login the item/spell text often isn't loaded yet, so a
    -- "no" here can be wrong. Don't trust a negative until we've looked a
    -- few times; until then return nil so Refresh keeps retrying.
    local function notYet()
        local n = (checkAttempts[itemID] or 0) + 1
        checkAttempts[itemID] = n
        if n >= MAX_CHECK_ATTEMPTS then
            foodCache[itemID] = false
            return false
        end
        return nil
    end

    if not C_Item.IsItemDataCachedByID(itemID) then
        C_Item.RequestLoadItemDataByID(itemID)
        return nil
    end

    local spellName, spellID = C_Item.GetItemSpell(itemID)
    if not spellName then return notYet() end

    if (spellID and NUTRITIOUS_SPELLS[spellID]) or NUTRITIOUS_NAMES[spellName] then
        foodCache[itemID] = true
        return true
    end

    if spellID and C_Spell and C_Spell.IsSpellDataCached
        and not C_Spell.IsSpellDataCached(spellID) then
        C_Spell.RequestLoadSpellData(spellID)
        return nil
    end

    local function hasWellFed(text)
        return text and not IsSecret(text) and text:lower():find(WELL_FED_LOWER, 1, true)
    end

    local data = C_TooltipInfo and C_TooltipInfo.GetItemByID(itemID)
    if data and data.lines then
        for _, line in ipairs(data.lines) do
            if hasWellFed(line.leftText) then
                foodCache[itemID] = true
                return true
            end
        end
    end

    if spellID and C_Spell and C_Spell.GetSpellDescription
        and hasWellFed(C_Spell.GetSpellDescription(spellID)) then
        foodCache[itemID] = true
        return true
    end

    return notYet()
end

local function ScanBags()
    wipe(items)
    local seen, needRetry = {}, false
    local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

    for bag = 0, lastBag do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local itemID = info and info.itemID
            if itemID and not seen[itemID] then
                seen[itemID] = true
                local isFood = IsWellFedFood(itemID)
                if isFood == nil then
                    needRetry = true
                elseif isFood then
                    local sell = select(11, C_Item.GetItemInfo(itemID)) or 0
                    if info.hasNoValue then sell = 0 end
                    items[#items + 1] = {
                        itemID = itemID,
                        icon   = info.iconFileID,
                        count  = C_Item.GetItemCount(itemID),
                        sell   = sell,
                    }
                    local _, spellID = C_Item.GetItemSpell(itemID)
                    if spellID then
                        spellToItem[spellID] = spellToItem[spellID] or {}
                        spellToItem[spellID][itemID] = true
                    end
                end
            end
        end
    end
    return needRetry
end

---------------------------------------------------------------------------
-- Sorting (first item = what the collapsed button shows)
---------------------------------------------------------------------------
local sorters = {}
sorters.smallest = function(a, b)
    if a.count ~= b.count then return a.count < b.count end
    return a.itemID < b.itemID
end
sorters.recent = function(a, b)
    local ta, tb = db.lastEaten[a.itemID] or 0, db.lastEaten[b.itemID] or 0
    if ta ~= tb then return ta > tb end
    return sorters.smallest(a, b)
end
sorters.value = function(a, b)
    if a.sell ~= b.sell then return a.sell < b.sell end
    return sorters.smallest(a, b)
end

---------------------------------------------------------------------------
-- Glow: Blizzard's spell-alert "proc" glow, desaturated and tinted, the same
-- way Glowing Bars draws its default "circling" glow. Falls back to marching
-- dashes if the template isn't available.
---------------------------------------------------------------------------
local GLOW_SCALE = 1.45
local GLOW_ALPHA = 0.95

local function CreateProcGlow(button)
    local ok, alert = pcall(CreateFrame, "Frame", nil, button, "ActionButtonSpellAlertTemplate")
    if not ok or not alert or not alert.ProcStartAnim or not alert.ProcLoop then
        return nil
    end
    alert:SetFrameLevel(button:GetFrameLevel() + 6)
    alert:SetPoint("CENTER", button, "CENTER", 0, 0)
    alert:SetSize(SIZE * GLOW_SCALE, SIZE * GLOW_SCALE)
    alert:SetAlpha(GLOW_ALPHA)
    if alert.ProcAltGlow then alert.ProcAltGlow:Hide() end

    alert:SetScript("OnShow", function(self)
        self.ProcLoop:Stop()
        if self.ProcStartFlipbook then self.ProcStartFlipbook:Show() end
        if self.ProcLoopFlipbook then self.ProcLoopFlipbook:SetAlpha(0) end
        self.ProcStartAnim:Play() -- the template chains into the looping animation
    end)
    alert:SetScript("OnHide", function(self)
        self.ProcStartAnim:Stop()
        self.ProcLoop:Stop()
    end)

    function alert:SetGlowColor(r, g, b)
        for _, tex in ipairs({ self.ProcStartFlipbook, self.ProcLoopFlipbook }) do
            if tex then
                tex:SetDesaturated(true)
                tex:SetVertexColor(r, g, b)
            end
        end
    end
    alert:Hide()
    return alert
end

-- Fallback: dashes marching around the border.
local DASHES, DASH_LEN, DASH_THICK, DASH_PERIOD = 8, 8, 2, 3

local function EdgeOf(p, w, h)
    if p < w then return 1, 0 end
    if p < w + h then return 2, w end
    if p < 2 * w + h then return 3, w + h end
    return 4, 2 * w + h
end

local function EdgeLen(edge, w, h)
    return (edge == 1 or edge == 3) and w or h
end

local function PlaceDash(g, tex, edge, a, b)
    local len = b - a
    if len <= 0 then tex:Hide() return end
    tex:ClearAllPoints()
    if edge == 1 then
        tex:SetPoint("TOPLEFT", g, "TOPLEFT", a, 0);          tex:SetSize(len, DASH_THICK)
    elseif edge == 2 then
        tex:SetPoint("TOPRIGHT", g, "TOPRIGHT", 0, -a);       tex:SetSize(DASH_THICK, len)
    elseif edge == 3 then
        tex:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", -a, 0); tex:SetSize(len, DASH_THICK)
    else
        tex:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 0, a);    tex:SetSize(DASH_THICK, len)
    end
    tex:Show()
end

local function CreateDashGlow(button)
    local g = CreateFrame("Frame", nil, button)
    g:SetPoint("TOPLEFT", -2, 2)
    g:SetPoint("BOTTOMRIGHT", 2, -2)
    g:SetFrameLevel(button:GetFrameLevel() + 6)
    g.t = 0
    g.dashes = {}
    for i = 1, DASHES do
        g.dashes[i] = { g:CreateTexture(nil, "OVERLAY"), g:CreateTexture(nil, "OVERLAY") }
    end
    g:SetScript("OnUpdate", function(self, elapsed)
        self.t = (self.t + elapsed / DASH_PERIOD) % 1
        local w, h = self:GetSize()
        if w <= 0 or h <= 0 then return end
        local per = 2 * (w + h)
        for i = 1, DASHES do
            local d = self.dashes[i]
            local s = ((self.t + (i - 1) / DASHES) % 1) * per
            local edge, start = EdgeOf(s, w, h)
            local a = s - start
            local b = a + DASH_LEN
            local elen = EdgeLen(edge, w, h)
            if b <= elen then
                PlaceDash(self, d[1], edge, a, b)
                d[2]:Hide()
            else
                PlaceDash(self, d[1], edge, a, elen)
                local nextEdge = edge % 4 + 1
                PlaceDash(self, d[2], nextEdge, 0, math.min(b - elen, EdgeLen(nextEdge, w, h)))
            end
        end
    end)
    function g:SetGlowColor(r, gg, b)
        for _, d in ipairs(self.dashes) do
            for j = 1, 2 do d[j]:SetColorTexture(r, gg, b, 1) end
        end
    end
    g:Hide()
    return g
end

local function CreateGlow(button)
    return CreateProcGlow(button) or CreateDashGlow(button)
end

---------------------------------------------------------------------------
-- Buttons (styled like a Blizzard action button / Forever's quickslots)
---------------------------------------------------------------------------
local ToggleExpanded, OpenMenu, SavePosition -- forward declarations

-- Mouse icons like Bagnon: |L left, |R right, |LS shift+left, |RS shift+right.
-- The shift icons are Bagnon's own art, so use them only when it's installed.
local LEFT_ICON  = "|A:NPE_LeftClick:14:14|a"
local RIGHT_ICON = "|A:NPE_RightClick:14:14|a"
local SHIFT_ART  = "|TInterface/AddOns/BagBrother/art/shift:14:26.6875:0:0:64:64:0:61:%s|t"

local function ClickMarkup()
    local hasBagnon = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("BagBrother")
    return {
        ["|LS"] = hasBagnon and SHIFT_ART:format("0:32")  or ("Shift " .. LEFT_ICON),
        ["|RS"] = hasBagnon and SHIFT_ART:format("32:64") or ("Shift " .. RIGHT_ICON),
        ["|L"]  = LEFT_ICON,
        ["|R"]  = RIGHT_ICON,
    }
end

local function AddHint(text)
    GameTooltip:AddLine((text:gsub("(%|%u+)", ClickMarkup())), 0.5, 0.8, 1)
end

local function Button_OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.itemID then
        GameTooltip:SetItemByID(self.itemID)
    else
        GameTooltip:AddLine("Well Fed Button")
        GameTooltip:AddLine("No Well Fed food in your bags.", 1, 1, 1)
    end
    -- Control hints only on the main button; the list just shows the item.
    if self == main then
        GameTooltip:AddLine(" ")
        if self.itemID then AddHint("|L Eat") end
        AddHint("|R " .. (db.expanded and "Collapse" or "Expand"))
        if not db.locked then AddHint("|LS Drag to move") end
    end
    GameTooltip:Show()
end

local function Button_OnDragStart(self)
    if IsShiftKeyDown() and not db.locked and not InCombatLockdown() then
        main.isMoving = true
        main:StartMoving()
    end
end

local function Button_OnDragStop(self)
    if not main.isMoving then return end
    main:StopMovingOrSizing()
    main:SetUserPlaced(false)
    SavePosition()
    main.isMoving = false
    main.dragEndedAt = GetTime()
end

local function JustDragged()
    return main.isMoving or (main.dragEndedAt and GetTime() - main.dragEndedAt < 0.3)
end

local function Button_PostClick(self, button, down)
    if down or JustDragged() then return end -- act once per click (on release), never after a drag
    if button == "RightButton" then
        if not IsShiftKeyDown() then ToggleExpanded() end
    elseif button == "LeftButton" and not IsShiftKeyDown() and self.itemID then
        lastClicked.itemID, lastClicked.t = self.itemID, GetTime()
    end
end

-- Action-button look shared by the food buttons and the gear button.
local function StyleButton(b)
    b:SetSize(SIZE, SIZE)
    b:RegisterForDrag("LeftButton")

    local slot = b:CreateTexture(nil, "BACKGROUND")
    slot:SetAllPoints()
    slot:SetColorTexture(0, 0, 0, 0.6)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Blizzard's quickslot frame (what action buttons wear)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetSize(SIZE * 66 / 36, SIZE * 66 / 36)
    border:SetPoint("CENTER", b, "CENTER", 0, -1)
    b.border = border

    b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    b:SetScript("OnLeave", GameTooltip_Hide)
    b:SetScript("OnDragStart", Button_OnDragStart)
    b:SetScript("OnDragStop", Button_OnDragStop)
end

local function CreateItemButton(name, parent)
    local b = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
    StyleButton(b)
    b:RegisterForClicks("AnyUp", "AnyDown")

    b.Count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.Count:SetPoint("BOTTOMRIGHT", -2, 2)

    -- Shift-left-click (drag) must NOT eat: give it a do-nothing macro action.
    -- Right-click has no secure action at all; it only expands / collapses.
    b:SetAttribute("shift-type1", "macro")

    b:SetScript("OnEnter", Button_OnEnter)
    b:SetScript("PostClick", Button_PostClick)
    return b
end

local function CreateGearButton(parent)
    local b = CreateFrame("Button", "WellFedButtonSettings", parent)
    StyleButton(b)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.icon:SetTexture(GEAR_ICON)
    b:SetScript("OnClick", function(self)
        if not JustDragged() then OpenMenu(self) end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Settings")
        AddHint("|L Open settings")
        GameTooltip:Show()
    end)
    b:Hide()
    return b
end

-- Secure part: only call out of combat.
local function SetButtonItem(b, it)
    if it then
        b.itemID = it.itemID
        b:SetAttribute("type1", "item")
        b:SetAttribute("item", "item:" .. it.itemID)
        b.icon:SetTexture(it.icon)
    else
        b.itemID = nil
        b:SetAttribute("type1", nil)
        b:SetAttribute("item", nil)
        b.icon:SetTexture(EMPTY_ICON)
    end
end

-- Non-secure part: safe any time.
local function UpdateCount(b)
    local count = b.itemID and C_Item.GetItemCount(b.itemID) or 0
    b.Count:SetText(b.itemID and count or "")
    b.icon:SetDesaturated(count == 0)
    if count == 0 then
        b.icon:SetVertexColor(0.6, 0.6, 0.6)
        return
    end
    -- Dim like an action bar does when the item can't be used right now
    -- (in combat, too low level, etc.).
    local usable = C_Item.IsUsableItem(b.itemID)
    if usable and inCombat then usable = false end
    local v = usable and 1 or 0.4
    b.icon:SetVertexColor(v, v, v)
end

local function UpdateAllCounts()
    if not main then return end
    UpdateCount(main)
    for _, b in ipairs(expandButtons) do
        if b:IsShown() then UpdateCount(b) end
    end
end

local function GetExpandButton(i)
    local b = expandButtons[i]
    if not b then
        b = CreateItemButton("WellFedButtonItem" .. i, main)
        expandButtons[i] = b
    end
    return b
end

local function CreateTray()
    local t = CreateFrame("Frame", nil, main, BackdropTemplateMixin and "BackdropTemplate" or nil)
    t:SetFrameLevel(math.max(main:GetFrameLevel() - 1, 0))
    t:EnableMouse(false)
    if t.SetBackdrop then
        t:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets   = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        t:SetBackdropColor(unpack(TRAY_BG))
        t:SetBackdropBorderColor(unpack(TRAY_BORDER))
    end
    t:Hide()
    return t
end

-- Fit the panel around the first..last expanded buttons.
local function LayoutTray(first, last)
    tray:ClearAllPoints()
    local d = db.direction
    local p = TRAY_PAD
    if d == "UP" then
        tray:SetPoint("BOTTOMLEFT", first, "BOTTOMLEFT", -p, -p)
        tray:SetPoint("TOPRIGHT", last, "TOPRIGHT", p, p)
    elseif d == "DOWN" then
        tray:SetPoint("TOPLEFT", first, "TOPLEFT", -p, p)
        tray:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT", p, -p)
    elseif d == "LEFT" then
        tray:SetPoint("TOPRIGHT", first, "TOPRIGHT", p, p)
        tray:SetPoint("BOTTOMLEFT", last, "BOTTOMLEFT", -p, -p)
    else
        tray:SetPoint("TOPLEFT", first, "TOPLEFT", -p, p)
        tray:SetPoint("BOTTOMRIGHT", last, "BOTTOMRIGHT", p, -p)
    end
end

---------------------------------------------------------------------------
-- Glow condition
---------------------------------------------------------------------------
local function CheckWellFed()
    local ok, result = pcall(function()
        for i = 1, 255 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then return false end
            local name = aura.name
            if IsSecret(name) then return nil end
            if name and name:find(WELL_FED, 1, true) then return true end
        end
        return false
    end)
    if ok then return result end
    return nil
end

local function UpdateGlow()
    if not main then return end
    local fed = CheckWellFed()
    if fed ~= nil then wellFedState = fed end

    main.glow:SetGlowColor(GlowRGB())
    local show = db.glow
        and #items > 0
        and not UnitIsDeadOrGhost("player")
        and wellFedState == false
    main.glow:SetShown(show)
end

---------------------------------------------------------------------------
-- Layout / refresh
---------------------------------------------------------------------------
local function ApplyLayout()
    if InCombatLockdown() then
        pendingLayout = true
        return
    end
    pendingLayout = false

    main:SetScale(db.scale or 1)
    SetButtonItem(main, items[1])
    UpdateCount(main)

    local dir = DIRECTIONS[db.direction] or DIRECTIONS.UP
    local prev = main
    for i, it in ipairs(items) do
        local b = GetExpandButton(i)
        SetButtonItem(b, it)
        UpdateCount(b)
        local gap = (i == 1) and FIRST_GAP or GAP
        b:ClearAllPoints()
        b:SetPoint(dir[1], prev, dir[2], dir[3] * gap, dir[4] * gap)
        b:SetShown(db.expanded)
        prev = b
    end
    for i = #items + 1, #expandButtons do
        expandButtons[i]:Hide()
        SetButtonItem(expandButtons[i], nil)
    end

    -- Gear goes at the end of the list (shown even when there's no food).
    local gap = (#items == 0) and FIRST_GAP or GAP
    gear:ClearAllPoints()
    gear:SetPoint(dir[1], prev, dir[2], dir[3] * gap, dir[4] * gap)
    gear:SetShown(db.expanded)

    if db.expanded then
        LayoutTray(expandButtons[1] and #items > 0 and expandButtons[1] or gear, gear)
        tray:Show()
    else
        tray:Hide()
    end
    UpdateGlow()
end

local function Refresh()
    if not main then return end
    local needRetry = ScanBags()
    table.sort(items, sorters[db.mode] or sorters.smallest)

    if InCombatLockdown() then
        pendingLayout = true
        UpdateAllCounts()
        UpdateGlow()
    else
        ApplyLayout()
    end

    if needRetry and not retryQueued then
        retryQueued = true
        C_Timer.After(1, function()
            retryQueued = false
            Refresh()
        end)
    end
end

function ToggleExpanded()
    if InCombatLockdown() then
        Print("Can't expand or collapse in combat.")
        return
    end
    db.expanded = not db.expanded
    ApplyLayout()
    if GameTooltip:GetOwner() == main then Button_OnEnter(main) end
end

-- Clicking anywhere outside the food bar (main button + list panel) closes it.
-- Ignored while an options menu is open, so menu clicks never close the bar.
local function IsMenuOpen()
    local ok, open = pcall(function()
        local mgr = Menu and Menu.GetManager and Menu.GetManager()
        return mgr and mgr:GetOpenMenu() ~= nil
    end)
    return ok and open
end

local function OnGlobalMouseDown()
    if not db.expanded or InCombatLockdown() or IsMenuOpen() then return end
    if main:IsMouseOver() or tray:IsMouseOver() or gear:IsMouseOver() then return end
    db.expanded = false
    ApplyLayout()
end

-- Used by the "Expand / collapse" key binding in Bindings.xml.
function WellFedButton_ToggleExpanded()
    if main then ToggleExpanded() end
end

local function UpdateHotkeyText()
    if not main then return end
    local key = GetBindingKey(EAT_BINDING)
    if key and GetBindingText then key = GetBindingText(key, true) end
    main.HotKey:SetText(key or "")
end

---------------------------------------------------------------------------
-- Position
---------------------------------------------------------------------------
function SavePosition()
    local point, _, relPoint, x, y = main:GetPoint(1)
    db.point = { point, relPoint, x, y }
end

local function RestorePosition()
    main:ClearAllPoints()
    local p = db.point
    if p then
        main:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        main:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    end
end

---------------------------------------------------------------------------
-- Options menu (right-click)
---------------------------------------------------------------------------
local function SetMode(mode)
    db.mode = mode
    Refresh()
end

local function SetDirection(dir)
    db.direction = dir
    ApplyLayout()
end

function OpenMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        Print("Type /wfb for options.")
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Well Fed Button")

        root:CreateTitle("Collapsed button shows:")
        for _, m in ipairs(MODES) do
            root:CreateRadio(m.label,
                function() return db.mode == m.key end,
                function() SetMode(m.key) end)
        end

        root:CreateDivider()
        root:CreateTitle("Expand direction:")
        for _, d in ipairs({ "UP", "DOWN", "LEFT", "RIGHT" }) do
            root:CreateRadio(d:sub(1, 1) .. d:sub(2):lower(),
                function() return db.direction == d end,
                function() SetDirection(d) end)
        end

        root:CreateDivider()
        root:CreateCheckbox("Glow when not Well Fed",
            function() return db.glow end,
            function() db.glow = not db.glow; UpdateGlow() end)
        local colors = root:CreateButton("Glow color")
        for _, c in ipairs(GLOW_COLORS) do
            colors:CreateRadio(c.label,
                function() return db.glowColor == c.key end,
                function() db.glowColor = c.key; UpdateGlow() end)
        end

        root:CreateDivider()
        root:CreateCheckbox("Lock position",
            function() return db.locked end,
            function() db.locked = not db.locked end)
        root:CreateButton("Reset position", function()
            if InCombatLockdown() then return end
            db.point = nil
            RestorePosition()
        end)
    end)
end

---------------------------------------------------------------------------
-- Creation
---------------------------------------------------------------------------
local function CreateMain()
    main = CreateItemButton("WellFedButtonMain", UIParent)
    main:SetMovable(true)
    main:SetClampedToScreen(true)

    main.HotKey = main:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    main.HotKey:SetPoint("TOPLEFT", 1, -3)
    main.HotKey:SetPoint("TOPRIGHT", -2, -3)
    main.HotKey:SetJustifyH("RIGHT")

    main.glow = CreateGlow(main)
    tray = CreateTray()
    gear = CreateGearButton(main)
    RestorePosition()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function OnSpellcast(spellID)
    if not spellID or IsSecret(spellID) then return end
    local candidates = spellToItem[spellID]
    if not candidates then return end

    local itemID
    if lastClicked.itemID and candidates[lastClicked.itemID] and GetTime() - lastClicked.t < 5 then
        itemID = lastClicked.itemID
    else
        local n = 0
        for id in pairs(candidates) do n = n + 1; itemID = id end
        if n ~= 1 then itemID = nil end -- shared "Food" spell; can't tell which item
    end
    if itemID then
        db.lastEaten[itemID] = time()
        if db.mode == "recent" then Refresh() end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")

        WellFedButtonDB = WellFedButtonDB or {}
        db = WellFedButtonDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then
                db[k] = type(v) == "table" and CopyTable(v) or v
            end
        end

        CreateMain()

        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("BAG_UPDATE_DELAYED")
        self:RegisterEvent("GET_ITEM_INFO_RECEIVED")
        pcall(self.RegisterEvent, self, "SPELL_DATA_LOAD_RESULT")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        self:RegisterEvent("SPELL_UPDATE_USABLE")
        self:RegisterEvent("PLAYER_LEVEL_UP")
        self:RegisterEvent("PLAYER_DEAD")
        self:RegisterEvent("PLAYER_ALIVE")
        self:RegisterEvent("PLAYER_UNGHOST")
        self:RegisterEvent("UPDATE_BINDINGS")
        pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN")
        self:RegisterUnitEvent("UNIT_AURA", "player")
        self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

    elseif event == "PLAYER_ENTERING_WORLD" or event == "BAG_UPDATE_DELAYED" then
        Refresh()
        if event == "PLAYER_ENTERING_WORLD" then UpdateHotkeyText() end

    elseif event == "UPDATE_BINDINGS" then
        UpdateHotkeyText()

    elseif event == "GLOBAL_MOUSE_DOWN" then
        OnGlobalMouseDown()

    elseif event == "GET_ITEM_INFO_RECEIVED" or event == "SPELL_DATA_LOAD_RESULT" then
        if not retryQueued then
            retryQueued = true
            C_Timer.After(0.3, function()
                retryQueued = false
                Refresh()
            end)
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        if pendingLayout then ApplyLayout() else UpdateGlow() end
        UpdateAllCounts()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        UpdateAllCounts()

    elseif event == "SPELL_UPDATE_USABLE"
        or event == "PLAYER_LEVEL_UP" then
        UpdateAllCounts()

    elseif event == "UNIT_AURA" or event == "PLAYER_DEAD"
        or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        UpdateGlow()

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        OnSpellcast(spellID)
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_WELLFEDBUTTON1 = "/wfb"
SLASH_WELLFEDBUTTON2 = "/wellfed"
SlashCmdList.WELLFEDBUTTON = function(msg)
    local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "mode" and sorters[arg] then
        SetMode(arg)
        Print("Collapsed button shows: " .. arg)
    elseif cmd == "dir" and DIRECTIONS[arg:upper()] then
        SetDirection(arg:upper())
    elseif cmd == "scale" and tonumber(arg) then
        db.scale = math.max(0.5, math.min(3, tonumber(arg)))
        ApplyLayout()
    elseif cmd == "glow" then
        db.glow = not db.glow
        UpdateGlow()
        Print("Glow " .. (db.glow and "on" or "off"))
    elseif cmd == "color" then
        for _, c in ipairs(GLOW_COLORS) do
            if c.key == arg then db.glowColor = arg; UpdateGlow(); return end
        end
        Print("Colors: blue, gold, green, white")
    elseif cmd == "lock" then
        db.locked = not db.locked
        Print(db.locked and "Locked" or "Unlocked (Shift-drag to move)")
    elseif cmd == "rescan" then
        wipe(foodCache)
        wipe(checkAttempts)
        Refresh()
        Print("Rescanning bags for Well Fed food.")
    elseif cmd == "reset" then
        if InCombatLockdown() then return end
        db.point = nil
        RestorePosition()
    else
        Print("Commands:")
        print("  /wfb mode smallest | recent | value")
        print("  /wfb dir up | down | left | right")
        print("  /wfb scale <0.5-3>")
        print("  /wfb glow   - toggle the glow")
        print("  /wfb color blue | gold | green | white")
        print("  /wfb lock   - toggle Shift-drag moving")
        print("  /wfb reset  - reset position")
        print("  /wfb rescan - look through your bags for food again")
    end
end
