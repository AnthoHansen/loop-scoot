local stationStates, spawned, blips = {}, {}, {}
local serverDelta, rental, phone = 0, nil, false
local stopping, mounting, menuBusy = false, false, false
local prompt, action, targetStation, targetVehicle
local initializedVehicles, modelFailures = {}, {}
local timelineAnchors, preparationHidden, stationLoading = {}, {}, {}
local clockReady, bestClockRtt = false, math.huge
local vehicleHash = joaat(Config.Model)
local propPoses = setmetatable({}, { __mode = 'k' })
local vehiclePhysics = {}
local phoneSession, phoneReady, phoneOperation = 0, false, 0
local stationRevisions, rentalRevision = {}, 0
local movingSounds = { rising=true, opening=true, extracting=true, lowering=true,
    arm_return=true, closing=true, retracting=true }
local createStation, applyPose
local animDict = 'loop_scooter_anims_v10'
local ridingClip, ridingPed
local ridingVehicle, ridingRate, ridingStartedAt
local ridingDuration, ridingObserved, ridingAttempts = nil, false, 0
local riderSession, riderSuppressed = nil, false
local riderState = ScootRider.New(1)
local riderTransition, riderRetryAt = nil, 0
local riderResumeAt = 0
local steerBases = { ride_cruise = true, ride_idle = true, ride_idle_left = true }
local steerSuffix, steerClips, helmetGuard = 'steer', {}, nil

local function guardHelmet(ped)
    if helmetGuard and helmetGuard.ped == ped then SetPedConfigFlag(ped, 35, false);return end
    helmetGuard = { ped = ped, flag = GetPedConfigFlag(ped, 35, true), wore = IsPedWearingHelmet(ped) }
    SetPedConfigFlag(ped, 35, false)
    SetPedHelmet(ped, false)
end

local function releaseHelmet()
    local guard = helmetGuard
    if not guard then return end
    helmetGuard = nil
    if not DoesEntityExist(guard.ped) then return end
    if not guard.wore and IsPedWearingHelmet(guard.ped) then RemovePedHelmet(guard.ped, true) end
    SetPedHelmet(guard.ped, true)
    SetPedConfigFlag(guard.ped, 35, guard.flag == true or guard.flag == 1)
end

local function suppressRider(at)
    riderSuppressed=true
    local ms=Config.Rider.resumeMs;if ms==nil then ms=3000 end
    riderResumeAt=ms>0 and at+ms or math.huge
end
local riderClipFailures = {}
local riderOriginHeight = {}

local function stopRiding(keepState)
    if ridingClip and ridingPed and DoesEntityExist(ridingPed) then
        StopAnimTask(ridingPed, animDict, ridingClip, 3.0)
    end
    ridingClip, ridingPed, ridingVehicle, ridingRate, ridingStartedAt = nil, nil, nil, nil, nil
    ridingDuration,ridingObserved=nil,false
    if not keepState then riderState=ScootRider.New(riderState.side) end
end

local function notify(message, kind)
    if LocalPlayer and LocalPlayer.state.loopCine == true then return end
    ScootUI.Notify(message, kind)
end

local function model(name, timeoutMs, cancelled)
    local hash = type(name) == 'number' and name or joaat(name)
    if HasModelLoaded(hash) then return hash end
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        if not modelFailures[hash] then
            print(('[loop-scoot] model missing or invalid: %s'):format(name))
            modelFailures[hash] = true
        end
        return nil, 'unregistered'
    end
    RequestModel(hash)
    local startedAt = GetGameTimer()
    local untilAt = startedAt + (timeoutMs or 7000)
    while not HasModelLoaded(hash) and GetGameTimer() < untilAt and not stopping
        and not (cancelled and cancelled()) do Wait(20) end
    if stopping or (cancelled and cancelled()) then return nil, 'cancelled' end
    if HasModelLoaded(hash) then return hash end
    print(('[loop-scoot] model: timeout for %s after %s ms'):format(name, GetGameTimer()-startedAt))
    return nil, 'timeout'
end

local function destroy(entity)
    if entity and DoesEntityExist(entity) then DeleteEntity(entity) end
end

local function closePhone()
    local wasOpen = phone
    phone, phoneReady, phoneSession = false, false, phoneSession + 1
    if wasOpen then TriggerEvent('loop-scoot:closePhone') end
end

local function now() return GetGameTimer() + serverDelta end

local function awaitCallback(name, timeout, ...)
    local complete, response, listening = false, nil, true
    local ok, problem = pcall(lib.callback, name, false, function(value)
        if listening then complete, response = true, value end
    end, ...)
    if not ok then
        print(('[scoot] %s: callback not sent (%s)'):format(name, tostring(problem)))
        return false
    end
    local deadline = GetGameTimer() + timeout
    while not complete and not stopping and GetGameTimer() < deadline do Wait(10) end
    listening = false
    if not complete then print(('[scoot] %s: no server reply after %d ms'):format(name, timeout)) end
    return complete, response
end

local function calibrateClock(serverNow, sent)
    if type(serverNow) ~= 'number' or not sent then return end
    local received = GetGameTimer()
    local rtt = math.max(0, received-sent)
    if not clockReady or rtt <= bestClockRtt + 5 then
        serverDelta = serverNow - (sent+received)/2
        bestClockRtt, clockReady = math.min(bestClockRtt, rtt), true
    end
end

local function sequenceElapsed(state)
    if not state or state.phase == 'idle' or not state.startedAt or state.startedAt <= 0 then return 0 end
    if state.pausedElapsed then return state.pausedElapsed end
    local anchor = timelineAnchors[state.id]
    if not anchor or anchor.startedAt ~= state.startedAt or anchor.token ~= state.token then
        anchor = { startedAt = state.startedAt, token = state.token,
            localStart = state.startedAt - serverDelta }
        timelineAnchors[state.id] = anchor
    end

    return math.max(0, GetGameTimer()-anchor.localStart)
end

function Scoot.GetStationDisplay(id)
    local station = Scoot.FindStation(id)
    if not station then return nil end
    local state, objects = stationStates[id], spawned[id]
    if not objects or not objects.body then return nil end
    local elapsed = sequenceElapsed(state)
    local phase = state and state.phase or 'preparing'
    if state and phase ~= 'idle' and phase ~= 'preparing' then
        phase = Scoot.Sequence(elapsed).phase
    end
    local energy = Config.ScooterEnergy or {}
    local rangeKm = energy.enabled ~= false and tonumber(energy.rangeKm) or nil
    local result = { entity=objects.body, label=station.label, capacity=station.capacity,
        available=state and state.available, known=state ~= nil and type(state.available)=='number',
        phase=phase, progress=math.max(0,math.min(1,elapsed / Config.Timeline.resetEnd)),
        durationMin=math.floor((tonumber(Config.RentalDuration) or 0) / 60 + .5), rangeKm=rangeKm }
    if type(rental) == 'table' and tonumber(rental.expiresAt) then
        result.rentalLeftMin = math.max(0, math.ceil((rental.expiresAt - now()) / 60000))
        local net = tonumber(rental.netId)
        local vehicle = net and net ~= 0 and NetworkDoesNetworkIdExist(net) and NetToVeh(net) or 0
        local battery = vehicle ~= 0 and DoesEntityExist(vehicle) and Entity(vehicle).state.loopScootBattery
        if rangeKm and type(battery) == 'number' and battery == battery then
            result.rentalRangeKm = math.max(0, math.floor(rangeKm * math.max(0, math.min(100, battery)) / 100 + .5))
        end
    end
    return result
end

local function publicStations()
    local result, player = {}, GetEntityCoords(PlayerPedId())
    for _, station in ipairs(Config.Stations) do
        local state = stationStates[station.id] or {}
        result[#result+1] = {
            id = station.id, label = station.label,
            available = type(state.available) == 'number' and state.available or 0,
            busy = state.phase and state.phase ~= 'idle' or false,
            distance = #(player - station.coords),
            coords = { x = station.coords.x, y = station.coords.y, z = station.coords.z },
            capacity = station.capacity
        }
    end
    return result
end

local function rentalAppState()
    return { stations = publicStations(), rental = rental or false,
        serverNow = now(), price = Config.Price, language = Config.Language,
        busy = menuBusy, ready = phoneReady and not stopping }
end

local function updateUI()
    if phone then TriggerEvent('loop-scoot:phoneState', rentalAppState()) end
end

local function applyPlacement(station, state)
    if state.coords then
        local same = station.coords.x == state.coords.x and station.coords.y == state.coords.y
            and station.coords.z == state.coords.z and station.heading == (state.heading or station.heading)
        if same then return end
        station.coords = vector3(state.coords.x, state.coords.y, state.coords.z)
        station.heading = state.heading or station.heading
        if blips[station.id] then SetBlipCoords(blips[station.id], station.coords.x, station.coords.y, station.coords.z) end
        local old = spawned[station.id]
        if old then for _, entity in pairs(old) do destroy(entity) end; spawned[station.id] = nil end
    end
end

local function syncSnapshot()
    local sent = GetGameTimer()
    local revisions, previousRental = {}, rentalRevision
    for id, revision in pairs(stationRevisions) do revisions[id] = revision end
    local ok, data = awaitCallback('loop-scoot:snapshot', 5000)
    if ok and type(data) == 'table' and data.ok == false and not stopping then
        Wait(1100)
        ok, data = awaitCallback('loop-scoot:snapshot', 5000)
    end
    if not ok or type(data) ~= 'table' or data.ok ~= true or type(data.stations) ~= 'table' then
        print(('[scoot] snapshot failed: %s'):format(not ok and 'no reply'
            or type(data) ~= 'table' and 'invalid reply' or tostring(data.message or 'refused')))
        return false
    end
    calibrateClock(data.serverNow, sent)

    for id, state in pairs(data.stations) do
        if stationRevisions[id] == revisions[id] then stationStates[id] = state end
    end
    if rentalRevision == previousRental then rental = data.rental end
    for _, station in ipairs(Config.Stations) do
        local state = stationStates[station.id]
        if state then applyPlacement(station, state) end
    end
    updateUI()
    return true
end

RegisterNetEvent('loop-scoot:station', function(state, serverNow)
    if type(state) ~= 'table' or not Scoot.FindStation(state.id) then return end
    stationRevisions[state.id] = (stationRevisions[state.id] or 0) + 1
    if not clockReady and serverNow then serverDelta, clockReady = serverNow-GetGameTimer(), true end
    local old = stationStates[state.id]
    stationStates[state.id] = state
    if state.coords and (not old or not old.coords or state.coords.x ~= old.coords.x
        or state.coords.y ~= old.coords.y or state.coords.z ~= old.coords.z or state.heading ~= old.heading) then
        applyPlacement(Scoot.FindStation(state.id), state)
    end
    updateUI()
end)

RegisterNetEvent('loop-scoot:rental', function(value, serverNow)
    rentalRevision = rentalRevision + 1
    rental = value
    if not clockReady and serverNow then serverDelta, clockReady = serverNow-GetGameTimer(), true end
    updateUI()
end)

RegisterNetEvent('loop-scoot:notify', function(message, kind) notify(message, kind) end)

local function phoneResource()
    return type(Config.NativePhone) == 'table' and Config.NativePhone.resource or nil
end

local function externalPhoneOpen()
    local resource = phoneResource()
    if resource and GetResourceState(resource) == 'started' then
        local ok, opened = pcall(function() return exports[resource]:isPhoneOpen() end)
        if ok and opened then return true end
    end
    return false
end
if ScootUiFocus then ScootUiFocus.SetExternalCheck(externalPhoneOpen) end
local function phoneUiBlocked()
    if ScootUiFocus and ScootUiFocus.Blocked() then return true end
    if IsNuiFocused() then return true end
    return externalPhoneOpen()
end

local function openPhone(stationId)
    if stopping or phone or menuBusy or phoneUiBlocked() or mounting then return end
    if stationId and not Scoot.FindStation(stationId) then
        notify(ScootText('err.stationNotFound'), 'error')
        return
    end
    local ped = PlayerPedId()
    if not DoesEntityExist(ped) or IsEntityDead(ped) or IsPedInAnyVehicle(ped, false) then
        notify(ScootText('err.phoneInVehicle'), 'error')
        return
    end
    local resource = phoneResource()
    if not resource or GetResourceState(resource) ~= 'started' then
        if ScootKiosk then ScootKiosk.Open(stationId) else notify(ScootText('err.serviceDown'), 'error') end
        return
    end
    TriggerEvent('loop-scoot:openPhone', stationId)
end

RegisterCommand(Config.OpenCommand, function() openPhone(targetStation and targetStation.id) end, false)
if Config.OpenKey ~= '' then RegisterKeyMapping(Config.OpenCommand, 'SCOOT: open station', 'keyboard', Config.OpenKey) end
local function nativePhoneCaller()
    local resource = phoneResource()
    return resource ~= nil and GetInvokingResource() == resource
end

exports('open', function(stationId)
    if nativePhoneCaller() then openPhone(stationId) end
end)

local function callable(value)
    if type(value) == 'function' then return true end
    local meta = type(value) == 'table' and getmetatable(value)
    return type(meta) == 'table' and meta.__call ~= nil
end

local function phoneReply(cb, result)
    if type(result) == 'table' and result.ok ~= true then
        print(('[scoot] phone reply: %s'):format(tostring(result.message)))
    end
    if not callable(cb) then
        print(('[scoot] phone reply dropped: callback is a %s'):format(type(cb)))
        return
    end
    local ok, problem = pcall(cb, result)
    if not ok then print('[scoot] phone reply failed: ' .. tostring(problem)) end
end

local function phoneRefused(what, cb, key)
    print(('[scoot] %s refused: caller %s, stopping %s, phone %s, ready %s, busy %s, mounting %s'):format(what,
        tostring(GetInvokingResource()), tostring(stopping), tostring(phone), tostring(phoneReady),
        tostring(menuBusy), tostring(mounting)))
    phoneReply(cb, { ok = false, message = ScootText(key or 'err.actionUnavailable') })
end

local function phoneSessionValid(session)
    return not stopping and phone and phoneSession == session
end

local function runPhoneOperation(cb, work)
    menuBusy, phoneOperation = true, phoneOperation + 1
    local operation = phoneOperation
    CreateThread(function()
        local ok, result = xpcall(work, debug.traceback)
        if phoneOperation == operation then menuBusy = false end
        if not ok then
            print('[scoot] phone operation failed: ' .. tostring(result))
            result = { ok = false, message = ScootText('err.serverSilent') }
        elseif type(result) ~= 'table' then
            result = { ok = false, message = ScootText('err.serverSilent') }
        end
        local stateOk, state = pcall(rentalAppState)
        if stateOk then
            result.state = state
            if phone then pcall(TriggerEvent, 'loop-scoot:phoneState', state) end
        end
        phoneReply(cb, result)
    end)
end

exports('GetRentalAppState', function()
    if not nativePhoneCaller() then return nil end
    return rentalAppState()
end)

local function beginRentalApp(cb)
    local ped = PlayerPedId()
    if stopping or menuBusy or mounting or not DoesEntityExist(ped) or IsEntityDead(ped)
        or IsPedInAnyVehicle(ped, false) then
        phoneRefused('open', cb)
        return
    end
    phone, phoneReady, phoneSession = true, false, phoneSession + 1
    local session = phoneSession
    runPhoneOperation(cb, function()
        if not syncSnapshot() then return { ok = false, message = ScootText('err.serviceDown') } end
        if not phoneSessionValid(session) then
            return { ok = false, message = ScootText('err.rentalCancelled') }
        end
        local currentPed = PlayerPedId()
        if not DoesEntityExist(currentPed) or IsEntityDead(currentPed) or IsPedInAnyVehicle(currentPed, false) then
            closePhone()
            return { ok = false, message = ScootText('err.phoneBusy') }
        end
        phoneReady = true
        return { ok = true }
    end)
end

exports('BeginRentalApp', function(cb)
    if not nativePhoneCaller() then
        phoneRefused('open', cb)
        return
    end
    beginRentalApp(cb)
end)

local function endRentalApp()
    phone, phoneReady, phoneSession = false, false, phoneSession + 1
    return true
end

exports('EndRentalApp', function()
    if not nativePhoneCaller() then return false end
    return endRentalApp()
end)

local function prepareDelivery(station, response)
    local pending = response.rental
    if not pending or pending.phase ~= 'preparing' then return response end
    local netId, token = pending.netId, pending.token
    preparationHidden[netId] = token
    rental = pending
    if response.station then stationStates[station.id] = response.station end
    local deadline = GetGameTimer() + ((Config.Delivery or {}).prepareTimeout or 15000) - 500
    local failure = ScootText('err.prepareFailed')
    local function acknowledged()
        local accepted = stationStates[station.id]
        if rental and rental.token == token and rental.netId == netId and rental.stationId == station.id
            and rental.phase ~= 'preparing' and accepted and accepted.token == token
            and accepted.netId == netId and accepted.startedAt and accepted.startedAt > 0 then
            preparationHidden[netId] = nil
            return {ok=true,rental=rental,station=accepted,serverNow=now()}
        end
    end
    if not spawned[station.id] then
        spawned[station.id] = createStation(station)
    end

    for i=1,3 do
        if stopping or GetGameTimer() >= deadline then break end
        local sent = GetGameTimer()
        local ok, clock = awaitCallback('loop-scoot:clock', math.min(1500,deadline-sent))
        if ok and clock and clock.ok then calibrateClock(clock.serverNow, sent) end
        if i<3 and GetGameTimer()<deadline then Wait(math.min(110,deadline-GetGameTimer())) end
    end
    while not stopping and spawned[station.id] and GetGameTimer()<deadline do
        if IsEntityDead(PlayerPedId()) then break end
        if not rental or rental.token ~= token or rental.netId ~= netId or rental.stationId ~= station.id then
            failure = ScootText('err.prepareCancelled')
            break
        end

        local accepted = acknowledged()
        if accepted then return accepted end
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local vehicle = NetToVeh(netId)
            if vehicle ~= 0 and DoesEntityExist(vehicle) and GetEntityModel(vehicle)==vehicleHash then
                SetEntityLocallyInvisible(vehicle)
                if not NetworkHasControlOfEntity(vehicle) then
                    NetworkRequestControlOfEntity(vehicle)
                else
                    local p = Scoot.Transform(station, Scoot.Sequence(0).vehicleOffset)
                    FreezeEntityPosition(vehicle, true)
                    SetEntityCollision(vehicle, false, false)
                    SetEntityCoordsNoOffset(vehicle, p.x,p.y,p.z, false,false,false)
                    SetEntityRotation(vehicle,0.0,0.0,station.heading+Config.VehicleHeadingOffset,2,true)
                    SetEntityVelocity(vehicle,0.0,0.0,0.0)
                    local sent = GetGameTimer()
                    local ok, ready = awaitCallback('loop-scoot:ready', math.min(2000,math.max(1,deadline-GetGameTimer())), station.id, netId, token)
                    if ok and ready and ready.ok then

                        if stopping or not rental or rental.token ~= token or rental.netId ~= netId
                            or rental.stationId ~= station.id then
                            failure = ScootText('err.prepareCancelled')
                            break
                        end
                        calibrateClock(ready.serverNow, sent)
                        rental = ready.rental
                        stationStates[station.id] = ready.station
                        preparationHidden[netId] = nil
                        if Config.Debug then print(('[loop-scoot] delivery: ready %s; synchronized start %s'):format(netId, ready.station.startedAt)) end
                        return ready
                    end
                    if ok and ready and not ready.retry then
                        failure = ready and ready.message or ScootText('err.prepareStopped')
                        break
                    end
                end
            end
        end
        Wait(110)
    end

    if not stopping then
        local accepted = acknowledged()
        if accepted then return accepted end
    end
    if rental and rental.token == token and rental.netId == netId and rental.phase == 'preparing' then
        awaitCallback('loop-scoot:cancelPreparation', 1500, station.id, netId, token)
    end
    preparationHidden[netId] = nil
    if rental and rental.token == token then rental = nil end
    return {ok=false, message=failure}
end

local function rentFromApp(stationId, cb)
    if stopping or not phone or not phoneReady or menuBusy then
        phoneRefused('rent', cb)
        return
    end
    local station = type(stationId) == 'string' and Scoot.FindStation(stationId)
    if not station then
        phoneRefused('rent ' .. tostring(stationId), cb, 'err.stationNotFound')
        return
    end
    local session = phoneSession
    runPhoneOperation(cb, function()
        local function cancelled() return not phoneSessionValid(session) end
        local preloadDeadline = GetGameTimer() + 14000
        for _, propName in pairs(Config.Models) do
            if cancelled() then return { ok = false, message = ScootText('err.rentalCancelled') } end
            local remaining = preloadDeadline - GetGameTimer()
            if remaining <= 0 or not model(propName, math.min(7000, remaining), cancelled) then
                return { ok = false, message = ScootText(cancelled() and 'err.rentalCancelled' or 'err.stationAsset') }
            end
        end
        if Config.Debug then print(('[loop-scoot] rent: loading vehicle %s'):format(Config.Model)) end
        local hash, failure = model(Config.Model, Config.VehicleLoadTimeout, cancelled)
        if cancelled() then return { ok = false, message = ScootText('err.rentalCancelled') } end
        if not hash or not IsModelAVehicle(hash) then
            return { ok = false, message = ScootText(failure == 'timeout' and 'err.scooterSlow' or 'err.scooterModel') }
        end
        local ped = PlayerPedId()
        if not DoesEntityExist(ped) or IsEntityDead(ped) or IsPedInAnyVehicle(ped, false) then
            return { ok = false, message = ScootText('err.phoneBusy') }
        end
        local ok, result = awaitCallback('loop-scoot:rent', 10000, station.id)
        if not ok or type(result) ~= 'table' then
            result = { ok = false, message = ScootText('err.serverSilent') }
        end
        if result.ok then result = prepareDelivery(station, result) end
        if result.ok then
            rental = result.rental or rental
            local closeAt = (result.rental and result.rental.startedAt or now())
                + ((Config.Delivery or {}).phoneCloseDelay or 1400)
            SetTimeout(math.max(0, closeAt - now()), function()
                if phoneSessionValid(session) then closePhone() end
            end)
        end
        return result
    end)
end

exports('RentFromPhone', function(stationId, cb)
    if not nativePhoneCaller() then
        phoneRefused('rent', cb)
        return
    end
    rentFromApp(stationId, cb)
end)

local function returnFromApp(stationId, cb)
    if stopping or not phone or not phoneReady or menuBusy then
        phoneRefused('return', cb)
        return
    end
    local station = type(stationId) == 'string' and Scoot.FindStation(stationId)
    if not station then
        phoneRefused('return ' .. tostring(stationId), cb, 'err.stationNotFound')
        return
    end
    local session = phoneSession
    runPhoneOperation(cb, function()
        local ok, result = awaitCallback('loop-scoot:return', 5000, station.id)
        if not ok or type(result) ~= 'table' then
            result = { ok = false, message = ScootText('err.serverSilent') }
        end
        if result.ok then
            rental = nil
            if phoneSessionValid(session) then closePhone() end
        end
        return result
    end)
end

exports('ReturnFromPhone', function(stationId, cb)
    if not nativePhoneCaller() then
        phoneRefused('return', cb)
        return
    end
    returnFromApp(stationId, cb)
end)

ScootApp = {
    Begin = beginRentalApp, End = endRentalApp, Rent = rentFromApp, Return = returnFromApp,
    State = function() return rentalAppState() end,
    Open = function() return phone end,
    Notify = function(message, kind) notify(message, kind) end,
}

createStation = function(station)
    if spawned[station.id] then return spawned[station.id] end
    if stationLoading[station.id] then
        while stationLoading[station.id] and not stopping do Wait(0) end
        return spawned[station.id]
    end
    stationLoading[station.id] = true
    local hashes = {}
    for key, name in pairs(Config.Models) do
        hashes[key] = model(name)
        if not hashes[key] or stopping then
            for _, hash in pairs(hashes) do SetModelAsNoLongerNeeded(hash) end
            stationLoading[station.id] = nil
            return nil
        end
    end
    local objects = {}
    for key, hash in pairs(hashes) do
        local c = station.coords
        local entity = CreateObjectNoOffset(hash, c.x, c.y, c.z-5.0, false, false, false)
        if entity == 0 then
            for _, object in pairs(objects) do destroy(object) end
            for _, requested in pairs(hashes) do SetModelAsNoLongerNeeded(requested) end
            stationLoading[station.id] = nil
            return nil
        end
        SetEntityHeading(entity, station.heading)
        FreezeEntityPosition(entity, true)
        SetEntityInvincible(entity, true)
        SetEntityCollision(entity, key == 'base' or key == 'body' or key == 'door', true)
        objects[key] = entity
        SetModelAsNoLongerNeeded(hash)
    end

    applyPose(station, objects, Scoot.Sequence(sequenceElapsed(stationStates[station.id])))
    spawned[station.id] = objects
    stationLoading[station.id] = nil
    return objects
end

applyPose = function(station, objects, pose)
    local cache = propPoses[objects]
    if not cache then cache = {}; propPoses[objects] = cache end
    local origin = station.coords
    local placementChanged = cache.x ~= origin.x or cache.y ~= origin.y or cache.z ~= origin.z
        or cache.heading ~= station.heading
    local function place(key, offset)
        local entity = objects[key]
        local previous = cache[key]
        if not previous or previous.entity ~= entity or placementChanged
            or previous.x ~= offset.x or previous.y ~= offset.y or previous.z ~= offset.z then
            if not DoesEntityExist(entity) then return end
            local p = Scoot.Transform(station, offset)
            SetEntityCoordsNoOffset(entity, p.x, p.y, p.z, false, false, false)
            if not previous or previous.entity ~= entity or cache.heading ~= station.heading then
                SetEntityHeading(entity, station.heading)
            end
            cache[key] = { entity=entity, x=offset.x, y=offset.y, z=offset.z }
        end
    end
    place('base', vector3(0,0,0))
    place('body', vector3(0,0,pose.bodyZ))
    place('door', vector3(0,0,pose.doorZ))
    place('tray', vector3(pose.trayX,0,pose.trayZ))
    if objects.grip then place('grip', vector3(pose.trayX,0,pose.gripZ)) end
    for key, factor in pairs(Config.RailTravel) do
        place(key, vector3(pose.trayX * factor, 0, pose.trayZ))
    end
    cache.x, cache.y, cache.z, cache.heading = origin.x, origin.y, origin.z, station.heading
end

local function settleVehicle(vehicle)
    if not DoesEntityExist(vehicle) or not NetworkHasControlOfEntity(vehicle) then return end
    SetEntityVelocity(vehicle, 0.0, 0.0, 0.0)
    SetEntityAngularVelocity(vehicle, 0.0, 0.0, 0.0)
    SetVehicleOnGroundProperly(vehicle)
    SetEntityRotation(vehicle, 0.0, 0.0, GetEntityHeading(vehicle), 2, true)
    if Config.Debug then print(('[loop-scoot] dismount: settled vehicle %s upright'):format(VehToNet(vehicle))) end
end

local function applyVehiclePhysics(vehicle, netId, dispensing, token, controlled)
    local previous = vehiclePhysics[netId]
    if not previous or previous.entity ~= vehicle or previous.dispensing ~= dispensing
        or previous.token ~= token or previous.controlled ~= controlled then
        FreezeEntityPosition(vehicle, dispensing)
        SetEntityCollision(vehicle, not dispensing, not dispensing)
        vehiclePhysics[netId] = {entity=vehicle, dispensing=dispensing, token=token, controlled=controlled}
    end
end

local function animateDelivery(vehicle, data)
    local station = Scoot.FindStation(data.stationId)
    local state = station and stationStates[station.id]
    local netId = VehToNet(vehicle)
    local controlled = NetworkHasControlOfEntity(vehicle)
    applyVehiclePhysics(vehicle,netId,true,data.token,controlled)
    if preparationHidden[netId] == data.token and state and state.token == data.token
        and state.startedAt and state.startedAt > 0 and not data.preparing then

        preparationHidden[netId] = nil
    end
    local timelineReady = state and state.token == data.token and clockReady
        and state.startedAt and state.startedAt > 0
        and not data.preparing and not preparationHidden[netId]
    local canPresent = timelineReady and spawned[station.id]
    if not canPresent then

        SetEntityLocallyInvisible(vehicle)
    end

    if not timelineReady or (not controlled and not canPresent) then return end
    local pose = Scoot.Sequence(sequenceElapsed(state))
    local p = Scoot.Transform(station, pose.vehicleOffset)

    SetEntityCoordsNoOffset(vehicle,p.x,p.y,p.z,false,false,false)
    SetEntityRotation(vehicle,0.0,0.0,station.heading+Config.VehicleHeadingOffset,2,true)
    if controlled then SetEntityVelocity(vehicle,0.0,0.0,0.0) end
end

CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(250) end
    Wait(700)
    for _, station in ipairs(Config.Stations) do
        local b = AddBlipForCoord(station.coords.x, station.coords.y, station.coords.z)
        SetBlipSprite(b, 226); SetBlipScale(b, 0.65); SetBlipColour(b, 2)
        SetBlipAsShortRange(b, true)
        BeginTextCommandSetBlipName('STRING'); AddTextComponentString(ScootText('blip.station',station.label)); EndTextCommandSetBlipName(b)
        blips[station.id] = b
    end
    syncSnapshot()
    while not stopping do
        local pos = GetEntityCoords(PlayerPedId())
        for _, station in ipairs(Config.Stations) do
            local distance = #(pos - station.coords)
            if distance < Config.StreamDistance and not spawned[station.id] then
                local objects = createStation(station)
                if objects then
                    if stopping then for _, entity in pairs(objects) do destroy(entity) end; break end
                    spawned[station.id] = objects
                end
            elseif distance > Config.UnloadDistance and spawned[station.id] then
                for _, entity in pairs(spawned[station.id]) do destroy(entity) end
                spawned[station.id] = nil
            elseif spawned[station.id] then

                for _, entity in pairs(spawned[station.id]) do
                    if not DoesEntityExist(entity) then
                        for _, remaining in pairs(spawned[station.id]) do destroy(remaining) end
                        spawned[station.id] = nil
                        break
                    end
                end
            end
        end
        Wait(1200)
    end
end)

CreateThread(function()
    local nextSound = 0
    local lastSoundPhase, lastSoundVolume = 'idle', 0
    while not stopping do
        local active = false
        local soundVolume, soundPhase = 0, 'idle'
        local pos = GetEntityCoords(PlayerPedId())
        for id, objects in pairs(spawned) do
            local state, station = stationStates[id], Scoot.FindStation(id)
            local elapsed = 0
            if state and state.phase ~= 'idle' then
                elapsed = sequenceElapsed(state)
                active = active or not state.pausedElapsed
            end
            local pose = Scoot.Sequence(elapsed)
            applyPose(station, objects, pose)
            if movingSounds[pose.phase] and not (state and state.pausedElapsed) then
                local volume = math.max(0, 1-#(pos-station.coords)/18.0)
                if volume > soundVolume then soundPhase, soundVolume = pose.phase, volume end
            end
        end
        for netId in pairs(preparationHidden) do
            active = true
            if NetworkDoesEntityExistWithNetworkId(netId) then
                local vehicle = NetToVeh(netId)
                if vehicle ~= 0 and DoesEntityExist(vehicle) then SetEntityLocallyInvisible(vehicle) end
            end
        end
        local rendered = {}
        for _, state in pairs(stationStates) do
            local waitingProps = not spawned[state.id]
            if (state.phase=='preparing' or state.phase=='dispensing' or (state.phase=='cooling' and waitingProps))
                and state.netId and state.netId ~= 0
                and NetworkDoesEntityExistWithNetworkId(state.netId) then
                local vehicle = NetToVeh(state.netId)
                if vehicle ~= 0 and DoesEntityExist(vehicle) and GetEntityModel(vehicle)==vehicleHash then
                    local data = Entity(vehicle).state.loopScoot
                    if not data then data = {stationId=state.id, token=state.token,
                        preparing=state.phase=='preparing', dispensing=state.phase~='cooling'} end
                    if data.dispensing then
                        active, rendered[state.netId] = true, true
                        animateDelivery(vehicle,data)
                    elseif waitingProps and data.token == state.token then
                        local station = Scoot.FindStation(state.id)
                        if station and #(GetEntityCoords(vehicle)-station.coords)
                            <= ((Config.Delivery or {}).maxDisplacement or 8.0) then

                            active = true
                            SetEntityLocallyInvisible(vehicle)
                        end
                    end
                end
            end
        end
        for netId, entry in pairs(initializedVehicles) do
            local vehicle = entry.entity
            if not rendered[netId] and DoesEntityExist(vehicle) then
                local data = Entity(vehicle).state.loopScoot
                if data and data.dispensing then
                    active = true
                    animateDelivery(vehicle, data)
                end
            end
        end
        if phone then
            DisableControlAction(0, 24, true); DisableControlAction(0, 25, true)
            DisableControlAction(0, 30, true); DisableControlAction(0, 31, true)
            DisablePlayerFiring(PlayerId(), true)
            if IsEntityDead(PlayerPedId()) then closePhone() end
        end
        if GetGameTimer() >= nextSound then

            local volume = math.floor(soundVolume * 100 + 0.5) / 100
            if soundPhase ~= lastSoundPhase or volume ~= lastSoundVolume then
                SendNUIMessage({ action = 'mechanism', phase = soundPhase, volume = volume * 0.12 })
                lastSoundPhase, lastSoundVolume = soundPhase, volume
            end
            nextSound = GetGameTimer() + 100
        end
        Wait(active and 0 or (phone and 0 or 150))
    end
end)

local function collectionHandsBusy(ped)
    local collection = Config.Collection
    if not collection or not collection.enabled or type(collection.animations) ~= 'table' or not DoesEntityExist(ped) then return false end
    for _, clip in pairs(collection.animations) do
        if type(clip) == 'table' and clip.dict and clip.clip then
            if IsEntityPlayingAnim(ped, clip.dict, clip.clip, 3) then return true end
            if clip.sided and (IsEntityPlayingAnim(ped, clip.dict, clip.clip .. '_left', 3)
                or IsEntityPlayingAnim(ped, clip.dict, clip.clip .. '_right', 3)) then return true end
        end
    end
    return false
end

local function rentalVehicle()
    if not rental or not rental.netId or not NetworkDoesEntityExistWithNetworkId(rental.netId) then return nil end
    local vehicle = NetToVeh(rental.netId)
    return vehicle ~= 0 and DoesEntityExist(vehicle) and vehicle or nil
end

local function riderAlive(ped)
    return DoesEntityExist(ped) and not IsEntityDead(ped) and not IsPedRagdoll(ped)
        and not IsPedFalling(ped) and not IsPedSwimming(ped)
end

local function rentalEngineVehicle()
    local ped=PlayerPedId()
    if stopping or mounting or phone or IsNuiFocused() or not riderAlive(ped) then return end
    local vehicle=rentalVehicle()
    if not vehicle or GetEntityModel(vehicle)~=vehicleHash
        or GetVehiclePedIsIn(ped,false)~=vehicle or GetPedInVehicleSeat(vehicle,-1)~=ped then return end
    local state=Entity(vehicle).state.loopScoot
    if not state or state.token~=rental.token or state.dispensing or state.preparing then return end
    return vehicle
end

local lastEngineToggle=-1000
local function toggleRentalEngine()
    local vehicle=rentalEngineVehicle()
    if not vehicle or GetGameTimer()-lastEngineToggle<400 then return end
    if not NetworkHasControlOfEntity(vehicle) then NetworkRequestControlOfEntity(vehicle);return end
    local enable=not GetIsVehicleEngineRunning(vehicle)
    local battery=Entity(vehicle).state.loopScootBattery
    if enable and (IsEntityDead(vehicle) or GetVehicleEngineHealth(vehicle)<=0
        or (type(battery)=='number' and battery<=0)) then return end
    lastEngineToggle=GetGameTimer()
    SetVehicleEngineOn(vehicle,enable,true,true)
end

RegisterCommand(Config.Rider.engineCommand or 'scootengine',toggleRentalEngine,false)
if Config.Rider.engineKey and Config.Rider.engineKey~='' then
    RegisterKeyMapping(Config.Rider.engineCommand or 'scootengine',ScootText('keybind.scooterEngine'),
        'keyboard',Config.Rider.engineKey)
end

local function riderDuration(clip)
    local seconds=GetAnimDuration(animDict,clip)
    if type(seconds)=='number' and seconds==seconds and seconds>=.3 and seconds<=4.0 then
        return math.floor(seconds*1000+.5)
    end
    if not riderClipFailures[clip] then
        print(('[loop-scoot] animation missing or invalid: %s; reload the collection YCD.'):format(clip))
        riderClipFailures[clip]=true
    end
end

local function steerClip(clip)
    if Config.Rider.steerFollow == false or not steerBases[clip] or not HasAnimDictLoaded(animDict) then return nil end
    local name = clip .. '_' .. steerSuffix
    if steerClips[name] == nil then
        local seconds = GetAnimDuration(animDict, name)
        steerClips[name] = type(seconds) == 'number' and seconds == seconds and seconds >= .3 and seconds <= 4.0
    end
    return steerClips[name] and name or nil
end

local function handlebarYaw(vehicle)
    local left, right = GetEntityBoneIndexByName(vehicle, 'hbgrip_l'), GetEntityBoneIndexByName(vehicle, 'hbgrip_r')
    if left == -1 or right == -1 then
        local angle = GetVehicleSteeringAngle(vehicle)
        return type(angle) == 'number' and angle == angle and angle or 0.0
    end
    local a, b = GetWorldPositionOfEntityBone(vehicle, left), GetWorldPositionOfEntityBone(vehicle, right)
    local l = GetOffsetFromEntityGivenWorldCoords(vehicle, a.x, a.y, a.z)
    local r = GetOffsetFromEntityGivenWorldCoords(vehicle, b.x, b.y, b.z)
    local yaw = math.deg(math.atan(r.y - l.y, r.x - l.x))
    if yaw ~= yaw then return 0.0 end
    if math.abs(yaw) >= 10.0 then
        local expected = (Config.Rider.steerPivotOffset or 0.13) * math.abs(math.sin(math.rad(yaw)))
        steerSuffix = math.abs((l.x + r.x) * .5) >= expected * .5 and 'steer' or 'steerc'
    end
    return yaw
end

local function steerPhase(vehicle)
    local lock = Config.Rider.steerLock or 32.0
    return math.max(0.0, math.min(.999, (handlebarYaw(vehicle) / lock + 1.0) * .5))
end

local function applySteer(ped, vehicle)
    if not ridingClip or ridingPed ~= ped or not ridingClip:find('_steerc?$') then return end
    SetEntityAnimSpeed(ped, animDict, ridingClip, 0.0)
    SetEntityAnimCurrentTime(ped, animDict, ridingClip, steerPhase(vehicle))
end

local function loadRiderClip(clip,valid)
    RequestAnimDict(animDict)
    local deadline=GetGameTimer()+1800
    while valid() and not HasAnimDictLoaded(animDict) and GetGameTimer()<deadline do Wait(20) end
    if valid() and HasAnimDictLoaded(animDict) then return riderDuration(clip) end
end

local function waitRider(duration,valid)
    local deadline=GetGameTimer()+duration
    while valid() and GetGameTimer()<deadline do Wait(math.min(20,deadline-GetGameTimer())) end
    return valid()
end

local nextRiderDebugAt=0
local function debugRiderPose(ped,vehicle)
    if not Config.Debug or GetGameTimer()<nextRiderDebugAt then return end
    nextRiderDebugAt=GetGameTimer()+1000
    local yaw=handlebarYaw(vehicle)
    local lHand,rHand=GetEntityBoneIndexByName(ped,'SKEL_L_Hand'),GetEntityBoneIndexByName(ped,'SKEL_R_Hand')
    local lGrip,rGrip=GetEntityBoneIndexByName(vehicle,'hbgrip_l'),GetEntityBoneIndexByName(vehicle,'hbgrip_r')
    local dl,dr='?','?'
    if lHand~=-1 and lGrip~=-1 then
        dl=('%.3f'):format(#(GetWorldPositionOfEntityBone(ped,lHand)-GetWorldPositionOfEntityBone(vehicle,lGrip)))
    end
    if rHand~=-1 and rGrip~=-1 then
        dr=('%.3f'):format(#(GetWorldPositionOfEntityBone(ped,rHand)-GetWorldPositionOfEntityBone(vehicle,rGrip)))
    end
    print(('[loop-scoot] ride: clip=%s suffix=%s side=%d yaw=%.1f phase=%.2f hand-grip L=%sm R=%sm')
        :format(tostring(ridingClip),tostring(steerSuffix),riderState.side,yaw,steerPhase(vehicle),dl,dr))
end

local function playRiderPose(ped,vehicle,clip,duration,loop,rate,t,blendIn)
    if t then t.secondaryClip=nil end
    stopRiding(true)
    TaskPlayAnim(ped,animDict,clip,blendIn or 5.0,-5.0,-1,loop and 33 or 34,0.0,false,false,false)
    ridingClip,ridingPed,ridingVehicle=clip,ped,vehicle
    ridingStartedAt,ridingDuration,ridingRate=GetGameTimer(),duration,rate or 1.0
    ridingObserved=false
    SetEntityAnimSpeed(ped,animDict,clip,ridingRate)
    if ridingRate==0 then SetEntityAnimCurrentTime(ped,animDict,clip,steerPhase(vehicle)) end
    if t then
        t.secondaryClip,t.secondaryStartedAt=clip,ridingStartedAt
    else ridingAttempts=ridingAttempts+1 end
end

local function stopTransitionPose(t)
    local clip=t.secondaryClip;t.secondaryClip=nil
    if clip and DoesEntityExist(t.ped) then StopAnimTask(t.ped,animDict,clip,3.0) end
    if ridingPed==t.ped and (not clip or ridingClip==clip) then stopRiding(true) end
end

local function riderStableVehicle(vehicle)
    if not DoesEntityExist(vehicle) or GetEntityModel(vehicle)~=vehicleHash or IsEntityInAir(vehicle) then return false end
    local r=GetEntityRotation(vehicle,2)
    return math.abs(r.x)<Config.Rider.maxTransitionTilt and math.abs(r.y)<Config.Rider.maxTransitionTilt
end

local function riderTransitionValid(t)
    local function bad(reason) t.reason=t.reason or reason;return false end
    if stopping then return bad('resource stopping') end
    if t.cancelled then return bad('cancelled') end
    if IsNuiFocused() then return bad('menu opened') end
    if riderTransition~=t then return bad('transition replaced') end
    if PlayerPedId()~=t.ped then return bad('ped changed') end
    if not riderAlive(t.ped) then return bad('ped down') end
    if not riderStableVehicle(t.vehicle) then return bad('scooter unstable or gone') end
    if t.clip and #(GetEntityCoords(t.ped)-(t.anchor or t.origin))>(t.anchor and .80 or 1.3) then
        t.displaced=true;return bad('ped displaced during clip')
    end
    if t.clip and t.clipStartedAt and GetGameTimer()-t.clipStartedAt>200
        and not IsEntityPlayingAnim(t.ped,animDict,t.clip,3) then
        t.poseInterrupted=true;return bad('clip interrupted')
    end
    if t.secondaryClip and GetGameTimer()-(t.secondaryStartedAt or 0)>200
        and not IsEntityPlayingAnim(t.ped,animDict,t.secondaryClip,3) then
        t.poseInterrupted=true;return bad('pose interrupted')
    end
    local state=Entity(t.vehicle).state.loopScoot
    if not state or state.token~=t.token or state.dispensing then return bad('rental state changed') end
    if #(GetEntityCoords(t.vehicle)-t.origin)>.20 then return bad('scooter moved') end
    local delta=(GetEntityHeading(t.vehicle)-t.heading+180)%360-180
    if math.abs(delta)>6 then return bad('scooter turned') end
    if t.kind=='mount' then
        if IsPedInAnyVehicle(t.ped,true) and not t.warpAttempted then return bad('ped already in a vehicle') end
        if GetPedInVehicleSeat(t.vehicle,-1)~=0 and not t.warpAttempted then return bad('seat taken') end
        if GetEntitySpeed(t.vehicle)>Config.Rider.maxMountSpeed then return bad('scooter moving') end
        return true
    end
    if t.exited then return not IsPedInAnyVehicle(t.ped,true) end
    return GetVehiclePedIsIn(t.ped,false)==t.vehicle and GetPedInVehicleSeat(t.vehicle,-1)==t.ped
end

local function riderStandingHeight(ped,position)
    if not IsPedInAnyVehicle(ped,true) then
        local found,z=GetGroundZFor_3dCoord(position.x,position.y,position.z+1.0,false)
        local height=found and position.z-z or 0
        if height>=.65 and height<=1.35 then riderOriginHeight[GetEntityModel(ped)]=height;return height end
    end
    local cached=riderOriginHeight[GetEntityModel(ped)]
    if cached then return cached end
    local minimum=GetModelDimensions(GetEntityModel(ped))
    return math.max(.65,math.min(1.35,-minimum.z))
end

local function riderClearance(ped,point,valid)
    local probe=StartShapeTestCapsule(point.x,point.y,point.z+.30,
        point.x,point.y,point.z+1.65,.24,31,ped,4)
    local deadline=GetGameTimer()+250
    while valid() and GetGameTimer()<deadline do
        local status,hit=GetShapeTestResult(probe)
        if status==2 then return hit==false or hit==0 end
        if status==0 then return false end
        Wait(0)
    end
    return false
end

local function maskRiderUntilPlaying(t,ped,clip)
    local deadline=GetGameTimer()+300
    while GetGameTimer()<deadline and DoesEntityExist(ped) and riderTransition==t
        and not IsEntityPlayingAnim(ped,animDict,clip,3) do
        SetEntityLocallyInvisible(ped);Wait(0)
    end
    for _=1,2 do SetEntityLocallyInvisible(ped);Wait(0) end
end

local function riderHeadingGap(ped,heading)
    return math.abs(((GetEntityHeading(ped)-heading+540.0)%360.0)-180.0)
end

local function chooseRiderSide(t,preferred)
    for _,side in ipairs({preferred,-preferred}) do
        if not riderTransitionValid(t) then return end
        local p=GetOffsetFromEntityInWorldCoords(t.vehicle,side*.50,-.130,0.0)
        local found,z=GetGroundZFor_3dCoord(p.x,p.y,p.z+1.0,false)
        if found and math.abs(z-t.origin.z)<.16 then
            local ground=vector3(p.x,p.y,z)
            if riderClearance(t.ped,ground,function() return riderTransitionValid(t) end) then return side,ground end
        end
    end
end

local function runFinishRiderTransition(t,success)
    if t.poseInterrupted and DoesEntityExist(t.ped) and DoesEntityExist(t.vehicle)
        and PlayerPedId()==t.ped and GetVehiclePedIsIn(t.ped,false)==t.vehicle then
        local current=Entity(t.vehicle).state.loopScoot
        if current and current.token==t.token then

            riderSession={ped=t.ped,vehicle=t.vehicle,token=t.token,pedModel=GetEntityModel(t.ped)}
            suppressRider(GetGameTimer())
        end
    end
    if t.secondaryClip then stopTransitionPose(t) end
    if t.frozen then
        t.frozen=false
        if DoesEntityExist(t.vehicle) then FreezeEntityPosition(t.vehicle,t.previousFrozen==true) end
    end
    if t.braked and DoesEntityExist(t.vehicle) and GetEntityModel(t.vehicle)==vehicleHash
        and NetworkHasControlOfEntity(t.vehicle) then
        SetVehicleHandbrake(t.vehicle,t.previousBrake or false)
        t.braked=false
    end
    if t.clip and DoesEntityExist(t.ped) then
        local ownsPose=IsEntityPlayingAnim(t.ped,animDict,t.clip,3)

        if not success and ownsPose and not t.displaced and not t.poseInterrupted and t.restore
            and #(GetEntityCoords(t.ped)-(t.anchor or t.origin))<=(t.anchor and .80 or 1.3) and PlayerPedId()==t.ped and riderAlive(t.ped)
            and not IsPedInAnyVehicle(t.ped,true) then
            StopAnimTask(t.ped,animDict,t.clip,1000.0)
            SetEntityCoordsNoOffset(t.ped,t.restore.x,t.restore.y,t.restore.z,false,false,false)
        else StopAnimTask(t.ped,animDict,t.clip,1000.0) end
    end
    if riderTransition==t then riderTransition=nil;mounting=false end
    if DoesEntityExist(t.ped) and not IsPedInAnyVehicle(t.ped,true) then releaseHelmet() end
end

local function finishRiderTransition(t,success)
    local ok,err=pcall(runFinishRiderTransition,t,success)
    if not ok then print('[loop-scoot] finish transition failed: '..tostring(err)) end
    if riderTransition==t then riderTransition=nil;mounting=false end
end

local riderClipNames={'mount_left','mount_right','dismount_left','dismount_right','ride_idle','ride_idle_left',
    'ride_cruise','ride_brake','ride_stand','stop_left','stop_right','lift_left','lift_right','push_off_left','push_off_right'}
local function releaseStuckRiderClips(ped)
    local stopped=false
    for _,clip in ipairs(riderClipNames) do
        if IsEntityPlayingAnim(ped,animDict,clip,3) then StopAnimTask(ped,animDict,clip,1000.0);stopped=true end
    end
    if stopped then
        if Config.Debug then print('[loop-scoot] freeze guard: stuck clip released on foot') end
        ClearPedSecondaryTask(ped)
    end
    return stopped
end

local function holdMountVehicle(t)
    local vehicle=t.vehicle
    if not NetworkHasControlOfEntity(vehicle) then
        NetworkRequestControlOfEntity(vehicle)
        local deadline=GetGameTimer()+300
        while not NetworkHasControlOfEntity(vehicle) and GetGameTimer()<deadline and DoesEntityExist(vehicle) do Wait(10) end
    end
    if not DoesEntityExist(vehicle) then return end
    t.previousFrozen=IsEntityPositionFrozen(vehicle)
    FreezeEntityPosition(vehicle,true);t.frozen=true
    if NetworkHasControlOfEntity(vehicle) then
        t.previousBrake=GetVehicleHandbrake(vehicle)
        SetVehicleHandbrake(vehicle,true);t.braked=true
    end
end

local function releaseMountVehicle(t)
    if t.frozen then
        t.frozen=false
        if DoesEntityExist(t.vehicle) then FreezeEntityPosition(t.vehicle,t.previousFrozen==true) end
    end
end

local function riderAlign(ped,goal,heading,valid)
    local from,fromHeading=GetEntityCoords(ped),GetEntityHeading(ped)
    local dist=#(vector2(from.x,from.y)-vector2(goal.x,goal.y))
    local gap=((heading-fromHeading+540.0)%360.0)-180.0
    local duration=math.max(160,math.min(520,math.floor(math.max(dist*450,math.abs(gap)*2.2))))
    local startedAt=GetGameTimer()
    while valid() do
        local k=(GetGameTimer()-startedAt)/duration
        if k>=1.0 then break end
        k=k*k*(3.0-2.0*k)
        SetEntityCoordsNoOffset(ped,from.x+(goal.x-from.x)*k,from.y+(goal.y-from.y)*k,from.z+(goal.z-from.z)*k,false,false,false)
        SetEntityHeading(ped,fromHeading+gap*k)
        Wait(0)
    end
    if not valid() then return false end
    SetEntityCoordsNoOffset(ped,goal.x,goal.y,goal.z,false,false,false)
    SetEntityHeading(ped,heading)
    return true
end

local mountSilent={['cancelled']=true,['resource stopping']=true,['ped down']=true,['menu opened']=true,
    ['ped changed']=true,['transition replaced']=true}

local function reportMount(t,err)
    if t.success or t.reported then return end
    t.reported=true
    local reason=t.reason or 'unknown'
    if err then reason='error '..tostring(err):match('^[^\n]*') end
    print(('[loop-scoot] mount: abandoned (%s)'):format(reason))
    if t.notified or mountSilent[reason] then return end
    if reason=='too far' then notify(ScootText('err.mountTooFar'),'error')
    else notify(ScootText('err.mountFailed'),'error') end
end

local function mountRefused(reason,key)
    print(('[loop-scoot] mount: refused (%s)'):format(reason))
    if key then notify(ScootText(key),'error') end
end

local function mount(vehicle)
    local ped=PlayerPedId()
    if mounting or riderTransition then return end
    if phone or IsNuiFocused() or stopping or not Config.Rider.enabled then return mountRefused('menu open or disabled') end
    if not riderAlive(ped) then return mountRefused('ped not able') end
    if IsPedInAnyVehicle(ped,true) then return mountRefused('ped in a vehicle') end
    if not vehicle or vehicle==0 or not DoesEntityExist(vehicle) then return mountRefused('no scooter') end
    if not riderStableVehicle(vehicle) then return mountRefused('scooter unstable','err.mountFailed') end
    if GetEntitySpeed(vehicle)>Config.Rider.maxMountSpeed then return mountRefused('scooter moving','err.mountFailed') end
    local state=Entity(vehicle).state.loopScoot
    if not state or state.dispensing then return mountRefused('scooter not ready') end
    if GetPedInVehicleSeat(vehicle,-1)~=0 then return mountRefused('seat taken','err.mountFailed') end
    local t={kind='mount',ped=ped,vehicle=vehicle,token=state.token,startedAt=GetGameTimer(),
        origin=GetEntityCoords(vehicle),heading=GetEntityHeading(vehicle),timeoutMs=9000}
    mounting,riderTransition=true,t
    local ok,err=xpcall(function()
        local position=GetEntityCoords(ped)
        local height=riderStandingHeight(ped,position)
        local sidePoints={}
        for _,s in ipairs({-1,1}) do sidePoints[s]=GetOffsetFromEntityInWorldCoords(vehicle,s*.50,-.130,0.0) end
        local preferred=#(position-sidePoints[-1])<=#(position-sidePoints[1]) and -1 or 1
        local side,ground=chooseRiderSide(t,preferred)
        if not side then
            if not t.reason then t.reason='no clear side';t.notified=true;notify(ScootText('err.noMountSide'),'error') end
            return
        end
        local clip=side<0 and 'mount_left' or 'mount_right'
        if Config.Debug then print(('[loop-scoot] mount: side %d clip %s'):format(side,clip)) end
        local goal=vector3(ground.x,ground.y,ground.z+height)
        if #(vector2(position.x,position.y)-vector2(goal.x,goal.y))>3.5 then t.reason='too far';return end
        local duration=loadRiderClip(clip,function() return riderTransitionValid(t) end)
        if not duration then
            if riderTransitionValid(t) then t.reason='clip missing';t.notified=true;notify(ScootText('err.riderAnims'),'error') end
            return
        end
        local idle=side<0 and 'ride_idle_left' or 'ride_idle'
        local idleDuration=riderDuration(idle)
        if not idleDuration then
            t.reason='idle clip missing';t.notified=true;notify(ScootText('err.riderPose'),'error');return
        end
        t.timeoutMs=7000+duration
        holdMountVehicle(t)
        if not riderTransitionValid(t) then return end

        local here=GetEntityCoords(ped)
        if #(vector2(here.x,here.y)-vector2(goal.x,goal.y))>.9 then
            TaskGoStraightToCoord(ped,goal.x,goal.y,goal.z,1.0,1400,t.heading%360,0.12)
            local walkDeadline=GetGameTimer()+1500
            while riderTransitionValid(t) and GetGameTimer()<walkDeadline do
                local now=GetEntityCoords(ped)
                if #(vector2(now.x,now.y)-vector2(goal.x,goal.y))<=.35 then break end
                Wait(30)
            end
            if not riderTransitionValid(t) then return end
            local now=GetEntityCoords(ped)
            if #(vector2(now.x,now.y)-vector2(goal.x,goal.y))>1.3 then t.reason='goal not reached';return end
        end
        ClearPedTasks(ped)
        if not riderAlign(ped,goal,t.heading,function() return riderTransitionValid(t) end) then return end

        t.anchor=goal;t.restore=goal;t.clip=clip;t.clipStartedAt=GetGameTimer()
        TaskPlayAnimAdvanced(ped,animDict,clip,goal.x,goal.y,goal.z,
            0.0,0.0,t.heading,4.0,-4.0,-1,2,0.0,0,0)
        if not waitRider(duration,function() return riderTransitionValid(t) end) then return end
        t.warpAttempted=true
        guardHelmet(ped)
        TaskWarpPedIntoVehicle(ped,vehicle,-1)
        local seatDeadline=GetGameTimer()+400
        while GetGameTimer()<seatDeadline and not stopping and PlayerPedId()==ped and riderAlive(ped)
            and DoesEntityExist(vehicle) and not IsPedInAnyVehicle(ped,false) do
            SetEntityLocallyInvisible(ped);Wait(0)
        end
        SetEntityLocallyInvisible(ped)
        if stopping or PlayerPedId()~=ped or not riderAlive(ped) or not DoesEntityExist(vehicle)
            or GetEntityModel(vehicle)~=vehicleHash or GetVehiclePedIsIn(ped,false)~=vehicle
            or GetPedInVehicleSeat(vehicle,-1)~=ped then t.reason=t.reason or 'seat not reached';return end
        local current=Entity(vehicle).state.loopScoot
        if not current or current.token~=t.token or current.dispensing then t.reason='rental state changed';return end
        StopAnimTask(ped,animDict,clip,1000.0);t.clip=nil
        releaseMountVehicle(t)
        SetVehicleEngineOn(vehicle,Config.Rider.autoStartEngine==true,true,Config.Rider.autoStartEngine~=true)
        riderState=ScootRider.New(side)
        riderSession={ped=ped,vehicle=vehicle,token=t.token,pedModel=GetEntityModel(ped)}
        riderSuppressed,ridingAttempts=false,0

        local steered=steerClip(idle)
        if steered then playRiderPose(ped,vehicle,steered,riderDuration(steered) or idleDuration,false,0.0,nil,1000.0)
        else playRiderPose(ped,vehicle,idle,idleDuration,true,1.0,nil,1000.0) end
        riderRetryAt=GetGameTimer()+200
        maskRiderUntilPlaying(t,ped,ridingClip or idle)
        if Config.Debug then
            local seat=GetOffsetFromEntityGivenWorldCoords(vehicle,GetEntityCoords(ped))
            print(('[loop-scoot] mount: seat offset %.3f %.3f %.3f (clip expects 0.000 -0.095 1.015)'):format(seat.x,seat.y,seat.z))
        end
        t.success=true
    end,debug.traceback)
    finishRiderTransition(t,t.success)
    reportMount(t,not ok and err or nil)
end

local function dismount(vehicle)
    local ped=PlayerPedId()
    if mounting or riderTransition or stopping or not riderAlive(ped) or not riderStableVehicle(vehicle)
        or GetVehiclePedIsIn(ped,false)~=vehicle or GetPedInVehicleSeat(vehicle,-1)~=ped
        or GetEntitySpeed(vehicle)>Config.Rider.maxDismountSpeed then return false end
    local state=Entity(vehicle).state.loopScoot
    if not state or state.dispensing then return false end
    if riderSuppressed then
        stopRiding(true);TaskLeaveVehicle(ped,vehicle,0);return false
    end
    local t={kind='dismount',ped=ped,vehicle=vehicle,token=state.token,startedAt=GetGameTimer(),
        origin=GetEntityCoords(vehicle),heading=GetEntityHeading(vehicle)}
    riderTransition=t;mounting=true
    local ok,err=xpcall(function()
        local side,ground=chooseRiderSide(t,riderState.side)
        if not side then notify(ScootText('err.noDismountSide'),'error');return end
        local clip=side<0 and 'dismount_left' or 'dismount_right'
        if Config.Debug then print(('[loop-scoot] dismount: side %d clip %s'):format(side,clip)) end
        local duration=loadRiderClip(clip,function() return riderTransitionValid(t) end)
        if not duration then
            if riderTransitionValid(t) then
                notify(ScootText('err.animFallback'),'error');t.nativeFallback=true
            end
            return
        end

        local idle=side<0 and 'ride_idle_left' or 'ride_idle'
        local settle=side<0 and 'stop_left' or 'stop_right'
        local lift=riderState.side<0 and 'lift_left' or 'lift_right'
        local idleDuration,settleDuration,liftDuration=riderDuration(idle),riderDuration(settle),riderDuration(lift)
        if not idleDuration or not settleDuration or not liftDuration then t.nativeFallback=true;return end
        if not NetworkHasControlOfEntity(vehicle) then
            NetworkRequestControlOfEntity(vehicle)
            local controlDeadline=GetGameTimer()+400
            while not NetworkHasControlOfEntity(vehicle) and GetGameTimer()<controlDeadline
                and riderTransitionValid(t) do Wait(20) end
            if not riderTransitionValid(t) then return end
        end
        if NetworkHasControlOfEntity(vehicle) then
            t.previousBrake=GetVehicleHandbrake(vehicle)
            SetVehicleHandbrake(vehicle,true);t.braked=true
        end
        local deadline=GetGameTimer()+800
        while riderTransitionValid(t) and GetEntitySpeed(vehicle)>.15 and GetGameTimer()<deadline do Wait(20) end
        if not riderTransitionValid(t) or GetEntitySpeed(vehicle)>.15 then return end

        if (riderState.mode=='push' or riderState.mode=='stop') and ridingClip and ridingStartedAt then
            t.secondaryClip,t.secondaryStartedAt=ridingClip,ridingStartedAt
            local length=(ridingDuration or riderDuration(ridingClip) or 0)/(ridingRate or 1.0)
            local remaining=math.max(0,length-(GetGameTimer()-ridingStartedAt))
            if not waitRider(remaining,function() return riderTransitionValid(t) end) then return end
            riderState.mode=riderState.mode=='stop' and 'idle' or 'cruise'
        end
        stopTransitionPose(t)
        if riderState.mode=='idle' and riderState.side~=side then
            playRiderPose(ped,vehicle,lift,liftDuration,false,1.0,t)
            if not waitRider(liftDuration,function() return riderTransitionValid(t) end) then return end
            stopTransitionPose(t);riderState.mode='cruise'
        end
        if riderState.mode~='idle' or riderState.side~=side then
            playRiderPose(ped,vehicle,settle,settleDuration,false,1.0,t)
            if not waitRider(settleDuration,function() return riderTransitionValid(t) end) then return end
            stopTransitionPose(t)
        end
        playRiderPose(ped,vehicle,idle,idleDuration,true,1.0,t)
        if not waitRider(300,function() return riderTransitionValid(t) end) then return end
        if not riderClearance(ped,ground,function() return riderTransitionValid(t) end) then return end
        stopTransitionPose(t)

        if t.braked and NetworkHasControlOfEntity(vehicle) then SetVehicleHandbrake(vehicle,t.previousBrake) end
        t.braked=false
        if Config.Debug then
            local seat=GetOffsetFromEntityGivenWorldCoords(vehicle,GetEntityCoords(ped))
            print(('[loop-scoot] dismount: seat offset %.3f %.3f %.3f (clip expects 0.000 -0.095 1.015)'):format(seat.x,seat.y,seat.z))
        end
        TaskLeaveVehicle(ped,vehicle,16)
        deadline=GetGameTimer()+500
        while DoesEntityExist(ped) and GetVehiclePedIsIn(ped,false)==vehicle
            and GetGameTimer()<deadline and not stopping do SetEntityLocallyInvisible(ped);Wait(0) end
        SetEntityLocallyInvisible(ped)
        t.exited=true
        if not riderTransitionValid(t) then return end
        local height=riderOriginHeight[GetEntityModel(ped)] or riderStandingHeight(ped,GetEntityCoords(ped))

        local anchor=vector3(ground.x,ground.y,ground.z+height)
        t.anchor=anchor;t.restore=anchor;t.clip=clip;t.clipStartedAt=GetGameTimer()
        SetEntityCoordsNoOffset(ped,anchor.x,anchor.y,anchor.z,false,false,false)
        SetEntityHeading(ped,t.heading)
        TaskPlayAnimAdvanced(ped,animDict,clip,anchor.x,anchor.y,anchor.z,
            0.0,0.0,t.heading,1000.0,-8.0,-1,2,0.0,0,0)
        maskRiderUntilPlaying(t,ped,clip)
        if not waitRider(math.max(0,duration-(GetGameTimer()-t.clipStartedAt)),function() return riderTransitionValid(t) end) then return end
        local groundFound,groundZ=GetGroundZFor_3dCoord(ground.x,ground.y,ground.z+1.0,false)
        if not groundFound or math.abs(groundZ-ground.z)>.08
            or not riderClearance(ped,ground,function() return riderTransitionValid(t) end) then return end
        SetEntityCoordsNoOffset(ped,ground.x,ground.y,ground.z+height,false,false,false)
        SetEntityHeading(ped,t.heading)
        StopAnimTask(ped,animDict,clip,4.0);t.clip=nil
        releaseHelmet()
        settleVehicle(vehicle)
        riderState=ScootRider.New(side);t.success=true
    end,debug.traceback)
    finishRiderTransition(t,t.success)
    if not ok then print('[loop-scoot] dismount interrupted: '..tostring(err)) end
    if t.nativeFallback and not stopping and riderAlive(ped) and PlayerPedId()==ped
        and DoesEntityExist(vehicle) and GetEntityModel(vehicle)==vehicleHash
        and GetVehiclePedIsIn(ped,false)==vehicle and GetPedInVehicleSeat(vehicle,-1)==ped then
        local current=Entity(vehicle).state.loopScoot
        if current and current.token==t.token and not current.dispensing then
            stopRiding(true);TaskLeaveVehicle(ped,vehicle,0)
        end
    end
    return t.success==true
end

local mountQueued,dismountQueued=false,false
local mountCooldownUntil=0
local function launchMount(vehicle)
    if mountQueued or dismountQueued or mounting or riderTransition or GetGameTimer()<mountCooldownUntil then return false end
    mountQueued=true
    CreateThread(function()
        local ok,err=pcall(mount,vehicle)
        mountQueued=false
        mountCooldownUntil=GetGameTimer()+600
        if not ok then print('[loop-scoot] mount failed: '..tostring(err)) end
    end)
    return true
end

local function launchDismount(vehicle)
    if mountQueued or dismountQueued or mounting or riderTransition then return false end
    dismountQueued=true
    CreateThread(function()
        local ok,err=pcall(dismount,vehicle)
        dismountQueued=false
        if not ok then print('[loop-scoot] dismount failed: '..tostring(err)) end
    end)
    return true
end

RegisterCommand('+loop-scoot-use', function()
    if phone or IsNuiFocused() then return end
    if action == 'mount' then launchMount(targetVehicle)
    elseif action == 'station' and targetStation then openPhone(targetStation.id) end
end, false)
RegisterCommand('-loop-scoot-use', function() end, false)
RegisterKeyMapping('+loop-scoot-use', 'SCOOT: rent / ride', 'keyboard', 'E')

CreateThread(function()
    while not stopping do
        local ped, text = PlayerPedId(), nil
        action, targetStation, targetVehicle = nil, nil, nil
        if not phone and not mounting and not IsEntityDead(ped) and not IsPedInAnyVehicle(ped,false) and not IsNuiFocused()
            and not collectionHandsBusy(ped) then
            local p, vehicle = GetEntityCoords(ped), rentalVehicle()
            if vehicle and #(p-GetEntityCoords(vehicle)) < 2.0 then
                local state = Entity(vehicle).state.loopScoot
                if state and not state.dispensing and GetPedInVehicleSeat(vehicle,-1)==0
                    and ScootCollectionPickupTarget~=vehicle then
                    text, action, targetVehicle = '~INPUT_CONTEXT~ ' .. ScootText('prompt.mount'), 'mount', vehicle
                end
            end
            if not text then
                local best = Config.InteractionDistance
                for _, station in ipairs(Config.Stations) do
                    local distance = #(p-station.coords)
                    if distance < best then best, targetStation = distance, station end
                end
                if targetStation then text, action = '~INPUT_CONTEXT~ ' .. ScootText('prompt.station'), 'station' end
            end
        end
        if action == 'mount' and targetVehicle and Config.Rider.enabled and not mounting and not riderTransition then
            DisableControlAction(0,23,true)
            if IsDisabledControlJustPressed(0,23) then
                local target = targetVehicle
                launchMount(target)
            end
        end
        local anchor = targetVehicle or (targetStation and targetStation.coords)
        if text and anchor then
            local point, lift = anchor, 0.45
            if targetVehicle then
                point = GetEntityCoords(targetVehicle)
            else
                point, lift = Scoot.Transform(targetStation, vector3(-1.3, 0.0, 1.5)), 0.0
            end
            local glyph, label = ScootPromptKey(text)
            ScootPrompts.Set('rental', { { key = glyph, label = label, world = point, offsetZ = lift,
                promptRange = Config.InteractionDistance, range = Config.InteractionDistance + 2.0 } })
        elseif prompt then
            ScootPrompts.Clear('rental')
        end
        prompt = text
        if phone then updateUI() end
        Wait(text and 0 or 250)
    end
end)

CreateThread(function()
    local vehicles, nextPoolScan = {}, 0
    local function include(netId)
        if not netId or netId == 0 or not NetworkDoesEntityExistWithNetworkId(netId) then return end
        local vehicle = NetToVeh(netId)
        if vehicle ~= 0 and DoesEntityExist(vehicle) and GetEntityModel(vehicle) == vehicleHash then vehicles[netId] = vehicle end
    end
    while not stopping do
        if GetGameTimer() >= nextPoolScan then
            vehicles = {}
            for _, vehicle in ipairs(GetGamePool('CVehicle')) do
                if GetEntityModel(vehicle) == vehicleHash and NetworkGetEntityIsNetworked(vehicle) then
                    vehicles[VehToNet(vehicle)] = vehicle
                end
            end
            nextPoolScan = GetGameTimer() + 1000
        end

        for _, state in pairs(stationStates) do include(state.netId) end
        if rental then include(rental.netId) end
        for netId, _ in pairs(initializedVehicles) do
            if not vehicles[netId] then initializedVehicles[netId], vehiclePhysics[netId] = nil, nil end
        end
        for netId, vehicle in pairs(vehicles) do
            if vehicle ~= 0 and DoesEntityExist(vehicle) and GetEntityModel(vehicle) == vehicleHash
                and NetworkGetEntityIsNetworked(vehicle) and VehToNet(vehicle) == netId then
                local state = Entity(vehicle).state.loopScoot
                if state then
                    local dispensing = state.dispensing == true
                    local initialized = initializedVehicles[netId]
                    if not initialized or initialized.entity ~= vehicle or initialized.dispensing ~= dispensing
                        or initialized.token ~= state.token then
                        if Config.Debug then print(('[loop-scoot] vehicle: initializing %s (%s)'):format(netId, dispensing and 'dispensing' or 'released')) end
                        applyVehiclePhysics(vehicle,netId,dispensing,state.token,NetworkHasControlOfEntity(vehicle))
                        SetVehicleDoorsLocked(vehicle, dispensing and 2 or 1)
                        SetVehicleCanBeVisiblyDamaged(vehicle, false)
                        SetVehicleTyresCanBurst(vehicle, false)
                        SetVehicleNumberPlateTextIndex(vehicle, 1)
                        SetVehicleFuelLevel(vehicle,100.0)
                        SetVehicleRadioEnabled(vehicle,false)
                        SetEntityMaxSpeed(vehicle,Config.MaxSpeed)
                        if dispensing then SetVehicleEngineOn(vehicle,false,true,true) end
                        initializedVehicles[netId] = { entity = vehicle, dispensing = dispensing, token = state.token }
                        if Config.Debug then print(('[loop-scoot] vehicle: initialized %s'):format(netId)) end
                    end
                end
            else
                vehicles[netId], initializedVehicles[netId], vehiclePhysics[netId] = nil, nil, nil
            end
        end
        Wait(150)
    end
end)

CreateThread(function()
    while not stopping do
        local lit = false
        local playerCoords = GetEntityCoords(PlayerPedId())
        for _, entry in pairs(initializedVehicles) do
            local vehicle = entry.entity
            if not entry.dispensing and DoesEntityExist(vehicle) and GetIsVehicleEngineRunning(vehicle)
                and #(GetEntityCoords(vehicle)-playerCoords)<45.0 then
                lit = true
                local front = GetEntityBoneIndexByName(vehicle,'headlight_l')
                local rear = GetEntityBoneIndexByName(vehicle,'taillight_l')
                if front ~= -1 then
                    local p, f = GetWorldPositionOfEntityBone(vehicle,front), GetEntityForwardVector(vehicle)
                    DrawSpotLight(p.x,p.y,p.z,f.x,f.y,f.z-0.12,230,245,255,18.0,2.0,0.0,18.0,1.0)
                    DrawLightWithRange(p.x,p.y,p.z,220,242,255,0.35,0.6)
                end
                if rear ~= -1 then
                    local p = GetWorldPositionOfEntityBone(vehicle,rear)
                    DrawLightWithRange(p.x,p.y,p.z,255,45,18,1.0,0.85)
                end
            end
        end
        Wait(lit and 0 or 250)
    end
end)

local function updateRiding()
    if riderTransition then return end
    local ped=PlayerPedId()
    local vehicle=GetVehiclePedIsIn(ped,false)
    if not Config.Rider.enabled or not DoesEntityExist(ped) or vehicle==0 or not DoesEntityExist(vehicle)
        or GetEntityModel(vehicle)~=vehicleHash or GetPedInVehicleSeat(vehicle,-1)~=ped then
        stopRiding();riderSession=nil;riderSuppressed=false;ridingAttempts=0
        if not IsPedInAnyVehicle(ped,true) then releaseHelmet() end
        return
    end
    guardHelmet(ped)
    local state=Entity(vehicle).state.loopScoot
    local token=state and state.token
    local pedModel=GetEntityModel(ped)
    if riderSession and (riderSession.ped~=ped or riderSession.vehicle~=vehicle
        or riderSession.token~=token or riderSession.pedModel~=pedModel) then
        stopRiding();riderSession=nil;riderSuppressed=false;ridingAttempts=0
    end
    riderSession=riderSession or {ped=ped,vehicle=vehicle,token=token,pedModel=pedModel}
    if not riderAlive(ped) or GetIsTaskActive(ped,2) or IsControlPressed(0,75)
        or (state and state.dispensing) then

        stopRiding(true);return
    end
    local nowAt=GetGameTimer()
    if riderSuppressed then

        if nowAt<riderResumeAt then return end
        riderSuppressed=false;ridingAttempts=0
    end
    if ridingClip and ridingPed==ped then
        local previousPlaying=IsEntityPlayingAnim(ped,animDict,ridingClip,3)
        if previousPlaying then
            ridingObserved=true;ridingAttempts=0
        elseif ridingStartedAt and nowAt-ridingStartedAt>=200 then
            if ridingObserved or ridingAttempts>=3 then
                stopRiding(true);suppressRider(nowAt)
                if Config.Debug then print('[loop-scoot] riding pose replaced or refused; resume deferred.') end
                return
            end
        end
    end
    local speed=GetEntitySpeed(vehicle)
    local velocity=GetEntitySpeedVector(vehicle,true)
    local throttle=GetControlNormal(0,71)
    if Config.Rider.autoStartEngine~=true and not GetIsVehicleEngineRunning(vehicle) then throttle=0 end
    local decision=ScootRider.Update(riderState,{now=nowAt,speed=speed,forwardSpeed=velocity.y,
        throttle=throttle,brake=GetControlNormal(0,72),
        steer=GetControlNormal(0,59),airborne=IsEntityInAir(vehicle)},Config.Rider)
    if not decision then stopRiding(true);return end
    local leavingLift=(ridingClip=='lift_left' or ridingClip=='lift_right') and decision.clip~=ridingClip
    if nowAt<riderRetryAt and not leavingLift then return end
    if not HasAnimDictLoaded(animDict) then
        RequestAnimDict(animDict);riderRetryAt=nowAt+250;return
    end
    local clip=decision.clip
    local steered=steerClip(clip)
    if steered then clip=steered;decision.loop,decision.rate,decision.durationMs=false,0.0,nil end
    local playing=ridingClip==clip and ridingPed==ped and IsEntityPlayingAnim(ped,animDict,clip,3)
    if playing and decision.durationMs then decision.rate=ridingDuration/decision.durationMs end
    if not playing then
        if ridingClip==clip and ridingStartedAt and nowAt-ridingStartedAt<200 then return end
        local duration=riderDuration(clip)
        if not duration then
            decision.rate=1.0
            clip=decision.mode=='idle' and 'ride_idle' or 'ride_stand'
            duration=riderDuration(clip)
            if not duration then stopRiding();riderRetryAt=nowAt+Config.Rider.retryMs;return end
            decision.loop,decision.rate,decision.durationMs=true,1.0,nil
        end
        if ridingClip==clip and IsEntityPlayingAnim(ped,animDict,clip,3) then return end
        if decision.durationMs then decision.rate=duration/decision.durationMs end
        playRiderPose(ped,vehicle,clip,duration,decision.loop,decision.rate)
        local playedDuration=duration/decision.rate
        if decision.mode=='push' and not decision.loop and not riderState.pushPlayedUntil then
            riderState.pushPlayedUntil=nowAt+playedDuration;riderState.pushUntil=riderState.pushPlayedUntil
        elseif decision.mode=='stop' and not decision.loop and not riderState.stopPlayedUntil then
            riderState.stopPlayedUntil=nowAt+playedDuration;riderState.stopUntil=riderState.stopPlayedUntil
        end

        riderRetryAt=nowAt+200
    elseif not ridingRate or math.abs(decision.rate-ridingRate)>.04 then
        SetEntityAnimSpeed(ped,animDict,clip,decision.rate);ridingRate=decision.rate
    end
end

CreateThread(function()
    local nextPose,nextFootGuard=0,0
    while not stopping do
        local ped=PlayerPedId()
        local vehicle=GetVehiclePedIsIn(ped,false)
        local riding=vehicle~=0 and DoesEntityExist(vehicle) and GetEntityModel(vehicle)==vehicleHash
            and GetPedInVehicleSeat(vehicle,-1)==ped and riderAlive(ped)
        local handsBusy=not riding and collectionHandsBusy(ped)
        local engineVehicle=rentalEngineVehicle()
        if engineVehicle then
            local running=GetIsVehicleEngineRunning(engineVehicle)
            if not running and Config.Rider.autoStartEngine~=true then DisableControlAction(0,71,true) end
            ScootPrompts.Set('rentalEngine',{{key=Config.Rider.enginePromptKey or Config.Rider.engineKey or '',
                label=ScootText(running and 'prompt.stopScooter' or 'prompt.startScooter'),anchor='screen'}})
        else ScootPrompts.Clear('rentalEngine') end
        if riderTransition and GetGameTimer()-(riderTransition.startedAt or 0)>(riderTransition.timeoutMs or Config.Rider.transitionTimeoutMs or 12000) then
            local stale=riderTransition
            stale.reason=stale.reason or ('timeout after '..(GetGameTimer()-(stale.startedAt or 0))..' ms')
            stale.cancelled=true
            if stale.kind~='mount' then
                print(('[loop-scoot] freeze guard: %s transition forced to finish after %d ms'):format(
                    tostring(stale.kind),GetGameTimer()-(stale.startedAt or 0)))
            end
            finishRiderTransition(stale,false)
            if DoesEntityExist(ped) and not IsPedInAnyVehicle(ped,true) then releaseStuckRiderClips(ped) end
            mounting=false
        end
        if riderTransition then
            if riderTransition.ped==ped and riderAlive(ped) then
                if GetGameTimer()-(riderTransition.startedAt or 0)>200 and not riderTransition.exited
                    and IsControlJustPressed(0,200) then
                    riderTransition.cancelled=true
                end
                for _,control in ipairs({23,75,21,22,24,25,30,31,59,60,71,72,140,141,142}) do
                    DisableControlAction(0,control,true)
                end
                DisablePlayerFiring(PlayerId(),true)
            end
        elseif riding and Config.Rider.enabled and not IsNuiFocused() then
            local entry=Entity(vehicle).state.loopScoot
            if entry and not entry.dispensing and riderStableVehicle(vehicle)
                and GetEntitySpeed(vehicle)<=Config.Rider.maxDismountSpeed then
                DisableControlAction(0,75,true)
                if IsDisabledControlJustPressed(0,75) then
                    launchDismount(vehicle)
                end
            elseif IsControlPressed(0,75) then
                stopRiding(true)
            end
        end
        if GetGameTimer()>=nextPose then updateRiding();nextPose=GetGameTimer()+50 end
        if riding and not riderTransition then applySteer(ped,vehicle);debugRiderPose(ped,vehicle) end
        if not riding and not riderTransition then
            if not mounting and not mountQueued and not dismountQueued and riderAlive(ped)
                and not IsPedInAnyVehicle(ped,true) and GetGameTimer()>=nextFootGuard then
                nextFootGuard=GetGameTimer()+400
                releaseStuckRiderClips(ped)
            end
            if handsBusy then DisableControlAction(0,23,true) end
            local entering=GetVehiclePedIsTryingToEnter(ped)
            if entering~=0 and DoesEntityExist(entering) and GetEntityModel(entering)==vehicleHash then
                if handsBusy then
                    guardHelmet(ped)
                elseif Config.Rider.enabled and not mounting and entering==rentalVehicle() then
                    ClearPedTasksImmediately(ped)
                    local target=entering
                    launchMount(target)
                else guardHelmet(ped) end
            end
        end
        Wait((riding or riderTransition or handsBusy) and 0 or 250)
    end
end)

RegisterCommand('scootplace', function(_, args)
    local id = args[1] or 'vespucci'
    local ped = PlayerPedId()
    local p = GetOffsetFromEntityInWorldCoords(ped, 0.0, 2.0, 0.0)
    local found, ground = GetGroundZFor_3dCoord(p.x,p.y,p.z+3.0,false)
    if not found then notify(ScootText('err.noGround'), 'error'); return end
    local ok,result = awaitCallback('loop-scoot:place',5000,id,
        {x=p.x,y=p.y,z=ground},GetEntityHeading(ped))
    if not ok or not result then notify(ScootText('err.placementUnavailable'), 'error'); return end
    notify(result.message or (result.ok and ScootText('notify.stationMoved') or ScootText('err.placementRefused')),result.ok and 'success' or 'error')
    if result.ok then syncSnapshot() end
end,false)

AddEventHandler('onResourceStop', function(resource)
    if resource == phoneResource() then
        phone, phoneReady, phoneSession = false, false, phoneSession + 1
        return
    end
    if resource ~= GetCurrentResourceName() then return end
    stopping = true
    if riderTransition then finishRiderTransition(riderTransition,false) end
    stopRiding()
    releaseHelmet()
    closePhone()
    for _, objects in pairs(spawned) do for _, entity in pairs(objects) do destroy(entity) end end
    for _, b in pairs(blips) do RemoveBlip(b) end
    ScootPrompts.Clear('rental')
    ScootPrompts.Clear('rentalEngine')
    RemoveAnimDict(animDict)
end)

ScootApp.Vehicle = function() return rentalVehicle() end
ScootApp.Rental = function() return rental end
ScootApp.Mount = function()
    local vehicle = rentalVehicle()
    if not vehicle or mounting or collectionHandsBusy(PlayerPedId()) then return false end
    launchMount(vehicle)
    return true
end
ScootApp.Engine = function(on)
    local vehicle = rentalEngineVehicle()
    if not vehicle then return false end
    if (on == true) ~= GetIsVehicleEngineRunning(vehicle) then toggleRentalEngine() end
    return true
end
