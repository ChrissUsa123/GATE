--==============================================================
--   AUTO SEND x VENDING SYSTEM  |  CLEAN REBUILD (NO WM)
--   Target API : Lucifer Lua v2.86 (Nuron / Kwelpinator docs)
--   Kompatibel : loader lama (membaca variabel global dari
--                file config) maupun standalone (edit CONFIG)
--==============================================================

--------------------------[ CONFIG ]--------------------------
-- Variabel ini otomatis membaca setting dari file loader.
-- Kalau script dijalankan langsung (tanpa loader), isi manual.

local CFG = {
    WebhookName  = (type(NamaBotWebhok)   == "string"  and NamaBotWebhok)   or "Bot Donate",
    WebhookColor = (type(ColorBotWebhook) == "string"  and ColorBotWebhook) or "0xFF0000",
    Vending      = (type(VendingSistem)   == "boolean" and VendingSistem)   or true,
    World        = (type(World)           == "string"  and World)           or "WORLD",
    WebhookBal   = (type(webhookBal)      == "string"  and webhookBal)      or "",

    -- Pemilik bot in-game (GrowID yang boleh kirim command via chat)
    OwnerGrowID  = "MeRoadToRich",

    -- Nilai lock (WL-based)
    ItemWL       = 242,    -- World Lock    = 1 WL
    ItemDL       = 1796,   -- Diamond Lock  = 100 WL
    ItemBGL      = 7188,   -- Blue Gem Lock = 10000 WL

    -- Radius scan drop & collect (tile)
    -- CATATAN: batas pickup server hanya 64 pixel = 2 tile.
    -- Nilai > 2 tidak akan menambah jangkauan, hanya membosankan.
    ScanRange    = 2,

    -- Interval polling drop (ms)
    ScanInterval = 1500,

    -- Prefix command chat
    Prefix       = ".",
}
----------------------------------------------------------------

local bot = getBot()
if bot == nil then
    print("[AUTOSEND] Script butuh konteks bot. Jalankan di tab bot.")
    return
end

-------------------------[ UTILITAS ]---------------------------

local function toIntColor(hex)
    -- "0xFF0000" / "#FF0000" -> decimal color untuk embed Discord
    if type(hex) == "number" then return hex end
    local h = tostring(hex):gsub("#", ""):gsub("^0x", "")
    return tonumber(h, 16) or 16711680
end

local function fmtNum(n)
    -- 1234567 -> "1,234,567"
    local s = tostring(math.floor(n or 0))
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function wlValue(itemID, count)
    if itemID == CFG.ItemWL  then return count end
    if itemID == CFG.ItemDL  then return count * 100 end
    if itemID == CFG.ItemBGL then return count * 10000 end
    return nil -- bukan lock, diabaikan
end

-- Unit WAJIB camelCase tanpa spasi: WorldLock / DiamondLock / BlueGemLock.
-- Bot Discord hanya mengenali tiga nama itu.
local function unitName(itemID)
    if itemID == CFG.ItemDL  then return "DiamondLock" end
    if itemID == CFG.ItemBGL then return "BlueGemLock" end
    return "WorldLock"
end

local UNIT_BY_TEXT = {
    ["world lock"]    = "WorldLock",
    ["diamond lock"]  = "DiamondLock",
    ["blue gem lock"] = "BlueGemLock",
    ["worldlock"]     = "WorldLock",
    ["diamondlock"]   = "DiamondLock",
    ["bluegem lock"]  = "BlueGemLock",
}

-------------------------[ WEBHOOK ]----------------------------

local function sendWebhook(title, desc, fields)
    if CFG.WebhookBal == "" or CFG.WebhookBal == "WEBHOOK" then return end
    local ok, err = pcall(function()
        local hook = Webhook.new(CFG.WebhookBal)
        hook.username = CFG.WebhookName
        hook.embed1.use = true
        hook.embed1.color = toIntColor(CFG.WebhookColor)
        hook.embed1.title = title
        hook.embed1.description = desc
        hook.embed1.timestamp = true
        if fields then
            for _, f in ipairs(fields) do
                hook.embed1:addField(f[1], f[2], f[3] or false)
            end
        end
        hook:send()
    end)
    if not ok then
        print("[WEBHOOK] Gagal kirim: " .. tostring(err))
    end
end

---------------------[ TRACKER DEPOSIT ]------------------------

local balances  = {}  -- balances[growid] = total WL
local knownObjs = {}  -- snapshot oid -> true

local function snapshotObjects(world)
    local snap = {}
    for _, obj in ipairs(world:getObjects()) do
        snap[obj.oid] = { id = obj.id, count = obj.count, x = obj.x, y = obj.y }
    end
    return snap
end

-- cari player terdekat dari posisi object (pixel)
local function nearestPlayer(world, px, py)
    local best, bestDist = nil, math.huge
    for _, p in ipairs(world:getPlayers()) do
        if not p.isLocalPlayer then
            local dx, dy = p.posx - px, p.posy - py
            local d = dx * dx + dy * dy
            if d < bestDist then best, bestDist = p, d end
        end
    end
    -- batasi ~ scan range (pixel = tile * 32)
    local maxPx = (CFG.ScanRange * 32) ^ 2
    if best and bestDist <= maxPx then return best end
    return nil
end

-- PENTING: bot Discord hanya membaca DESCRIPTION embed dan mencari pola
-- "GrowID: <nama>" serta "Amount: <jumlah> <Unit>".
-- Kalau formatnya beda, saldo pembeli TIDAK akan bertambah.
local function creditDeposit(name, count, unit)
    local itemID = CFG.ItemWL
    if unit == "DiamondLock" then itemID = CFG.ItemDL end
    if unit == "BlueGemLock" then itemID = CFG.ItemBGL end
    local wl = wlValue(itemID, count) or 0
    balances[name] = (balances[name] or 0) + wl
    -- FORMAT ASLI (lihat pesan "DONATION LOGS" di channel):
    --   title       : DONATION LOGS
    --   description : "GrowID: <nama>" + "Amount: <jumlah> <Unit>"
    -- Bot Discord hanya mem-parse description itu. Emoji custom sengaja
    -- tidak disertakan karena ID-nya milik server lain dan akan tampil
    -- sebagai teks mentah di server Anda.
    sendWebhook("DONATION LOGS",
        "GrowID: " .. name .. " \nAmount: " .. count .. " " .. unit)
    print("[DEPOSIT] " .. name .. " +" .. count .. " " .. unit ..
          " = " .. fmtNum(wl) .. " WL (total " .. fmtNum(balances[name]) .. ")")
end

---------------------[ DONATION BOX ]--------------------------

-- Donation Box bukan Giving Tree: ia block solid biasa tanpa tile extra
-- sendiri, jadi isinya TIDAK pernah muncul di world:getObjects().
-- Satu-satunya sumber GrowID + jumlah adalah PESAN SISTEM di console.
-- Contoh pesan yang ditangani: "**Vixhan** places 1 World Lock into the
-- Donation Box"
local function handleDonationBox(text)
    local clean = removeColor(text)
    -- buang chat player (!) dan slash command (/)
    local first = string.sub(clean, 1, 1)
    if first == "!" or first == "/" then return end

    local low = string.lower(clean)
    -- hanya pesan berujar donasi
    if not string.find(low, "donat", 1, true) then return end

    -- "**Vixhan** places 1 World Lock into the Donation Box"
    local name, num, item = string.match(low,
        "^%*?([%w_%-%.]+)%*?[^%d]*(%d+)%s*([%a ]+)")
    if not name or not num then
        print("[BOX] " .. clean)
        return
    end

    -- ambil nama asli dari world supaya kapitalisasi GrowID benar
    local real = nil
    for _, p in ipairs(bot:getWorld():getPlayers() or {}) do
        if type(p.name) == "string" and string.lower(p.name) == name then
            real = p.name
            break
        end
    end

    creditDeposit(real or name, tonumber(num), UNIT_BY_TEXT[(item or ""):lower()] or "WorldLock")
end

local function pollDrops()
    while true do
        pcall(function()
            if bot:isInWorld(CFG.World) then
                local world = bot:getWorld()
                local now = snapshotObjects(world)
                for oid, obj in pairs(now) do
                    if not knownObjs[oid] then
                        local wl = wlValue(obj.id, obj.count)
                        if wl then
                            local p = nearestPlayer(world, obj.x, obj.y)
                            if p then creditDeposit(p.name, obj.count, unitName(obj.id)) end
                        end
                    end
                end
                knownObjs = now
                -- ambil lock yang tergeletak di sekitar bot
                bot:collect(CFG.ScanRange, 250)
            end
        end)
        sleep(CFG.ScanInterval)
    end
end

---------------------[ MONITOR VENDING ]------------------------

-- Keyword console message saat ada pembelian vending.
-- Sesuaikan kalau format pesan server berubah.
local VEND_PATTERNS = { "bought", "sold", "vending", "Vending" }

local function checkVendMessage(text)
    if not CFG.Vending then return end
    local clean = removeColor(text)
    for _, pat in ipairs(VEND_PATTERNS) do
        if clean:lower():find(pat:lower(), 1, true) then
            sendWebhook("Aktivitas Vending", "```" .. clean .. "```")
            print("[VENDING] " .. clean)
            return
        end
    end
end

-------------------[ COMMAND VIA CHAT ]-------------------------

-- Command (chat biasa / PM dari OwnerGrowID):
--   .bal <growid>          -> cek balance deposit
--   .wd <growid> <wl>      -> potong balance (withdraw manual)
--   .send <wl>             -> drop WL ke pemesan di world yang sama
--   .status                -> status bot

local function reply(msg)
    bot:say(msg)
end

local function handleCommand(sender, text)
    if sender ~= CFG.OwnerGrowID then return end
    if text:sub(1, 1) ~= CFG.Prefix then return end

    local args = {}
    for w in text:gmatch("%S+") do args[#args + 1] = w end
    local cmd = (args[1] or ""):sub(2):lower()

    if cmd == "bal" and args[2] then
        reply("Balance " .. args[2] .. ": " .. fmtNum(balances[args[2]] or 0) .. " WL")

    elseif cmd == "wd" and args[2] and tonumber(args[3]) then
        local wl = tonumber(args[3])
        local cur = balances[args[2]] or 0
        if wl <= 0 or cur < wl then
            reply("Balance " .. args[2] .. " tidak cukup (" .. fmtNum(cur) .. " WL)")
            return
        end
        balances[args[2]] = cur - wl
        sendWebhook("Withdraw", "**" .. args[2] .. "** WD **" .. fmtNum(wl) .. " WL**", {
            { "Sisa Balance", fmtNum(balances[args[2]]) .. " WL", true },
        })
        reply("WD " .. fmtNum(wl) .. " WL untuk " .. args[2] .. " berhasil dicatat")

    elseif cmd == "send" and tonumber(args[2]) then
        local wl = tonumber(args[2])
        local dl  = math.floor(wl / 100)
        local sisa = wl % 100
        if dl > 0  then bot:drop(CFG.ItemDL, dl)  sleep(300) end
        if sisa > 0 then bot:drop(CFG.ItemWL, sisa) end
        sendWebhook("Auto Send", "Bot mengirim **" .. fmtNum(wl) .. " WL** di `" .. bot:getWorld().name .. "`")

    elseif cmd == "status" then
        reply("Online | World: " .. bot:getWorld().name ..
              " | Gems: " .. fmtNum(bot.gem_count) ..
              " | Ping: " .. bot:getPing() .. "ms")
    end
end

-------------------------[ EVENTS ]-----------------------------

-- values adalah objek Variant (bukan tabel biasa).
-- API Lucifer: values:get(0):getString() = nama fungsi
--              values:get(1):getString() = isi pesan
addEvent(Event.variantlist, function(values, netid)
    local v0 = values and values:get(0):getString()
    if type(v0) == "string" and v0:find("OnConsoleMessage", 1, true) then
        local msg = values:get(1):getString()
        if type(msg) == "string" then
            checkVendMessage(msg)
            handleDonationBox(msg)
        end
    end
end)

addEvent(Event.game_message, function(text)
    checkVendMessage(text)
    handleDonationBox(text)
end)

------------------------[ MAIN LOOP ]---------------------------

local function main()
    print("==================================")
    print("  AUTO SEND x VENDING  |  CLEAN")
    print("  World depo : " .. CFG.World)
    print("  Vending    : " .. tostring(CFG.Vending))
    print("==================================")

    bot.auto_reconnect = true
    bot.auto_collect   = true   -- tanpa ini bot tidak pernah ambil lock
    bot.custom_status  = "AutoSend Aktif"

    -- warp ke world deposit kalau belum di sana
    if not bot:isInWorld(CFG.World) then
        bot:warp(CFG.World)
        sleep(5000)
    end

    -- thread polling drop deposit
    runThread(pollDrops)

    sendWebhook("Bot Online", "AutoSend aktif di world **" .. CFG.World .. "**")

    -- loop event listener (blocking per-window, ulangi terus)
    while true do
        listenEvents(10)
    end
end

-- cleanup saat script distop
function on_stop(err)
    if err ~= "" then
        print("[AUTOSEND] Stop dengan error: " .. err)
    else
        print("[AUTOSEND] Script berhenti.")
    end
end

main()
