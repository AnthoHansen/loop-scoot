local dui, textureReady, selected, stopping, retryAt = nil, false, nil, false, 0
local dictionary, texture = 'loop_scoot_dock_display', 'screen'
local drawPoly = DrawTexturedPoly or DrawSpritePoly or function(...)
    return Citizen.InvokeNative(0x29280002282F1928, ...)
end
local options = Config.StationDisplay or {}
local maxDistance = math.max(2, tonumber(options.distance) or 9)
local lastVisible = 0

local function destroy()
    textureReady = false
    if dui then DestroyDui(dui); dui = nil end
end

local function start()
    if dui or GetGameTimer() < retryAt then return end
    retryAt = GetGameTimer() + 10000
    local ok, handle = pcall(CreateDui,
        ('https://cfx-nui-%s/web/station-display/index.html'):format(GetCurrentResourceName()), 1024, 400)
    if ok and handle and handle ~= 0 then dui = handle end
end

local function nearest()
    if not Scoot.GetStationDisplay then return nil end
    local player, best, distance = GetEntityCoords(PlayerPedId()), nil, maxDistance
    for _, station in ipairs(Config.Stations) do
        local d = #(player - station.coords)
        if d < distance then
            local state = Scoot.GetStationDisplay(station.id)
            if state and state.entity and DoesEntityExist(state.entity) then
                best, distance = station.id, d
            end
        end
    end
    return best
end

local function quad(entity, points)
    local p = {}
    for i, v in ipairs(points) do p[i] = GetOffsetFromEntityInWorldCoords(entity, v[1], v[2], v[3]) end

    drawPoly(p[1].x,p[1].y,p[1].z,p[4].x,p[4].y,p[4].z,p[3].x,p[3].y,p[3].z,
        255,255,255,255,dictionary,texture,0,0,1,0,1,1,1,1,1)
    drawPoly(p[1].x,p[1].y,p[1].z,p[3].x,p[3].y,p[3].z,p[2].x,p[2].y,p[2].z,
        255,255,255,255,dictionary,texture,0,0,1,1,1,1,1,0,1)
end

CreateThread(function()
    if options.enabled == false then return end
    while not stopping do
        local id = nearest()
        selected = id
        if id then
            lastVisible = GetGameTimer()
            start()
            if dui and IsDuiAvailable(dui) then
                if not textureReady then
                    local txd = CreateRuntimeTxd(dictionary)
                    CreateRuntimeTextureFromDuiHandle(txd, texture, GetDuiHandle(dui))
                    textureReady = true
                end
                local state = Scoot.GetStationDisplay(id)
                if state then
                    SendDuiMessage(dui, json.encode({type='station', id=id, label=state.label,
                        available=state.available, capacity=state.capacity, phase=state.phase,
                        progress=state.progress, known=state.known, durationMin=state.durationMin,
                        rangeKm=state.rangeKm, rentalLeftMin=state.rentalLeftMin, rentalRangeKm=state.rentalRangeKm,
                        language=ScootLocale.Resolve()}))
                end
            elseif dui and GetGameTimer() >= retryAt then
                destroy()
            end
        elseif dui and GetGameTimer() - lastVisible > 15000 then
            destroy()
        end
        Wait(250)
    end
end)

CreateThread(function()
    if options.enabled == false then return end
    while not stopping do
        local state = selected and Scoot.GetStationDisplay and Scoot.GetStationDisplay(selected)
        local entity = state and state.entity
        if textureReady and entity and DoesEntityExist(entity) and IsEntityOnScreen(entity) then
            local player = GetEntityCoords(PlayerPedId())
            local localPlayer = GetOffsetFromEntityGivenWorldCoords(entity, player.x,player.y,player.z)
            if localPlayer.y < -.45 then
                quad(entity, {{-.475,-.4409,1.108},{.225,-.4409,1.108},{.225,-.4409,.836},{-.475,-.4409,.836}})
            end
            if localPlayer.z > 1.66 then

                quad(entity, {{-.48,.1875,1.6517},{.48,.1875,1.6517},{.48,-.1875,1.6517},{-.48,-.1875,1.6517}})
            end
            Wait(0)
        else
            Wait(150)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    stopping, selected = true, nil
    destroy()
end)
