local ESX = { GetPlayerFromId = ScootBridge.GetPlayer }
local stations, rentals, limits, stationOverrides = {}, {}, {}, {}
local stopped, serial = false, 0
local RESOURCE = GetCurrentResourceName()

local function rentalKeys(rental, give)
    if not give and not rental.keysGranted then return true end
    local accepted = ScootBridge.VehicleKeys(rental.source, rental.plate, rental.netId, give)
    rental.keysGranted = give and accepted or false
    return accepted
end

local function now()
    return GetGameTimer()
end

local function distance(a, b)
    local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(x * x + y * y + z * z)
end

local function identity(player)
    return player and (player.identifier or (player.getIdentifier and player.getIdentifier()))
end

local function playerFor(rental)
    local player = ESX.GetPlayerFromId(rental.source)
    if identity(player) == rental.identifier then return player end
end

local function result(message)
    return { ok = false, message = message, serverNow = now() }
end

local function logged(name, handler)
    return function(src, ...)
        local ok, response = xpcall(handler, debug.traceback, src, ...)
        if not ok then
            print(('[scoot] %s crashed for %s: %s'):format(name, tostring(src), tostring(response)))
            return result(ScootText('err.serverSilent'))
        end
        if type(response) ~= 'table' then
            print(('[scoot] %s gave no answer for %s'):format(name, tostring(src)))
            return result(ScootText('err.serverSilent'))
        end
        if response.ok ~= true and not response.retry then
            print(('[scoot] %s refused for %s: %s'):format(name, tostring(src), tostring(response.message)))
        end
        return response
    end
end

local function allowed(src, action, interval)
    local time = now()
    limits[src] = limits[src] or {}
    if limits[src][action] and time - limits[src][action] < interval then return false end
    limits[src][action] = time
    return true
end

local function publicStation(station)
    return {
        id = station.config.id, phase = station.phase, startedAt = station.startedAt,
        netId = station.netId, renter = station.renter, available = station.available,
        pausedElapsed = station.pausedElapsed, token = station.token,
        coords = { x = station.config.coords.x, y = station.config.coords.y, z = station.config.coords.z },
        heading = station.config.heading, label = station.config.label, capacity = station.config.capacity,
    }
end

local function publicRental(rental)
    if not rental then return nil end
    return {
        stationId = rental.stationId, netId = rental.netId or 0,
        expiresAt = rental.expiresAt or 0, plate = rental.plate,
        phase = rental.phase, token = rental.token, startedAt = rental.startedAt or 0,
    }
end

local function broadcast(station)
    TriggerClientEvent('loop-scoot:station', -1, publicStation(station), now())
end

local function notify(src, message, kind)
    TriggerClientEvent('loop-scoot:notify', src, message, kind or 'inform')
end

local function idle(station)
    station.phase, station.startedAt, station.netId, station.renter = 'idle', 0, 0, 0
    station.token, station.pausedElapsed = nil, nil
    broadcast(station)
end

local function nearby(src, station, reach)
    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then return false end
    if GetPlayerRoutingBucket(src) ~= (station.config.bucket or 0) then return false end
    return distance(GetEntityCoords(ped), station.config.coords) <= reach
end

local function refundKey(identifier)
    return 'pending-refund:' .. identifier
end

local function readRefunds(identifier)
    local raw = GetResourceKvpString(refundKey(identifier))
    if not raw then return {} end
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == 'table' then return decoded end
    print(('[%s] Invalid refund ledger for %s; manual inspection required.'):format(RESOURCE, identifier))
    return nil
end

local function collectRefunds(player)
    local identifier = identity(player)
    if not identifier then return end
    local refunds = readRefunds(identifier)
    if not refunds then return end
    for account, amount in pairs(refunds) do
        if type(amount) == 'number' and amount > 0 then
            local ok, err = ScootBridge.Credit(player, account, amount, 'LOOP SCOOT - remboursement')
            if ok then
                refunds[account] = nil
                SetResourceKvp(refundKey(identifier), json.encode(refunds))
            else
                print(('[%s] Refund deferred: %s'):format(RESOURCE, tostring(err)))
            end
        end
    end
end

local function refund(rental)
    if not rental.charged or rental.price <= 0 then return end
    local refunds = readRefunds(rental.identifier)
    if not refunds then return end
    refunds[rental.account] = (refunds[rental.account] or 0) + rental.price
    SetResourceKvp(refundKey(rental.identifier), json.encode(refunds))
    rental.charged = false
    local player = playerFor(rental)
    if player then collectRefunds(player) end
end

local function rentalEntityExists(rental)
    local entity = rental.entity
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    if not rental.tagged then return true end
    local state = Entity(entity).state.loopScoot
    return type(state) == 'table' and state.token == rental.token and state.renter == rental.source
        and state.stationId == rental.stationId and NetworkGetNetworkIdFromEntity(entity) == rental.netId
end

local function dockedAt(coords, bucket)
    if not coords then return false end
    for _, station in pairs(stations) do
        if bucket == (station.config.bucket or 0)
            and distance(coords, station.config.coords) <= (Config.ReturnDistance or 6.0) then return true end
    end
    return false
end

local function rentalPresent(rental)
    if rentalEntityExists(rental) then
        rental.missingSince = nil
        local entity = rental.entity
        rental.lastSeen = { coords = GetEntityCoords(entity), bucket = GetEntityRoutingBucket(entity),
            parked = GetEntitySpeed(entity) <= 0.8 and GetPedInVehicleSeat(entity, -1) == 0 }
        return true
    end
    local netId = rental.netId
    if rental.tagged and netId and netId ~= 0 and type(NetworkGetEntityFromNetworkId) == 'function' then
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity and entity ~= 0 and entity ~= rental.entity and DoesEntityExist(entity) then
            local previous = rental.entity
            rental.entity = entity
            if rentalEntityExists(rental) then return rentalPresent(rental) end
            rental.entity = previous
        end
    end
    rental.missingSince = rental.missingSince or now()
    return false
end

local function rentalGone(rental)
    if rentalPresent(rental) then return false end
    return now() - rental.missingSince >= (Config.LostGraceMs or 15000)
end

local function goneReason(rental)
    local seen = rental.lastSeen
    if seen and seen.parked and dockedAt(seen.coords, seen.bucket) then return 'returned' end
    return 'lost'
end

local function deleteRentalEntity(rental)
    local entity = rental.entity
    if not entity or entity == 0 then return end

    if rental.tagged then
        if rentalEntityExists(rental) then DeleteEntity(entity) end
        return
    end
    if DoesEntityExist(entity) then
        DeleteEntity(entity)
    elseif not rental.cleanupScheduled and not stopped then
        rental.cleanupScheduled = true
        CreateThread(function()
            local deadline = now() + (Config.SpawnTimeout or 5000)
            while not stopped and not DoesEntityExist(entity) and now() < deadline do Wait(50) end
            if DoesEntityExist(entity) then DeleteEntity(entity) end
        end)
    end
end

local AUTO_RETURN = { expired = true, abandoned = true, disconnected = true }

local function docked(rental)
    if not rental.released or not rentalEntityExists(rental) then return false end
    if GetEntitySpeed(rental.entity) > 0.8 or GetPedInVehicleSeat(rental.entity, -1) ~= 0 then return false end
    return dockedAt(GetEntityCoords(rental.entity), GetEntityRoutingBucket(rental.entity))
end

local function dispose(rental, reason)
    if rental.disposed then return end
    if AUTO_RETURN[reason] and docked(rental) then reason = 'returned' end
    if rental.released then print(('[scoot] rental %s closed: %s'):format(tostring(rental.token), tostring(reason))) end
    rental.disposed = true
    rentalKeys(rental, false)
    for key, value in pairs(rentals) do
        if value == rental then rentals[key] = nil end
    end
    local station = stations[rental.stationId]
    if rental.reserved then
        station.available = math.min(station.config.capacity, station.available + 1)
        rental.reserved = false
    end
    deleteRentalEntity(rental)
    if not rental.released then
        refund(rental)
        if station.token == rental.token then idle(station) else broadcast(station) end
    else
        broadcast(station)
    end
    if playerFor(rental) then
        TriggerClientEvent('loop-scoot:rental', rental.source, nil, now(), reason)
    end
end

local function rentalForEntity(entity)
    for _, rental in pairs(rentals) do
        if rental.entity == entity and not rental.disposed then return rental end
    end
end
function ScootRentalCollectable(entity, collector)
    local rental = rentalForEntity(entity)
    -- Only a live rental can be adopted: a loop_scooter the server did not rent out is not ours to collect.
    if not rental then return false, ScootText('err.scooterBusyOrGone') end
    if rental.phase ~= 'active' or not rental.released then return false, ScootText('err.scooterEmerging') end
    -- The renter must not hand their own rental in.
    if rental.source == collector then return false, ScootText('err.rentalInUse') end
    if playerFor(rental) then
        local ped = GetPlayerPed(rental.source)
        local radius = (Config.Collection and Config.Collection.rentalGuardRadius) or 40.0
        if ped and ped ~= 0 and DoesEntityExist(ped) and DoesEntityExist(entity)
            and distance(GetEntityCoords(ped), GetEntityCoords(entity)) <= radius then
            return false, ScootText('err.renterNearby')
        end
    end
    return true
end
function ScootRentalCollect(entity, collector)
    local rental = rentalForEntity(entity)
    if not rental then return nil end
    local ok, message = ScootRentalCollectable(entity, collector)
    if not ok then return false, message end
    if rental.source ~= collector and playerFor(rental) then
        notify(rental.source, ScootText('notify.rentalCollected'))
    end
    dispose(rental, 'collected')
    return true
end

local function setVehicleState(rental, dispensing)
    Entity(rental.entity).state:set('loopScoot', {
        renter = rental.source, stationId = rental.stationId, dispensing = dispensing,
        plate = rental.plate, expiresAt = rental.expiresAt or 0,
        token = rental.token, startedAt = rental.startedAt or 0,
        preparing = rental.phase == 'preparing',
    }, true)
    rental.tagged = true
end

local function blocked(station)

    local sequence = Scoot.Sequence(Scoot.RetractAt or 30000)
    local exit = Scoot.Transform(station.config, sequence.vehicleOffset)
    local radius = Config.ResetClearance or 1.3
    local function inMechanism(coords)
        return distance(coords, exit) < radius or distance(coords, station.config.coords) < radius
    end
    for _, vehicle in ipairs(GetAllVehicles()) do
        if DoesEntityExist(vehicle) and GetEntityRoutingBucket(vehicle) == (station.config.bucket or 0)
            and inMechanism(GetEntityCoords(vehicle)) then return true end
    end
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        local ped = GetPlayerPed(src)
        if ped ~= 0 and DoesEntityExist(ped) and GetPlayerRoutingBucket(src) == (station.config.bucket or 0)
            and inMechanism(GetEntityCoords(ped)) then return true end
    end
    return false
end

local function runSequence(station, rental)
    while not stopped and station.token == rental.token do
        local elapsed = station.pausedElapsed or math.max(0, now() - station.startedAt)
        local sequence = Scoot.Sequence(elapsed)
        if not rental.released then
            if rental.disposed or not playerFor(rental) or not rentalEntityExists(rental) then
                dispose(rental, 'cancelled')
                return
            end

            local maxDisplacement = (Config.Delivery or {}).maxDisplacement or 8.0
            if GetPlayerRoutingBucket(rental.source) ~= (station.config.bucket or 0)
                or GetEntityRoutingBucket(rental.entity) ~= (station.config.bucket or 0)
                or not (distance(GetEntityCoords(rental.entity), station.config.coords) <= maxDisplacement) then
                dispose(rental, 'cancelled')
                return
            end
            if sequence.released or sequence.complete then

                local final = Scoot.Transform(station.config, Scoot.Sequence(Config.Timeline.release).vehicleOffset)
                if distance(GetEntityCoords(rental.entity), final) > ((Config.Delivery or {}).releaseTolerance or 0.35) then
                    rental.releaseDeadline = rental.releaseDeadline or now() + ((Config.Delivery or {}).releaseTimeout or 2000)
                    if now() >= rental.releaseDeadline then
                        dispose(rental, 'delivery_failed')
                        return
                    end
                else
                    rental.released, rental.phase = true, 'active'
                    rental.expiresAt = now() + math.max(30, Config.RentalDuration or 1800) * 1000
                    station.phase = 'cooling'
                    FreezeEntityPosition(rental.entity, false)
                    SetVehicleDoorsLocked(rental.entity, 1)
                    setVehicleState(rental, false)
                    rentalKeys(rental, true)
                    TriggerClientEvent('loop-scoot:rental', rental.source, publicRental(rental), now())
                    broadcast(station)
                end
            end
        end
        if sequence.retracting and Scoot.RetractAt then
            if blocked(station) then
                if not station.pausedElapsed then
                    station.pausedElapsed = Scoot.RetractAt
                    broadcast(station)
                end
            elseif station.pausedElapsed then
                station.startedAt = now() - station.pausedElapsed
                station.pausedElapsed = nil
                broadcast(station)
            end
        end
        if sequence.complete and not station.pausedElapsed then
            idle(station)
            return
        end
        Wait(station.pausedElapsed and 500 or 50)
    end
end

local function rent(src, stationId)
    if stopped then return result(ScootText('err.serviceStopped')) end
    if not allowed(src, 'rent', 1500) then return result(ScootText('err.waitAMoment')) end
    if type(stationId) ~= 'string' then return result(ScootText('err.stationUnknown')) end
    local station = stations[stationId]
    if not station then return result(ScootText('err.stationUnknown')) end
    if not nearby(src, station, Config.InteractionDistance or 4.5) then return result(ScootText('err.tooFarStation')) end
    local player = ESX.GetPlayerFromId(src)
    if not identity(player) then return result(ScootText('err.characterNotLoaded')) end
    if rentals[src] then return result(ScootText('err.alreadyRenting')) end
    if station.phase ~= 'idle' then return result(ScootText('err.stationBusy')) end
    if station.available < 1 then return result(ScootText('err.stationEmpty')) end
    local price = math.max(0, math.floor(tonumber(Config.Price) or 0))
    local account = Config.Account or 'money'
    if price > 0 then
        local balance = ScootBridge.AccountBalance(player, account)
        if not balance or balance < price then return result(ScootText('err.noMoney')) end
    end
    serial = serial + 1
    local rental = {
        source = src, identifier = identity(player), stationId = stationId, token = serial,
        price = price, account = account, phase = 'preparing', reserved = true,
        plate = ('LS%06d'):format(serial % 1000000),
    }
    rentals[src] = rental
    station.token, station.phase, station.renter = rental.token, 'preparing', src
    station.available = station.available - 1
    broadcast(station)

    local ok, response = xpcall(function()
        if price > 0 then
            local paid, message = ScootBridge.Debit(player, account, price, 'LOOP SCOOT - location')
            if not paid then error('rental payment refused: ' .. tostring(message)) end
            rental.charged = true
        end

        local hiddenDepth = math.max(3.0, (Config.Delivery or {}).hiddenDepth or 4.0)
        local coords = Scoot.Transform(station.config, vector3(0.0, 0.0, -hiddenDepth))
        local entity = CreateVehicleServerSetter(joaat(Config.Model), Config.VehicleType or 'bike',
            coords.x, coords.y, coords.z, station.config.heading + (Config.VehicleHeadingOffset or 0.0))
        rental.entity = entity
        if entity == 0 then error('vehicle creation returned 0') end
        local deadline = now() + (Config.SpawnTimeout or 5000)
        while not DoesEntityExist(entity) and now() < deadline do
            if rental.disposed or not playerFor(rental) then error('renter disconnected during creation') end
            Wait(50)
        end
        if rental.disposed or not playerFor(rental) or not DoesEntityExist(entity) then error('vehicle creation cancelled or timed out') end
        SetEntityOrphanMode(entity, 2)
        SetEntityRoutingBucket(entity, station.config.bucket or 0)
        FreezeEntityPosition(entity, true)
        SetVehicleDoorsLocked(entity, 2)
        SetVehicleNumberPlateText(entity, rental.plate)
        Entity(entity).state:set('fuelLevel', 100.0, true)
        rental.netId = NetworkGetNetworkIdFromEntity(entity)
        if not rental.netId or rental.netId == 0 then error('vehicle has no network ID') end
        rental.prepareDeadline = now() + ((Config.Delivery or {}).prepareTimeout or 15000)
        station.netId, station.startedAt = rental.netId, 0
        setVehicleState(rental, true)
        broadcast(station)
        TriggerClientEvent('loop-scoot:rental', src, publicRental(rental), now())
        return { ok = true, rental = publicRental(rental), station = publicStation(station), serverNow = now() }
    end, debug.traceback)
    if ok then return response end
    print(('[scoot] rent failed: %s'):format(tostring(response)))

    deleteRentalEntity(rental)
    dispose(rental, 'cancelled')
    return result(ScootText('err.releaseFailed'))
end

lib.callback.register('loop-scoot:rent', logged('rent', rent))

lib.callback.register('loop-scoot:ready', logged('ready', function(src, stationId, netId, token)
    local rental = rentals[src]
    if stopped or not rental or not playerFor(rental) or rental.disposed
        or rental.stationId ~= stationId or rental.netId ~= netId or rental.token ~= token then
        return result(ScootText('err.prepareInvalid'))
    end
    local station = stations[rental.stationId]
    if station.token ~= rental.token then return result(ScootText('err.prepareInvalid')) end
    if rental.phase ~= 'preparing' then
        return { ok = true, rental = publicRental(rental), station = publicStation(station), serverNow = now() }
    end
    if not allowed(src, 'ready', 100) then
        return { ok = false, retry = true, message = ScootText('err.syncing'), serverNow = now() }
    end
    if not rental.prepareDeadline or now() >= rental.prepareDeadline
        or not nearby(src, station, Config.InteractionDistance or 4.5)
        or not rentalEntityExists(rental)
        or GetEntityRoutingBucket(rental.entity) ~= (station.config.bucket or 0)
        or not (distance(GetEntityCoords(rental.entity), station.config.coords) <= ((Config.Delivery or {}).maxDisplacement or 8.0)) then
        dispose(rental, 'preparation_failed')
        return result(ScootText('err.prepareRefunded'))
    end
    if NetworkGetEntityOwner(rental.entity) ~= src then
        return { ok = false, retry = true, message = ScootText('err.vehicleSyncing'), serverNow = now() }
    end
    local ok, response = xpcall(function()
        rental.startedAt = now() + ((Config.Delivery or {}).startLead or 300)
        rental.phase, rental.prepareDeadline = 'dispensing', nil
        station.phase, station.startedAt = 'dispensing', rental.startedAt
        setVehicleState(rental, true)
        broadcast(station)
        TriggerClientEvent('loop-scoot:rental', src, publicRental(rental), now())
        CreateThread(function()
            local sequenceOk, err = xpcall(function() runSequence(station, rental) end, debug.traceback)
            if not sequenceOk then
                print(('[%s] Sequence failed: %s'):format(RESOURCE, tostring(err)))
                dispose(rental, 'cancelled')
                if station.token == rental.token then idle(station) end
            end
        end)
        return { ok = true, rental = publicRental(rental), station = publicStation(station), serverNow = now() }
    end, debug.traceback)
    if ok then return response end
    print(('[scoot] preparation failed: %s'):format(tostring(response)))
    dispose(rental, 'preparation_failed')
    return result(ScootText('err.prepareRefunded'))
end))

function GetScootRentalBlips(src)
    local result = {}
    if type(src) ~= 'number' or not ESX.GetPlayerFromId(src) then return result end
    local bucket = GetPlayerRoutingBucket(src)
    for _, entry in pairs(rentals) do
        if entry.released and entry.phase == 'active' and not entry.disposed
            and playerFor(entry) and rentalEntityExists(entry)
            and GetEntityRoutingBucket(entry.entity) == bucket then
            local p = GetEntityCoords(entry.entity)
            result[#result + 1] = { id = 'rental:' .. tostring(entry.token), netId = entry.netId,
                coords = { x = p.x, y = p.y, z = p.z }, state = 'rented', token = entry.token }
        end
    end
    return result
end

lib.callback.register('loop-scoot:cancelPreparation', function(src, stationId, netId, token)
    local rental = rentals[src]
    if stopped or not rental or not playerFor(rental) or rental.disposed
        or rental.stationId ~= stationId or rental.netId ~= netId or rental.token ~= token
        or rental.phase ~= 'preparing' then return result(ScootText('err.prepareInvalid')) end
    dispose(rental, 'preparation_cancelled')
    return { ok = true, serverNow = now() }
end)

lib.callback.register('loop-scoot:clock', function(src)
    if not allowed(src, 'clock', 100) then return result(ScootText('err.waitAMoment')) end
    return { ok = true, serverNow = now() }
end)

lib.callback.register('loop-scoot:snapshot', logged('snapshot', function(src)
    if not allowed(src, 'snapshot', 1000) then return result(ScootText('err.waitAMoment')) end
    local states = {}
    for id, station in pairs(stations) do states[id] = publicStation(station) end
    return { ok = true, stations = states, rental = publicRental(rentals[src]), serverNow = now() }
end))

exports('GetStationAvailability', function()
    local available = {}
    for id, station in pairs(stations) do available[id] = station.available end
    return available
end)

lib.callback.register('loop-scoot:return', logged('return', function(src, stationId)
    if not allowed(src, 'return', 1000) then return result(ScootText('err.waitAMoment')) end
    local rental = rentals[src]
    if not rental or not playerFor(rental) then return result(ScootText('err.noRental')) end
    if rental.phase ~= 'active' then return result(ScootText('err.waitRelease')) end
    local station = type(stationId) == 'string' and stations[stationId]
    if not station then return result(ScootText('err.stationUnknown')) end
    if not rentalPresent(rental) then
        if rentalGone(rental) then dispose(rental, goneReason(rental)) end
        return result(ScootText('err.scooterUnavailable'))
    end
    local charge = Entity(rental.entity).state.loopScootBattery
    local flat = type(charge) == 'number' and charge <= 0
    if flat then
        local ped = GetPlayerPed(src)
        if ped == 0 or not DoesEntityExist(ped)
            or distance(GetEntityCoords(ped), GetEntityCoords(rental.entity)) > (Config.ReturnDistance or 6.0) then
            return result(ScootText('err.bringScooterBack'))
        end
    else
        if not nearby(src, station, Config.ReturnDistance or 6.0) then return result(ScootText('err.tooFarStation')) end
        if GetEntityRoutingBucket(rental.entity) ~= (station.config.bucket or 0)
            or distance(GetEntityCoords(rental.entity), station.config.coords) > (Config.ReturnDistance or 6.0) then
            return result(ScootText('err.bringScooterBack'))
        end
    end
    if GetEntitySpeed(rental.entity) > 0.8 then return result(ScootText('err.stopScooter')) end
    if GetPedInVehicleSeat(rental.entity, -1) ~= 0 then return result(ScootText('err.dismountFirst')) end
    dispose(rental, flat and 'depleted' or 'returned')
    return { ok = true, message = ScootText('notify.rentalReturned'), serverNow = now() }
end))

local function finite(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

local function validPlacement(coords, heading)
    local kind = type(coords)
    return (kind == 'table' or kind == 'vector3') and finite(coords.x)
        and finite(coords.y) and finite(coords.z) and finite(heading)
end

lib.callback.register('loop-scoot:place', function(src, stationId, coords, heading)
    if not ScootBridge.IsAdmin(src) then return result(ScootText('err.adminOnly')) end
    if not allowed(src, 'place', 1000) then return result(ScootText('err.waitAMoment')) end
    local station = type(stationId) == 'string' and stations[stationId]
    if not station or not validPlacement(coords, heading) then return result(ScootText('err.placementInvalid')) end
    if station.phase ~= 'idle' then return result(ScootText('err.stationClosing')) end
    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) or distance(GetEntityCoords(ped), coords) > 5.0
        or GetPlayerRoutingBucket(src) ~= (station.config.bucket or 0) then
        return result(ScootText('err.tooFarNewSpot'))
    end
    local placement = { coords = { x = coords.x, y = coords.y, z = coords.z }, heading = heading % 360 }
    local previous = stationOverrides[stationId]
    stationOverrides[stationId] = placement
    if not SaveResourceFile(RESOURCE, 'station_overrides.json', json.encode(stationOverrides), -1) then
        stationOverrides[stationId] = previous
        return result(ScootText('err.saveSpotFailed'))
    end
    station.config.coords = vector3(coords.x, coords.y, coords.z)
    station.config.heading = placement.heading
    broadcast(station)
    return { ok = true, message = ScootText('notify.stationSaved'), station = publicStation(station), serverNow = now() }
end)

local function detach(src)
    limits[src] = nil
    local rental = rentals[src]
    if not rental or rental.disposed then return end
    dispose(rental, 'disconnected')
end

local reattach
reattach = function(src, player)
    local identifier = identity(player)
    if type(src) ~= 'number' or not identifier or rentals[src] then return end
    for key, rental in pairs(rentals) do
        if rental.detachedUntil and not rental.disposed and rental.identifier == identifier then
            if not rentalPresent(rental) then
                if rentalGone(rental) then
                    dispose(rental, goneReason(rental))
                elseif not rental.reattachPending then
                    rental.reattachPending = true
                    SetTimeout(1000, function()
                        rental.reattachPending = nil
                        if not rental.disposed and rental.detachedUntil then reattach(src, player) end
                    end)
                end
                return
            end
            rentals[key] = nil
            rental.source, rental.detachedUntil = src, nil
            rentals[src] = rental
            setVehicleState(rental, false)
            rentalKeys(rental, true)
            TriggerClientEvent('loop-scoot:rental', src, publicRental(rental), now())
            return
        end
    end
end

AddEventHandler('playerDropped', function()
    detach(source)
end)

ScootBridge.OnPlayerUnloaded(function(playerId)
    detach(playerId)
end)

ScootBridge.OnPlayerLoaded(function(playerId, player)
    if player then collectRefunds(player) end
    reattach(tonumber(playerId), player)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    stopped = true
    local pending = {}
    for _, rental in pairs(rentals) do pending[#pending + 1] = rental end
    for _, rental in ipairs(pending) do dispose(rental, 'stopped') end
end)

local savedPlacements = LoadResourceFile(RESOURCE, 'station_overrides.json')
if savedPlacements then
    local ok, saved = pcall(json.decode, savedPlacements)
    if ok and type(saved) == 'table' then stationOverrides = saved end
end

for _, config in ipairs(Config.Stations) do
    assert(type(config.id) == 'string' and not stations[config.id], 'Station IDs must be unique strings')
    local placement = stationOverrides[config.id]
    if type(placement) == 'table' and validPlacement(placement.coords, placement.heading) then
        config.coords = vector3(placement.coords.x, placement.coords.y, placement.coords.z)
        config.heading = placement.heading % 360
    end
    config.capacity = math.max(1, math.floor(config.capacity or 8))
    stations[config.id] = { config = config, available = config.capacity, phase = 'idle', startedAt = 0, netId = 0, renter = 0 }
end

CreateThread(function()
    for _, src in ipairs(GetPlayers()) do
        local player = ESX.GetPlayerFromId(tonumber(src))
        if player then collectRefunds(player) end
    end
    while not stopped do
        Wait(1000)
        local expired = {}
        for _, rental in pairs(rentals) do
            if rental.phase == 'preparing' and rental.prepareDeadline then
                if not playerFor(rental) or not rentalEntityExists(rental) then
                    expired[#expired + 1] = { rental, 'preparation_failed' }
                elseif now() >= rental.prepareDeadline then
                    expired[#expired + 1] = { rental, 'preparation_timeout' }
                end
            elseif rental.phase == 'active' then
                if rentalGone(rental) then
                    expired[#expired + 1] = { rental, goneReason(rental) }
                elseif now() >= rental.expiresAt then
                    expired[#expired + 1] = { rental, 'expired' }
                elseif rental.detachedUntil and now() >= rental.detachedUntil then
                    expired[#expired + 1] = { rental, 'abandoned' }
                elseif not rental.keysGranted and not rental.missingSince and playerFor(rental) then
                    rentalKeys(rental, true)
                end
            end
        end
        for _, entry in ipairs(expired) do
            if playerFor(entry[1]) then
                local message = entry[2] == 'expired' and ScootText('notify.rentalEnded')
                    or entry[2] == 'returned' and ScootText('notify.rentalReturned')
                    or entry[1].phase == 'preparing' and ScootText('err.prepareRefunded')
                    or ScootText('err.scooterUnavailable')
                notify(entry[1].source, message)
            end
            dispose(entry[1], entry[2])
        end
    end
end)

RegisterNetEvent('loop-scoot:cine:endRental', function()
    local src = source
    if GetResourceState('loop-cine') ~= 'started' or not ScootBridge.IsAdmin(src) then return end
    local rental = rentals[src]
    if rental and not rental.disposed then dispose(rental, 'returned') end
end)
