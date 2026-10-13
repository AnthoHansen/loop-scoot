local options = Config.ScooterEnergy or {}
if options.enabled == false then return end
local model, stopping, depleted = joaat(Config.Model), false, nil
CreateThread(function()
    while not stopping do
        local ped = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)
        local driving = vehicle ~= 0 and DoesEntityExist(vehicle) and GetEntityModel(vehicle) == model
            and GetPedInVehicleSeat(vehicle, -1) == ped
        local battery = driving and Entity(vehicle).state.loopScootBattery
        local empty = type(battery) == 'number' and battery == battery and battery <= 0
        if driving and empty then
            depleted = vehicle
            DisableControlAction(0, 71, true)
            SetVehicleEngineOn(vehicle, false, true, true)
            Wait(0)
        else
            if driving and vehicle == depleted and type(battery) == 'number' and battery > 0 then
                SetVehicleEngineOn(vehicle, true, true, false)
            end
            depleted = nil
            Wait(200)
        end
    end
end)
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then stopping = true end
end)
