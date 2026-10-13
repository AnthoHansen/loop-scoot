RegisterNetEvent('loop-scoot:bridge:keys', function(system, give, plate)
    if type(plate) ~= 'string' then return end
    if system == 'qs-vehiclekeys' and GetResourceState('qs-vehiclekeys') == 'started' then
        local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
        local model = vehicle ~= 0 and GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)) or Config.Model
        pcall(function()
            if give then exports['qs-vehiclekeys']:GiveKeys(plate, model, true)
            else exports['qs-vehiclekeys']:RemoveKeys(plate, model) end
        end)
    end
end)

local ENGINE_COMMAND = 'loopscootmoteur'

RegisterCommand(ENGINE_COMMAND, function()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 or GetPedInVehicleSeat(vehicle, -1) ~= ped then return end
    local model = GetEntityModel(vehicle)
    if model == joaat(Config.Model) then
        ExecuteCommand(Config.Rider.engineCommand or 'scootengine')
    elseif Config.Collection and Config.Collection.truck and model == joaat(Config.Collection.truck.model) then
        ExecuteCommand('scootmoteur')
    end
end, false)

if not Config.Rider.engineKey or Config.Rider.engineKey == '' then
    local S = Config.Standalone or {}
    RegisterKeyMapping(ENGINE_COMMAND, ScootText('keybind.scooterEngine'), S.engineMapper or 'MOUSE_BUTTON', S.engineKey or 'MOUSE_MIDDLE')
end

CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    Wait(2000)
    TriggerServerEvent('loop-scoot:bridge:ready')
end)
