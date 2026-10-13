-- Read-only configuration diagnosis, not a gameplay or sale certification.
ScootDiagnostics = {}
local frameworks = { esx = 'es_extended', qbcore = 'qb-core', qbox = 'qbx_core', ox = 'ox_core' }
local choices = { auto = true, esx = true, qbcore = true, qbox = true, ox = true, standalone = true }
local keyResources = { 'qbx_vehiclekeys', 'MrNewbVehicleKeys', 'wasabi_carlock',
    'Renewed-Vehiclekeys', 'qs-vehiclekeys', 'qb-vehiclekeys' }
local function started(name)
    return type(name) == 'string' and GetResourceState(name) == 'started'
end
local function finite(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

function ScootDiagnostics.Report()
    local B, C = Config.Bridge or {}, Config.Collection or {}
    local report = { version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0),
        configurationReady = true, checks = {}, warnings = {}, inGameVerified = false }
    local function check(name, passed)
        report.checks[#report.checks + 1] = { name = name, passed = passed == true }
        if passed ~= true then report.configurationReady = false end
    end
    check('ox_lib started', started('ox_lib'))
    local onesync = GetConvar('onesync', 'off')
    check('OneSync enabled', onesync ~= '' and onesync ~= 'off' and onesync ~= 'false' and onesync ~= '0')
    check('supported framework setting', choices[B.framework or 'auto'] == true)
    local chosen = ScootBridge and ScootBridge.Framework and ScootBridge.Framework()
    report.framework = chosen or 'unresolved'
    check('framework resolved', choices[chosen] == true and chosen ~= 'auto')
    if frameworks[chosen] then check('selected framework started', started(frameworks[chosen])) end
    local active = 0
    for _, resource in pairs(frameworks) do if started(resource) then active = active + 1 end end
    if active > 1 and (B.framework or 'auto') == 'auto' then
        report.warnings[#report.warnings + 1] = 'Several frameworks started: set Config.Bridge.framework explicitly.'
    end
    check('nonnegative integer rental price', finite(Config.Price) and Config.Price >= 0 and Config.Price % 1 == 0)
    check('positive finite rental duration', finite(Config.RentalDuration) and Config.RentalDuration > 0)
    check('rental account configured', type(Config.Account) == 'string' and Config.Account ~= '')
    local reward = C.payPerScooter or 0
    check('nonnegative integer collection reward', finite(reward) and reward >= 0 and reward % 1 == 0)
    if C.enabled ~= false and finite(reward) and reward > 0 then
        check('collection reward account configured', type(C.payAccount) == 'string' and C.payAccount ~= '')
    end
    if chosen == 'standalone' and ((finite(Config.Price) and Config.Price > 0) or (C.enabled ~= false and finite(reward) and reward > 0)) then
        local adapter = B.standaloneMoney
        check('standalone economy adapter complete', type(adapter) == 'table'
            and type(adapter.get) == 'function' and type(adapter.add) == 'function' and type(adapter.remove) == 'function')
    end
    if chosen == 'ox' then
        check('ox_inventory started for ox cash bridge', started('ox_inventory'))
        check('ox rental cash account', Config.Account == 'money' or Config.Account == 'cash')
        if C.enabled ~= false and finite(reward) and reward > 0 then
            check('ox reward cash account', C.payAccount == 'money' or C.payAccount == 'cash')
        end
    end
    local keys = B.vehicleKeys or 'auto'
    report.keys = type(keys) == 'table' and 'custom' or tostring(keys)
    if type(keys) == 'table' then
        check('custom keys adapter complete', type(keys.give) == 'function' and type(keys.remove) == 'function')
    elseif keys ~= 'auto' and keys ~= 'none' and keys ~= false then
        local known = false
        for _, name in ipairs(keyResources) do if name == keys then known = true end end
        check('known and started explicit key system', known and started(keys))
    elseif keys == 'auto' then
        local found = false
        for _, name in ipairs(keyResources) do if started(name) then found = true; break end end
        if not found then report.warnings[#report.warnings + 1] = 'No key system detected; check custom engine locks in game.' end
    end
    local stations, ids = Config.Stations or {}, {}
    check('at least one station', #stations > 0)
    for i, station in ipairs(stations) do
        local validId = type(station.id) == 'string' and station.id ~= '' and not ids[station.id]
        check('unique station id ' .. i, validId)
        if station.id then ids[station.id] = true end
        check('positive integer station capacity ' .. i, finite(station.capacity) and station.capacity > 0 and station.capacity % 1 == 0)
    end
    report.warnings[#report.warnings + 1] = 'Static configuration only: exports, economy, keys, assets and gameplay need real server tests.'
    return report
end

RegisterCommand('scootdoctor', function(src)
    if src ~= 0 then
        local allowed = IsPlayerAceAllowed(src, 'command.scootdoctor') or IsPlayerAceAllowed(src, Config.AdminAce or 'loop.scoot.admin')
        if not allowed and ScootBridge and ScootBridge.IsAdmin then
            local ok, admin = pcall(ScootBridge.IsAdmin, src)
            allowed = ok and admin == true
        end
        if not allowed then return end
    end
    local report = ScootDiagnostics.Report()
    -- Console only; no balances, identifiers, credentials or privileged output broadcast.
    print(('[loop-scoot] scootdoctor %s'):format(json.encode(report)))
end, false)
