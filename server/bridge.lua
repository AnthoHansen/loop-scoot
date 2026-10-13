ScootBridge = {}

local B = Config.Bridge or {}
local framework, core = nil, nil
local loadedHandlers, unloadedHandlers = {}, {}
local coreGeneration = 0
local playerBindings = setmetatable({}, { __mode = 'k' })

local function started(name)
    return type(name) == 'string' and GetResourceState(name) == 'started'
end

local FRAMEWORKS = { { 'es_extended', 'esx' }, { 'qbx_core', 'qbox' }, { 'qb-core', 'qbcore' }, { 'ox_core', 'ox' } }
local FRAMEWORK_RESOURCE = { esx = 'es_extended', qbox = 'qbx_core', qbcore = 'qb-core', ox = 'ox_core' }

local ACCOUNT_QB = { money = 'cash' }
local function finite(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

local function detect()
    local wanted = B.framework or 'auto'
    if wanted ~= 'auto' then return wanted end
    for _, entry in ipairs(FRAMEWORKS) do
        if started(entry[1]) then return entry[2] end
    end
    return 'standalone'
end

local function licenseOf(src)
    local id = GetPlayerIdentifierByType and GetPlayerIdentifierByType(src, 'license')
    if id then return id end
    for _, value in ipairs(GetPlayerIdentifiers(src) or {}) do
        if value:sub(1, 8) == 'license:' then return value end
    end
    return nil
end

local function resolveCore()
    local resource = FRAMEWORK_RESOURCE[framework]
    if resource and not started(resource) then core = nil; return nil end
    if core then return core end
    local ok, value = false, nil
    if framework == 'esx' then
        ok, value = pcall(function() return exports.es_extended:getSharedObject() end)
    elseif framework == 'qbcore' then
        ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
    elseif framework == 'ox' then
        ok, value = pcall(function() return require('@ox_core.lib.init') end)
    elseif framework == 'qbox' or framework == 'standalone' then
        ok, value = true, {}
    end
    if ok and value then core = value end
    return core
end

local function qbWrapper(p, src, isQbox)
    local data = p.PlayerData or {}
    local function account(name) return ACCOUNT_QB[name] or name end
    return {
        source = src, identifier = data.citizenid, raw = p,
        getAccount = function(name)
            local money
            if isQbox then money = exports.qbx_core:GetMoney(src, account(name))
            else money = (p.PlayerData and p.PlayerData.money or {})[account(name)] end
            if not finite(money) then return nil end
            return { name = name, money = money }
        end,
        addAccountMoney = function(name, amount, reason)
            if isQbox then return exports.qbx_core:AddMoney(src, account(name), amount, reason) end
            return p.Functions.AddMoney(account(name), amount, reason)
        end,
        removeAccountMoney = function(name, amount, reason)
            if isQbox then return exports.qbx_core:RemoveMoney(src, account(name), amount, reason) end
            return p.Functions.RemoveMoney(account(name), amount, reason)
        end,
        getJob = function()
            local job = p.PlayerData and p.PlayerData.job or {}
            local grade = type(job.grade) == 'table' and job.grade.level or job.grade
            return { name = job.name, grade = tonumber(grade) or 0 }
        end,
        getGroup = function() return nil end,
    }
end

local function oxWrapper(p, src)
    local function inventoryMoney(name)
        if (name ~= 'money' and name ~= 'cash') or not started('ox_inventory') then return nil end
        local ok, count = pcall(function() return exports.ox_inventory:GetItemCount(src, 'money') end)
        return ok and count or nil
    end
    return {
        source = src, identifier = p.charId and tostring(p.charId) or p.stateId or licenseOf(src), raw = p,
        getAccount = function(name)
            local money = inventoryMoney(name)
            if not finite(money) then return nil end
            return { name = name, money = money }
        end,
        addAccountMoney = function(name, amount)
            if (name ~= 'money' and name ~= 'cash') or not started('ox_inventory') then return false end
            return exports.ox_inventory:AddItem(src, 'money', amount)
        end,
        removeAccountMoney = function(name, amount)
            if (name ~= 'money' and name ~= 'cash') or not started('ox_inventory') then return false end
            return exports.ox_inventory:RemoveItem(src, 'money', amount)
        end,
        getJob = function()
            local groups = p.getGroups and p.getGroups() or {}
            for name in pairs(groups) do return { name = name } end
            return {}
        end,
        getGroup = function() return nil end,
    }
end

local function standaloneWrapper(src)
    local identifier = licenseOf(src)
    if not identifier then return nil end
    local handler = B.standaloneMoney
    return {
        source = src, identifier = identifier, raw = nil,
        getAccount = function(name)
            if type(handler) ~= 'table' or type(handler.get) ~= 'function' then return nil end
            local money = handler.get(src, name)
            if finite(money) then return { name = name, money = money } end
            return nil
        end,
        addAccountMoney = function(name, amount, reason)
            if type(handler) == 'table' and type(handler.add) == 'function' then return handler.add(src, name, amount, reason) end
            return false
        end,
        removeAccountMoney = function(name, amount, reason)
            if type(handler) == 'table' and type(handler.remove) == 'function' then return handler.remove(src, name, amount, reason) end
            return false
        end,
        getJob = function() return {} end,
        getGroup = function() return nil end,
    }
end

function ScootBridge.Framework()
    return framework
end

local function getPlayer(src)
    local c = resolveCore()
    if not c then return nil end
    if framework == 'esx' then
        return c and c.GetPlayerFromId and c.GetPlayerFromId(src) or nil
    elseif framework == 'qbcore' then
        local p = c and c.Functions and c.Functions.GetPlayer(src)
        return p and qbWrapper(p, src) or nil
    elseif framework == 'qbox' then
        local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
        return ok and p and qbWrapper(p, src, true) or nil
    elseif framework == 'ox' then
        local ok, p = pcall(function() return c.GetPlayer and c.GetPlayer(src) end)
        if ok and p and (p.charId or p.stateId) then return oxWrapper(p, src) end
        return nil
    end
    if framework == 'standalone' then return standaloneWrapper(src) end
    return nil
end

function ScootBridge.GetPlayer(src)
    src = tonumber(src)
    if not src or src <= 0 or not GetPlayerName(src) then return nil end
    local ok, player = pcall(getPlayer, src)
    if not ok or type(player) ~= 'table' then return nil end
    playerBindings[player] = { framework = framework, generation = coreGeneration }
    return player
end

function ScootBridge.Identifier(player)
    return player and (player.identifier or (player.getIdentifier and player.getIdentifier())) or nil
end

function ScootBridge.AccountBalance(player, account)
    local binding = player and playerBindings[player]
    if not binding or binding.framework ~= framework or binding.generation ~= coreGeneration then return nil end
    local resource = FRAMEWORK_RESOURCE[framework]
    if resource and not started(resource) then return nil end
    if type(account) ~= 'string' or type(player.getAccount) ~= 'function' then return nil end
    local ok, value = pcall(player.getAccount, account)
    if ok and type(value) == 'table' and finite(value.money) then return value.money end
    return nil
end

local function changeMoney(player, account, amount, reason, debit)
    if not finite(amount) or amount <= 0 or amount % 1 ~= 0 then return false, 'invalid amount' end
    local balance = ScootBridge.AccountBalance(player, account)
    if balance == nil then return false, 'account unavailable' end
    if debit and balance < amount then return false, 'insufficient funds' end
    local operation = player.addAccountMoney
    if debit then operation = player.removeAccountMoney end
    if type(operation) ~= 'function' then return false, 'money adapter unavailable' end
    local kind = playerBindings[player].framework
    local ok, accepted = pcall(operation, account, amount, reason)
    if not ok then return false, tostring(accepted) end
    -- ESX's documented mutations return no value on success; boolean adapters must confirm.
    if accepted == true or (kind == 'esx' and accepted == nil) then return true end
    return false, 'money adapter refused or did not confirm'
end

function ScootBridge.Credit(player, account, amount, reason)
    return changeMoney(player, account, amount, reason, false)
end

function ScootBridge.Debit(player, account, amount, reason)
    return changeMoney(player, account, amount, reason, true)
end

function ScootBridge.IsAdmin(src)
    if IsPlayerAceAllowed(src, Config.AdminAce or 'loop.scoot.admin') or IsPlayerAceAllowed(src, 'group.admin') then return true end
    local p = ScootBridge.GetPlayer(src)
    if framework == 'esx' then
        local group = p and p.getGroup and p.getGroup()
        return group == 'admin' or group == 'superadmin'
    end
    if framework == 'qbcore' then
        local c = resolveCore()
        local ok, allowed = pcall(function() return c.Functions.HasPermission(src, 'admin') or c.Functions.HasPermission(src, 'god') end)
        return ok and allowed == true
    end
    return false
end

function ScootBridge.OnPlayerLoaded(handler)
    loadedHandlers[#loadedHandlers + 1] = handler
end

function ScootBridge.OnPlayerUnloaded(handler)
    unloadedHandlers[#unloadedHandlers + 1] = handler
end

local function fireLoaded(src)
    src = tonumber(src)
    if not src then return end
    local player = ScootBridge.GetPlayer(src)
    if not player then return end
    for _, handler in ipairs(loadedHandlers) do pcall(handler, src, player) end
end

local function fireUnloaded(src)
    src = tonumber(src)
    if not src then return end
    for _, handler in ipairs(unloadedHandlers) do pcall(handler, src) end
end

AddEventHandler('esx:playerLoaded', function(src) if framework == 'esx' then fireLoaded(src) end end)
AddEventHandler('esx:playerDropped', function(src) if framework == 'esx' then fireUnloaded(src) end end)
AddEventHandler('QBCore:Server:PlayerLoaded', function(p)
    if framework ~= 'qbcore' and framework ~= 'qbox' then return end
    fireLoaded(type(p) == 'table' and p.PlayerData and p.PlayerData.source or p)
end)
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    if framework == 'qbcore' or framework == 'qbox' then fireUnloaded(src) end
end)
AddEventHandler('ox:playerLoaded', function(src) if framework == 'ox' then fireLoaded(src) end end)
AddEventHandler('ox:playerLogout', function(src) if framework == 'ox' then fireUnloaded(src) end end)
RegisterNetEvent('loop-scoot:bridge:ready', function()
    if framework == 'standalone' then fireLoaded(source) end
end)

local KEY_SYSTEMS = {
    { name = 'qbx_vehiclekeys',
      give = function(src, _, entity) return entity and exports.qbx_vehiclekeys:GiveKeys(src, entity, true) ~= false end,
      remove = function(src, _, entity) return entity and exports.qbx_vehiclekeys:RemoveKeys(src, entity, true) ~= false end },
    { name = 'MrNewbVehicleKeys',
      give = function(src, plate) exports.MrNewbVehicleKeys:GiveKeysByPlate(src, plate);return true end,
      remove = function(src, plate) exports.MrNewbVehicleKeys:RemoveKeysByPlate(src, plate);return true end },
    { name = 'wasabi_carlock',
      give = function(src, plate) exports.wasabi_carlock:GiveKey(src, plate);return true end,
      remove = function(src, plate) exports.wasabi_carlock:RemoveKey(src, plate);return true end },
    { name = 'Renewed-Vehiclekeys',
      give = function(src, plate) exports['Renewed-Vehiclekeys']:addKey(src, plate);return true end,
      remove = function(src, plate) exports['Renewed-Vehiclekeys']:removeKey(src, plate);return true end },
    { name = 'qs-vehiclekeys',
      give = function(src, plate) TriggerClientEvent('loop-scoot:bridge:keys', src, 'qs-vehiclekeys', true, plate);return true end,
      remove = function(src, plate) TriggerClientEvent('loop-scoot:bridge:keys', src, 'qs-vehiclekeys', false, plate);return true end },
    { name = 'qb-vehiclekeys',
      give = function(src, plate) TriggerClientEvent('vehiclekeys:client:SetOwner', src, plate);return true end,
      remove = function(src, plate) TriggerClientEvent('qb-vehiclekeys:client:RemoveKeys', src, plate);return true end },
}

local function keySystem()
    local wanted = B.vehicleKeys or 'auto'
    if wanted == 'none' or wanted == false then return nil end
    for _, system in ipairs(KEY_SYSTEMS) do
        if (wanted == 'auto' or wanted == system.name) and started(system.name) then return system end
    end
    if type(wanted) == 'table' then return wanted end
    return nil
end

function ScootBridge.VehicleKeys(src, plate, netId, give)
    local system = keySystem()
    if not system then return true end
    local entity = netId and NetworkGetEntityFromNetworkId(netId) or nil
    if entity == 0 then entity = nil end
    local ok, accepted = pcall(give and system.give or system.remove, src, plate, entity)
    if not ok then
        print(('[loop-scoot] keys %s (%s): %s'):format(give and 'give' or 'remove', system.name or 'custom', tostring(accepted)))
        return false
    end
    if give and accepted ~= false and system.after then pcall(system.after, src, netId) end
    return accepted ~= false
end

framework = detect()
AddEventHandler('onResourceStop', function(resource)
    if resource ~= FRAMEWORK_RESOURCE[framework] then return end
    core = nil
    coreGeneration = coreGeneration + 1
    if framework == 'ox' and package and package.loaded then package.loaded['@ox_core.lib.init'] = nil end
end)
AddEventHandler('onResourceStart', function(resource)
    local supported = false
    for _, entry in ipairs(FRAMEWORKS) do if resource == entry[1] then supported = true; break end end
    if not supported then return end
    local chosen = detect()
    if chosen ~= framework or resource == FRAMEWORK_RESOURCE[framework] then
        framework, core = chosen, nil
        coreGeneration = coreGeneration + 1
        if framework == 'ox' and package and package.loaded then package.loaded['@ox_core.lib.init'] = nil end
    end
end)
CreateThread(function()
    local deadline = GetGameTimer() + 15000
    while not resolveCore() and GetGameTimer() < deadline do Wait(250) end
    print(('[loop-scoot] framework: %s | keys: %s'):format(framework, (keySystem() or {}).name or 'none'))
end)
