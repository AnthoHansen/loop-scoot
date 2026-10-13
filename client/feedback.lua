ScootUI = {}

local MODES = { loop = true, ox = true, esx = true, qb = true }
local KINDS = {
    inform = 'info', info = 'info', primary = 'info',
    success = 'success', error = 'error',
    warn = 'warn', warning = 'warn',
}
local OX_KINDS = { info = 'inform', success = 'success', error = 'error', warn = 'warning' }
local ESX_KINDS = { info = 'info', success = 'success', error = 'error', warn = 'warning' }
local QB_KINDS = { info = 'primary', success = 'success', error = 'error', warn = 'warning' }
local DISABLED_CONTROLS = { 30, 31, 21, 22, 23, 24, 25, 37 }
local CANCEL_CONTROLS = { 200, 202 }

local counter = 0
local active = nil
local stopping = false

local function settings()
    return type(Config) == 'table' and type(Config.UI) == 'table' and Config.UI or {}
end

local function modeOf(name)
    local value = settings()[name]
    if type(value) == 'string' and MODES[value] then return value end
    return 'loop'
end

function ScootUI.Mode(name)
    return modeOf(name)
end

local function kindOf(kind)
    return KINDS[kind or 'inform'] or 'info'
end

local function notifyLoop(message, kind, duration)
    counter = counter + 1
    SendNUIMessage({
        action = 'loop:notify',
        id = 'n' .. counter,
        title = ScootText('notify.title'),
        sub = message,
        kind = kind,
        duration = duration,
    })
    return true
end

local function notifyOx(message, kind)
    lib.notify({
        description = message, type = OX_KINDS[kind] or 'inform', position = 'top-left',
        icon = 'exclamation', iconColor = '#1FE8F5',
    })
    return true
end

local function notifyEsx(message, kind, duration)
    if GetResourceState('es_extended') ~= 'started' then return false end
    return pcall(function()
        exports['es_extended']:getSharedObject().ShowNotification(message, ESX_KINDS[kind] or 'info', duration)
    end)
end

local function notifyQb(message, kind, duration)
    if GetResourceState('qb-core') ~= 'started' then return false end
    return pcall(function()
        exports['qb-core']:GetCoreObject().Functions.Notify(message, QB_KINDS[kind] or 'primary', duration)
    end)
end

local NOTIFIERS = { loop = notifyLoop, ox = notifyOx, esx = notifyEsx, qb = notifyQb }

function ScootUI.Notify(message, kind, duration)
    if type(message) ~= 'string' or message == '' then return false end
    if LocalPlayer.state.loopCine == true then return true end
    kind = kindOf(kind)
    duration = tonumber(duration) or tonumber(settings().notifyDuration) or 4500
    local mode = ScootUI.Mode('notify')
    if NOTIFIERS[mode](message, kind, duration) then return true end
    return notifyLoop(message, kind, duration)
end

local function pedUsable(ped)
    return ped ~= 0 and DoesEntityExist(ped) and not IsEntityDead(ped) and not IsPedRagdoll(ped)
end

local function playAnim(ped, anim)
    if type(anim) ~= 'table' or not anim.dict then return end
    RequestAnimDict(anim.dict)
    local deadline = GetGameTimer() + 1000
    while not HasAnimDictLoaded(anim.dict) and GetGameTimer() < deadline do Wait(0) end
    if HasAnimDictLoaded(anim.dict) then
        TaskPlayAnim(ped, anim.dict, anim.clip, 4.0, -4.0, -1, 49, 0.0, false, false, false)
    end
end

local function cancelPressed()
    for _, control in ipairs(CANCEL_CONTROLS) do DisableControlAction(0, control, true) end
    for _, control in ipairs(CANCEL_CONTROLS) do
        if IsDisabledControlJustPressed(0, control) then return true end
    end
    return false
end

local function drive(options, duration)
    local ped = PlayerPedId()
    playAnim(ped, options.anim)
    local startedAt = GetGameTimer()
    local cancelled = false
    while GetGameTimer() - startedAt < duration do
        if options.disable then
            for _, control in ipairs(DISABLED_CONTROLS) do DisableControlAction(0, control, true) end
        end
        if options.canCancel and cancelPressed() then cancelled = true break end
        if active and active.cancelled then cancelled = true break end
        if stopping or not pedUsable(ped) or ped ~= PlayerPedId() then cancelled = true break end
        Wait(0)
    end
    if options.anim and options.anim.dict then StopAnimTask(ped, options.anim.dict, options.anim.clip, 3.0) end
    return not cancelled
end

local function progressLoop(options, duration)
    SendNUIMessage({
        action = 'loop:progress', open = true,
        label = options.label or '', duration = duration,
        cancellable = options.canCancel == true, cancelKey = 'ESC',
        cancelLabel = ScootText('progress.cancel'),
    })
    local done = drive(options, duration)
    SendNUIMessage({ action = 'loop:progress', open = false })
    return done
end

local function progressOx(options)
    return lib.progressBar(options) == true
end

local function progressEsx(options, duration)
    if GetResourceState('esx_progressbar') ~= 'started' then return nil end
    local result = promise.new()
    local animation
    if options.anim and options.anim.dict then
        animation = { type = 'anim', dict = options.anim.dict, lib = options.anim.clip }
    end
    local ok = pcall(function()
        exports['esx_progressbar']:Progressbar(options.label or '', duration, {
            FreezePlayer = options.disable ~= nil,
            animation = animation,
            onFinish = function() result:resolve(true) end,
            onCancel = function() result:resolve(false) end,
        })
    end)
    if not ok then return nil end
    return Citizen.Await(result)
end

local function progressQb(options, duration)
    if GetResourceState('qb-core') ~= 'started' then return nil end
    local result = promise.new()
    local disable = options.disable or {}
    local animation = {}
    if options.anim and options.anim.dict then
        animation = { animDict = options.anim.dict, anim = options.anim.clip, flags = 49 }
    end
    local ok = pcall(function()
        exports['qb-core']:GetCoreObject().Functions.Progressbar(
            'loop_scoot_' .. GetGameTimer(), options.label or '', duration, false, options.canCancel == true,
            {
                disableMovement = disable.move == true, disableCarMovement = disable.car == true,
                disableMouse = false, disableCombat = disable.combat == true,
            },
            animation, {}, {},
            function() result:resolve(true) end,
            function() result:resolve(false) end
        )
    end)
    if not ok then return nil end
    return Citizen.Await(result)
end

function ScootUI.Progress(options)
    options = options or {}
    if active or stopping then return false end
    local duration = math.max(1, tonumber(options.duration) or 1000)
    active = { cancelled = false }
    local mode = ScootUI.Mode('progress')
    local ok, result = pcall(function()
        local value
        if LocalPlayer.state.loopCine == true then value = drive(options, duration)
        elseif mode == 'ox' then value = progressOx(options)
        elseif mode == 'esx' then value = progressEsx(options, duration)
        elseif mode == 'qb' then value = progressQb(options, duration) end
        if value == nil then value = progressLoop(options, duration) end
        return value
    end)
    active = nil
    if not ok then
        SendNUIMessage({ action = 'loop:progress', open = false })
        error(result, 0)
    end
    return result == true
end

function ScootUI.CancelProgress()
    if active then active.cancelled = true end
end

function ScootUI.Busy()
    return active ~= nil
end

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    stopping = true
    SendNUIMessage({ action = 'loop:progress', open = false })
end)
