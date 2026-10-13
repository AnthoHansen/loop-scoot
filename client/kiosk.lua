ScootKiosk = {}

local open, loading, lease, stationId, pending = false, false, nil, nil, false
local highlight, cinematic = nil, false

local function stationEntry(state)
    for _, entry in ipairs(state and state.stations or {}) do
        if entry.id == stationId then return entry end
    end
end

local function priceText(price)
    price = math.floor(tonumber(price) or 0)
    if price <= 0 then return ScootText('kiosk.free') end
    return ScootText('kiosk.price', price)
end

local function returnRange(station)
    local limit = Config.ReturnDistance or 6.0
    local vehicle = ScootApp.Vehicle and ScootApp.Vehicle() or nil
    if not vehicle or not station or not station.coords then return false, nil, limit end
    local position = GetEntityCoords(vehicle)
    local distance = #(position - station.coords)
    if distance <= limit then return true, distance, limit end
    local charge = Entity(vehicle).state.loopScootBattery
    if type(charge) == 'number' and charge <= 0 and #(position - GetEntityCoords(PlayerPedId())) <= limit then
        return true, distance, limit
    end
    return false, distance, limit
end

local function push()
    if not open or LocalPlayer.state.loopCine == true then
        SendNUIMessage({ action = 'loop:dialogue', state = { open = false } })
        return
    end
    local ok, state = pcall(ScootApp.State)
    if not ok or type(state) ~= 'table' then state = {} end
    local station = Scoot.FindStation(stationId) or {}
    local entry = stationEntry(state) or {}
    local rental = state.rental
    local choices, line = {}, ''
    if loading then
        line = ScootText('kiosk.loading')
    elseif type(rental) == 'table' then
        local minutes = math.max(0, math.ceil(((rental.expiresAt or 0) - (state.serverNow or 0)) / 60000))
        if rental.phase == 'preparing' then
            line = ScootText('kiosk.lineRental', minutes)
        else
            local near, distance, limit = returnRange(station)
            if near then
                line = ScootText('kiosk.lineRental', minutes)
                choices[#choices + 1] = { id = 'return', label = ScootText('kiosk.return') }
            elseif distance then
                line = ScootText('kiosk.lineRentalFar', minutes, math.ceil(distance), math.floor(limit))
            else
                line = ScootText('kiosk.lineRentalLost', minutes, math.floor(limit))
            end
        end
    else
        local available = tonumber(entry.available) or 0
        if available > 0 then
            line = ScootText('kiosk.line', available, priceText(state.price), math.floor((Config.RentalDuration or 1800) / 60))
            if not entry.busy then choices[#choices + 1] = { id = 'rent', label = ScootText('kiosk.rent') } end
        else
            line = ScootText('kiosk.empty')
        end
    end
    choices[#choices + 1] = { id = 'leave', label = ScootText('kiosk.leave') }
    local index = nil
    if highlight then
        for i, choice in ipairs(choices) do if choice.id == highlight then index = i - 1 end end
    end
    SendNUIMessage({ action = 'loop:dialogue', state = {
        open = true, name = ScootText('kiosk.name'), role = entry.label or station.label or '', index = index,
        line = line, choices = choices, busy = loading or state.busy == true,
        text = { move = ScootText('kiosk.move'), select = ScootText('kiosk.select'), back = ScootText('kiosk.back') },
    } })
end

local function hide()
    open, loading, highlight, cinematic = false, false, nil, false
    SendNUIMessage({ action = 'loop:dialogue', state = { open = false } })
    if lease then ScootUiFocus.Release(lease) end
    lease = nil
end

local function close(endSession)
    local wasOpen = open
    hide()
    if endSession and not pending and ScootApp.Open() then ScootApp.End() end
    return wasOpen
end

local function failed(result)
    local message = type(result) == 'table' and result.message
    if message then ScootApp.Notify(message, 'error') end
end

function ScootKiosk.Open(id, options)
    if open or pending then return false end
    if not id or not Scoot.FindStation(id) then
        ScootApp.Notify(ScootText('err.tooFarStation'), 'error')
        return false
    end
    local noFocus = type(options) == 'table' and options.noFocus == true
    if not noFocus then
        lease = ScootUiFocus.Acquire('phone')
        if not lease then return false end
    end
    open, loading, stationId, cinematic = true, true, id, noFocus
    push()
    if lease then ScootUiFocus.Activate(lease) end
    ScootApp.Begin(function(result)
        if not open then
            if ScootApp.Open() and not pending then ScootApp.End() end
            return
        end
        if type(result) ~= 'table' or result.ok ~= true then
            failed(result)
            close(true)
            return
        end
        loading = false
        push()
    end)
end

function ScootKiosk.IsOpen()
    return open
end

function ScootKiosk.IsReady()
    return open and not loading
end

function ScootKiosk.Close()
    if open then close(true) end
    return true
end

function ScootKiosk.Highlight(id)
    highlight = id
    if open then push() end
end

local function run(action)
    local id = stationId
    pending = true
    hide()
    local handler = action == 'rent' and ScootApp.Rent or ScootApp.Return
    handler(id, function(result)
        pending = false
        if type(result) == 'table' and result.ok == true then
            if action == 'rent' then ScootApp.Notify(ScootText('kiosk.rented'), 'success')
            elseif result.message then ScootApp.Notify(result.message, 'success') end
            return
        end
        failed(result)
        if ScootApp.Open() then ScootApp.End() end
    end)
end

function ScootKiosk.Choose(id)
    if not open or loading then return false end
    if id == 'leave' then close(true)
    elseif id == 'return' then
        local near = returnRange(Scoot.FindStation(stationId))
        if not near then
            ScootApp.Notify(ScootText('err.scooterTooFar', math.floor(Config.ReturnDistance or 6.0)), 'error')
            push()
            return false
        end
        run(id)
    elseif id == 'rent' then run(id)
    else return false end
    return true
end

RegisterNUICallback('loop:dialogue:choose', function(data, cb)
    cb({ ok = true })
    if cinematic then return end
    ScootKiosk.Choose(type(data) == 'table' and data.id or nil)
end)

RegisterNUICallback('loop:dialogue:close', function(_, cb)
    cb({ ok = true })
    if open and not cinematic then close(true) end
end)

AddEventHandler('loop-scoot:closePhone', function()
    if open then hide() end
end)

AddEventHandler('loop-scoot:phoneState', function()
    if open and not loading then push() end
end)

CreateThread(function()
    while true do
        if open then
            local station = Scoot.FindStation(stationId)
            local ped = PlayerPedId()
            if not station or IsEntityDead(ped) or IsPedInAnyVehicle(ped, false)
                or #(GetEntityCoords(ped) - station.coords) > (Config.InteractionDistance or 4.5) + 2.0 then
                close(true)
            elseif not cinematic then
                DisableControlAction(0, 1, true)
                DisableControlAction(0, 2, true)
                DisableControlAction(0, 200, true)
                DisableControlAction(0, 322, true)
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() and open then hide() end
end)
