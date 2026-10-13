ScootInteract = {}

local CFG = (Config.Standalone or {}).interact or {}
local points, count, serial = {}, 0, 0
local visible, nVisible = {}, 0
local deployed, lastSent = nil, nil
local fading = {}
local resX, resY = 1920, 1080
local lastFrame, lastFollow = nil, 0
local texture = { txd = 'loop_scoot_interact', names = {}, ready = false, tries = 0, nextTry = 0 }

local CANVAS, LEVELS = 24.0, { 48, 24, 12 }
local DISC, RING, STROKE, SHADOW = 9.5, 18.0, 2.0, 2.0
local WHITE, DARK, SHADOW_ALPHA = 0.80, 0.36, 0.10
local SUB = 4

local function num(v, d) v = tonumber(v);if v == nil then return d end;return v end
local function ringRange(p) return p.range or num(CFG.range, 6.0) end
local function promptRange(p) return p.promptRange or num(CFG.promptRange, 2.0) end
local function fadeMs() return math.max(1, num(CFG.fade, 183)) end
local function approach(v, t, s) if v < t then return math.min(t, v + s) end;return math.max(t, v - s) end

local function layer(r)
    if r < DISC * 0.5 then return 1.0, WHITE end
    local inner, outer = RING * 0.5 - STROKE * 0.5, RING * 0.5 + STROKE * 0.5
    if r < inner then return 0.0, DARK end
    if r < outer then return 1.0, WHITE end
    if r < outer + SHADOW then return 0.0, SHADOW_ALPHA * (outer + SHADOW - r) / SHADOW end
    return 0.0, 0.0
end

local function paintLevel(txd, name, texels)
    local tex = CreateRuntimeTexture(txd, name, texels, texels)
    local step, centre = CANVAS / texels, CANVAS * 0.5
    local sub = SUB * math.max(1, math.floor(LEVELS[1] / texels))
    local n = sub * sub
    for ty = 0, texels - 1 do
        for tx = 0, texels - 1 do
            local sumA, sumW = 0.0, 0.0
            for j = 0, sub - 1 do
                for i = 0, sub - 1 do
                    local px = (tx + (i + 0.5) / sub) * step - centre
                    local py = (ty + (j + 0.5) / sub) * step - centre
                    local white, a = layer(math.sqrt(px * px + py * py))
                    sumA, sumW = sumA + a, sumW + white * a
                end
            end
            local grey = sumA > 0 and (sumW / sumA) or 0.0
            local c = math.floor(grey * 255 + 0.5)
            SetRuntimeTexturePixel(tex, tx, ty, c, c, c, math.floor(sumA / n * 255 + 0.5))
        end
    end
    CommitRuntimeTexture(tex)
end

local function paint()
    if texture.ready then return true end
    if texture.tries >= 10 or GetGameTimer() < texture.nextTry then return false end
    texture.tries = texture.tries + 1
    texture.nextTry = GetGameTimer() + 1000 * texture.tries
    local ok = pcall(function()
        local txd = CreateRuntimeTxd(texture.txd)
        for l = #LEVELS, 1, -1 do
            local name = l == 1 and 'dot' or ('dot_' .. (l - 1))
            paintLevel(txd, name, LEVELS[l])
            texture.names[l] = name
        end
    end)
    texture.ready = ok
    return ok
end

local function mipFor(p, px)
    local l = p.mip or 1
    while l > 1 and LEVELS[l] / px < 1.5 do l = l - 1 end
    while l < #LEVELS and LEVELS[l + 1] / px >= 1.75 do l = l + 1 end
    p.mip = l
    return texture.names[l] or 'dot'
end

local function send(payload)
    payload.action = 'loop:interact'
    SendNUIMessage(payload)
end

local function scale(p)
    return math.max(num(CFG.labelMinScale, 0.85), math.min(1.0, (p.diam or RING) / RING))
end

local function show(p)
    deployed = p
    if not p then
        if lastSent then send({ visible = false }) end
        lastSent = nil
        return
    end
    lastSent = { x = p.sx, y = p.sy, s = scale(p), id = p.id, key = p.key, label = p.label }
    lastFollow = GetGameTimer()
    send({ visible = true, id = p.id, x = p.sx, y = p.sy, scale = lastSent.s,
        key = p.key or 'E', label = p.label or 'INTERACT', fade = fadeMs(), t = lastFollow })
end

local function follow(p)
    local t = GetGameTimer()
    if t - lastFollow < num(CFG.followTick, 33) then return end
    local s = scale(p)
    if lastSent and math.abs(p.sx - lastSent.x) * resX < 0.5 and math.abs(p.sy - lastSent.y) * resY < 0.5
        and math.abs(s - lastSent.s) < 0.004 then return end
    lastFollow = t
    lastSent.x, lastSent.y, lastSent.s = p.sx, p.sy, s
    SendNUIMessage({ action = 'loop:interact:pos', x = p.sx, y = p.sy, scale = s, t = t })
end

local function canShow()
    if IsNuiFocused() or IsPauseMenuActive() then return false end
    if LocalPlayer.state.loopCine == true then return false end
    local ped = PlayerPedId()
    if IsEntityDead(ped) then return false end
    if CFG.inVehicle ~= true and IsPedInAnyVehicle(ped, false) then return false end
    return true
end

local function scan()
    if count == 0 or not canShow() then visible, nVisible = {}, 0;return end
    local ok, rx, ry = pcall(GetActiveScreenResolution)
    if ok and rx and rx > 0 then resX, resY = rx, ry end
    local pos = GetEntityCoords(PlayerPedId())
    local list, n = {}, 0
    for _, p in pairs(points) do
        if p.enabled then
            local d = #(pos - p.anchor)
            local reach = ringRange(p) + (p.ring and 0.25 or 0.0)
            if d <= reach then
                p.d = d;n = n + 1;list[n] = p
            else
                p.ring, p.onScreen = false, false
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local cap = math.floor(num(CFG.maxMarkers, 6))
    for i = 1, n do list[i].ring = i <= cap;if i > cap then list[i] = nil end end
    visible, nVisible = list, math.min(n, cap)
end

local function project(alive)
    if not alive then return end
    local cam = GetGameplayCamCoord()
    for i = 1, nVisible do
        local p = visible[i]
        local ok, sx, sy = GetScreenCoordFromWorldCoord(p.anchor.x, p.anchor.y, p.anchor.z)
        if ok and sx >= 0.0 and sx <= 1.0 and sy >= 0.0 and sy <= 1.0 then
            p.sx, p.sy, p.onScreen = sx, sy, true
            p.diam = math.min(RING, num(CFG.k, 54.0) / math.max(0.05, #(cam - p.anchor)))
        else
            p.onScreen = false
        end
    end
    local best, bestDc, currentDc = nil, nil, nil
    for i = 1, nVisible do
        local p = visible[i]
        local reach = promptRange(p) + (deployed == p and 0.25 or 0.0)
        if p.onScreen and p.d <= reach then
            local dx, dy = (p.sx - 0.5) * resX, (p.sy - 0.5) * resY
            local dc = math.sqrt(dx * dx + dy * dy)
            if p == deployed then currentDc = dc end
            if not best or dc < bestDc then best, bestDc = p, dc end
        end
    end
    local choice = best
    local hyst = num(CFG.centerHysteresis, 24) * (resY / 1080.0)
    if deployed and currentDc and best ~= deployed and bestDc > currentDc - hyst then choice = deployed end
    if choice ~= deployed then show(choice)
    elseif choice and (choice.label ~= lastSent.label or choice.key ~= lastSent.key) then show(choice) end
end

local frameNo = 0
local function frame()
    frameNo = frameNo + 1
    local t = GetGameTimer()
    local dt = lastFrame and math.max(0, math.min(100, t - lastFrame)) or 16
    lastFrame = t
    local step = dt / fadeMs()
    local alive = canShow()
    if not alive and deployed then show(nil) end
    project(alive)
    if deployed and (nVisible == 0 or not deployed.onScreen or not deployed.enabled) then show(nil) end
    for i = 1, nVisible do
        local p = visible[i]
        p.seen = frameNo
        local target = (alive and p.enabled and p.ring and p.onScreen and p ~= deployed) and 1.0 or 0.0
        p.alpha = approach(p.alpha or 0.0, target, step)
        if p.alpha > 0 then fading[p] = true end
    end
    for p in pairs(fading) do
        if p.seen ~= frameNo then p.alpha = approach(p.alpha or 0.0, 0.0, step) end
        if (p.alpha or 0) <= 0 then fading[p] = nil end
    end
    if texture.ready then
        local u = resY / 1080.0
        for p in pairs(fading) do
            local a = math.floor(255 * p.alpha)
            if a >= 1 and p.diam and p.diam > 0 then
                local px = CANVAS * (p.diam / RING) * u
                SetDrawOrigin(p.anchor.x, p.anchor.y, p.anchor.z, false)
                DrawSprite(texture.txd, mipFor(p, px), 0.0, 0.0, px / resX, px / resY, 0.0, 255, 255, 255, a)
                ClearDrawOrigin()
            end
        end
    end
    if deployed and deployed.onScreen then follow(deployed) end
end

local function busy()
    return nVisible > 0 or deployed ~= nil or next(fading) ~= nil
end

CreateThread(function()
    Wait(500)
    while true do
        if count > 0 or deployed then
            if not texture.ready then paint() end
            local ok, err = pcall(scan)
            if not ok then print('[loop-scoot] interact scan: ' .. tostring(err));visible, nVisible = {}, 0 end
        elseif nVisible > 0 then
            visible, nVisible = {}, 0
        end
        Wait(num(CFG.tickIdle, 150))
    end
end)

CreateThread(function()
    Wait(501)
    while true do
        if busy() then
            local ok, err = pcall(frame)
            if not ok then print('[loop-scoot] interact frame: ' .. tostring(err));show(nil) end
            Wait(0)
        else
            lastFrame = nil
            Wait(150)
        end
    end
end)

CreateThread(function()
    while true do
        if deployed and deployed.onPress and not IsNuiFocused() then
            if IsControlJustPressed(0, 38) then
                local p = deployed
                local ok, err = pcall(p.onPress, p.id)
                if not ok then print(('[loop-scoot] interact %s: %s'):format(tostring(p.id), tostring(err))) end
            end
            Wait(0)
        else
            Wait(150)
        end
    end
end)

local function toVector(c)
    if type(c) == 'vector3' then return c end
    if type(c) == 'vector4' then return vector3(c.x, c.y, c.z) end
    if type(c) == 'table' and tonumber(c.x) and tonumber(c.y) and tonumber(c.z) then
        return vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0)
    end
end

function ScootInteract.Add(id, def)
    if type(id) ~= 'string' or type(def) ~= 'table' then return false end
    local coords = toVector(def.coords)
    if not coords then return false end
    serial = serial + 1
    local p = {
        id = id, order = serial, enabled = def.enabled ~= false,
        label = type(def.label) == 'string' and def.label or nil,
        key = type(def.key) == 'string' and def.key ~= '' and def.key or nil,
        range = tonumber(def.range), promptRange = tonumber(def.promptRange),
        onPress = type(def.onPress) == 'function' and def.onPress or nil, group = def.group,
    }
    p.anchor = vector3(coords.x, coords.y, coords.z + num(def.offsetZ, 0.0))
    local old = points[id]
    if old then
        p.alpha, p.diam, p.sx, p.sy, p.onScreen, p.ring, p.d, p.mip, p.seen =
            old.alpha, old.diam, old.sx, old.sy, old.onScreen, old.ring, old.d, old.mip, old.seen
        old.enabled = false
        fading[old] = nil
        if p.alpha and p.alpha > 0 then fading[p] = true end
        for i = 1, nVisible do if visible[i] == old then visible[i] = p end end
        if deployed == old then
            deployed = p
            if old.label ~= p.label or old.key ~= p.key then show(p) end
        end
    else
        count = count + 1
    end
    points[id] = p
    return true
end

function ScootInteract.Remove(id)
    local p = points[id]
    if not p then return false end
    p.enabled = false
    points[id] = nil
    count = count - 1
    if deployed == p then show(nil) end
    return true
end

function ScootInteract.RemoveGroup(group)
    local ids = {}
    for id, p in pairs(points) do if p.group == group then ids[#ids + 1] = id end end
    for _, id in ipairs(ids) do ScootInteract.Remove(id) end
    return #ids
end

function ScootInteract.Clear()
    points, count, visible, nVisible = {}, 0, {}, 0
    show(nil)
end

AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then ScootInteract.Clear() end
end)
