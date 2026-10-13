ScootPrompts = ScootPrompts or {}

local channels = {}
local order = {}
local signatureEcran = nil
local ecranPose = false
local poses = {}
local stopped = false

local LOCAL = {
    setPrompts = function(items)
        if LocalPlayer.state.loopCine == true then items = {} end
        SendNUIMessage({ action = 'loop:prompts', items = items })
        return true
    end,
    clearPrompts = function() SendNUIMessage({ action = 'loop:prompts', items = {} }) return true end,
    interactAdd = function(id, def) return ScootInteract.Add(id, def) end,
    interactRemove = function(id) return ScootInteract.Remove(id) end,
}

local mode = nil

local function appel(nom, ...)
    if stopped then return false end
    local args = table.pack(...)
    local fn = LOCAL[nom]
    if not fn then return false end
    return pcall(fn, table.unpack(args, 1, args.n))
end

local function modeCourant()
    return 'local'
end

local function poserEcran(items)
    local parts = {}
    for i = 1, #items do
        parts[i] = tostring(items[i].key or '') .. '|' .. tostring(items[i].label or '')
    end
    local signature = table.concat(parts, ';')
    if signature == signatureEcran then return end
    signatureEcran = signature
    if #items > 0 then
        ecranPose = true
        appel('setPrompts', items)
    elseif ecranPose then
        ecranPose = false
        appel('clearPrompts', {})
    end
end

local function memeEndroit(a, b)
    return a and b and math.abs(a.x - b.x) < 0.05 and math.abs(a.y - b.y) < 0.05 and math.abs(a.z - b.z) < 0.05
end

local function poserMonde(items)
    local vus = {}
    for i = 1, #items do
        local item = items[i]
        local id = 'loop-scoot:' .. tostring(item.canal) .. ':' .. i
        vus[id] = true
        local avant = poses[id]
        if not avant or avant.label ~= item.label or avant.key ~= item.key
            or avant.promptRange ~= item.promptRange or avant.range ~= item.range
            or not memeEndroit(avant.coords, item.world) then
            local ok, pose = appel('interactAdd', id, {
                coords = item.world,
                offsetZ = item.offsetZ or 0.45,
                label = item.label,
                key = item.key,
                promptRange = item.promptRange or 4.5,
                range = item.range or 6.0,
                group = 'loop-scoot',
            })
            if ok and pose ~= false then
                poses[id] = { label = item.label, key = item.key, coords = item.world,
                    promptRange = item.promptRange, range = item.range }
            else
                vus[id] = nil
            end
        end
    end
    local retires = {}
    for id in pairs(poses) do
        if not vus[id] then retires[#retires + 1] = id end
    end
    for i = 1, #retires do
        appel('interactRemove', retires[i])
        poses[retires[i]] = nil
    end
end

local function publish()
    local courant = modeCourant()
    if mode and mode ~= courant then
        signatureEcran, ecranPose, poses = nil, false, {}
    end
    mode = courant
    local ecran, monde = {}, {}
    local cache = type(IsNuiFocused) == 'function' and IsNuiFocused()
    if not stopped and LocalPlayer.state.loopCine ~= true then
        for i = 1, #order do
            local list = channels[order[i]]
            if list then
                for j = 1, #list do
                    local item = list[j]
                    if type(item.world) == 'vector3' or (type(item.world) == 'table' and item.world.x) then
                        monde[#monde + 1] = {
                            canal = order[i], key = item.key, label = item.label,
                            world = item.world, offsetZ = item.offsetZ,
                            promptRange = item.promptRange, range = item.range,
                        }
                    elseif not cache then
                        ecran[#ecran + 1] = { key = item.key or 'E', label = item.label or '' }
                    end
                end
            end
        end
    end
    poserEcran(ecran)
    poserMonde(monde)
end

function ScootPrompts.Set(channel, list)
    if stopped or type(channel) ~= 'string' then return end
    if channels[channel] == nil then order[#order + 1] = channel end
    channels[channel] = list or {}
    publish()
end

function ScootPrompts.Clear(channel)
    ScootPrompts.Set(channel, {})
end

function ScootPrompts.Reset()
    for name in pairs(channels) do channels[name] = {} end
    signatureEcran = nil
    publish()
end

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    stopped = true
    channels, order = {}, {}
    local retires = {}
    for id in pairs(poses) do retires[#retires + 1] = id end
    for i = 1, #retires do
        poses[retires[i]] = nil
    end
    ecranPose = false
    pcall(LOCAL.clearPrompts)
end)
