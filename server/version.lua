local REPOSITORY = 'loopfivem/loop-scoot'

local function parse(v)
    local a, b, c = tostring(v or ''):match('(%d+)%.(%d+)%.(%d+)')
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

local function newer(remote, current)
    for i = 1, 3 do
        if remote[i] ~= current[i] then return remote[i] > current[i] end
    end
    return false
end

CreateThread(function()
    if GetConvar('loop_scoot_versioncheck', 'true') == 'false' then return end
    Wait(5000)
    local resource = GetCurrentResourceName()
    local current = parse(GetResourceMetadata(resource, 'version', 0))
    if not current then return end
    PerformHttpRequest(('https://api.github.com/repos/%s/releases/latest'):format(REPOSITORY), function(status, body)
        if status ~= 200 or not body then return end
        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= 'table' then return end
        local remote = parse(data.tag_name)
        if not remote or not newer(remote, current) then return end
        print(('^3[%s]^7 Update available: ^2%s^7 (installed %d.%d.%d) - %s'):format(resource, data.tag_name, current[1], current[2], current[3], data.html_url or ('https://github.com/' .. REPOSITORY .. '/releases/latest')))
    end, 'GET', '', { ['User-Agent'] = resource, ['Accept'] = 'application/vnd.github+json' })
end)
