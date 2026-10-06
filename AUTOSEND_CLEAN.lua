--============================================================--
--   AUTO SEND x VENDING SYSTEM  |  CLEAN REBUILD (NO WM)
--   Target API : Lucifer Lua v2.86
--   Kompatibel : loader lama (membaca variabel global dari
--                file config) maupun standalone (edit CONFIG)
--============================================================--

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
    ScanRange    = 4,

    -- Interval polling drop (ms)
    ScanInterval = 1500,
    -- Jendela listenEvents (detik). Sisanya dijeda supaya total cadence
    -- tetap ~ ScanInterval tanpa menabrak batas minimum timer.
    ListenWindow = 1,

    -- Radius (tile) untuk mencari player di sekitar drop. Sengaja lebih lebar
    -- dari ScanRange: orang yang sempat jalan sedikit tetap terdeteksi,
    -- sementara lock tetap diambil pada radius dekat.
    CreditRange  = 12,

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
    local maxPx = (CFG.CreditRange * 32) ^ 2
    if best and bestDist <= maxPx then return best end
    return nil
end

local function creditDeposit(name, wl)
    balances[name] = (balances[name] or 0) + wl
    sendWebhook("Deposit Masuk", "**" .. name .. "** deposit **" .. fmtNum(wl) .. " WL**", {
        { "GrowID", name, true },
        { "Jumlah", fmtNum(wl) .. " WL", true },
        { "Total Balance", fmtNum(balances[name]) .. " WL", true },
    })
    print("[DEPOSIT] " .. name .. " +" .. fmtNum(wl) .. " WL (total " .. fmtNum(balances[name]) .. ")")
end

-- Statistik satu putaran terakhir (dipakai buat heartbeat di console).
local stats = { world = "-", objects = 0, credited = 0 }

-- Satu kali pemindaian drop. Sengaja BUKAN while-loop di thread terpisah:
-- runThread punya Lua state sendiri sehingga state lokal di file ini
-- (knownObjs / balances) tidak bisa diandalkan di dalam thread.
local function pollOnce()
    stats.credited = 0
    if not bot:isInWorld(CFG.World) then
        return "not-in-world"
    end
    local world = bot:getWorld()
    stats.world = tostring(world.name)
    local now = snapshotObjects(world)
    stats.objects = 0
    for _ in pairs(now) do
        stats.objects = stats.objects + 1
    end
    for oid, obj in pairs(now) do
        if not knownObjs[oid] then
            local wl = wlValue(obj.id, obj.count)
            if wl then
                local p = nearestPlayer(world, obj.x, obj.y)
                if p then
                    local nm = p.name
                    if nm == nil or nm == "" then
                        nm = p.altName
                    end
                    creditDeposit(nm, wl)
                    stats.credited = stats.credited + 1
                else
                    print("[DROP] lock id=" .. tostring(obj.id) .. " x" .. tostring(obj.count) .. " -> tidak ada player dalam radius " .. CFG.CreditRange .. " tile, tidak di-credit")
                end
            end
        end
    end
    knownObjs = now
    -- ambil lock yang tergeletak di sekitar bot
    bot:collect(CFG.ScanRange, 250)
    return "ok"
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

addEvent(Event.variantlist, function(values, netid)
    -- OnConsoleMessage = chat & notifikasi server
    local v0 = values and (values[0] or values[1])
    if type(v0) == "string" then
        if v0:find("OnConsoleMessage") then
            local msg = values[1] or values[2]
            if type(msg) == "string" then checkVendMessage(msg) end
        end
    end
end)

addEvent(Event.game_message, function(text)
    checkVendMessage(text)
end)

------------------------[ MAIN LOOP ]---------------------------

local function main()
    print("==================================")
    print("  AUTO SEND x VENDING  |  CLEAN")
    print("  World depo : " .. CFG.World)
    print("  Vending    : " .. tostring(CFG.Vending))
    print("==================================")

    bot.auto_reconnect = true
    bot.custom_status  = "AutoSend Aktif"

    -- warp ke world deposit kalau belum di sana
    if not bot:isInWorld(CFG.World) then
        bot:warp(CFG.World)
        sleep(5000)
    end

    sendWebhook("Bot Online", "AutoSend aktif di world **" .. CFG.World .. "**")

    -- Loop utama: pindai drop -> dengarkan event -> jeda sisa waktu.
    -- Tidak memakai runThread supaya tidak bergantung Lua state thread lain.
    local tick = 0
    local lastWorld = nil
    local warned = false
    while true do
        tick = tick + 1
        local _0xok, _0xstatus = pcall(pollOnce)
        if not _0xok then
            print("[ERROR] poll gagal: " .. tostring(_0xstatus))
        elseif _0xstatus == "not-in-world" then
            if not warned then
                warned = true
                print("[WARN] bot tidak di world \"" .. CFG.World .. "\" -> deposit tidak akan terdeteksi")
            end
        else
            warned = false
            if stats.world ~= lastWorld then
                lastWorld = stats.world
                knownObjs = {}
                print("[INFO] monitoring world \"" .. lastWorld .. "\"")
            end
            if tick % 20 == 0 then
                print("[HEARTBEAT] tick " .. tick .. " | world=" .. stats.world .. " | objek=" .. stats.objects .. " | deposit=" .. stats.credited)
            end
        end
        listenEvents(CFG.ListenWindow)
        local _0xrest = CFG.ScanInterval - CFG.ListenWindow * 1000
        if _0xrest > 0 then
            sleep(_0xrest)
        end
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
