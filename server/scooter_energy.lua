local options = Config.ScooterEnergy or {}
if options.enabled == false then return end
local RESOURCE, BATTERY = GetCurrentResourceName(), 'loopScootBattery'
local model = joaat(Config.Model)
local tracked, stopped = {}, false
local function finite(v) return type(v) == 'number' and v == v and math.abs(v) < math.huge end
local function setting(value, fallback, low, high)
    return finite(value) and math.max(low, math.min(high, value)) or fallback
end
local rangeMetres = setting(options.rangeKm, 55, 1, 1000) * 1000
local sampleMs = math.floor(setting(options.sampleMs, 1000, 250, 5000))
local publishMs = math.floor(setting(options.publishMs, 5000, sampleMs, 30000))
local maximumSpeed = setting(options.maxSpeedMps, math.max(20, setting(Config.MaxSpeed, 48 / 3.6, 1, 80) * 1.5), 1, 80)
local function charge(value)
    if value == nil then return 100 end
    return finite(value) and math.max(0, math.min(100, value)) or 0
end
local function position(value)
    if value and finite(value.x) and finite(value.y) and finite(value.z) then
        return {x = value.x, y = value.y, z = value.z}
    end
end
local function validToken(value)
    return (type(value) == 'string' and value ~= '') or (finite(value) and value > 0)
end
local function identity(vehicle, state)
    local rental, collection = state.loopScoot, state.loopScootCollection
    local token
    if type(rental) == 'table' and validToken(rental.token) then
        token = 'rental:' .. type(rental.token) .. ':' .. tostring(rental.token) .. ':' .. tostring(rental.renter) .. ':' .. tostring(rental.stationId)
    elseif type(collection) == 'table' and collection.kind == 'scooter'
        and validToken(collection.token) then
        token = 'collection:' .. type(collection.token) .. ':' .. tostring(collection.token) .. ':' .. tostring(collection.id)
    end
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    if token and netId and netId ~= 0 then return tostring(netId) .. ':' .. token end
end
local function publish(vehicle, record, time)
    if not DoesEntityExist(vehicle) or GetEntityModel(vehicle) ~= model then return end
    local state = Entity(vehicle).state
    if identity(vehicle, state) ~= record.identity then return end
    local value = math.floor(record.charge * 100 + .5) / 100
    record.published, record.publishedAt = value, time
    state:set(BATTERY, value, true)
end
local function sample(vehicle, time)
    if not DoesEntityExist(vehicle) or GetEntityModel(vehicle) ~= model then return end
    local state = Entity(vehicle).state
    local key = identity(vehicle, state)
    if not key then return end
    local record = tracked[vehicle]
    if not record or record.identity ~= key then
        record = {identity = key, charge = charge(state[BATTERY]), published = state[BATTERY], publishedAt = time}
        tracked[vehicle] = record

        if state[BATTERY] == nil or state[BATTERY] ~= record.charge then publish(vehicle, record, time) end
    end
    local rental, collection = state.loopScoot, state.loopScootCollection
    local blocked = type(rental) == 'table' and (rental.dispensing or rental.preparing)
    blocked = blocked or (type(collection) == 'table' and (collection.state == 'carried' or collection.state == 'loaded'))

    if type(GetEntityAttachedTo) == 'function' and GetEntityAttachedTo(vehicle) ~= 0 then blocked = true end
    local driver = GetPedInVehicleSeat(vehicle, -1)
    local coords, speed = position(GetEntityCoords(vehicle)), GetEntitySpeed(vehicle)
    local ridden = not blocked and driver and driver ~= 0 and DoesEntityExist(driver)
        and GetVehiclePedIsIn(driver, false) == vehicle and GetEntityHealth(driver) > 0
        and coords and finite(speed) and speed >= 0 and speed <= maximumSpeed
    local previous = record.previous
    if ridden and previous and previous.driver == driver then
        local elapsed = time - previous.time
        if elapsed > 0 and elapsed <= math.max(10000, sampleMs * 3) then
            local dx, dy, dz = coords.x - previous.coords.x, coords.y - previous.coords.y, coords.z - previous.coords.z
            local horizontal = math.sqrt(dx * dx + dy * dy)
            local metres = math.sqrt(horizontal * horizontal + dz * dz)
            local seconds = elapsed / 1000

            local plausible = math.max(speed, previous.speed) > .15 and metres <= maximumSpeed * seconds + 1
                and metres <= (math.max(speed, previous.speed) + 4) * seconds + 2
                and math.abs(dz) <= math.max(3, horizontal)
            if plausible and metres >= .05 then
                record.charge = math.max(0, record.charge - metres * 100 / rangeMetres)
            end
        end
    end
    record.previous = ridden and {driver = driver, coords = coords, speed = speed, time = time} or nil

    local displayed = math.floor(record.charge * 100 + .5) / 100
    if state[BATTERY] ~= record.published or (record.charge == 0 and record.published ~= 0)
        or (displayed ~= record.published and time - record.publishedAt >= publishMs) then
        publish(vehicle, record, time)
    end
    return true
end

CreateThread(function()
    while not stopped do
        local time, seen = GetGameTimer(), {}
        for _, vehicle in ipairs(GetAllVehicles()) do
            local ok, retained = pcall(sample, vehicle, time)
            if ok and retained then seen[vehicle] = true end
        end
        for vehicle in pairs(tracked) do if not seen[vehicle] then tracked[vehicle] = nil end end
        Wait(sampleMs)
    end
end)

if type(AddStateBagChangeHandler) == 'function' and type(GetEntityFromStateBagName) == 'function' then
    AddStateBagChangeHandler(BATTERY, nil, function(bagName, _, value)
        local vehicle = GetEntityFromStateBagName(bagName)
        local record = vehicle and tracked[vehicle]
        if stopped or not record or value == record.published then return end

        SetTimeout(0, function()
            if not stopped and tracked[vehicle] == record then publish(vehicle, record, GetGameTimer()) end
        end)
    end)
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    stopped = true
    for vehicle, record in pairs(tracked) do pcall(publish, vehicle, record, GetGameTimer()) end
end)
