ScootRider = {}
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
local function number(n,fallback)
    return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge and n or fallback
end
function ScootRider.New(side)
    return {side=side==-1 and -1 or 1, mode='idle', clip=nil, changedAt=-10000,
        steer=0, moving=false, armed=true, pushUntil=nil}
end
function ScootRider.Update(s,input,settings)
    local cfg=settings or {}
    local electric=cfg.launchStyle=='electric'
    local launchDuration=electric and clamp(number(cfg.launchDuration,350),200,1000) or (cfg.pushDuration or 1400)
    local now=number(input.now,0)
    local elapsed=s.lastAt and math.max((now-s.lastAt)/1000,0) or .05
    local dt=clamp(elapsed,0,.25)
    local speed=math.max(0,number(input.speed,0))
    local throttle=clamp(number(input.throttle,0),0,1)
    local brake=clamp(number(input.brake,0),0,1)
    local forward=number(input.forwardSpeed,speed)
    local raw=clamp(number(input.steer,0),-1,1)
    local alpha=1-math.exp(-dt/.10)
    s.steer=s.steer+(raw-s.steer)*alpha
    local accel=s.lastSpeed and elapsed>0 and (speed-s.lastSpeed)/elapsed or 0
    s.lastAt,s.lastSpeed=now,speed
    if input.blocked or input.airborne then
        s.pushUntil=nil;s.pushPlayedUntil=nil;s.stopUntil=nil;s.stopPlayedUntil=nil
        s.stoppedAt=nil;s.armed=false;s.clip=nil;s.mode='blocked';s.moving=false
        return nil
    end
    local wasMoving=s.moving
    s.moving=speed>.60 or (s.moving and speed>.28)

    if s.moving or forward<-.10 then s.armed=false end
    if speed<.20 and forward>=-.10 and throttle<.12 then
        s.stoppedAt=s.stoppedAt or now
        if now-s.stoppedAt>=250 then s.armed=true end
    else s.stoppedAt=nil end
    local suffix=s.side==-1 and 'left' or 'right'
    if wasMoving and not s.moving and throttle<.12 then
        s.stopUntil=now+(cfg.stopDuration or 700);s.stopPlayedUntil=nil
    end

    if s.stopUntil and (now>=s.stopUntil or s.moving or throttle>.18) then
        s.stopUntil=nil;s.stopPlayedUntil=nil
    end
    if s.pushUntil and (now>=s.pushUntil or (not electric and speed>=(cfg.pushMaxSpeed or 3.0))
        or forward<-.10 or throttle<=.10 or brake>=.10) then
        s.pushUntil=nil;s.pushPlayedUntil=nil
    end

    local braking=cfg.brakePose==true and s.moving and (brake>.18 or (accel<-2.0 and throttle<.12))
    local mode,clip,loop='cruise','ride_cruise',true
    if braking then
        s.pushUntil=nil;s.pushPlayedUntil=nil;mode,clip='brake','ride_brake'
    elseif s.stopUntil then
        mode,clip,loop='stop','stop_'..suffix,false
    elseif s.pushUntil then
        mode,clip,loop='push',(electric and 'lift_' or 'push_off_')..suffix,false
    elseif s.armed and not s.moving and forward>=-.10 and throttle>.18 and brake<.1 then
        s.armed=false;s.pushUntil=now+launchDuration;s.pushPlayedUntil=nil
        mode,clip,loop='push',(electric and 'lift_' or 'push_off_')..suffix,false
    elseif not s.moving then
        s.pushUntil=nil;mode='idle';clip=s.side==-1 and 'ride_idle_left' or 'ride_idle'
    else
        s.pushUntil=nil
        local turning=s.mode=='turn' or s.mode=='lean'
        if cfg.steeringPoses==true and math.abs(s.steer)>(turning and .10 or .22) and forward>.20 then
            local fast=speed>(s.mode=='lean' and 4.0 or 4.5)
            mode=fast and 'lean' or 'turn'
            clip='ride_'..mode..'_'..(s.steer<0 and 'left' or 'right')
        end
    end

    local priority=mode=='brake' or mode=='idle' or mode=='push' or mode=='stop'
        or s.mode=='push' or s.mode=='stop' or s.mode=='blocked'
    if s.clip and clip~=s.clip and not priority and now-s.changedAt<(cfg.minHold or 240) then
        mode,clip,loop=s.mode,s.clip,s.mode~='push' and s.mode~='stop'
    end
    if clip~=s.clip then s.changedAt=now end
    s.mode,s.clip=mode,clip
    local rate=mode=='cruise' and clamp(.86+speed*.018,.86,1.1) or 1.0
    return {mode=mode,clip=clip,loop=loop,rate=rate,
        durationMs=mode=='push' and electric and launchDuration or nil}
end
