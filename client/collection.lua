local C = Config.Collection
if not C or not C.enabled then return end
local Motion = ScootCollectionMotion
if type(AddTextEntry)=='function' then
    AddTextEntry('SCOOTTRUCK',C.truck.displayName or 'SCOOT CARGO 26')
    AddTextEntry('LOOP','LOOP')
end
local NS = 'loop-scoot:collection:'
local state = { fleet = {}, trucks = {}, session = nil, actions = {} }
local depot = C.depot
local stopped, busy, action, wardrobe, workshop = false, false, nil, nil, nil
local visuals, marks, initialized = {}, {}, {}
local observedMotions, groundVisuals = {}, {}
local visualStage = {}
local localCarry, uniformApplied, lastSnapshot, renderOrigin = nil, false, 0, nil
local resetSessions, dressingSession, ownedEntities, retiredEpochs = {}, nil, {}, {}
local workerGeneration=0
local engineRequest, lastEngineRequest=nil,-10000
local recoveryRequest, lastRecoveryRequest=nil,-10000
local placementHold
local assetsRequestedAt=-1000
local collectionUi, uiMutation, uiReading, uiGarageCache, uiTicket
local uiSerial, uiCooldown=math.max(0,GetGameTimer())*1000,0
local emitCollectionState, closeCollectionUi, retireCollectionEpoch
local adoptScan={at=0,vehicle=0,netId=0}

ScootCollectionPickupTarget=nil

local function alive(ped)
    return ped ~= 0 and DoesEntityExist(ped) and not IsEntityDead(ped) and not IsPedRagdoll(ped)
end

local function tell(message, kind)
    ScootUI.Notify(message,kind)
end

local function scootProgressBar(options)
    return ScootUI.Progress(options)
end
local function dist(a,b) return ScootCollection.Distance(a,b) end
local function world(offset) return ScootCollection.World(depot,offset) end
local function netEntity(id)
    if type(id) ~= 'number' or id <= 0 or not NetworkDoesNetworkIdExist(id) then return 0 end
    local entity = NetworkGetEntityFromNetworkId(id)
    return entity and DoesEntityExist(entity) and entity or 0
end
local function collectionEntity(id,kind,token,itemId)
    local entity=netEntity(id)
    if entity==0 or token==nil then return 0 end
    local tag=Entity(entity).state.loopScootCollection
    local expected=kind=='truck' and C.truck.model or C.scooterModel
    if GetEntityModel(entity)~=joaat(expected) or type(tag)~='table' or tag.kind~=kind
        or tag.token~=token or (itemId and tag.id~=itemId) then return 0 end
    return entity
end
local function own(entity,hash)
    if entity and entity~=0 then ownedEntities[entity]=hash end
    return entity
end
local function model(name, timeout)
    local hash=joaat(name)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local deadline=GetGameTimer()+(timeout or 6000)
    while not HasModelLoaded(hash) and GetGameTimer()<deadline and not stopped do Wait(20) end
    return HasModelLoaded(hash) and hash or nil
end
local function modelsLoaded()
    for _,name in ipairs(C.carryModels or {C.carryModel}) do
        if not model(name) then return false end
    end
    return true
end
local function clipOf(kind,side)
    local clip=C.animations[kind]
    if type(clip)~='table' then return nil end
    if clip.sided and side then return {dict=clip.dict,clip=clip.clip..(side<0 and '_left' or '_right'),flag=clip.flag} end
    return clip
end
local function sameClip(a,b) return a and b and a.dict==b.dict and a.clip==b.clip end
local function nativeAnimationPhase(ped,kind,side)
    local clip=clipOf(kind,side)
    if clip and IsEntityPlayingAnim(ped,clip.dict,clip.clip,3) then
        local phase=GetEntityAnimCurrentTime(ped,clip.dict,clip.clip)
        if type(phase)=='number' and phase==phase and phase>=0 and phase<=1 then return phase end
    end
end
local function animationPhase(ped,kind,fallback,side)
    return nativeAnimationPhase(ped,kind,side) or math.max(0,math.min(1,fallback or 0))
end
local function warmCollectionAssets()
    if GetGameTimer()-assetsRequestedAt<500 then return end
    assetsRequestedAt=GetGameTimer()
    for _,name in ipairs(C.carryModels or {C.carryModel}) do
        local hash=joaat(name)
        if not HasModelLoaded(hash) then RequestModel(hash) end
    end
    local clip=clipOf('pickup')
    if clip and not HasAnimDictLoaded(clip.dict) then RequestAnimDict(clip.dict) end
end
local function animation(kind)
    kind=kind or 'carry'
    local clip=clipOf(kind)
    if not clip then return true end
    RequestAnimDict(clip.dict)
    local deadline=GetGameTimer()+3000
    while not HasAnimDictLoaded(clip.dict) and GetGameTimer()<deadline and not stopped do Wait(20) end
    if not HasAnimDictLoaded(clip.dict) then return false,ScootText('err.animsMissing') end

    local expected=not clip.vanilla and Motion.durations[kind] or nil
    local variants=clip.sided and {clipOf(kind,-1),clipOf(kind,1)} or {clip}
    for _,variant in ipairs(variants) do
        local duration=GetAnimDuration(variant.dict,variant.clip)
        if expected and (type(duration)~='number' or duration~=duration or math.abs(duration*1000-expected)>80) then
            return false,ScootText('err.animsStale')
        end
    end
    return true
end
local function remove(entity)
    if entity and entity~=0 and ownedEntities[entity] and DoesEntityExist(entity)
        and not NetworkGetEntityIsNetworked(entity) and GetEntityModel(entity)==ownedEntities[entity] then DeleteEntity(entity) end
    if entity then ownedEntities[entity]=nil end
end
local function fleetItem(id)
    for _,item in ipairs(state.fleet or {}) do if item.id==id then return item end end
end
local function workTruck()
    if not state.session then return nil,0 end
    for _,truck in ipairs(state.trucks or {}) do
        if truck.netId==state.session.truckNetId then return truck,collectionEntity(truck.netId,'truck',truck.token,truck.id) end
    end
    return nil,0
end
local function reconcileUiOperation(snapshot)
    local receipt=snapshot.uiOperation
    if uiMutation and type(receipt)=='table' and receipt.uiGeneration==uiMutation.generation
        and receipt.requestId==uiMutation.id and receipt.status=='complete' and uiMutation.complete then
        local result={};for k,v in pairs(snapshot) do result[k]=v end
        result.ok=receipt.ok==true;result.message=receipt.message
        if receipt.retiredTicket then uiTicket=nil end
        uiMutation.complete(result)
    end
end
local function receive(snapshot)
    if type(snapshot)~='table' or snapshot.ok==false then return end
    if type(snapshot.fleet)~='table' or type(snapshot.trucks)~='table' then return end
    if snapshot.epoch and retiredEpochs[snapshot.epoch] then return end
    if state.epoch and snapshot.epoch==state.epoch then
        if type(snapshot.revision)=='number' and type(state.revision)=='number' and snapshot.revision<state.revision then return end
        if snapshot.revision==state.revision and type(snapshot.serverNow)=='number'
            and type(state.serverNow)=='number' and snapshot.serverNow<state.serverNow then return end
    end
    if state.epoch and snapshot.epoch and state.epoch~=snapshot.epoch then
        retiredEpochs[state.epoch]=true
        if retireCollectionEpoch then retireCollectionEpoch() end
        if closeCollectionUi then closeCollectionUi('serverRestart') end
        uiMutation=nil;uiGarageCache=nil;uiTicket=nil
    end
    if snapshot.session and resetSessions[snapshot.session.token] then snapshot.session=nil end
    state=snapshot
    if state.session then warmCollectionAssets() end
    if snapshot.depot then
        depot={}
        for key,value in pairs(C.depot) do depot[key]=value end
        for key,value in pairs(snapshot.depot) do depot[key]=value end
    end
    lastSnapshot=GetGameTimer()
    local session=state.session
    local key=session and session.token or false
    local truck=session and session.truckNetId or 0
    if snapshot.garage then uiGarageCache={value=snapshot.garage,session=key,truck=truck}
    elseif uiGarageCache and (uiGarageCache.session~=key or uiGarageCache.truck~=truck) then uiGarageCache=nil end
    if type(snapshot.uiTicket)=='string' then uiTicket=snapshot.uiTicket end
    reconcileUiOperation(snapshot)
    if emitCollectionState then emitCollectionState() end
    return true
end
local function call(name,...)
    local ok,result=pcall(lib.callback.await,NS..name,false,...)
    if not ok or type(result)~='table' then return {ok=false,message=ScootText('err.serverSilentRetry')} end
    if result.fleet then receive(result) end
    return result
end

local function settleAction(name,token,generation)
    if stopped or generation~=workerGeneration then return {ok=false,retired=true} end
    local request={}
    CreateThread(function()
        if not stopped and generation==workerGeneration then request.result=call(name,token) end
    end)
    local deadline=GetGameTimer()+4000
    while not request.result and not stopped and generation==workerGeneration and GetGameTimer()<deadline do Wait(0) end
    if stopped or generation~=workerGeneration then return {ok=false,retired=true} end
    if name=='finish' and (not request.result or not request.result.ok) then
        CreateThread(function() if not stopped and generation==workerGeneration then call('cancel',token) end end)
    end
    if request.result then return request.result end
    return {ok=false,message=ScootText('err.serverLate')}
end
local function requestCarryRecovery()
    local session=state.session
    if recoveryRequest and GetGameTimer()-lastRecoveryRequest>=4000 then recoveryRequest=nil end
    if not session or not session.carrying or recoveryRequest or GetGameTimer()-lastRecoveryRequest<1500 then return end
    local request={session=session.token,id=session.carrying,carryToken=session.carryToken}
    recoveryRequest=request;lastRecoveryRequest=GetGameTimer()
    CreateThread(function()
        call('recover',request.session,request.id,request.carryToken)
        if recoveryRequest==request then recoveryRequest=nil end
    end)
end
local function configureWorkTruck(entity)
    if SetVehicleHasBeenOwnedByPlayer then SetVehicleHasBeenOwnedByPlayer(entity,true) end
    if SetVehicleNeedsToBeHotwired then SetVehicleNeedsToBeHotwired(entity,false) end
end
local function toggleWorkTruckEngine()
    if stopped or engineRequest or GetGameTimer()-lastEngineRequest<1000 then return end
    local ped=PlayerPedId()
    local truck,entity=workTruck()
    local me=GetPlayerServerId(PlayerId())
    if busy or not alive(ped) or not truck or entity==0 or truck.owner~=me or not state.session
        or state.session.carrying or GetVehiclePedIsIn(ped,false)~=entity or GetPedInVehicleSeat(entity,-1)~=ped then
        return tell(ScootText('err.sitInTruck'),'error')
    end
    local request={session=state.session.token,netId=truck.netId,token=truck.token,id=truck.id,
        ped=ped,generation=workerGeneration,startedAt=GetGameTimer()}
    engineRequest=request;lastEngineRequest=request.startedAt

    CreateThread(function()
        request.result=call('engine',request.session,request.netId,request.token)
        if request.expired and engineRequest==request then engineRequest=nil end
    end)
    while not request.result and not stopped and request.generation==workerGeneration
        and GetGameTimer()-request.startedAt<4000 do Wait(25) end
    local result=request.result
    if not result then
        request.expired=true
        if not stopped then tell(ScootText('err.engineAuthExpired'),'error') end
        return
    end
    local function current()
        local currentTruck,currentEntity=workTruck()
        return not stopped and not busy and request.generation==workerGeneration and PlayerPedId()==ped
            and alive(ped) and state.session and state.session.token==request.session and not state.session.carrying
            and currentTruck and currentEntity==entity and currentTruck.netId==request.netId
            and currentTruck.token==request.token and currentTruck.id==request.id and currentTruck.owner==me
            and Entity(entity).state.loopScootCollection.owner==me and not IsEntityDead(entity)
            and GetVehiclePedIsIn(ped,false)==entity and GetPedInVehicleSeat(entity,-1)==ped
    end
    if result.ok~=true then
        if engineRequest==request then engineRequest=nil end
        if not stopped then tell(result.message or ScootText('err.engineRefused'),'error') end
        return
    end
    local authorized=result.sessionToken==request.session and result.netId==request.netId
        and result.entityToken==request.token and result.id==request.id and result.owner==me
        and result.validForMs==1500
    local deadline=math.min(request.startedAt+4000,GetGameTimer()+1500)
    while authorized and current() and not NetworkHasControlOfEntity(entity) and GetGameTimer()<deadline do
        NetworkRequestControlOfEntity(entity);Wait(25)
    end
    if authorized and GetGameTimer()<deadline and current() and NetworkHasControlOfEntity(entity) then
        local enable=not GetIsVehicleEngineRunning(entity)
        local fuel=Entity(entity).state.fuelLevel
        if type(fuel)~='number' then fuel=100.0 end
        if enable and fuel>0 and GetVehicleFuelLevel and GetVehicleFuelLevel(entity)<=0 then SetVehicleFuelLevel(entity,fuel+0.0) end
        if enable and fuel>0 and not IsEntityDead(entity) and GetVehicleEngineHealth and GetVehicleEngineHealth(entity)<=0 then SetVehicleEngineHealth(entity,1000.0) end
        if enable and (IsEntityDead(entity) or fuel<=0) then
            tell(ScootText('err.truckBroken'),'error')
        else
            configureWorkTruck(entity)
            SetVehicleEngineOn(entity,enable,false,true)
            tell(enable and ScootText('notify.engineOn') or ScootText('notify.engineOff'),'success')
        end
    elseif not stopped then tell(ScootText('err.engineChanged'),'error') end
    if engineRequest==request then engineRequest=nil end
end
RegisterCommand('scootmoteur',function() CreateThread(toggleWorkTruckEngine) end,false)
RegisterNetEvent(NS..'sync',function(snapshot)
    if source~=65535 then return end
    receive(snapshot)
end)

local function stopOwnedPose(ped,kind)
    if not DoesEntityExist(ped) then return end
    local carry=clipOf('carry')
    for name,clip in pairs(C.animations) do
        if type(clip)=='table' and (kind==nil or name==kind) and not sameClip(clip,carry) then
            local variants=clip.sided and {clipOf(name,-1),clipOf(name,1)} or {clip}
            for _,v in ipairs(variants) do
                if IsEntityPlayingAnim(ped,v.dict,v.clip,3) then StopAnimTask(ped,v.dict,v.clip,3.0) end
            end
        end
    end
end
local function clearCarry()
    if localCarry then
        local ped=localCarry.ped

        local carry=clipOf('carry')
        if carry and DoesEntityExist(ped) and IsEntityPlayingAnim(ped,carry.dict,carry.clip,3) then
            StopAnimTask(ped,carry.dict,carry.clip,3.0)
        end
        localCarry=nil
    end
end

local function uniformInteger(value,minimum,maximum)
    return type(value)=='number' and value==value and value%1==0
        and value>=minimum and value<=maximum
end
local function uniformLog(reason,detail)
    local ok,text=pcall(json.encode,detail or {})
    print(('[loop-scoot uniform] %s %s'):format(tostring(reason),ok and text or tostring(detail)))
end
local function nativeTrue(value) return value==true or value==1 end
local function sameCollection(a,b)
    if a==b then return true end
    return type(a)=='string' and type(b)=='string' and a:lower()==b:lower()
end
local function sameUniformPiece(a,b)
    if not (a and b and a.kind==b.kind and a.id==b.id and (a.global==true)==(b.global==true)) then return false end
    return sameCollection(a.collection,b.collection)
        and a.drawable==b.drawable and a.texture==b.texture and a.palette==b.palette
end
local function readGlobalPiece(ped,piece)
    local ok,current=pcall(function()
        local v={kind=piece.kind,id=piece.id,global=true}
        if v.kind=='component' then
            v.drawable=GetPedDrawableVariation(ped,v.id)
            v.texture=GetPedTextureVariation(ped,v.id)
            v.palette=GetPedPaletteVariation(ped,v.id)
            if not uniformInteger(v.palette,0,3) then v.palette=0 end
        else
            v.drawable=GetPedPropIndex(ped,v.id)
            v.texture=(type(v.drawable)=='number' and v.drawable>=0) and GetPedPropTextureIndex(ped,v.id) or 0
        end
        if not uniformInteger(v.drawable,v.kind=='prop' and -1 or 0,2147483647)
            or not uniformInteger(v.texture,0,2147483647) then return nil end
        return v
    end)
    return ok and current or nil
end
local function readUniformPiece(ped,piece)
    if piece.global then return readGlobalPiece(ped,piece) end
    local ok,current=pcall(function()
        local v={kind=piece.kind,id=piece.id}
        if v.kind=='component' then
            v.collection=GetPedDrawableVariationCollectionName(ped,v.id)
            v.drawable=GetPedDrawableVariationCollectionLocalIndex(ped,v.id)
            v.texture=GetPedTextureVariation(ped,v.id);v.palette=GetPedPaletteVariation(ped,v.id)
            if not uniformInteger(v.palette,0,3) then v.palette=0 end
        else
            if GetPedPropIndex(ped,v.id)<0 then v.drawable=-1;v.texture=0;return v end
            v.collection=GetPedPropCollectionName(ped,v.id)
            v.drawable=GetPedPropCollectionLocalIndex(ped,v.id)
            v.texture=GetPedPropTextureIndex(ped,v.id)
        end
        if type(v.collection)~='string' or not uniformInteger(v.drawable,0,2147483647)
            or not uniformInteger(v.texture,0,2147483647) then return nil end
        return v
    end)
    return ok and current or nil
end
local function uniformPieceAvailable(ped,v)
    local ok,valid=pcall(function()
        if v.global then
            if v.kind=='component' then return type(SetPedComponentVariation)=='function' end
            if v.drawable<0 then return type(ClearPedProp)=='function' end
            return type(SetPedPropIndex)=='function'
        end
        if v.kind=='component' then
            if type(SetPedCollectionComponentVariation)~='function' then return false end
            return nativeTrue(IsPedCollectionComponentVariationValid(ped,v.id,v.collection,v.drawable,v.texture))
        end
        if v.drawable<0 then return type(ClearPedProp)=='function' end
        if type(SetPedCollectionPropIndex)~='function' then return false end
        return v.drawable<GetNumberOfPedCollectionPropDrawableVariations(ped,v.id,v.collection)
            and v.texture<GetNumberOfPedCollectionPropTextureVariations(ped,v.id,v.collection,v.drawable)
    end)
    return ok and valid==true
end
local function setUniformPiece(ped,v)
    if v.global then
        if v.kind=='component' then SetPedComponentVariation(ped,v.id,v.drawable,v.texture,v.palette or 0)
        elseif v.drawable<0 then ClearPedProp(ped,v.id)
        else SetPedPropIndex(ped,v.id,v.drawable,v.texture,true) end
    elseif v.kind=='component' then
        SetPedCollectionComponentVariation(ped,v.id,v.collection,v.drawable,v.texture,v.palette)
    elseif v.drawable<0 then ClearPedProp(ped,v.id)
    else SetPedCollectionPropIndex(ped,v.id,v.collection,v.drawable,v.texture,true) end
end
local function knownCollections(ped)
    local names={}
    pcall(function()
        local count=GetPedCollectionsCount(ped)
        if type(count)~='number' then return end
        for i=0,math.min(count,64)-1 do names[#names+1]=GetPedCollectionName(ped,i) end
    end)
    return names
end
local function targetStatus(ped,piece)
    if piece.kind=='component' then
        if type(SetPedCollectionComponentVariation)~='function' or type(IsPedCollectionComponentVariationValid)~='function' then
            return false,'natives',{collection=piece.collection}
        end
        local callOk,valid=pcall(IsPedCollectionComponentVariationValid,ped,piece.id,piece.collection,piece.drawable,piece.texture)
        if callOk and nativeTrue(valid) then return true end
        local countOk,count=pcall(GetNumberOfPedCollectionDrawableVariations,ped,piece.id,piece.collection)
        local detail={collection=piece.collection,component=piece.id,drawable=piece.drawable,texture=piece.texture,
            model=GetEntityModel(ped),valid=callOk and valid or ('error:'..tostring(valid)),
            drawableCount=countOk and count or nil,known=knownCollections(ped)}
        if countOk and type(count)=='number' and count>piece.drawable then return false,'drawable',detail end
        return false,'streamed',detail
    end
    if uniformPieceAvailable(ped,piece) then return true end
    return false,'streamed',{collection=piece.collection,prop=piece.id,drawable=piece.drawable,texture=piece.texture}
end
local function uniformPlan(ped,outfit)
    if type(outfit)~='table' or type(outfit.components)~='table'
        or (outfit.props~=nil and type(outfit.props)~='table') then return nil,'config',{} end
    local pieces,seen={},{}
    for _,group in ipairs({{kind='component',values=outfit.components,maximum=11},
        {kind='prop',values=outfit.props or {},maximum=7}}) do
        for _,v in ipairs(group.values) do
            if type(v)~='table' then return nil,'config',{kind=group.kind} end
            local piece={kind=group.kind,id=v[1],collection=v.collection,
                drawable=v.drawable or v[2],texture=v.texture or v[3],palette=group.kind=='component' and (v.palette or 0) or nil}
            if not uniformInteger(piece.id,0,group.maximum) or not uniformInteger(piece.drawable,group.kind=='prop' and -1 or 0,2147483647)
                or not uniformInteger(piece.texture,0,2147483647)
                or (piece.kind=='component' and not uniformInteger(piece.palette,0,3)) then return nil,'config',piece end
            if piece.kind=='prop' and piece.drawable==-1 then piece.collection=nil;piece.texture=0
            elseif type(piece.collection)~='string' then return nil,'config',piece end
            local key=piece.kind..piece.id
            if seen[key] then return nil,'config',piece end
            local available,reason,detail=targetStatus(ped,piece)
            if not available then return nil,reason,detail end
            seen[key]=true
            local previous=readUniformPiece(ped,piece)
            if not previous or not uniformPieceAvailable(ped,previous) then
                local fallback=readGlobalPiece(ped,piece)
                if not fallback or not uniformPieceAvailable(ped,fallback) then
                    return nil,'previous',{kind=piece.kind,component=piece.id,collectionRead=previous~=nil}
                end
                uniformLog('previous-saved-by-global-index',fallback)
                previous=fallback
            end
            if not sameUniformPiece(previous,piece) then pieces[#pieces+1]={before=previous,expected=piece} end
        end
    end
    return pieces
end
local UNIFORM_FAILURE_TEXT={config='err.uniformConfig',natives='err.uniformNatives',streamed='err.uniformNotStreamed',
    drawable='err.uniformDrawable',previous='err.uniformPrevious'}
local function uniformFailure(reason,detail)
    uniformLog('refused:'..tostring(reason),detail)
    tell(ScootText(UNIFORM_FAILURE_TEXT[reason] or 'err.uniformNotStreamed'),'error')
end
local function restoreUniform(rollback)
    if not wardrobe then uniformApplied=false;return true end
    local ped=PlayerPedId()
    if ped~=wardrobe.ped or GetEntityModel(ped)~=wardrobe.model then
        wardrobe=nil;uniformApplied=false;return true
    end
    local remaining={}
    for _,entry in ipairs(wardrobe.pieces) do
        local current=readUniformPiece(ped,entry.expected)
        -- A different outfit/appearance resource owns any slot that no longer matches.
        if not current and not rollback then
            remaining[#remaining+1]=entry -- Ownership is unknown: do not overwrite the slot.
        elseif rollback or sameUniformPiece(current,entry.expected) then
            local restored=false
            if uniformPieceAvailable(ped,entry.before) then
                local ok=pcall(setUniformPiece,ped,entry.before)
                restored=ok and sameUniformPiece(readUniformPiece(ped,entry.before),entry.before)
            end
            if not restored then
                uniformLog('restore-failed',{before=entry.before,now=readUniformPiece(ped,entry.before)})
                entry.expected=readUniformPiece(ped,entry.expected) or entry.expected
                remaining[#remaining+1]=entry
            end
        end
    end
    if #remaining>0 then
        wardrobe.pieces=remaining;uniformApplied=true
        if not wardrobe.warned then tell(ScootText('err.outfitPieceMissing'),'error');wardrobe.warned=true end
        return false
    end
    wardrobe=nil;uniformApplied=false;return true
end
local function selectOutfit(uniforms,hash)
    local outfit=hash==joaat('mp_m_freemode_01') and uniforms.male or hash==joaat('mp_f_freemode_01') and uniforms.female
    if type(outfit)~='table' or uniforms.keepOwnOutfit~=true or type(outfit.components)~='table' then return outfit end
    local only={}
    for _,v in ipairs(outfit.components) do
        if type(v)=='table' and v[1]==11 then only[#only+1]=v end
    end
    return {components=only,props={}}
end
local function dress()
    if busy or not state.session or state.session.carrying then return end
    if uniformApplied then
        if restoreUniform() then tell(ScootText('notify.uniformRestored')) end
        return
    end
    local ped=PlayerPedId();local hash=GetEntityModel(ped)
    local uniforms=type(C.uniform)=='table' and C.uniform or {}
    local outfit=selectOutfit(uniforms,hash)
    if not outfit then tell(ScootText('err.notFreemode'),'error');return end
    local firstPlan,firstReason,firstDetail=uniformPlan(ped,outfit)
    if not firstPlan then
        uniformFailure(firstReason,firstDetail);return
    end
    busy=true
    local sessionToken=state.session.token;dressingSession=sessionToken

    local progressOk,complete=pcall(scootProgressBar,{duration=3000,label=ScootText('progress.clothes'),canCancel=true,
        disable={move=true,car=true,combat=true},anim={dict='clothingtie',clip='try_tie_positive_a'}})
    if not progressOk then
        if dressingSession==sessionToken then dressingSession=nil;busy=false end
        tell(ScootText('err.uniformFailed'),'error');return
    end
    if complete and not stopped and state.session and state.session.token==sessionToken
        and ped==PlayerPedId() and GetEntityModel(ped)==hash and alive(ped) then
        local plan,reason,detail=uniformPlan(ped,outfit)
        if not plan then
            uniformLog('gone:'..tostring(reason),detail)
            tell(ScootText('err.uniformGone'),'error')
        else
            wardrobe={ped=ped,model=hash,pieces={}}
            local applied=pcall(function()
                for _,entry in ipairs(plan) do
                    wardrobe.pieces[#wardrobe.pieces+1]=entry
                    setUniformPiece(ped,entry.expected)
                    local got=readUniformPiece(ped,entry.expected)
                    if not sameUniformPiece(got,entry.expected) then
                        uniformLog('readback-mismatch',{expected=entry.expected,got=got})
                        error('SCOOT collection piece did not apply')
                    end
                end
            end)
            if applied then uniformApplied=true
            else restoreUniform(true);tell(ScootText('err.uniformFailed'),'error') end
        end
    end
    if dressingSession==sessionToken then dressingSession=nil;busy=false end
end

RegisterCommand('scootpolo',function()
    local ped=PlayerPedId();local hash=GetEntityModel(ped)
    local uniforms=type(C.uniform)=='table' and C.uniform or {}
    local outfit=selectOutfit(uniforms,hash)
    if not outfit then print('[loop-scoot uniform] dry-run: not a freemode ped');return end
    local plan,reason,detail=uniformPlan(ped,outfit)
    if plan then uniformLog('dry-run:ok',{pieces=#plan,first=plan[1]})
    else uniformLog('dry-run:refused:'..tostring(reason),detail) end
end,false)

local function clearMarker(key)
    local mark=marks[key]
    if not mark then return end
    if mark.native and DoesBlipExist(mark.native) then RemoveBlip(mark.native) end
    if mark.backend=='loop' and GetResourceState('loop-pausemenu')=='started' then
        pcall(function() exports['loop-pausemenu']:setBlip(key,nil) end)
    end
    marks[key]=nil
end
local function marker(key,label,point,sprite,color,scale)
    local backend=GetResourceState('loop-pausemenu')=='started' and 'loop' or 'native'
    if marks[key] and marks[key].backend~=backend then clearMarker(key) end
    local mark=marks[key] or {backend=backend};marks[key]=mark
    if backend=='loop' then
        local ok=pcall(function() exports['loop-pausemenu']:setBlip(key,{id=key,name=label,sprite=sprite,
            x=point.x,y=point.y,z=point.z,color=color,scale=scale,alpha=255,shortRange=false,display=4}) end)
        if not ok then marks[key]=nil end
    else
        if not mark.native then mark.native=AddBlipForCoord(point.x,point.y,point.z) end
        SetBlipCoords(mark.native,point.x,point.y,point.z);SetBlipSprite(mark.native,sprite)
        SetBlipColour(mark.native,color);SetBlipScale(mark.native,scale);SetBlipAsShortRange(mark.native,false)
        BeginTextCommandSetBlipName('STRING');AddTextComponentString(label);EndTextCommandSetBlipName(mark.native)
    end
end
local function updateMarkers()
    local keep={}
    local function put(id,label,point,sprite,color,scale)
        local key='loop-scoot:collection:'..id;keep[key]=true;marker(key,label,point,sprite,color,scale)
    end
    put('depot',ScootText('blip.depot'),world(C.depot.manager),566,2,.85)
    if state.session then
        for _,item in ipairs(state.fleet or {}) do
            if item.coords and item.state=='ground' then put(item.id,ScootText('blip.collect'),item.coords,348,2,.62) end
        end
        for _,item in ipairs(state.rentals or {}) do
            if item.coords then put('rental:'..tostring(item.netId),ScootText('blip.rental'),item.coords,348,5,.50) end
        end
        for _,truck in ipairs(state.trucks or {}) do
            if truck.owner==GetPlayerServerId(PlayerId()) and truck.coords then put('truck',ScootText('blip.truck'),truck.coords,477,1,.8) end
        end
    end
    local stale={};for key in pairs(marks) do if not keep[key] then stale[#stale+1]=key end end
    for _,key in ipairs(stale) do clearMarker(key) end
end

local promptFrame={}
local function promptReset()
    for i=#promptFrame,1,-1 do promptFrame[i]=nil end
end
local function promptFlush()
    local frame={}
    for i=1,#promptFrame do frame[i]=promptFrame[i] end
    ScootPrompts.Set('collection',frame)
end

local function prompt3d(point,text)
    local glyph,label=ScootPromptKey(text)
    promptFrame[#promptFrame+1]={key=glyph,label=label,world=point,offsetZ=.45}
end

local function screenPrompt(text)
    local glyph,label=ScootPromptKey(text)
    promptFrame[#promptFrame+1]={key=glyph,label=label,anchor='screen'}
end
local function countSlots(truck)
    local n=0;for _,id in pairs(truck and truck.slots or {}) do if id then n=n+1 end end;return n
end

local function transferContext(ped,netId,index)
    local slot=C.truck.slots[tonumber(index)]
    if not slot then return end
    for _,truck in ipairs(state.trucks or {}) do
        if truck.netId==netId then
            local entity=collectionEntity(truck.netId,'truck',truck.token,truck.id)
            if entity~=0 then
                local p,v=GetEntityCoords(ped),GetEntityCoords(entity);local h=math.rad(GetEntityHeading(entity))
                local side=((p.x-v.x)*math.cos(h)+(p.y-v.y)*math.sin(h))<0 and -1 or 1
                return entity,slot,side
            end
        end
    end
end

local function toLocal(ped,wx,wy,wz,wh)
    local p=GetEntityCoords(ped);local heading=GetEntityHeading(ped);local h=math.rad(heading)
    local dx,dy=wx-p.x,wy-p.y
    return dx*math.cos(h)+dy*math.sin(h),-dx*math.sin(h)+dy*math.cos(h),wz-p.z,((wh-heading+540)%360)-180
end
local function mix(a,b,t) return a+(b-a)*t end
local function mixYaw(a,b,t) return a+(((b-a+540)%360)-180)*t end
local function attachToPed(object,ped,x,y,z,yaw)

    AttachEntityToEntity(object,ped,-1,x,y,z,0.0,0.0,yaw,false,false,false,false,2,true)
end

retireCollectionEpoch=function()
    workerGeneration=workerGeneration+1
    if action then stopOwnedPose(action.ped) end
    if placementHold and DoesEntityExist(placementHold.ped) then TaskStandStill(placementHold.ped,1) end
    action=nil;busy=false;placementHold=nil;recoveryRequest=nil;engineRequest=nil
    clearCarry()
    for _,entity in pairs(visuals) do remove(entity) end
    visuals={};observedMotions={};groundVisuals={};initialized={};visualStage={}
    ScootCollectionPickupTarget=nil
end
local sampleMotion
local function carryOffset(ped)
    local pose=C.carryPose
    local yaw=pose.yaw
    local bone=GetPedBoneIndex(ped,pose.bone)
    local hand=bone and bone>=0 and type(GetPedBoneCoords)=='function'
        and GetPedBoneCoords(ped,pose.bone,0.0,0.0,0.0)
    if hand and type(hand.x)=='number' and type(hand.y)=='number' and type(hand.z)=='number'
        and hand.x==hand.x and hand.y==hand.y and hand.z==hand.z
        and math.abs(hand.x)<math.huge and math.abs(hand.y)<math.huge and math.abs(hand.z)<math.huge then
        local x,y,z=toLocal(ped,hand.x,hand.y,hand.z,GetEntityHeading(ped)+yaw)
        x,y,z=x+pose.palm.x,y+pose.palm.y,z+pose.palm.z
        local angle=math.rad(yaw);local c,s=math.cos(angle),math.sin(angle)
        return x-(pose.grip.x*c-pose.grip.y*s),y-(pose.grip.x*s+pose.grip.y*c),z-pose.grip.z,yaw
    end
    return pose.fallback.x,pose.fallback.y,pose.fallback.z,yaw
end
local function attachToHand(object,ped)
    local x,y,z,yaw=carryOffset(ped)
    attachToPed(object,ped,x,y,z,yaw)
end
local function attachToTruck(object,truck,slot)
    AttachEntityToEntity(object,truck,0,slot.x,slot.y,slot.z,0,0,slot.heading or 90,false,false,false,false,2,true)
end
local function transitionVehicle(transition)
    local vehicle=transition and transition.netId and netEntity(transition.netId) or 0
    if vehicle~=0 and GetEntityModel(vehicle)~=joaat(C.scooterModel) then vehicle=0 end
    return vehicle
end

sampleMotion=function(path,phase)
    local at=math.max(0,math.min(1,phase))*(#path.frames-1)
    local index=math.floor(at)+1
    local a,b=path.frames[index],path.frames[math.min(index+1,#path.frames)]
    local t=at-math.floor(at)
    return mix(a[1],b[1],t),mix(a[2],b[2],t),mix(a[3],b[3],t),mixYaw(a[4],b[4],t),
        mix(a[5],b[5],t),mix(a[6],b[6],t)
end
local function smooth(t)
    t=math.max(0,math.min(1,t))
    return t*t*(3-2*t)
end
local function pickupPose(ped,phase,transition,item)
    local gx,gy,gz,gyaw
    local vehicle=transitionVehicle(transition)
    if vehicle~=0 then
        local v=GetEntityCoords(vehicle);gx,gy,gz,gyaw=toLocal(ped,v.x,v.y,v.z,GetEntityHeading(vehicle))
    elseif item and item.coords then
        gx,gy,gz,gyaw=toLocal(ped,item.coords.x,item.coords.y,item.coords.z,item.heading or 0)
    else gx,gy,gz,gyaw=table.unpack(Motion.paths.drop.groundPose) end
    local cx,cy,cz,cyaw=carryOffset(ped)
    local p=C.carryPose.pickup
    local s=smooth((phase-p.liftFrom)/(p.liftTo-p.liftFrom))
    return mix(gx,cx,s),mix(gy,cy,s),math.max(gz,mix(gz,cz,s)),mixYaw(gyaw,cyaw,s)
end
local function dropPose(ped,phase)
    local gx,gy,gz,gyaw=table.unpack(Motion.paths.drop.groundPose)
    local cx,cy,cz,cyaw=carryOffset(ped)
    local p=C.carryPose.drop
    local s=smooth((phase-p.lowerFrom)/(p.lowerTo-p.lowerFrom))
    return mix(cx,gx,s),mix(cy,gy,s),math.max(gz,mix(cz,gz,s)),mixYaw(cyaw,gyaw,s)
end
local function placeCarry(object,ped,kind,phase,transition,item)
    kind=kind or 'carry';phase=math.max(0,math.min(1,phase or 0))
    if kind=='carry' then attachToHand(object,ped);return end
    local truck,slot,side
    if kind=='load' or kind=='unload' then
        truck,slot,side=transferContext(ped,transition and transition.truckNetId,transition and transition.slot)
        if not truck or truck==0 or not slot then attachToHand(object,ped);return end
    end
    phase=animationPhase(ped,kind,phase,side)
    if kind=='pickup' or kind=='drop' then
        local x,y,z,yaw
        if kind=='pickup' then x,y,z,yaw=pickupPose(ped,phase,transition,item) else x,y,z,yaw=dropPose(ped,phase) end
        attachToPed(object,ped,x,y,z,yaw)
        return
    end
    local path=Motion.paths[kind..((kind=='load' or kind=='unload') and (side<0 and '_left' or '_right') or '')]
    if not path then attachToHand(object,ped);return end
    if truck and ((path.attachTruckFrom and phase>=path.attachTruckFrom)
        or (path.attachTruckUntil and phase<=path.attachTruckUntil)) then
        attachToTruck(object,truck,slot);return
    end
    local x,y,z,yaw,groundWeight,truckWeight=sampleMotion(path,phase)
    if truck then

        local w=GetOffsetFromEntityInWorldCoords(truck,slot.x,slot.y,slot.z)
        local sx,sy,sz,syaw=toLocal(ped,w.x,w.y,w.z,GetEntityHeading(truck)+(slot.heading or 90))
        local nominal=path.truckPose
        x=x+(sx-nominal[1])*truckWeight;y=y+(sy-nominal[2])*truckWeight;z=z+(sz-nominal[3])*truckWeight
        yaw=yaw+(((syaw-nominal[4]+540)%360)-180)*truckWeight
    end
    attachToPed(object,ped,x,y,z,yaw)
end
local function transitionEntity(item)
    local vehicle=collectionEntity(item.netId,'scooter',item.token,item.id)
    if vehicle==0 and item.state=='adopting' then vehicle=transitionVehicle(item) end
    return vehicle
end
local function stageModel(stage)
    local list=C.carryModels or {C.carryModel}
    return list[stage] or C.carryModel
end
local function wantedStage(transition,carrying)
    if transition then
        if transition.ground then return 1,true end
        local kind,phase=transition.kind,transition.phase or 0
        if kind=='pickup' then
            local p=C.carryPose.pickup
            return phase>=p.stage3 and 3 or phase>=p.stage2 and 2 or 1,true
        end
        if kind=='drop' then
            local p=C.carryPose.drop
            return phase<p.stage2 and 3 or phase<p.stage1 and 2 or 1,true
        end
        if kind=='carry' then return 3,false end
        return 1,false
    end
    return carrying and 3 or 1,false
end
local function resolveStage(id,wanted,direct)
    local now=GetGameTimer()
    local current=visualStage[id]
    if direct or not current then
        visualStage[id]={stage=wanted,at=now}
        return wanted
    end
    if current.stage~=wanted and now-current.at>=(C.carryPose.stepMs or 150) then
        current.stage=current.stage+(wanted>current.stage and 1 or -1)
        current.at=now
    end
    return current.stage
end
local function makeVisual(id,stage)
    local hash=joaat(stageModel(stage or 1))
    local previous=visuals[id]
    if previous and DoesEntityExist(previous) and ownedEntities[previous]==hash
        and GetEntityModel(previous)==hash and not NetworkGetEntityIsNetworked(previous) then return previous end
    if not HasModelLoaded(hash) then
        RequestModel(hash)
        if previous and DoesEntityExist(previous) and ownedEntities[previous] then return previous end
        return nil
    end
    if previous then remove(previous);visuals[id]=nil end
    local p=GetEntityCoords(PlayerPedId())
    local object=own(CreateObjectNoOffset(hash,p.x,p.y,p.z,false,false,false),hash)
    if object==0 then return nil end
    SetEntityCollision(object,false,false);SetEntityInvincible(object,true)
    visuals[id]=object;return object
end
local function releasePose(ped)
    local pose=Motion.paths.drop.groundPose
    local p=GetOffsetFromEntityInWorldCoords(ped,pose[1],pose[2],pose[3])
    return {x=p.x,y=p.y,z=p.z,heading=(GetEntityHeading(ped)+pose[4])%360}
end
local function placeGroundVisual(object,point)
    if type(DetachEntity)=='function' then DetachEntity(object,true,true) end
    FreezeEntityPosition(object,true)
    SetEntityCoordsNoOffset(object,point.x,point.y,point.z,false,false,false)
    SetEntityHeading(object,point.heading)
end
local function dropOnGround(phase)
    return phase>=C.carryPose.drop.groundAt
end
local function carryingId()
    if action and action.completed then
        if action.kind=='pickup' or action.kind=='unload' then return action.id end
        return nil
    end
    return state.session and state.session.carrying
end
local function renderFleet()
    local keep={};local player=PlayerPedId();local me=GetPlayerServerId(PlayerId());local p=GetEntityCoords(player)
    local presented,observedKeep={},{}
    if state.session then warmCollectionAssets() end
    for _,pending in ipairs(state.actions or {}) do
        if pending.source~=me and pending.id and (pending.kind=='pickup' or pending.kind=='drop'
            or pending.kind=='load' or pending.kind=='unload') then
            local playerId=GetPlayerFromServerId(pending.source)
            if playerId~=-1 and GetPlayerServerId(playerId)==pending.source then
                local ped=GetPlayerPed(playerId)
                if alive(ped) and not IsPedInAnyVehicle(ped,false) then
                    warmCollectionAssets()
                    local side
                    if pending.kind=='load' or pending.kind=='unload' then
                        local _,_,value=transferContext(ped,pending.truckNetId,pending.slot);side=value
                    end
                    local key=tostring(pending.source)..':'..tostring(pending.kind)..':'..tostring(pending.startedAt)
                    local previous=observedMotions[pending.id]
                    local phase=nativeAnimationPhase(ped,pending.kind,side)
                    observedKeep[pending.id]=true
                    if phase~=nil or (previous and previous.key==key) then
                        local motion=previous and previous.key==key and previous or {key=key,release=pending.kind=='drop' and releasePose(ped)}
                        motion.ped,motion.kind,motion.truckNetId,motion.slot,motion.netId=ped,pending.kind,pending.truckNetId,pending.slot,pending.netId
                        motion.phase=phase or motion.phase or 0
                        observedMotions[pending.id]=motion;presented[pending.id]=motion
                        if pending.kind=='drop' and dropOnGround(motion.phase) then
                            motion.ground=motion.release;groundVisuals[pending.id]=motion.release
                        end
                    end
                end
            end
        end
    end
    for id in pairs(observedMotions) do if not observedKeep[id] then observedMotions[id]=nil end end
    if action and action.id and action.nativeStarted then
        local kind=action.kind
        if action.completed and (kind=='pickup' or kind=='unload') then kind='carry' end
        local phase=action.completed and 1 or action.phase or 0
        local ground=action.kind=='drop' and dropOnGround(phase) and action.release
        if ground then groundVisuals[action.id]=ground end
        presented[action.id]={ped=action.ped,kind=kind,truckNetId=action.truckNetId,slot=action.slot,netId=action.netId,
            phase=phase,ground=ground}
    end
    local anyNearby=false
    for _,item in ipairs(state.fleet or {}) do
        if item.coords and dist(p,item.coords)<140 then warmCollectionAssets() end
        local target=0;local carrying=false;local slot=nil
        if item.state=='carried' and item.carrier then
            local playerId=GetPlayerFromServerId(item.carrier)
            if playerId~=-1 and GetPlayerServerId(playerId)==item.carrier then
                target=GetPlayerPed(playerId);carrying=alive(target) and not IsPedInAnyVehicle(target,false)
                if not carrying then target=0 end
            end
        elseif item.state=='loaded' then
            for _,truck in ipairs(state.trucks or {}) do
                if truck.netId==item.truckNetId and truck.slots and truck.slots[tostring(item.slot)]==item.id then
                    target=collectionEntity(truck.netId,'truck',truck.token,truck.id);break
                end
            end
            slot=C.truck.slots[tonumber(item.slot)]
        end
        local transition=presented[item.id]
        if transition then target=transition.ped;carrying=true;slot=nil end
        if target~=0 and DoesEntityExist(target) and dist(p,GetEntityCoords(target))<140 and (carrying or slot) then
            anyNearby=true
            local wanted,direct=wantedStage(transition,carrying)
            local object=makeVisual(item.id,resolveStage(item.id,wanted,direct))
            if object then
                keep[item.id]=true
                if carrying then
                    if transition then
                        if transition.ground then placeGroundVisual(object,transition.ground)
                        else
                            FreezeEntityPosition(object,false)
                            placeCarry(object,target,transition.kind,transition.phase,transition,item)
                        end
                        local vehicle=transitionEntity(item)
                        if vehicle~=0 then SetEntityLocallyInvisible(vehicle) end
                    else placeCarry(object,target) end
                else
                    AttachEntityToEntity(object,target,0,slot.x,slot.y,slot.z,0,0,slot.heading or 90,false,false,false,false,2,true)
                end
            end
        end
        if item.state=='ground' then
            local vehicle=collectionEntity(item.netId,'scooter',item.token,item.id)
            local release=groundVisuals[item.id]
            if vehicle~=0 then groundVisuals[item.id]=nil
            elseif release and dist(p,release)<140 then
                local object=makeVisual(item.id,resolveStage(item.id,1,true))
                if object then keep[item.id]=true;anyNearby=true;placeGroundVisual(object,release) end
            end
            if vehicle~=0 and NetworkHasControlOfEntity(vehicle) then
                local key=tostring(item.netId)..':'..tostring(item.token)
                if not initialized[key] then
                    SetVehicleOnGroundProperly(vehicle);SetVehicleDoorsLocked(vehicle,2);SetVehicleUndriveable(vehicle,true)
                    SetVehicleEngineOn(vehicle,false,true,true);initialized[key]=true
                end
            end
        elseif not transition or transition.kind~='drop' then groundVisuals[item.id]=nil end
    end
    local stale={};for id,object in pairs(visuals) do if not keep[id] then remove(object);stale[#stale+1]=id end end
    for _,id in ipairs(stale) do visuals[id]=nil;groundVisuals[id]=nil;visualStage[id]=nil end
    for _,truck in ipairs(state.trucks or {}) do
        local entity=collectionEntity(truck.netId,'truck',truck.token,truck.id)
        if entity~=0 and NetworkHasControlOfEntity(entity) then
            local key='truck:'..tostring(truck.netId)..':'..tostring(truck.token)
            if not initialized[key] then
                SetVehicleOnGroundProperly(entity);SetVehicleCustomPrimaryColour(entity,table.unpack(C.truck.primaryColour))
                SetVehicleCustomSecondaryColour(entity,table.unpack(C.truck.secondaryColour));SetVehicleDirtLevel(entity,C.truck.dirtLevel)
                SetVehicleFuelLevel(entity,100);SetVehicleDoorsLocked(entity,1);initialized[key]=true
                if truck.owner==me and state.session and state.session.truckNetId==truck.netId
                    and Entity(entity).state.loopScootCollection.owner==me then
                    configureWorkTruck(entity)
                    TriggerEvent('loop-scoot:collection:keys',entity,GetVehicleNumberPlateText(entity))
                end
            end
        end
    end
    return anyNearby
end

local function blockCarryControls()
    for _,control in ipairs({21,22,23,24,25,36,37,44,45,140,141,142,143,257,263,264}) do DisableControlAction(0,control,true) end
    DisablePlayerFiring(PlayerId(),true)
end
local function startCarryPose(ped,fadeIn)
    local carry=clipOf('carry')
    if not carry or not DoesEntityExist(ped) then return false end
    RequestAnimDict(carry.dict)
    if not HasAnimDictLoaded(carry.dict) then return false end
    TaskPlayAnim(ped,carry.dict,carry.clip,fadeIn or carry.blendIn or 4.0,carry.blendOut or -4.0,-1,carry.flag or 49,0.0,false,false,false)
    return true
end
local function blockActionControls()
    for _,control in ipairs({30,31,21,22,23,24,25,37,38}) do DisableControlAction(0,control,true) end
    DisablePlayerFiring(PlayerId(),true)
end
local function adoptableVehicle(netId)
    if C.collectRentals==false then return 0 end
    local vehicle=netEntity(netId)
    if vehicle==0 or GetEntityModel(vehicle)~=joaat(C.scooterModel) then return 0 end
    if Entity(vehicle).state.loopScootCollection~=nil or GetPedInVehicleSeat(vehicle,-1)~=0 then return 0 end
    return vehicle
end

local function nearestAdoptable(position)
    if C.collectRentals==false or type(GetGamePool)~='function' then return 0,0 end
    if GetGameTimer()-adoptScan.at>400 then
        adoptScan.at=GetGameTimer();adoptScan.vehicle,adoptScan.netId=0,0
        local best,hash=C.interactionDistance,joaat(C.scooterModel)
        for _,vehicle in ipairs(GetGamePool('CVehicle')) do
            if GetEntityModel(vehicle)==hash and NetworkGetEntityIsNetworked(vehicle)
                and Entity(vehicle).state.loopScootCollection==nil and GetPedInVehicleSeat(vehicle,-1)==0 then
                local d=dist(position,GetEntityCoords(vehicle))
                if d<best then best=d;adoptScan.vehicle,adoptScan.netId=vehicle,NetworkGetNetworkIdFromEntity(vehicle) end
            end
        end
    end
    if adoptScan.vehicle~=0 and (not DoesEntityExist(adoptScan.vehicle) or dist(position,GetEntityCoords(adoptScan.vehicle))>C.interactionDistance) then return 0,0 end
    return adoptScan.vehicle,adoptScan.netId
end
local function placementReference(entity)
    local tag=Entity(entity).state.loopScootCollection
    return {entity=entity,coords=GetEntityCoords(entity),heading=GetEntityHeading(entity),model=GetEntityModel(entity),
        tagged=type(tag)=='table',token=type(tag)=='table' and tag.token,id=type(tag)=='table' and tag.id}
end
local function placementDistance(a,b)
    return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2)
end
local function samePlacementEntity(anchor)
    if not anchor then return true end
    if not DoesEntityExist(anchor.entity) or GetEntityModel(anchor.entity)~=anchor.model then return false end
    local tag=Entity(anchor.entity).state.loopScootCollection
    if anchor.tagged then return type(tag)=='table' and tag.token==anchor.token and tag.id==anchor.id end
    return tag==nil
end
local function placementCollision(ped,anchor)
    if samePlacementEntity(anchor) and anchor and DoesEntityExist(ped) then

        SetEntityNoCollisionEntity(ped,anchor.entity,true)
        SetEntityNoCollisionEntity(anchor.entity,ped,true)
    end
end
local function standingHeight(ped)
    local p=GetEntityCoords(ped)
    local found,z=GetGroundZFor_3dCoord(p.x,p.y,p.z+.5,false)
    local height=found and type(z)=='number' and p.z-z
    return height and height>=.5 and height<=1.3 and height or Motion.originToGround or .968
end
local function makePlacement(ped,anchor,kind,x,y,headingOffset,groundOffset)
    return {ped=ped,anchor=anchor,kind=kind,x=x,y=y,headingOffset=headingOffset,groundOffset=groundOffset,
        origin=GetEntityCoords(ped),height=standingHeight(ped)}
end
local function alignPlacement(placement)
    local ped,anchor=placement.ped,placement.anchor
    if not samePlacementEntity(anchor) then return false end
    local v=GetEntityCoords(anchor.entity)

    if dist(v,anchor.coords)>1.0 or GetEntitySpeed(anchor.entity)>.15
        or (placement.kind=='pickup' and GetPedInVehicleSeat(anchor.entity,-1)~=0) then return false end
    local heading=GetEntityHeading(anchor.entity)
    local h=math.rad(heading)
    local point={x=v.x+placement.x*math.cos(h)-placement.y*math.sin(h),
        y=v.y+placement.x*math.sin(h)+placement.y*math.cos(h)}
    if placementDistance(point,placement.origin)>(C.interactionDistance or 1.8)+.75 then return false end
    local ground=v.z-placement.groundOffset
    local found,z=GetGroundZFor_3dCoord(point.x,point.y,ground+1.0,false)
    if found and type(z)=='number' and z==z and math.abs(z-ground)<=.75 then ground=z end
    point.z=ground+placement.height
    placement.point,placement.heading=point,(heading+placement.headingOffset)%360
    placementCollision(ped,anchor)
    local now=GetGameTimer()
    local p=GetEntityCoords(ped)
    local distance=placementDistance(p,point)
    local turn=((placement.heading-GetEntityHeading(ped)+540)%360)-180
    if not placement.started then
        placement.started,placement.advancedAt,placement.progressAt=now,now,now
        placement.best=distance+math.abs(turn)/600
        if distance>.06 or math.abs(turn)>5 then

            if type(TaskGoStraightToCoord)=='function' then
                TaskGoStraightToCoord(ped,point.x,point.y,point.z,1.0,-1,placement.heading,0.0)
            else placement.assisted=true end
        end
    end
    if distance<=.06 and math.abs(p.z-point.z)<=.06 and math.abs(turn)<=5 then
        if not placement.done then TaskStandStill(ped,1) end
        placement.done=true
        return true
    end
    placement.done=false
    if now-placement.started>5000 then return false end
    local metric=distance+math.abs(turn)/600
    if metric<placement.best-.008 then placement.best,placement.progressAt=metric,now end

    if now-placement.progressAt>=450 then placement.assisted=true end
    local dt=math.min(.10,math.max(0,(now-placement.advancedAt)/1000))
    placement.advancedAt=now
    if placement.assisted and dt>0 then
        local travel=math.min(distance,.95*dt)
        local fraction=distance>0 and travel/distance or 1
        local z=p.z+math.max(-.45*dt,math.min(.45*dt,point.z-p.z))
        SetEntityCoordsNoOffset(ped,p.x+(point.x-p.x)*fraction,p.y+(point.y-p.y)*fraction,z,true,true,false)
        SetEntityHeading(ped,(GetEntityHeading(ped)+math.max(-140*dt,math.min(140*dt,turn)))%360)
    end
    return true
end
local function prepareAtPlacement(kind,id,slot,netId,ped,generation,anchor,placement)
    local origin,heading=GetEntityCoords(ped),GetEntityHeading(ped)
    local epoch=state.epoch
    local function sameEpoch() return not stopped and state.epoch==epoch and not (epoch and retiredEpochs[epoch]) end
    local sessionToken=state.session and state.session.token
    local function valid()
        if stopped or generation~=workerGeneration or ped~=PlayerPedId() or not alive(ped)
            or IsPedInAnyVehicle(ped,false) or IsNuiFocused()
            or not state.session or state.session.token~=sessionToken then return false end
        if placement then
            if IsControlJustPressed(0,177) then return false end

            local ok,aligned=pcall(alignPlacement,placement)
            if not ok then print(('[loop-scoot] Collection placement: %s'):format(tostring(aligned))) end
            return ok and aligned
        end
        return placementDistance(GetEntityCoords(ped),origin)<=.12 and math.abs(GetEntityCoords(ped).z-origin.z)<=.20
            and math.abs(((GetEntityHeading(ped)-heading+540)%360)-180)<=5 and samePlacementEntity(anchor)
    end
    if not valid() then return {ok=false,message=ScootText('err.handlingTargetGone')} end
    local request={}

    CreateThread(function()
        if stopped or generation~=workerGeneration then return end
        request.response=call('prepare',kind,id,slot,netId)
        if sameEpoch() and request.abandoned and request.response.ok and request.response.token then
            call('cancel',request.response.token)
        end
    end)
    local deadline=GetGameTimer()+5000
    while true do
        if request.response and not request.response.ok then
            if placement then TaskStandStill(ped,1) end
            return request.response
        end
        if not valid() or IsControlJustPressed(0,177) or GetGameTimer()>=deadline then
            request.abandoned=true
            if request.response and request.response.ok and request.response.token then
                CreateThread(function()
                    if sameEpoch() then call('cancel',request.response.token) end
                end)
            end
            if placement then TaskStandStill(ped,1) end
            return {ok=false,message=ScootText('err.handlingCancelled')}
        end

        if request.response and (not placement or placement.done) then return request.response end
        blockActionControls();Wait(0)
    end
end
local function runAction(kind,id,slot,netId)
    if busy then return end
    local ped=PlayerPedId()
    if not alive(ped) or IsPedInAnyVehicle(ped,false) or IsNuiFocused() then return end
    busy=true
    local generation,epoch=workerGeneration,state.epoch
    local ready,animationError=animation(kind)
    if ready and (kind=='pickup' or kind=='unload') then ready,animationError=animation('carry') end
    if not ready then
        if generation==workerGeneration then busy=false;tell(animationError or ScootText('err.animsMissing'),'error') end
        return
    end
    if not modelsLoaded() then
        if generation==workerGeneration then busy=false;tell(ScootText('err.carryModelMissing'),'error') end
        return
    end
    if stopped or generation~=workerGeneration then return end

    local placement,transferSide,transferNetId,pickupNetId,placementAnchor
    if kind=='pickup' then
        local vehicle=0;local item=id and fleetItem(id)
        if id then vehicle=item and collectionEntity(item.netId,'scooter',item.token,item.id) or 0
        elseif netId then vehicle=adoptableVehicle(netId) end
        if vehicle==0 and (not id or item) then busy=false;tell(ScootText('err.scooterNotFound'),'error');return end
        if vehicle~=0 then
            placementAnchor=placementReference(vehicle)
            pickupNetId=netId or (item and item.netId)

            placement=makePlacement(ped,placementAnchor,kind,C.pickupDistance or .55,0,90,0)
        end
    elseif kind=='load' or kind=='unload' then
        local truck,vehicle=workTruck()
        if vehicle~=0 and C.truck.slots[slot] then
            local _,s,side=transferContext(ped,truck.netId,slot)
            if s then
                placementAnchor=placementReference(vehicle)
                transferSide=side;transferNetId=truck.netId
                placement=makePlacement(ped,placementAnchor,kind,side*(C.truck.approachSide or 1.95),s.y,
                    side<0 and 270 or 90,C.truck.groundOffset or 1.2554745)
            end
        end
    end
    if stopped or generation~=workerGeneration then return end
    if not alive(ped) or ped~=PlayerPedId() or IsPedInAnyVehicle(ped,false) or IsNuiFocused() then busy=false;return end
    placementHold=placement
    local response=prepareAtPlacement(kind,id,slot,netId,ped,generation,placementAnchor,placement)
    if placementHold==placement then placementHold=nil end
    if stopped or generation~=workerGeneration then
        if response.ok and response.token then
            CreateThread(function()
                if not stopped and state.epoch==epoch and not (epoch and retiredEpochs[epoch]) then call('cancel',response.token) end
            end)
        end
        return
    end
    if not response.ok then busy=false;tell(response.message or ScootText('err.actionImpossible'),'error');return end
    local point=GetEntityCoords(ped)
    local clip=clipOf(kind,transferSide)
    action={token=response.token,kind=kind,id=response.id or id,ped=ped,duration=response.duration or 1500,started=GetGameTimer(),origin=point,
        requestedAt=GetGameTimer(),nativeStarted=not clip,phase=0,release=kind=='drop' and releasePose(ped),
        truckNetId=transferNetId,slot=slot,side=transferSide,netId=pickupNetId,placementAnchor=placementAnchor}
    local current=action

    if clip then TaskPlayAnim(ped,clip.dict,clip.clip,clip.blendIn or 4.0,clip.blendOut or -4.0,-1,clip.flag or 2,0.0,false,false,false) end
    local cancelled=false
    while action==current and not stopped do
        local now=GetGameTimer()
        if clip then
            local phase=nativeAnimationPhase(ped,kind,transferSide)
            if phase~=nil then
                if not current.nativeStarted then

                    current.nativeStarted=true
                    current.started=math.max(current.requestedAt,now-phase*current.duration)
                    clearCarry()
                end
                current.phase=phase;current.missingSince=nil
            elseif current.nativeStarted then
                current.missingSince=current.missingSince or now
                if now-current.missingSince>150 then cancelled=true;break end
            elseif now-current.requestedAt>1500 then cancelled=true;break end
        end
        placementCollision(ped,placementAnchor)
        renderFleet()
        blockActionControls()
        if not alive(ped) or ped~=PlayerPedId() or IsPedInAnyVehicle(ped,false) or IsNuiFocused()
            or dist(GetEntityCoords(ped),point)>.8 or IsControlJustPressed(0,177) then cancelled=true;break end
        local elapsed=GetGameTimer()-current.started
        if current.nativeStarted and elapsed>=current.duration then

            if not clip or current.phase>=.995 then break end
            if elapsed>=current.duration+750 then cancelled=true;break end
        end
        if not clip then current.phase=math.min(1,elapsed/current.duration) end
        Wait(0)
    end
    if stopped or generation~=workerGeneration then return end
    if action~=current then cancelled=true end
    if cancelled or stopped then
        if current.id then groundVisuals[current.id]=nil end
        stopOwnedPose(ped,kind)

        if action==current then action=nil end
        renderFleet()
        settleAction('cancel',current.token,generation)
    else

        current.completed=true;current.phase=1
        if kind=='drop' and current.id then groundVisuals[current.id]=current.release end
        if (kind=='pickup' or kind=='unload') and startCarryPose(ped) then
            localCarry={ped=ped,lastTry=GetGameTimer(),missingSince=nil}
        end
        stopOwnedPose(ped,kind)
        renderFleet()
        local result=settleAction('finish',current.token,generation)
        if stopped or generation~=workerGeneration or result.retired then return end
        if not result.ok then
            if current.id then groundVisuals[current.id]=nil end
            tell(result.message or ScootText('err.actionRefused'),'error')
        elseif kind=='service' then tell(ScootText('notify.handedIn',result.paid or result.reward or 0),'success') end
    end
    if generation==workerGeneration then
        if action==current then action=nil end
        stopOwnedPose(ped,kind);busy=false
    end
end
local function beginAction(...)
    local generation=workerGeneration
    local ok,err=xpcall(runAction,debug.traceback,...)
    if not ok and generation==workerGeneration then
        placementHold=nil
        local failed=action;action=nil;busy=false
        if failed then
            stopOwnedPose(failed.ped,failed.kind)
            CreateThread(function() call('cancel',failed.token) end)
        end
        print(('[loop-scoot] Collection action: %s'):format(tostring(err)))
        if not stopped then tell(ScootText('err.handlingInterrupted'),'error') end
    end
end

local function managerPromptPoint()
    local entity=workshop and workshop.entities.manager
    if not entity or not ownedEntities[entity] or not DoesEntityExist(entity)
        or NetworkGetEntityIsNetworked(entity) or GetEntityModel(entity)~=ownedEntities[entity] then return end

    local point=world(C.depot.managerPed or C.depot.manager);point.z=point.z+.75
    return point
end
local function help()
    lib.alertDialog({header=ScootText('help.header'),content=ScootText('help.body'),centered=true})
end

local function legacyManager()
    if busy or IsNuiFocused() then return end
    if not managerPromptPoint() then tell(ScootText('notify.managerAway'),'error');return end
    local options={
        {title=ScootText('menu.subtitle'),description=ScootText('menu.intro'),readOnly=true},
        {title=ScootText(state.session and 'menu.clockOut' or 'menu.clockIn'),icon='user-clock',onSelect=function()
            local onDuty=state.session~=nil
            local result=call('duty',not state.session)
            if result.ok then if not state.session then restoreUniform();clearCarry() end
                tell(ScootText(onDuty and 'notify.clockOut' or 'notify.clockIn'),'success')
            else tell(result.message or ScootText('notify.dutyFailed'),'error') end
        end},
        {title=ScootText('menu.getVehicle'),description=ScootText('menu.vehicleHint',C.truck.capacity),icon='truck',disabled=not state.session,onSelect=function()
            local result=call('truck')
            tell(result.ok and ScootText('notify.truckReady') or result.message or ScootText('notify.truckUnavailable'),result.ok and 'success' or 'error')
        end},

        {title=ScootText('menu.locate'),icon='location-dot',disabled=not state.session,onSelect=function()
            local best,distance;local pos=GetEntityCoords(PlayerPedId())
            for _,item in ipairs(state.fleet or {}) do
                if item.state=='ground' and item.coords then local d=dist(pos,item.coords);if not distance or d<distance then best=item;distance=d end end
            end
            if best then SetNewWaypoint(best.coords.x,best.coords.y);tell(ScootText('notify.route')) else tell(ScootText('notify.noScooter')) end
        end},
        {title=ScootText('menu.needHelp'),icon='circle-question',onSelect=help},
    }
    lib.registerContext({id='scoot_collection_manager',title=ScootText('menu.title'),options=options})
    lib.showContext('scoot_collection_manager')
end

local function uiModel()
    local garage={name=C.truck.displayName,status='unavailable',capacity=C.truck.capacity,thumbnail='assets/collection-truck.png'}
    if uiGarageCache then
        for _,key in ipairs({'name','status','capacity','thumbnail','plate'}) do garage[key]=uiGarageCache.value[key] end
    elseif state.session then garage.status=(state.session.truckNetId or 0)>0 and 'out' or 'available' end
    if GetVehicleModelNumberOfSeats then
        local ok,seats=pcall(GetVehicleModelNumberOfSeats,joaat(C.truck.model))
        if ok and type(seats)=='number' and seats%1==0 and seats>0 and seats<=32 then garage.seats=seats end
    end
    return {duty=state.session~=nil,garage=garage,language=ScootLocale.Resolve(),
        pending=uiMutation~=nil or uiReading~=nil or (collectionUi and collectionUi.loading)==true}
end
local function emitUi(actionName,extra,u)
    u=u or collectionUi
    if not u then return end
    local message=uiModel();u.sequence=u.sequence+1
    message.action='collection:'..actionName;message.uiGeneration=u.generation;message.uiSequence=u.sequence;message.view=u.view
    for key,value in pairs(extra or {}) do message[key]=value end
    local ok=pcall(SendNUIMessage,message)
    if not ok and actionName~='close' and collectionUi==u and closeCollectionUi then closeCollectionUi('nuiUnavailable') end
    return ok
end
emitCollectionState=function() if collectionUi then emitUi('state') end end
local function ackUi(request,value)
    if not request.cb then return end
    local cb=request.cb;request.cb=nil
    value.uiGeneration=request.generation;value.requestId=request.id
    cb(value)
end
closeCollectionUi=function(reason)
    local u=collectionUi
    if not u then return end
    collectionUi=nil;uiCooldown=GetGameTimer()+300
    if uiReading and uiReading.ui==u then
        uiReading.expired=true;ackUi(uiReading,{ok=false,message=ScootText('err.screenClosed')});uiReading=nil
    end
    if uiMutation and uiMutation.ui==u then ackUi(uiMutation,{ok=false,message=ScootText('err.screenClosedPending')}) end
    emitUi('close',{reason=reason or 'closed'},u)
    if ScootUiFocus then ScootUiFocus.Release(u.lease) end
end
local function uiAllowed(u,reach)
    local ped=PlayerPedId()
    return not stopped and not busy and not action and alive(ped) and (not u or u.ped==ped)
        and not IsPedInAnyVehicle(ped,false) and not (state.session and state.session.carrying)
        and managerPromptPoint()~=nil and dist(GetEntityCoords(ped),world(C.depot.manager))<=(reach or 3)
        and (not u or (ScootUiFocus.Owns(u.lease) and not ScootUiFocus.ExternalBlocked()))
end
local function uiRpc(u,name,id,cb,mutating,onResult,...)
    if (mutating and uiMutation) or (not mutating and uiReading) then
        if cb then cb({ok=false,uiGeneration=u.generation,requestId=id,message=ScootText('err.requestInFlight')}) end
        return false
    end
    local request={ui=u,generation=u.generation,id=id,cb=cb,name=name,
        actionName=({duty='setDuty',truck='retrieve',garage='openGarage'})[name],deadline=GetGameTimer()+8000,
        worker=workerGeneration,epoch=state.epoch,mutating=mutating,ticket=uiTicket}
    if mutating then uiMutation=request else uiReading=request end
    emitCollectionState()
    local function completed(result)
        if request.completed then return end;request.completed=true
        if uiMutation==request then uiMutation=nil end
        if uiReading==request then uiReading=nil end
        local current=not stopped and request.worker==workerGeneration
            and not (request.epoch and retiredEpochs[request.epoch])
        if type(result)~='table' then result={ok=false,message=ScootText('err.serverSilent')} end
        if current and (mutating or not request.expired) and result.fleet then receive(result) end
        if current and not mutating and not request.expired then reconcileUiOperation(result) end
        if collectionUi==u then
            u.loading=false
            if not current or not uiAllowed(u,u.view=='garage' and 4 or 3) then
                closeCollectionUi('contextChanged')
            elseif request.expired then emitCollectionState()
            else
                if onResult then onResult(result) end
                if collectionUi==u then
                    if id>0 then emitUi('result',{requestId=id,actionName=request.actionName,ok=result.ok==true,message=result.message or (result.ok and ScootText('notify.actionDone') or ScootText('err.actionRefused'))}) end
                    emitCollectionState()
                end
            end
        elseif collectionUi then emitCollectionState() end
        ackUi(request,{ok=current and result.ok==true,message=result.message})
    end
    request.complete=completed
    if collectionUi~=u then completed({ok=false,message=ScootText('err.screenClosedBeforeSend')});return false end
    local ok
    if mutating then
        ok=pcall(lib.callback,NS..'uiAction',false,completed,u.generation,id,name,select(1,...),request.ticket)
    else ok=pcall(lib.callback,NS..name,false,completed,...) end
    if not ok then completed({ok=false,message=ScootText('err.serverSilent')}) end
    return true
end
local function refreshUi(u,id,cb,view)
    local navigation=u.navigation
    local uncertain=uiMutation and uiMutation.expired and uiMutation or nil
    return uiRpc(u,'garage',id,cb,false,function(result)
        if not result.ok then
            if id==0 then tell(result.message or ScootText('err.managerUnavailable'),'error');closeCollectionUi('unavailable') end
            return
        end
        u.nextRefresh=GetGameTimer()+2000
        if view and u.navigation==navigation then u.view=view end
    end,uncertain and uncertain.generation,uncertain and uncertain.id,uncertain and uncertain.ticket)
end
local function manager()

    if not ScootUiFocus or type(RegisterNUICallback)~='function' then return legacyManager() end
    if collectionUi or GetGameTimer()<uiCooldown or not uiAllowed(nil,3) then return end
    local lease=ScootUiFocus.Acquire('collection')
    if not lease then return end
    if not ScootUiFocus.Activate(lease) then ScootUiFocus.Release(lease);return end
    uiSerial=uiSerial+1
    local u={generation=uiSerial,sequence=0,ped=PlayerPedId(),lease=lease,view='manager',lastRequest=0,navigation=0,
        loading=true,nextRefresh=GetGameTimer()+2000}
    collectionUi=u
    if emitUi('open') then refreshUi(u,0,nil) end
end
local uiEnums={setDuty=true,openGarage=true,retrieve=true,help=true,nextScooter=true,back=true,close=true}
if type(RegisterNUICallback)=='function' then RegisterNUICallback('collectionAction',function(data,cb)
    local u=collectionUi
    local function safeId(value)
        return type(value)=='number' and value==value and value%1==0 and value>0 and value<=9007199254740991 and value or 0
    end
    local function reply(ok,message)
        cb({ok=ok,uiGeneration=safeId(type(data)=='table' and data.uiGeneration),
            requestId=safeId(type(data)=='table' and data.requestId),message=message})
    end
    if type(data)~='table' or not u or data.uiGeneration~=u.generation or type(data.requestId)~='number'
        or data.requestId~=data.requestId or data.requestId%1~=0 or data.requestId<=u.lastRequest or data.requestId>2147483647
        or not uiEnums[data.action] then return reply(false,ScootText('err.requestInvalid')) end
    for key in pairs(data) do
        if key~='action' and key~='uiGeneration' and key~='requestId' and key~='enabled' then return reply(false,ScootText('err.fieldNotAllowed')) end
    end
    if (data.action=='setDuty' and type(data.enabled)~='boolean') or (data.action~='setDuty' and data.enabled~=nil) then return reply(false,ScootText('err.badRequest')) end
    u.lastRequest=data.requestId
    if data.action=='close' then closeCollectionUi('closed');return reply(true) end
    if not uiAllowed(u,u.view=='garage' and 4 or 3) then closeCollectionUi('contextChanged');return reply(false,ScootText('err.contextChanged')) end
    if data.action=='back' then u.navigation=u.navigation+1;u.view='manager';emitCollectionState();return reply(true) end
    if data.action=='help' then u.navigation=u.navigation+1;u.view='help';emitCollectionState();return reply(true) end
    if data.action=='nextScooter' then
        if not state.session or u.view~='help' then return reply(false,ScootText('err.routeNeedsDuty')) end
        local best,nearest;local position=GetEntityCoords(PlayerPedId())
        for _,item in ipairs(state.fleet or {}) do
            if item.state=='ground' and item.coords and not item.reservedBy then
                local distance=dist(position,item.coords)
                if not nearest or distance<nearest then best=item;nearest=distance end
            end
        end
        local message=best and ScootText('notify.route') or ScootText('notify.noScooter')
        if best then SetNewWaypoint(best.coords.x,best.coords.y) end
        emitUi('result',{requestId=data.requestId,actionName=data.action,ok=best~=nil,message=message});return reply(best~=nil,message)
    end
    if uiMutation or uiReading or u.loading then return reply(false,ScootText('err.requestPending')) end
    if data.action=='openGarage' then
        if not state.session then return reply(false,ScootText('err.truckNeedsDuty')) end
        return refreshUi(u,data.requestId,cb,'garage')
    end
    if data.action=='setDuty' then
        if u.view~='manager' or not uiAllowed(u,3) then return reply(false,ScootText('err.talkToManager')) end
        return uiRpc(u,'duty',data.requestId,cb,true,function(result)
            if result.ok then
                if not state.session then restoreUniform();clearCarry() end
                tell(ScootText(data.enabled and 'notify.clockIn' or 'notify.clockOut'),'success')
            end
        end,data.enabled)
    end
    if data.action=='retrieve' then
        if u.view~='garage' or not state.session then return reply(false,ScootText('err.openGarage')) end
        return uiRpc(u,'truck',data.requestId,cb,true,function(result)
            if result.ok then tell(ScootText('notify.truckReady'),'success');closeCollectionUi('retrieved') end
        end)
    end
end) end
CreateThread(function()
    while not stopped do
        local now=GetGameTimer()
        for _,request in pairs({read=uiReading,mutation=uiMutation}) do
            if not request.expired and now>=request.deadline then
                request.expired=true
                if uiReading==request then uiReading=nil end
                if collectionUi==request.ui then
                    collectionUi.loading=false
                    if request.id>0 then emitUi('result',{requestId=request.id,actionName=request.actionName,ok=false,
                        message=ScootText('err.timeoutNoRetry')}) end
                    if not request.mutating and request.id==0 then closeCollectionUi('timeout') else emitCollectionState() end
                end
                ackUi(request,{ok=false,message=ScootText('err.timeout')})
            end
        end
        local u=collectionUi
        if u then
            if not uiAllowed(u,u.view=='garage' and 4 or 3) then closeCollectionUi('contextChanged')
            elseif not uiReading and (not uiMutation or uiMutation.expired) and now>=u.nextRefresh then
                u.nextRefresh=now+2000;refreshUi(u,0,nil)
            end
        end
        Wait(100)
    end
end)
RegisterCommand('scootjobclose',function() closeCollectionUi('recovery') end,false)

local function updateMloDoors()
    local current=workshop
    if stopped or not current or not current.nativeMlo then return end

    if type(AddDoorToSystem)~='function' or type(DoorSystemFindExistingDoor)~='function' then return end
    for _,name in ipairs({'shutter','officeDoor','innerDoor'}) do
        local definition=depot[name]
        if definition then
            local entry=current.doors[name]
            if not entry then
                entry={id=joaat(NS..'mlo:v2:'..name),model=joaat(definition.model),point=world(definition)}
                current.doors[name]=entry
            end
            local registered=IsDoorRegisteredWithSystem(entry.id)
            if entry.owned and not registered then
                entry.owned=false;entry.ready=false
            end
            if not entry.owned and not registered then
                local p=entry.point
                local found=DoorSystemFindExistingDoor(p.x,p.y,p.z,entry.model)
                if not found then
                    AddDoorToSystem(entry.id,entry.model,p.x,p.y,p.z,false,false,false)
                    entry.owned=IsDoorRegisteredWithSystem(entry.id)
                end
            end
            if entry.owned then

                local loaded=DoorSystemGetIsPhysicsLoaded(entry.id)
                if loaded and not entry.ready then
                    DoorSystemSetDoorState(entry.id,0,false,true)

                    local distance=name=='shutter' and (definition.automaticDistance or 8.0) or 0.0
                    DoorSystemSetAutomaticDistance(entry.id,distance,false,true)
                    DoorSystemSetAutomaticRate(entry.id,definition.movementRate or 1.0,false,true)
                    if name=='shutter' then DoorSystemSetHoldOpen(entry.id,false) end
                    entry.ready=true
                elseif not loaded then entry.ready=false end
            end
        end
    end
end
local function destroyWorkshop()
    if closeCollectionUi then closeCollectionUi('managerUnloaded') end
    if workshop then
        for _,entry in pairs(workshop.doors or {}) do
            if entry.owned and IsDoorRegisteredWithSystem(entry.id) then RemoveDoorFromSystem(entry.id) end
        end
        for _,entity in pairs(workshop.entities) do remove(entity) end
    end
    workshop=nil;renderOrigin=nil
end
local function innerDoorHasPasserby(definition,position)
    local hinge=world(definition);local radius=definition.openDistance or 2.35
    if dist(position,hinge)<radius then return true end

    if GetActivePlayers then
        for _,player in ipairs(GetActivePlayers()) do
            local ped=GetPlayerPed(player)
            if ped and ped~=0 and DoesEntityExist(ped) and dist(GetEntityCoords(ped),hinge)<radius then return true end
        end
    end
    return false
end
local function updateInnerDoor(position)
    local current=workshop;local definition=depot.innerDoor
    if current and current.nativeMlo then return false end
    local entity=current and current.entities.innerDoor
    if stopped or not definition or not entity or not ownedEntities[entity] or not DoesEntityExist(entity)
        or NetworkGetEntityIsNetworked(entity) or GetEntityModel(entity)~=ownedEntities[entity] then return false end
    local now=GetGameTimer()
    if now>=(current.innerDoorPollAt or 0) then
        current.innerDoorPollAt=now+200
        if innerDoorHasPasserby(definition,position) then current.innerDoorHeldUntil=now+(definition.closeDelayMs or 1200) end
    end
    local target=now<(current.innerDoorHeldUntil or 0) and 1 or 0
    local amount=current.innerDoorAmount or 0
    local step=math.max(0,GetFrameTime())*(definition.degreesPerSecond or 90)/math.max(1,math.abs(definition.yaw or 90))
    current.innerDoorAmount=target>amount and math.min(target,amount+step) or math.max(target,amount-step)
    SetEntityHeading(entity,world(definition).heading+current.innerDoorAmount*(definition.yaw or 90))
    return true
end
local function buildWorkshop()
    local origin={x=depot.x,y=depot.y,z=depot.z,heading=depot.heading};local entities={}
    if not depot.nativeMlo then
        local hash=model(depot.model,8000)
        if not hash or stopped then return end
        local shell=own(CreateObjectNoOffset(hash,origin.x,origin.y,origin.z,false,false,false),hash)
        if shell==0 then return end
        entities.shell=shell;SetEntityHeading(shell,origin.heading);FreezeEntityPosition(shell,true)
    elseif stopped then return end
    local currentWorkshop={entities=entities,door=0,pedDoor=0,nativeMlo=depot.nativeMlo==true,doors={}}
    workshop=currentWorkshop;renderOrigin=origin
    updateMloDoors()
    local sh=depot.shutter
    if sh and not currentWorkshop.nativeMlo then
        local shutterHash=model(sh.model)
        if stopped or workshop~=currentWorkshop then return end
        if shutterHash then local p=world(sh);local entity=own(CreateObjectNoOffset(shutterHash,p.x,p.y,p.z,false,false,false),shutterHash)
            if entity~=0 then entities.shutter=entity;SetEntityHeading(entity,origin.heading);FreezeEntityPosition(entity,true) end end
    end
    local chair=depot.managerChair
    local chairPosition
    if chair then
        local chairHash=model(chair.model,3000)
        if stopped or workshop~=currentWorkshop then return end
        if chairHash then
            local p=world(chair)

            local entity=own(CreateObjectNoOffset(chairHash,p.x,p.y,p.z+(chair.originOffsetZ or 0),false,false,false),chairHash)
            if entity~=0 then
                entities.managerChair=entity;chairPosition=p
                SetEntityHeading(entity,p.heading);FreezeEntityPosition(entity,true)
            end
        end
    end
    local pedHash=model(C.managerModel)
    if stopped or workshop~=currentWorkshop then return end
    if pedHash then
        local pos=world(C.depot.managerPed or C.depot.manager)
        local entity=own(CreatePed(4,pedHash,pos.x,pos.y,pos.z,pos.heading,false,false),pedHash)
        if entity~=0 then
            entities.manager=entity;SetEntityInvincible(entity,true);SetBlockingOfNonTemporaryEvents(entity,true);FreezeEntityPosition(entity,true)
            if chairPosition then
                TaskStartScenarioAtPosition(entity,'PROP_HUMAN_SEAT_CHAIR',chairPosition.x,chairPosition.y,
                    chairPosition.z+(chair.seatHeight or .45),pos.heading,0,true,true)
            end
        end
    end
    for _,name in ipairs({'officeDoor','innerDoor','rack'}) do
        local definition=depot[name]
        if definition and not currentWorkshop.nativeMlo then
            local hash=model(definition.model)
            if stopped or workshop~=currentWorkshop then return end
            if hash then local p=world(definition)
                local entity=own(CreateObjectNoOffset(hash,p.x,p.y,p.z,false,false,false),hash)
                if entity~=0 then
                    entities[name]=entity
                    local heading=p.heading
                    if name=='innerDoor' then

                        local open=innerDoorHasPasserby(definition,GetEntityCoords(PlayerPedId()))
                        currentWorkshop.innerDoorAmount=open and 1 or 0
                        currentWorkshop.innerDoorHeldUntil=open and (GetGameTimer()+(definition.closeDelayMs or 1200)) or 0
                        heading=heading+currentWorkshop.innerDoorAmount*(definition.yaw or 90)
                    end
                    SetEntityHeading(entity,heading);FreezeEntityPosition(entity,true)
                end
            end
        end
    end
end

RegisterCommand(C.command,function()
    if dist(GetEntityCoords(PlayerPedId()),world(C.depot.manager))<3 then manager()
    else SetNewWaypoint(depot.x,depot.y);tell(ScootText('notify.depotWaypoint')) end
end,false)
RegisterCommand('scootjobplace',function()
    local result=call('place')
    tell(result.ok and ScootText('notify.depotSaved') or result.message or ScootText('err.placementRefused'),result.ok and 'success' or 'error')
end,false)
RegisterNetEvent(NS..'reset',function(_,token)
    if source~=65535 then return end
    if token then resetSessions[token]=true end
    if token and state.session and state.session.token~=token then return end
    closeCollectionUi('sessionReset');uiGarageCache=nil;uiMutation=nil;uiTicket=nil
    if dressingSession and lib.cancelProgress then pcall(lib.cancelProgress) end
    dressingSession=nil
    placementHold=nil
    if action then stopOwnedPose(action.ped) end
    workerGeneration=workerGeneration+1
    action=nil;busy=false;recoveryRequest=nil;state.session=nil;clearCarry();restoreUniform()
end)

CreateThread(function()
    while not stopped do
        local result=call('snapshot')
        if result.ok then updateMarkers() end
        Wait(C.snapshotMs)
    end
end)
CreateThread(function()
    while not stopped do
        local pos=GetEntityCoords(PlayerPedId())
        local near=dist(pos,depot)<(depot.streamDistance or 150)
        if near then warmCollectionAssets() end
        if workshop and (not near or not renderOrigin or dist(renderOrigin,depot)>.01 or renderOrigin.heading~=depot.heading) then destroyWorkshop() end
        if near and not workshop then buildWorkshop() end
        if workshop then updateMloDoors() end
        Wait(1000)
    end
end)
CreateThread(function()
    while not stopped do
        local ped=PlayerPedId();local position=GetEntityCoords(ped);local sleep=250
        promptReset()
        if not state.session and uniformApplied then restoreUniform() end

        local renderNearby=renderFleet()
        if renderNearby or action or (workshop and workshop.entities.shutter) then sleep=0 end

        if action and not action.completed then
            blockActionControls();placementCollision(action.ped,action.placementAnchor)
        elseif placementHold then
            sleep=0;placementCollision(placementHold.ped,placementHold.anchor)
        end
        if workshop and not workshop.nativeMlo and workshop.entities.shutter then
            local near=dist(position,world({x=0,y=0,z=0}))<8.5
            local target=near and 1 or 0
            workshop.door=workshop.door+(target-workshop.door)*math.min(1,GetFrameTime()*1.4)
            local point=world(depot.shutter);SetEntityCoordsNoOffset(workshop.entities.shutter,point.x,point.y,point.z+workshop.door*(depot.shutter.travel or 2.9),false,false,false)
            SetEntityVisible(workshop.entities.shutter,workshop.door<.99,false)
            SetEntityCollision(workshop.entities.shutter,workshop.door<.99,true)
        end
        if workshop and not workshop.nativeMlo and workshop.entities.officeDoor then
            local target=dist(position,world(depot.officeDoor))<2.3 and 1 or 0
            workshop.pedDoor=workshop.pedDoor+(target-workshop.pedDoor)*math.min(1,GetFrameTime()*2)
            SetEntityHeading(workshop.entities.officeDoor,depot.heading+workshop.pedDoor*depot.officeDoor.yaw)
        end
        if updateInnerDoor(position) then sleep=0 end
        if workshop and not workshop.nativeMlo and dist(position,depot)<22 then
            for _,offset in ipairs(depot.lightPoints or {}) do local p=world(offset);DrawLightWithRange(p.x,p.y,p.z,225,238,244,5.5,1.1) end
        end
        if carryingId() and (not action or action.completed or not action.nativeStarted) then
            sleep=0
            if alive(ped) and not IsPedInAnyVehicle(ped,false) then
                if not localCarry or localCarry.ped~=ped then
                    clearCarry();localCarry={ped=ped,lastTry=-1000,missingSince=GetGameTimer()}
                end
                blockCarryControls()
                local carry=clipOf('carry')
                if carry and IsEntityPlayingAnim(ped,carry.dict,carry.clip,3) then localCarry.missingSince=nil
                elseif carry then
                    localCarry.missingSince=localCarry.missingSince or GetGameTimer()

                    RequestAnimDict(carry.dict)
                    if HasAnimDictLoaded(carry.dict) and GetGameTimer()-localCarry.lastTry>=500 then
                        TaskPlayAnim(ped,carry.dict,carry.clip,carry.blendIn or 4.0,carry.blendOut or -4.0,-1,carry.flag or 49,0.0,false,false,false)
                        localCarry.lastTry=GetGameTimer()
                    end
                    if GetGameTimer()-localCarry.missingSince>=5000 then requestCarryRecovery() end
                end
                if not busy and not IsNuiFocused() and not IsPauseMenuActive() and IsControlJustPressed(0,47) then
                    local id=carryingId();CreateThread(function() beginAction('drop',id) end)
                end
            else clearCarry();requestCarryRecovery() end
        else clearCarry() end
        if not busy and alive(ped) and not IsPedInAnyVehicle(ped,false) and not IsNuiFocused() then
            local choice,nearest=nil,C.interactionDistance
            local function offer(point,text,callback,displayPoint,vehicle)
                local distance=dist(position,point)
                if distance<C.interactionDistance and (not choice or distance<nearest) then
                    nearest=distance;choice={point=displayPoint or point,text=text,callback=callback,vehicle=vehicle}
                end
            end
            local managerPoint=managerPromptPoint()
            if managerPoint then offer(world(C.depot.manager),'~INPUT_CONTEXT~ '..ScootText('prompt.talk'),manager,managerPoint) end
            if state.session then

                if not state.session.carrying then offer(world(C.depot.locker),'~INPUT_CONTEXT~ '..ScootText('prompt.clothes'),dress) end
                if not state.session.carrying then
                    for _,item in ipairs(state.fleet or {}) do
                        if item.state=='ground' and item.coords and not item.reservedBy then
                            local vehicle=collectionEntity(item.netId,'scooter',item.token,item.id)
                            if vehicle~=0 then
                                local targetId=item.id;offer(GetEntityCoords(vehicle),'~INPUT_CONTEXT~ '..ScootText('prompt.collect'),function() beginAction('pickup',targetId) end,nil,vehicle)
                            end
                        end
                    end
                    local adoptVehicle,adoptNetId=nearestAdoptable(position)
                    if adoptVehicle~=0 then
                        local v=GetEntityCoords(adoptVehicle)
                        offer({x=v.x,y=v.y,z=v.z},'~INPUT_CONTEXT~ '..ScootText('prompt.collect'),function() beginAction('pickup',nil,nil,adoptNetId) end,nil,adoptVehicle)
                    end
                end
                local truck,vehicle=workTruck()
                if vehicle~=0 and GetEntitySpeed(vehicle)<=C.truck.maxLoadSpeed then
                    for index,slot in ipairs(C.truck.slots) do
                        local loadId=truck.slots and (truck.slots[tostring(index)] or truck.slots[index])
                        local usable=state.session.carrying and not loadId or not state.session.carrying and loadId
                        if usable then
                            for _,side in ipairs({-1,1}) do
                                local point=GetOffsetFromEntityInWorldCoords(vehicle,side*(C.truck.promptSide or 1.60),slot.y,-(C.truck.groundOffset or 1.2554745))
                                point={x=point.x,y=point.y,z=point.z}
                                local targetSlot=index;local scooterId=state.session.carrying or loadId

                                offer(point,'~INPUT_CONTEXT~ '..ScootText(state.session.carrying and 'prompt.load' or 'prompt.unload'),function()
                                    beginAction(state.session.carrying and 'load' or 'unload',scooterId,targetSlot)
                                end)
                            end
                        end
                    end
                    if countSlots(truck)>0 and not state.session.carrying and dist(GetEntityCoords(vehicle),world(C.depot.returns))<10 then
                        offer(world(C.depot.returns),'~INPUT_CONTEXT~ '..ScootText('prompt.deliver'),function() beginAction('service') end)
                    end
                end
            end
            ScootCollectionPickupTarget=choice and choice.vehicle or nil
            if choice then
                sleep=0;prompt3d(choice.point,choice.text)
                if IsControlJustPressed(0,38) then local callback=choice.callback;CreateThread(callback) end
            end
            if managerPoint and not (choice and choice.callback==manager)
                and dist(position,world(C.depot.manager))<(C.managerRingRange or 8.0) then
                local glyph,label=ScootPromptKey('~INPUT_CONTEXT~ '..ScootText('prompt.talk'))
                promptFrame[#promptFrame+1]={key=glyph,label=label,world=managerPoint,offsetZ=.45,
                    promptRange=0.0,range=C.managerRingRange or 8.0}
            end
        elseif not busy then ScootCollectionPickupTarget=nil end
        if carryingId() then
            sleep=0;screenPrompt('~INPUT_DETONATE~ '..ScootText('prompt.putDown'))
        end
        promptFlush()
        Wait(sleep)
    end
end)

AddEventHandler('onClientResourceStart',function(name)
    if name=='loop-pausemenu' then for key in pairs(marks) do clearMarker(key) end;updateMarkers() end
end)
AddEventHandler('onResourceStop',function(name)
    if name~=GetCurrentResourceName() then return end
    stopped=true
    promptReset()
    ScootPrompts.Clear('collection')
    ScootUI.CancelProgress()
    closeCollectionUi('resourceStopped')
    placementHold=nil
    workerGeneration=workerGeneration+1
    if action then stopOwnedPose(action.ped) end
    clearCarry();restoreUniform();destroyWorkshop()
    for _,entity in pairs(visuals) do remove(entity) end
    observedMotions={};groundVisuals={}
    local keys={};for key in pairs(marks) do keys[#keys+1]=key end;for _,key in ipairs(keys) do clearMarker(key) end
    if lib.getOpenContextMenu and lib.getOpenContextMenu()=='scoot_collection_manager' then lib.hideContext(false) end
end)

local CINE = 'loop-cine'
local cineResults = {}
local function cineCaller() return GetInvokingResource() == CINE end
local function cineRun(key, fn)
    cineResults[key] = nil
    CreateThread(function()
        local ok, res = pcall(fn)
        cineResults[key] = ok and (res or { ok = true }) or { ok = false, message = tostring(res) }
    end)
end
exports('CineJobPoints', function()
    if not cineCaller() then return nil end
    local function pt(o) local p = world(o) return { x = p.x, y = p.y, z = p.z, heading = p.heading } end
    return { origin = { x = depot.x, y = depot.y, z = depot.z, heading = depot.heading },
        manager = pt(C.depot.manager), managerPed = pt(C.depot.managerPed or C.depot.manager),
        locker = pt(C.depot.locker), truckSpawn = pt(C.depot.truckSpawn), returns = pt(C.depot.returns) }
end)
exports('CineJobManager', function(open)
    if not cineCaller() then return false end
    if not open then
        if collectionUi and closeCollectionUi then closeCollectionUi('cine') end
        return true
    end
    if collectionUi then return true end
    local lease = ScootUiFocus.Acquire('collection')
    if not lease then return false end
    uiSerial = uiSerial + 1
    local u = { generation = uiSerial, sequence = 0, ped = PlayerPedId(), lease = lease, view = 'manager', lastRequest = 0,
        navigation = 0, loading = true, nextRefresh = GetGameTimer() + 2000 }
    collectionUi = u
    if emitUi('open') then refreshUi(u, 0, nil) end
    return true
end)
exports('CineJobDuty', function()
    if not cineCaller() then return false end
    cineRun('duty', function() return call('duty', true) end)
    return true
end)
exports('CineJobTruck', function()
    if not cineCaller() then return false end
    cineRun('truck', function() return call('truck') end)
    return true
end)
exports('CineJobDress', function()
    if not cineCaller() then return false end
    cineRun('dress', function() dress() return { ok = uniformApplied == true } end)
    return true
end)
exports('CineJobResult', function(key)
    if not cineCaller() then return nil end
    return cineResults[key]
end)
exports('CineJobState', function()
    if not cineCaller() then return nil end
    local s = state.session
    local _, vehicle = workTruck()
    local p = GetEntityCoords(PlayerPedId())
    local nearest = nil
    for _, item in ipairs(state.fleet or {}) do
        if item.state == 'ground' and item.coords and not item.reservedBy then
            local d = #(p - vector3(item.coords.x, item.coords.y, item.coords.z))
            if not nearest or d < nearest.d then
                nearest = { id = item.id, d = d, x = item.coords.x, y = item.coords.y, z = item.coords.z }
            end
        end
    end
    return { session = s ~= nil, carrying = s and s.carrying or nil, truck = vehicle or 0, busy = busy,
        uniform = uniformApplied == true, nearest = nearest }
end)
exports('CineJobPickup', function(id)
    if not cineCaller() then return false end
    CreateThread(function() beginAction('pickup', id) end)
    return true
end)
exports('CineJobLoad', function(slot)
    if not cineCaller() then return false end
    local id = carryingId()
    if not id then return false end
    CreateThread(function() beginAction('load', id, slot) end)
    return true
end)
