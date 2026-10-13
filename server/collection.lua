local C = Config.Collection
if not C or not C.enabled then return end
local ESX = { GetPlayerFromId = ScootBridge.GetPlayer }
local RESOURCE, TAG = GetCurrentResourceName(), 'loopScootCollection'
local sessions, fleet, limits = {}, {}, {}
local uiReceipts,uiViews={},{}
local stopped, initialized, serial, revision = false, false, 0, 0
local truckSpawnReservation
local initializingFleet=false
local depot = {}
for k,v in pairs(C.depot) do depot[k]=v end
local function now() return GetGameTimer() end
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<1e7 end
local function position(p)
    if not p or not finite(p.x) or not finite(p.y) or not finite(p.z) then return nil end
    return {x=p.x,y=p.y,z=p.z}
end
local function copy(t) local r={};for k,v in pairs(t or {}) do r[k]=v end;return r end
local function distance(a,b) return ScootCollection.Distance(a,b) end
local function nextToken() serial=serial+1;return ('%d:%d'):format(now(),serial) end
local epoch=nextToken()
local function identity(p) return p and (p.identifier or (p.getIdentifier and p.getIdentifier())) end
local function player(src) return ESX.GetPlayerFromId(src) end
local function validPlayer(src, session)
    local p=player(src)
    if not identity(p) or (session and session.identifier~=identity(p)) then return nil end
    if GetPlayerRoutingBucket(src)~=(C.bucket or 0) then return nil end
    local ped=GetPlayerPed(src)
    if ped==0 or not DoesEntityExist(ped) or GetEntityHealth(ped)<=0 then return nil end
    return p,ped
end
local function allowed(src,key,interval)
    local t=now();limits[src]=limits[src] or {}
    if limits[src][key] and t-limits[src][key]<interval then return false end
    limits[src][key]=t;return true
end
local function fail(message) return {ok=false,message=message,serverNow=now()} end
local function near(ped,coords,reach)
    return position(coords) and distance(GetEntityCoords(ped),coords)<=(reach or C.interactionDistance or 1.8)
end
local function onFoot(ped) return GetVehiclePedIsIn(ped,false)==0 end
local function atDepot(ped,point,reach)
    return near(ped,ScootCollection.World(depot,depot[point]),reach)
end
local function ownsEntity(entry)
    if not entry or not entry.entity or not entry.netId or not DoesEntityExist(entry.entity) then return false end
    if NetworkGetNetworkIdFromEntity(entry.entity)~=entry.netId
        or GetEntityModel(entry.entity)~=joaat(entry.model) then return false end
    local tag=Entity(entry.entity).state[TAG]
    return type(tag)=='table' and tag.token==entry.entityToken and tag.id==entry.id and tag.kind==entry.kind
end
local function truckKeys(entry, give)
    if not entry or entry.kind ~= 'truck' or not entry.owner or not entry.plate then return false end
    if not give and not entry.keysGranted then return true end
    local accepted = ScootBridge.VehicleKeys(entry.owner, entry.plate, entry.netId, give)
    entry.keysGranted = give and accepted or false
    return accepted
end
local function deleteOwned(entry)
    truckKeys(entry, false)
    if ownsEntity(entry) then DeleteEntity(entry.entity) end
    if entry then entry.entity,entry.netId=nil,nil end
end
local function entityCoords(entry)
    if ownsEntity(entry) then return position(GetEntityCoords(entry.entity)) end
end
local function entityValid(entry)
    return ownsEntity(entry) and GetEntityRoutingBucket(entry.entity)==(C.bucket or 0)
        and GetEntityHealth(entry.entity)>0
end
local function truckStill(session)
    if not session or not entityValid(session.truck)
        or GetEntitySpeed(session.truck.entity)>(C.truck.maxLoadSpeed or 0.15) then return false end
    if GetEntityRotation then
        local rotation=GetEntityRotation(session.truck.entity,2)
        if not rotation or math.abs(rotation.x)>(C.truck.maxTilt or 8) or math.abs(rotation.y)>(C.truck.maxTilt or 8) then return false end
    end
    return true
end
local function truckEmpty(session)
    if not session.truck then return true end
    return next(session.truck.slots)==nil
end
local function createEntity(entry,coords,isCurrent)
    entry.entityToken=nextToken()
    local created,entity=pcall(CreateVehicleServerSetter,joaat(entry.model),entry.kind=='truck' and (C.truck.type or 'automobile') or 'bike',
        coords.x,coords.y,coords.z,coords.heading or 0)
    if not created or not entity or entity==0 then return false end
    entry.entity=entity
    local untilAt=now()+5000
    while not stopped and not DoesEntityExist(entity) and now()<untilAt do Wait(50) end
    if not DoesEntityExist(entity) then

        CreateThread(function()
            local cleanupAt=now()+5000
            while not stopped and not DoesEntityExist(entity) and now()<cleanupAt do Wait(100) end
            if DoesEntityExist(entity) and GetEntityModel(entity)==joaat(entry.model)
                and Entity(entity).state[TAG]==nil then DeleteEntity(entity) end
        end)
        entry.entity=nil;return false
    end
    if GetEntityModel(entity)~=joaat(entry.model) or Entity(entity).state[TAG]~=nil then entry.entity=nil;return false end

    entry.entity=entity
    entry.netId=NetworkGetNetworkIdFromEntity(entity)
    if not entry.netId or entry.netId==0 then DeleteEntity(entity);entry.entity=nil;return false end
    Entity(entity).state:set(TAG,{id=entry.id,token=entry.entityToken,kind=entry.kind,owner=entry.owner},true)
    if stopped or (isCurrent and not isCurrent()) then deleteOwned(entry);return false end
    SetEntityRoutingBucket(entity,C.bucket or 0)
    SetEntityOrphanMode(entity,2)
    entry.plate = entry.kind=='truck' and ('SC%06d'):format(serial%1000000) or 'SCOOT'
    SetVehicleNumberPlateText(entity,entry.plate)
    SetVehicleDoorsLocked(entity,entry.kind=='scooter' and 2 or 1)
    if entry.kind=='scooter' then FreezeEntityPosition(entity,true) end
    Entity(entity).state:set('fuelLevel',100.0,true)
    truckKeys(entry, true)
    return true
end

local function publicFleet(entry)
    local p=entry.coords
    if entry.state=='ground' then p=entityCoords(entry) or p end
    if entry.state=='carried' then
        local session=sessions[entry.carrier]
        local ped
        if session then local _;_,ped=validPlayer(entry.carrier,session) end
        if ped then p=position(GetEntityCoords(ped)) or p end
    elseif entry.state=='loaded' then
        local session=sessions[entry.owner]
        p=session and entityCoords(session.truck) or p
    end
    return {id=entry.id,netId=entry.netId or 0,token=entry.entityToken,coords=copy(p),heading=entry.heading or 0,
        state=entry.state,carrier=entry.carrier,truckNetId=entry.truckNetId,slot=entry.slot,reservedBy=entry.reservedBy}
end
local function snapshot(src)
    local response={ok=true,epoch=epoch,serverNow=now(),revision=revision,depot={x=depot.x,y=depot.y,z=depot.z,heading=depot.heading},fleet={},trucks={},actions={}}
    if GetPlayerRoutingBucket(src)~=(C.bucket or 0) then return response end
    for _,entry in pairs(fleet) do response.fleet[#response.fleet+1]=publicFleet(entry) end
    table.sort(response.fleet,function(a,b) return a.id<b.id end)
    for _,session in pairs(sessions) do
        if session.truck and ownsEntity(session.truck) then
            response.trucks[#response.trucks+1]={id=session.truck.id,netId=session.truck.netId,owner=session.source,
                token=session.truck.entityToken,coords=entityCoords(session.truck),slots=copy(session.truck.slots)}
        end
        if session.pending then
            local a=session.pending
            response.actions[#response.actions+1]={source=session.source,kind=a.kind,id=a.id,slot=a.slot,netId=a.netId,
                truckNetId=session.truck and session.truck.netId,startedAt=a.startedAt,duration=a.duration}
        end
    end
    local session=sessions[src]
    if session and validPlayer(src,session) then
        response.session={token=session.token,truckNetId=session.truck and session.truck.netId or 0,
            carrying=session.carrying,carryToken=session.carryToken,delivered=session.delivered,earned=session.earned,onDuty=true}
    end

    local ok,rentals=pcall(function() return exports[RESOURCE]:GetScootRentalBlips(src) end)
    if ok and type(rentals)=='table' then response.rentals=rentals end
    return response
end
local function broadcast()
    revision=revision+1
    for _,id in ipairs(GetPlayers()) do
        local src=tonumber(id)
        if src then TriggerClientEvent('loop-scoot:collection:sync',src,snapshot(src)) end
    end
end
local function cancelPending(session)
    local action=session and session.pending
    if not action then return end
    local entry=action.id and fleet[action.id]
    if entry and entry.reservedBy==action.token then entry.reservedBy=nil end
    if entry and entry.state=='adopting' and entry.pendingToken==action.token then fleet[entry.id]=nil end
    if session.truck and action.slot and session.truck.reservedSlots[action.slot]==action.token then
        session.truck.reservedSlots[action.slot]=nil
    end
    session.pending=nil
end
local function ground(entry,coords)
    deleteOwned(entry)
    entry.state,entry.carrier,entry.owner,entry.truckNetId,entry.slot,entry.reservedBy='ground',nil,nil,nil,nil,nil
    entry.coords=position(coords) or copy(entry.home)
    entry.heading=coords and coords.heading or entry.heading or 0
    entry.spawning=true
    local generation=nextToken();entry.generation=generation
    local ok=createEntity(entry,{x=entry.coords.x,y=entry.coords.y,z=entry.coords.z,heading=entry.heading},function()
        return entry.generation==generation and entry.state=='ground'
    end)
    entry.spawning=false
    if not ok and entry.generation==generation then entry.state='cooldown';entry.respawnAt=now()+5000 end
    return ok
end
local function safeDrop(session)
    local p=session.lastGround or ScootCollection.World(depot,depot.returns)
    local _,ped=validPlayer(session.source,session)
    if ped then
        local coords=GetEntityCoords(ped)
        if position(coords) then p={x=coords.x,y=coords.y,z=coords.z-ScootCollectionMotion.originToGround,heading=GetEntityHeading(ped)} end
    end
    local heading=p.heading or 0
    local radians=math.rad(heading)

    local d=C.pickupDistance or .55
    local yaw=(C.carryAttach and C.carryAttach.yaw) or -90
    return {x=p.x-math.sin(radians)*d,y=p.y+math.cos(radians)*d,z=p.z,heading=(heading+yaw)%360}
end
local function recoverCarry(session)
    if not session or not session.carrying then return end
    local entry=fleet[session.carrying]
    session.carrying=nil;session.carryToken=nil
    if entry and entry.state=='carried' and entry.carrier==session.source then ground(entry,safeDrop(session)) end
end
local function cleanup(session,reason)
    if not session or session.cleaning then return end
    session.cleaning=true
    cancelPending(session)

    if sessions[session.source]==session then sessions[session.source]=nil end
    TriggerClientEvent('loop-scoot:collection:reset',session.source,reason,session.token)
    recoverCarry(session)
    if session.truck then
        for _,id in pairs(session.truck.slots) do
            local entry=fleet[id]
            if entry and entry.state=='loaded' and entry.owner==session.source then ground(entry,entry.home) end
        end
        deleteOwned(session.truck)
    end
    broadcast()
end
local function initializeFleet()
    if initialized then return end
    initialized=true
    initializingFleet=true
    for _,point in ipairs(C.fleet or {}) do
        if type(point.id)=='string' and not fleet[point.id] and position(point) then
            fleet[point.id]={id=point.id,home=copy(point),coords=position(point),heading=point.heading or 0,
                kind='scooter',model=C.scooterModel or Config.Model,state='cooldown',respawnAt=now()}
        end
    end
    for _,entry in pairs(fleet) do if not stopped then ground(entry,entry.home) end end
    initializingFleet=false
end
local function sessionFor(src)
    local session=sessions[src]
    local p,ped=validPlayer(src,session)
    if not session or session.cleaning or not p then return nil end
    if C.allowedJob then
        local job=(p.getJob and p.getJob()) or p.job
        if not job or job.name~=C.allowedJob then return nil end
    end
    return session,p,ped
end

lib.callback.register('loop-scoot:collection:engine',function(src,sessionToken,netId,entityToken)
    if stopped or not allowed(src,'engine',1000) then return fail(ScootText('err.engineCooldown')) end
    if type(sessionToken)~='string' or #sessionToken>64 or type(entityToken)~='string' or #entityToken>64
        or not finite(netId) or netId<=0 or netId%1~=0 then return fail(ScootText('err.engineInvalid')) end
    local session,_,ped=sessionFor(src)
    local truck=session and session.truck
    if not session or session.token~=sessionToken or session.pending or session.carrying
        or not truck or truck.owner~=src or truck.netId~=netId or truck.entityToken~=entityToken
        or not entityValid(truck) then return fail(ScootText('err.truckMismatch')) end
    local tag=Entity(truck.entity).state[TAG]
    if tag.owner~=src or GetVehiclePedIsIn(ped,false)~=truck.entity
        or GetPedInVehicleSeat(truck.entity,-1)~=ped then return fail(ScootText('err.sitInTruck')) end
    return {ok=true,sessionToken=session.token,netId=truck.netId,entityToken=truck.entityToken,
        id=truck.id,owner=src,validForMs=1500,serverNow=now()}
end)

local function adoptable(vehicle,src)
    if C.collectRentals==false then return false,ScootText('err.rentalNotCollectable') end
    if Entity(vehicle).state.loopScoot~=nil then
        if type(ScootRentalCollectable)~='function' then return false,ScootText('err.rentalOwned') end
        local ok,message=ScootRentalCollectable(vehicle,src)
        if not ok then return false,message or ScootText('err.rentalInUse') end
    end
    return true
end
local function truckPoint(session,slot)
    local p=entityCoords(session.truck)
    if not p then return nil end
    p.heading=GetEntityHeading(session.truck.entity)
    local offset=C.truck.slots[tonumber(slot)]
    if not offset then return nil end

    return ScootCollection.World(p,offset)
end
local function hasPlacement(kind) return kind=='pickup' or kind=='load' or kind=='unload' end
local PLACEMENT_TIMEOUT_MS,FINISH_REACH_GRACE=5000,1.0
local function validateAction(session,ped,kind,id,slot,finishGrace)
    finishGrace=finishGrace or 0
    if not onFoot(ped) then return false,ScootText('err.leaveVehicle') end
    local entry=id and fleet[id]
    if kind=='pickup' then
        if session.carrying then return false,ScootText('err.alreadyCarrying') end
        if entry and entry.state=='adopting' then

            local vehicle=entry.netId and NetworkGetEntityFromNetworkId(entry.netId) or 0
            if vehicle==0 or not DoesEntityExist(vehicle) or GetEntityModel(vehicle)~=joaat(C.scooterModel)
                or Entity(vehicle).state[TAG]~=nil then return false,ScootText('err.scooterBusyOrGone') end
            if GetPedInVehicleSeat(vehicle,-1)~=0 or GetEntitySpeed(vehicle)>0.15 then return false,ScootText('err.scooterMoving') end
            if not near(ped,GetEntityCoords(vehicle),(C.interactionDistance or 1.8)+finishGrace) then return false,ScootText('err.tooFarScooter') end
            local ok,message=adoptable(vehicle,session.source)
            if not ok then return false,message end
            entry.entity=vehicle
            return true
        end
        if not entry or entry.state~='ground' or entry.spawning or not entityValid(entry) then return false,ScootText('err.scooterBusyOrGone') end
        if Entity(entry.entity).state.loopScoot~=nil then return false,ScootText('err.rentalOwned') end
        if GetPedInVehicleSeat(entry.entity,-1)~=0 or GetEntitySpeed(entry.entity)>0.15 then return false,ScootText('err.scooterMoving') end
        if not near(ped,GetEntityCoords(entry.entity),(C.interactionDistance or 1.8)+finishGrace) then return false,ScootText('err.tooFarScooter') end
    elseif kind=='drop' then
        if not entry or session.carrying~=id or entry.state~='carried' or entry.carrier~=session.source then return false,ScootText('err.notCarryingThis') end
    elseif kind=='load' or kind=='unload' then
        if not truckStill(session) then return false,ScootText('err.truckNotReady') end
        if not slot or not C.truck.slots[tonumber(slot)] or tonumber(slot)>(C.truck.capacity or #C.truck.slots) then return false,ScootText('err.slotUnknown') end
        local p=truckPoint(session,slot)
        if not p or not near(ped,p,(C.interactionDistance or 1.8)+0.6+finishGrace) then return false,ScootText('err.tooFarSlot') end
        if kind=='load' then
            if not entry or session.carrying~=id or entry.state~='carried' or entry.carrier~=session.source then return false,ScootText('err.needCarry') end
            if session.truck.slots[slot] then return false,ScootText('err.slotTaken') end
        else
            if session.carrying then return false,ScootText('err.putDownFirst') end
            if not entry or session.truck.slots[slot]~=id or entry.state~='loaded' or entry.owner~=session.source then return false,ScootText('err.slotEmpty') end
        end
    elseif kind=='service' then
        if session.carrying then return false,ScootText('err.stowCarried') end
        if not truckStill(session) or truckEmpty(session) then return false,ScootText('err.needLoadedTruck') end
        local returns=ScootCollection.World(depot,depot.returns)
        if not near(ped,returns,6.0) or distance(GetEntityCoords(session.truck.entity),returns)>9.0 then return false,ScootText('err.truckToDepot') end
        if not atDepot(ped,'manager',4.0) and not near(ped,returns,6.0) then return false,ScootText('err.tooFarDepot') end
    else return false,ScootText('err.actionUnknown') end
    return true
end

lib.callback.register('loop-scoot:collection:snapshot',function(src)
    if not allowed(src,'snapshot',350) then return fail(ScootText('err.waitAMoment')) end
    return snapshot(src)
end)

local function uiNumber(value,max)
    return type(value)=='number' and value==value and value%1==0 and value>0 and value<=max
end
local function uiOrder(record,generation,id)
    if not record then return 1 end
    if generation==record.generation and id==record.requestId then return 0 end
    return (generation>record.generation or (generation==record.generation and id>record.requestId)) and 1 or -1
end
local function uiReceipt(record)
    return {uiGeneration=record.generation,requestId=record.requestId,status=record.status,
        ok=record.ok==true,message=record.message}
end
lib.callback.register('loop-scoot:collection:garage',function(src,generation,requestId,ticket)
    if stopped or not allowed(src,'garage',500) then return fail(ScootText('err.waitAMoment')) end
    local existing=sessions[src]
    local p,ped=validPlayer(src,existing)
    if not p or not onFoot(ped) or not atDepot(ped,'manager',4.0) then return fail(ScootText('err.talkToManager')) end
    local session=sessionFor(src)
    if existing and not session then return fail(ScootText('err.shiftMismatch')) end
    local garage={name=C.truck.displayName,status='unavailable',capacity=C.truck.capacity,
        thumbnail='assets/collection-truck.png'}
    if session then
        garage.status='available'
        if session.truck then
            if truckSpawnReservation==session.truck then garage.status='spawning'
            elseif entityValid(session.truck) then
                garage.status='out'
                if GetVehicleNumberPlateText then
                    local ok,plate=pcall(GetVehicleNumberPlateText,session.truck.entity)
                    if ok and type(plate)=='string' and #plate<=16 then garage.plate=plate:match('^%s*(.-)%s*$') end
                end
            else garage.status='unavailable' end
        end
    end
    local view=uiViews[src]
    if not view or view.identifier~=identity(p) then
        view={identifier=identity(p),ticket=nextToken()};uiViews[src]=view;uiReceipts[src]=nil
    end
    local response=snapshot(src);response.garage=garage;response.uiTicket=view.ticket
    if generation~=nil or requestId~=nil or ticket~=nil then
        if not uiNumber(generation,9007199254740991) or not uiNumber(requestId,2147483647) then return fail(ScootText('err.badRequest')) end
        if ticket~=view.ticket then

            local expired=fail(ScootText('err.requestMismatch'))
            expired.uiOperation={uiGeneration=generation,requestId=requestId,status='complete',ok=false,
                message=expired.message,retiredTicket=true}
            return expired
        end
        local record=uiReceipts[src];local order=uiOrder(record,generation,requestId)
        if order>0 then

            if record and record.status=='pending' then return fail(ScootText('err.serverBusy')) end
            record={identifier=identity(p),generation=generation,requestId=requestId,status='complete',ok=false,
                message=ScootText('err.requestLost')};uiReceipts[src]=record
        elseif order<0 then
            record={generation=generation,requestId=requestId,status='complete',ok=false,message=ScootText('err.requestReplaced')}
        end
        response.uiOperation=uiReceipt(record)
    end
    return response
end)
local function dutyMutation(src,enabled)
    if stopped or type(enabled)~='boolean' or not allowed(src,'duty',1000) then return fail(ScootText('err.actionUnavailable')) end
    local p,ped=validPlayer(src)
    if not p or not onFoot(ped) or not atDepot(ped,'manager',3.0) then return fail(ScootText('err.talkToManager')) end
    local session=sessions[src]
    if not enabled then
        if not session or identity(p)~=session.identifier then return fail(ScootText('err.notOnDuty')) end
        if session.pending or session.carrying or not truckEmpty(session) then return fail(ScootText('err.finishHandling')) end
        cleanup(session,'shift_ended');return snapshot(src)
    end
    if session then return fail(ScootText('err.alreadyOnDuty')) end
    if C.allowedJob then
        local job=(p.getJob and p.getJob()) or p.job
        if not job or job.name~=C.allowedJob then return fail(ScootText('err.jobNotAllowed')) end
    end
    local count=0;for _ in pairs(sessions) do count=count+1 end
    if count>=(C.maxWorkers or 8) then return fail(ScootText('err.shiftsFull')) end
    session={source=src,identifier=identity(p),token=nextToken(),delivered=0,earned=0}
    sessions[src]=session
    initializeFleet()
    if sessions[src]~=session or not validPlayer(src,session) then return fail(ScootText('err.shiftCancelled')) end
    broadcast();return snapshot(src)
end
lib.callback.register('loop-scoot:collection:duty',dutyMutation)
local function truckMutation(src)
    if stopped or not allowed(src,'truck',1000) then return fail(ScootText('err.waitAMoment')) end
    local session,_,ped=sessionFor(src)
    if not session or session.pending or session.carrying or not onFoot(ped)
        or not atDepot(ped,'manager',4.0) then return fail(ScootText('err.askManagerTruck')) end
    if session.truck then return fail(ScootText('err.alreadyHaveTruck')) end
    if truckSpawnReservation then return fail(ScootText('err.truckSpawning')) end
    local coords=ScootCollection.World(depot,depot.truckSpawn)
    for _,vehicle in ipairs(GetAllVehicles()) do
        if DoesEntityExist(vehicle) and GetEntityRoutingBucket(vehicle)==(C.bucket or 0)
            and distance(GetEntityCoords(vehicle),coords)<4.0 then return fail(ScootText('err.truckSpotTaken')) end
    end

    local entry={id='truck:'..session.token,kind='truck',model=C.truck.model,owner=src,slots={},reservedSlots={}}
    session.truck=entry
    truckSpawnReservation=entry
    local ok=createEntity(entry,coords,function() return sessions[src]==session and session.truck==entry and validPlayer(src,session)~=nil end)
    if truckSpawnReservation==entry then truckSpawnReservation=nil end
    if not ok then if session.truck==entry then session.truck=nil end;return fail(ScootText('err.truckSpawnFailed')) end
    broadcast();local response=snapshot(src);response.netId=entry.netId;return response
end
lib.callback.register('loop-scoot:collection:truck',truckMutation)

lib.callback.register('loop-scoot:collection:uiAction',function(src,generation,requestId,kind,enabled,ticket)
    if stopped or not uiNumber(generation,9007199254740991) or not uiNumber(requestId,2147483647)
        or (kind~='duty' and kind~='truck') or (kind=='duty' and type(enabled)~='boolean')
        or (kind=='truck' and enabled~=nil) or not allowed(src,'uiAction',500) then return fail(ScootText('err.badOrFastRequest')) end
    local p,ped=validPlayer(src,sessions[src]);local view=uiViews[src]
    if not p or not view or view.identifier~=identity(p) or ticket~=view.ticket or not onFoot(ped)
        or not atDepot(ped,'manager',kind=='duty' and 3.0 or 4.0) then return fail(ScootText('err.talkToManager')) end
    local previous=uiReceipts[src];local order=uiOrder(previous,generation,requestId)
    if order<=0 then
        local response=snapshot(src)
        response.ok=order==0 and previous.status=='complete' and previous.ok==true
        response.message=order==0 and previous.message or ScootText('err.requestExpired')
        response.uiOperation=order==0 and uiReceipt(previous) or nil;return response
    end
    if previous and previous.status=='pending' then return fail(ScootText('err.serverBusy')) end
    local record={identifier=identity(p),generation=generation,requestId=requestId,status='pending'};uiReceipts[src]=record
    local ok,result=pcall(kind=='duty' and dutyMutation or truckMutation,src,enabled)
    if not ok or type(result)~='table' then result=fail(ScootText('err.serverActionFailed')) end
    record.status='complete';record.ok=result.ok==true;record.message=result.message
    result.uiOperation=uiReceipt(record);return result
end)
lib.callback.register('loop-scoot:collection:prepare',function(src,kind,id,slot,netId)
    if stopped or not allowed(src,'prepare',180) then return fail(ScootText('err.waitAMoment')) end
    local session,_,ped=sessionFor(src)
    if not session or session.pending then return fail(ScootText('err.handlingBusy')) end
    if type(kind)~='string' then return fail(ScootText('err.actionInvalid')) end
    if id~=nil and type(id)~='string' then return fail(ScootText('err.scooterUnknown')) end
    if netId~=nil and (not finite(netId) or netId<=0 or netId%1~=0) then return fail(ScootText('err.scooterUnknown')) end
    if kind=='pickup' and id==nil and netId then
        if session.carrying then return fail(ScootText('err.alreadyCarrying')) end
        local vehicle=NetworkGetEntityFromNetworkId(netId)
        if vehicle==0 or not DoesEntityExist(vehicle) or GetEntityModel(vehicle)~=joaat(C.scooterModel) then return fail(ScootText('err.scooterNotFound')) end
        if Entity(vehicle).state[TAG]~=nil then return fail(ScootText('err.alreadyFleet')) end
        for _,other in pairs(fleet) do
            if other.state=='adopting' and other.netId==netId then return fail(ScootText('err.scooterBusy')) end
        end
        id='adopt:'..nextToken()
        local p=position(GetEntityCoords(vehicle)) or {x=0,y=0,z=0}
        fleet[id]={id=id,home=copy(p),coords=copy(p),heading=GetEntityHeading(vehicle),kind='scooter',model=C.scooterModel,
            state='adopting',adopted=true,netId=netId,entity=vehicle}
    end
    if slot~=nil then
        local n=tonumber(slot)
        if not finite(n) or n%1~=0 or n<1 or n>64 then return fail(ScootText('err.slotInvalid')) end
        slot=tostring(math.floor(n))
    end
    if kind=='load' or kind=='drop' then id=id or session.carrying end
    if kind=='unload' and session.truck and slot then id=id or session.truck.slots[slot] end
    local entry=id and fleet[id]
    if entry and entry.reservedBy then return fail(ScootText('err.scooterBusy')) end
    if session.truck and slot and session.truck.reservedSlots[slot] then return fail(ScootText('err.slotReserved')) end
    local ok,message=validateAction(session,ped,kind,id,slot)
    if not ok then
        if entry and entry.state=='adopting' then fleet[id]=nil end
        return fail(message)
    end
    local duration=math.max(250,math.floor(tonumber(C[kind..'Ms']) or 1500))
    local token=nextToken()

    local approachMs=hasPlacement(kind) and PLACEMENT_TIMEOUT_MS or 0
    session.pending={token=token,kind=kind,id=id,slot=slot,startedAt=now(),duration=duration,netId=entry and entry.netId,
        deadline=now()+math.max(duration+approachMs+2000,C.actionTimeoutMs or 12000),ped=ped,pedCoords=position(GetEntityCoords(ped)),
        dropCoords=kind=='drop' and safeDrop(session) or nil,
        entityToken=entry and entry.entityToken,truckToken=session.truck and session.truck.entityToken}
    if entry then entry.reservedBy=token end
    if entry and entry.state=='adopting' then entry.pendingToken=token end
    if slot then session.truck.reservedSlots[slot]=token end
    broadcast()
    local response=snapshot(src)
    response.ok,response.token,response.duration,response.kind,response.id,response.slot=true,token,duration,kind,id,slot
    return response
end)
lib.callback.register('loop-scoot:collection:finish',function(src,token)
    local session,p,ped=sessionFor(src)
    local action=session and session.pending
    if stopped or type(token)~='string' or not action or action.token~=token then return fail(ScootText('err.actionExpired')) end
    if now()<action.startedAt+action.duration then return fail(ScootText('err.handlingUnfinished')) end
    local entry=action.id and fleet[action.id]
    local placement=hasPlacement(action.kind)
    local valid,message=validateAction(session,ped,action.kind,action.id,action.slot,placement and FINISH_REACH_GRACE or 0)

    local movementLimit=placement and ((C.interactionDistance or 1.8)+.75+FINISH_REACH_GRACE)
        or (action.kind=='drop' and FINISH_REACH_GRACE or 2.0)
    if now()>action.deadline or ped~=action.ped or distance(GetEntityCoords(ped),action.pedCoords)>movementLimit
        or (entry and entry.reservedBy~=action.token)
        or (entry and action.entityToken~=entry.entityToken)
        or (action.truckToken and (not session.truck or session.truck.entityToken~=action.truckToken)) then valid=false;message=ScootText('err.contextChangedCancel') end
    if not valid then cancelPending(session);broadcast();return fail(message) end

    if entry and entry.state=='adopting' then entry.pendingToken=nil end
    cancelPending(session)
    local paid=0
    if action.kind=='pickup' then
        if entry.state=='adopting' then
            local vehicle=entry.entity
            if vehicle and DoesEntityExist(vehicle) and Entity(vehicle).state.loopScoot~=nil then
                local taken,message=false,nil
                if type(ScootRentalCollect)=='function' then taken,message=ScootRentalCollect(vehicle,src) end
                if not taken then fleet[entry.id]=nil;broadcast();return fail(message or ScootText('err.rentalNoLongerCollectable')) end
            elseif vehicle and DoesEntityExist(vehicle) and GetEntityModel(vehicle)==joaat(C.scooterModel)
                and Entity(vehicle).state[TAG]==nil then DeleteEntity(vehicle) end
            entry.entity,entry.netId,entry.pendingToken=nil,nil,nil
        else deleteOwned(entry) end
        entry.state,entry.carrier='carried',src;session.carrying=entry.id;session.carryToken=action.token
        entry.coords=position(GetEntityCoords(ped));session.lastGround={x=entry.coords.x,y=entry.coords.y,z=entry.coords.z-ScootCollectionMotion.originToGround,heading=GetEntityHeading(ped)}
    elseif action.kind=='drop' then
        session.carrying=nil;session.carryToken=nil;ground(entry,action.dropCoords or safeDrop(session))
    elseif action.kind=='load' then
        session.carrying=nil;session.carryToken=nil;session.truck.slots[action.slot]=entry.id
        entry.state,entry.carrier,entry.owner,entry.truckNetId,entry.slot='loaded',nil,src,session.truck.netId,action.slot
    elseif action.kind=='unload' then
        session.truck.slots[action.slot]=nil;session.carrying=entry.id;session.carryToken=action.token
        entry.state,entry.carrier,entry.owner,entry.truckNetId,entry.slot='carried',src,nil,nil,nil
    elseif action.kind=='service' then
        local count=0
        for slot,id in pairs(session.truck.slots) do
            local item=fleet[id]
            if item and item.state=='loaded' and item.owner==src and item.slot==slot then count=count+1 end
        end
        local reward=count*math.max(0,math.floor(tonumber(C.payPerScooter) or 0))
        if reward>0 then
            local account=C.payAccount or 'money'
            if ScootBridge.AccountBalance(p,account)==nil then
                print(('[%s] Collection reward %s deferred: account %s unavailable for %s'):format(RESOURCE,reward,account,session.identifier))
                broadcast();return fail(ScootText('err.payNoAccount'))
            end
            local paidOk,errorMessage=ScootBridge.Credit(p,account,reward,'LOOP SCOOT - collecte')
            if not paidOk then
                print(('[%s] Collection reward %s deferred for %s: %s'):format(RESOURCE,reward,session.identifier,tostring(errorMessage)))
                broadcast();return fail(ScootText('err.payFailed'))
            end
        end
        -- Keep the load available for retry until the synchronous money adapter confirms.
        for slot,id in pairs(session.truck.slots) do
            local item=fleet[id]
            if item and item.state=='loaded' and item.owner==src and item.slot==slot then
                item.state,item.owner,item.truckNetId,item.slot='cooldown',nil,nil,nil
                item.respawnAt=now()+math.max(5000,C.respawnMs or 600000);item.coords=copy(item.home)
                if item.adopted then fleet[id]=nil end
            end
            session.truck.slots[slot]=nil
        end
        session.delivered=session.delivered+count
        if reward>0 then
            session.earned=session.earned+reward
            paid=reward
        end
    end
    broadcast();local response=snapshot(src);response.paid=paid;return response
end)
lib.callback.register('loop-scoot:collection:cancel',function(src,token)
    local session=sessionFor(src)
    if not session or not session.pending or type(token)~='string' or session.pending.token~=token then return fail(ScootText('err.alreadyFinished')) end
    cancelPending(session);broadcast();return snapshot(src)
end)
lib.callback.register('loop-scoot:collection:recover',function(src,sessionToken,carryId,carryToken)
    if not allowed(src,'recover',1000) then return fail(ScootText('err.waitAMoment')) end
    local session=sessions[src]
    if not session or identity(player(src))~=session.identifier then return fail(ScootText('err.shiftNotFound')) end

    if sessionToken~=nil and (session.token~=sessionToken or session.carrying~=carryId
        or session.carryToken~=carryToken or session.pending) then return snapshot(src) end
    cancelPending(session);recoverCarry(session);broadcast();return snapshot(src)
end)
lib.callback.register('loop-scoot:collection:place',function(src)
    if not IsPlayerAceAllowed(src,Config.AdminAce or 'loop.scoot.admin') then return fail(ScootText('err.adminOnly')) end
    if C.depot.nativeMlo then return fail(ScootText('err.mloFixed')) end
    if not allowed(src,'place',1000) then return fail(ScootText('err.waitAMoment')) end
    local _,ped=validPlayer(src)
    if not ped or not onFoot(ped) then return fail(ScootText('err.standOnDepot')) end
    for _ in pairs(sessions) do return fail(ScootText('err.depotBusy')) end
    local p=position(GetEntityCoords(ped));local heading=GetEntityHeading(ped)
    if not p or not finite(heading) then return fail(ScootText('err.badCoords')) end

    local placement={x=p.x,y=p.y,z=p.z-0.9,heading=heading%360}
    SetResourceKvp('collection-depot',json.encode(placement))
    for k,v in pairs(placement) do depot[k]=v end
    broadcast();return snapshot(src)
end)

local saved=GetResourceKvpString('collection-depot')
if saved and not C.depot.nativeMlo then
    local ok,p=pcall(json.decode,saved)
    if ok and type(p)=='table' and position(p) and finite(p.heading) then for _,k in ipairs({'x','y','z','heading'}) do depot[k]=p[k] end end
end
AddEventHandler('playerDropped',function()
    local src=source;local session=sessions[src]
    if session then cleanup(session,'disconnected') end;limits[src]=nil;uiReceipts[src]=nil;uiViews[src]=nil
end)
ScootBridge.OnPlayerUnloaded(function(src)
    local session=sessions[src];if session then cleanup(session,'logout') end;limits[src]=nil;uiReceipts[src]=nil;uiViews[src]=nil
end)
AddEventHandler('onResourceStop',function(resource)
    if resource~=RESOURCE then return end
    stopped=true
    for _,session in pairs(sessions) do
        cancelPending(session);deleteOwned(session.truck)
        TriggerClientEvent('loop-scoot:collection:reset',session.source,'stopped',session.token)
    end
    for _,entry in pairs(fleet) do deleteOwned(entry) end
    sessions={}
end)
CreateThread(function()
    local nextBroadcast=now()+(C.snapshotMs or 3000)
    while not stopped do
        Wait(1000)
        if stopped then break end
        local clean={}
        for src,session in pairs(sessions) do
            local _,_,ped=sessionFor(src)
            if not ped then clean[#clean+1]=session
            elseif session.truck and session.truck.netId and not entityValid(session.truck) then clean[#clean+1]=session
            else
                if session.truck and not session.truck.keysGranted then truckKeys(session.truck, true) end
                local p=position(GetEntityCoords(ped))
                if p and onFoot(ped) then session.lastGround={x=p.x,y=p.y,z=p.z-ScootCollectionMotion.originToGround,heading=GetEntityHeading(ped)} end
                if session.pending and now()>session.pending.deadline then cancelPending(session);broadcast() end
            end
        end
        for _,session in ipairs(clean) do cleanup(session,'session_lost') end
        if initialized and not initializingFleet then
            for _,entry in pairs(fleet) do
                if entry.state=='ground' and not entry.spawning and not ownsEntity(entry) then
                    entry.entity,entry.netId=nil,nil;entry.state='cooldown';entry.respawnAt=now()+5000;entry.reservedBy=nil
                elseif entry.state=='cooldown' and now()>=(entry.respawnAt or 0) then ground(entry,entry.home) end
            end
        end
        if now()>=nextBroadcast then broadcast();nextBroadcast=now()+(C.snapshotMs or 3000) end
    end
end)

RegisterNetEvent('loop-scoot:cine:resetJob', function()
    local src = source
    if GetResourceState('loop-cine') ~= 'started' or not ScootBridge.IsAdmin(src) then return end
    local session = sessions[src]
    if session then cleanup(session, 'shift_ended') end
end)
