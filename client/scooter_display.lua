ScootDisplay = ScootDisplay or {}
local D = ScootDisplay
local resource = GetCurrentResourceName()
local hash = joaat((Config and Config.Model) or 'loop_scooter')
local options = (Config and Config.ScooterDisplay) or {}
local txdName, textureName = 'loop_scoot_console', 'live_screen'
local drawPoly = DrawTexturedPoly or DrawSpritePoly or function(...)
    return Citizen.InvokeNative(0x29280002282F1928, ...)
end
local selected, dui, ready, stopping = 0, nil, false, false
local createdAt, retryAt, lastDataAt, lastVisibleAt = 0, 0, 0, 0
local bones = {}
local corners = {{-.039,-.032,.05375},{.039,-.032,.05375},
    {.039,.020,.05375},{-.039,.020,.05375}}
local shaftLength = math.sqrt(.13*.13 + .73*.73)
local s, c = .13 / shaftLength, .73 / shaftLength

local function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
local function subtract(a,b) return {x=a.x-b.x,y=a.y-b.y,z=a.z-b.z} end
local function dot(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end
local function cross(a,b) return {x=a.y*b.z-a.z*b.y,y=a.z*b.x-a.x*b.z,z=a.x*b.y-a.y*b.x} end
local function combine(a,ka,b,kb) return {x=a.x*ka+b.x*kb,y=a.y*ka+b.y*kb,z=a.z*ka+b.z*kb} end
local function unit(a)
    local length=math.sqrt(dot(a,a))
    if not finite(length) or length<.001 then return nil end
    return {x=a.x/length,y=a.y/length,z=a.z/length}
end
local function valid(entity)
    return entity and entity~=0 and DoesEntityExist(entity) and GetEntityModel(entity)==hash
end

function D.GetScreenFrame(entity)
    if not valid(entity) then return nil end
    local b=bones[entity]
    if not b then
        b={}
        for _,name in ipairs({'handlebars','forks_u','hbgrip_l','hbgrip_r'}) do
            b[name]=GetEntityBoneIndexByName(entity,name)
            if b[name]<0 then return nil end
        end
        bones[entity]=b
    end
    local origin=GetWorldPositionOfEntityBone(entity,b.handlebars)
    local fork=GetWorldPositionOfEntityBone(entity,b.forks_u)
    local left=GetWorldPositionOfEntityBone(entity,b.hbgrip_l)
    local right=GetWorldPositionOfEntityBone(entity,b.hbgrip_r)
    local x=unit(subtract(right,left))
    if not x then return nil end
    local shaft=subtract(origin,fork)
    local d=unit(combine(shaft,1,x,-dot(shaft,x)))
    if not d then return nil end
    local q=unit(cross(x,d))
    if not q then return nil end
    local y,z=combine(q,-c,d,-s),combine(q,-s,d,c)
    local points={}
    for i,p in ipairs(corners) do
        points[i]={x=origin.x+x.x*p[1]+y.x*p[2]+z.x*p[3],
            y=origin.y+x.y*p[1]+y.y*p[2]+z.y*p[3],
            z=origin.z+x.z*p[1]+y.z*p[2]+z.z*p[3]}
    end
    return {corners=points,origin=origin,right=x,forward=y,up=z}
end

function D.GetTelemetry(entity)
    if not valid(entity) then return nil end
    local state=Entity(entity).state
    local battery=state.loopScootBattery
    if not finite(battery) or battery<0 or battery>100 then battery=nil end
    local rental=state.loopScoot
    local collection=state.loopScootCollection
    local door=GetVehicleDoorLockStatus(entity)
    local busy=type(rental)=='table' and (rental.preparing==true or rental.dispensing==true)
    local service=type(collection)=='table' and (collection.state=='carried' or collection.state=='loaded')
    local locked=busy or service or (door~=0 and door~=1)
        or GetVehicleDoorsLockedForPlayer(entity,PlayerId())
    local speed=GetEntitySpeed(entity)*3.6
    if not finite(speed) then speed=0 end
    local riding=GetPedInVehicleSeat(entity,-1)~=0
    local _,lights,highbeams=GetVehicleLightsState(entity)
    return {type='telemetry',speed=math.max(0,speed),battery=battery,
        batteryAvailable=battery~=nil,locked=locked==true,riding=riding,
        service=service==true,busy=busy==true,headlight=lights==1 or highbeams==1,
        damaged=IsEntityDead(entity),powered=GetIsVehicleEngineRunning(entity)}
end

local function destroy()
    if dui then DestroyDui(dui) end
    dui,ready=nil,false
end
local function ensureDui(now)
    if dui then
        if not ready and IsDuiAvailable(dui) then
            local dictionary=CreateRuntimeTxd(txdName)
            CreateRuntimeTextureFromDuiHandle(dictionary,textureName,GetDuiHandle(dui))
            ready=true
        elseif not ready and now-createdAt>10000 then destroy();retryAt=now+5000 end
        return ready
    end
    if now<retryAt then return false end
    local ok,handle=pcall(CreateDui,('https://cfx-nui-%s/web/scooter-display/index.html'):format(resource),512,340)
    dui=ok and handle and handle~=0 and handle or nil
    createdAt=now
    if not dui then retryAt=now+5000 end
    return false
end

local function choose()
    local ped=PlayerPedId()
    local vehicle=GetVehiclePedIsIn(ped,false)
    if valid(vehicle) and GetPedInVehicleSeat(vehicle,-1)==ped then return vehicle end
    local position=GetEntityCoords(ped)
    local nearest,limit=0,math.max(2,math.min(8,tonumber(options.distance) or 6.0))^2
    for _,entity in ipairs(GetGamePool('CVehicle')) do
        if valid(entity) and IsEntityVisible(entity) and IsEntityOnScreen(entity) then
            local delta=subtract(GetEntityCoords(entity),position)
            local distance=dot(delta,delta)
            if distance<limit then nearest,limit=entity,distance end
        end
    end
    return nearest
end

local function triangle(a,b,c1,u1,v1,u2,v2,u3,v3)
    drawPoly(a.x,a.y,a.z,b.x,b.y,b.z,c1.x,c1.y,c1.z,
        255,255,255,255,txdName,textureName,u1,v1,1.0,u2,v2,1.0,u3,v3,1.0)
end
CreateThread(function()
    if options.enabled==false then return end
    local nextScan=0
    while not stopping do
        local now=GetGameTimer()
        if now>=nextScan then
            local target=choose()
            if target~=selected then selected=target;lastDataAt=0 end
            nextScan=now+500
            for entity in pairs(bones) do if entity~=selected then bones[entity]=nil end end
        end
        if valid(selected) then
            lastVisibleAt=now
            local frame=D.GetScreenFrame(selected)
            if frame and ensureDui(now) then
                if now-lastDataAt>=100 then
                    local data=D.GetTelemetry(selected)
                    if data then data.language=ScootLocale.Resolve();SendDuiMessage(dui,json.encode(data));lastDataAt=now end
                end
                local p=frame.corners

                triangle(p[1],p[2],p[3],0,1,1,1,1,0)
                triangle(p[1],p[3],p[4],0,1,1,0,0,0)
            end
            Wait(0)
        else
            selected=0
            if dui and now-lastVisibleAt>10000 then destroy() end
            Wait(100)
        end
    end
end)
AddEventHandler('onResourceStop',function(name)
    if name~=resource then return end
    stopping=true;destroy();bones={}
end)
