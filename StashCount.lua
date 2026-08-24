local ADDON_NAME, _ = ...

-- Personal, on-body containers (bags + reagent bag). Bank/Warband tabs are
-- discovered at runtime via C_Bank.FetchPurchasedBankTabIDs since players
-- buy tabs incrementally -- never hardcode how many exist.
local PERSONAL_BAG_IDS = {
    Enum.BagIndex.Backpack,
    Enum.BagIndex.Bag_1,
    Enum.BagIndex.Bag_2,
    Enum.BagIndex.Bag_3,
    Enum.BagIndex.Bag_4,
    Enum.BagIndex.ReagentBag,
}

local bankOpen = false

local function CharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

local function EnsureCharEntry()
    local key = CharKey()
    StashCountDB.characters[key] = StashCountDB.characters[key] or { bags = {}, bank = {} }
    return StashCountDB.characters[key]
end

-- Flat scan for containers that are always fully loaded client-side
-- (personal bags). Returns {itemID -> count}.
local function ScanBagSet(bagIDs)
    local counts = {}
    for _, bagID in ipairs(bagIDs) do
        local numSlots = bagID and C_Container.GetContainerNumSlots(bagID)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bagID, slot)
                if info and info.itemID then
                    counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
                end
            end
        end
    end
    return counts
end

-- Bank/Warband tabs reportedly only have live data for whichever tab is
-- currently active in the UI -- the others report their slot count but
-- every slot query comes back nil. So: store counts PER TAB, and only
-- overwrite a given tab's cached snapshot when the scan actually saw real
-- slot data back (sawAny), never when it looks empty-because-not-loaded.
-- tabStore shape: { [tabID] = {itemID -> count}, ... }
local function ScanTabInto(tabStore, tabID)
    local numSlots = tabID and C_Container.GetContainerNumSlots(tabID)
    if not numSlots or numSlots == 0 then return end
    local counts, sawAny = {}, false
    for slot = 1, numSlots do
        local info = C_Container.GetContainerItemInfo(tabID, slot)
        if info then sawAny = true end
        if info and info.itemID then
            counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
        end
    end
    if sawAny then
        tabStore[tabID] = counts
    end
end

local function SumTabs(tabStore, itemID)
    local total = 0
    if tabStore then
        for _, counts in pairs(tabStore) do
            total = total + (counts[itemID] or 0)
        end
    end
    return total
end

local function GetPurchasedTabs(bankType)
    if not C_Bank or not C_Bank.FetchPurchasedBankTabIDs then return {} end
    local ok, tabs = pcall(C_Bank.FetchPurchasedBankTabIDs, bankType)
    return (ok and tabs) or {}
end

local function ScanPersonalBags()
    local charData = EnsureCharEntry()
    charData.bags = ScanBagSet(PERSONAL_BAG_IDS)
    charData.lastUpdate = time()
end

local function ScanPersonalBank()
    local tabs = GetPurchasedTabs(Enum.BankType.Character)
    if #tabs == 0 then return end
    local charData = EnsureCharEntry()
    charData.bank = charData.bank or {}
    for _, tabID in ipairs(tabs) do
        ScanTabInto(charData.bank, tabID)
    end
    charData.lastUpdate = time()
end

local function ScanWarbandBank()
    local tabs = GetPurchasedTabs(Enum.BankType.Account)
    if #tabs == 0 then return end
    StashCountDB.warband.tabs = StashCountDB.warband.tabs or {}
    for _, tabID in ipairs(tabs) do
        ScanTabInto(StashCountDB.warband.tabs, tabID)
    end
    StashCountDB.warband.lastUpdate = time()
end

-- Events

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        StashCountDB = StashCountDB or { characters = {}, warband = { tabs = {} } }
        StashCountDB.characters = StashCountDB.characters or {}
        StashCountDB.warband = StashCountDB.warband or { tabs = {} }
        StashCountDB.warband.tabs = StashCountDB.warband.tabs or {}
        EnsureCharEntry()

    elseif event == "PLAYER_ENTERING_WORLD" then
        ScanPersonalBags()

    elseif event == "BAG_UPDATE_DELAYED" then
        ScanPersonalBags()
        -- Switching bank/warband tabs while the bank is open causes their
        -- contents to (re)load, which shows up as a bag update -- this is
        -- how we catch each tab without knowing the exact tab-switch event.
        if bankOpen then
            ScanPersonalBank()
            ScanWarbandBank()
        end

    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        local PIT = Enum.PlayerInteractionType
        -- Patch 11.0 split the generic Banker type into CharacterBanker /
        -- AccountBanker; check all three since it's cheap and one of them
        -- will exist on any given client build.
        if arg1 == PIT.Banker or arg1 == PIT.CharacterBanker or arg1 == PIT.AccountBanker then
            bankOpen = true
            -- Slight delay: the first tab's contents populate right after
            -- the interaction opens, not synchronously with this event.
            C_Timer.After(0.3, function()
                ScanPersonalBank()
                ScanWarbandBank()
            end)
        end

    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local PIT = Enum.PlayerInteractionType
        if arg1 == PIT.Banker or arg1 == PIT.CharacterBanker or arg1 == PIT.AccountBanker then
            bankOpen = false
        end
    end
end)

-- Tooltip

local function AddStashLines(tooltip, data)
    -- Prefer the data payload: not every tooltip that fires this callback
    -- (e.g. the comparison "ShoppingTooltip") implements :GetItem().
    local itemLink = data and data.hyperlink
    if not itemLink and tooltip and tooltip.GetItem then
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok then itemLink = link end
    end
    if not itemLink then return end
    local itemID = (C_Item and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(itemLink))
        or (GetItemInfoInstant and GetItemInfoInstant(itemLink))
    if not itemID then return end

    local rows = {}
    local personalTotal = 0
    local oldestUpdate = nil
    for charKey, charData in pairs(StashCountDB.characters) do
        local bags = (charData.bags and charData.bags[itemID]) or 0
        local bank = SumTabs(charData.bank, itemID)
        if bags > 0 or bank > 0 then
            rows[#rows + 1] = { name = charKey:match("^(.-)%-") or charKey, bags = bags, bank = bank }
            personalTotal = personalTotal + bags + bank
            if charData.lastUpdate and (not oldestUpdate or charData.lastUpdate < oldestUpdate) then
                oldestUpdate = charData.lastUpdate
            end
        end
    end
    table.sort(rows, function(a, b) return (a.bags + a.bank) > (b.bags + b.bank) end)

    local warband = SumTabs(StashCountDB.warband.tabs, itemID)
    local total = personalTotal + warband
    if warband > 0 and StashCountDB.warband.lastUpdate
        and (not oldestUpdate or StashCountDB.warband.lastUpdate < oldestUpdate) then
        oldestUpdate = StashCountDB.warband.lastUpdate
    end

    if total == 0 then return end

    tooltip:AddLine(" ")
    tooltip:AddLine("|cff00ccffStashCount|r")
    for _, row in ipairs(rows) do
        tooltip:AddDoubleLine(
            row.name,
            ("%d (bags) + %d (banco)"):format(row.bags, row.bank),
            1, 1, 1, 0.8, 0.8, 0.8)
    end
    if warband > 0 then
        tooltip:AddDoubleLine("Warband Bank", tostring(warband), 1, 1, 1, 0.8, 0.8, 0.8)
    end
    tooltip:AddDoubleLine("Total", tostring(total), 1, 0.82, 0, 1, 0.82, 0)
    if oldestUpdate then
        tooltip:AddLine(("dado mais antigo: %s"):format(date("%d/%m/%y %H:%M", oldestUpdate)), 0.6, 0.6, 0.6)
    end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddStashLines)

-- Slash command

SLASH_STASHCOUNT1 = "/sc"
SlashCmdList["STASHCOUNT"] = function(msg)
    local cmd = (msg or ""):lower()
    if cmd == "scan" then
        ScanPersonalBags()
        ScanPersonalBank()
        ScanWarbandBank()
        print("StashCount: bags/banco/warband escaneados (banco e warband so contam se o banco estiver aberto agora).")
    else
        print("StashCount - comandos:")
        print("  /sc scan  - forca um re-scan (bags sempre; banco/warband so se o banco estiver aberto)")
        print("Personagens rastreados:")
        for charKey, charData in pairs(StashCountDB.characters) do
            print(("  %s (ultima atualizacao: %s)"):format(charKey, charData.lastUpdate and date("%d/%m %H:%M", charData.lastUpdate) or "nunca"))
        end
        print(("Warband Bank (ultima atualizacao: %s)"):format(
            StashCountDB.warband.lastUpdate and date("%d/%m %H:%M", StashCountDB.warband.lastUpdate) or "nunca"))
    end
end
