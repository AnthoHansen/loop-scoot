Scoot = {}
Scoot.RetractAt = Config.Timeline.resetStart

local function clamp(v) return math.max(0.0, math.min(1.0, v)) end
local function fraction(t, a, b)
    if b <= a then return t >= b and 1.0 or 0.0 end
    return clamp((t - a) / (b - a))
end

local function smooth(v) return v*v*v*(v*(v*6.0-15.0)+10.0) end
local function smoothCubic(v) return v*v*(3.0-2.0*v) end

function Scoot.Transform(station, p)
    local h = math.rad(station.heading or 0)
    local c, s = math.cos(h), math.sin(h)
    return vector3(station.coords.x + p.x*c - p.y*s,
        station.coords.y + p.x*s + p.y*c, station.coords.z + p.z)
end

function Scoot.FindStation(id)
    for _, station in ipairs(Config.Stations) do
        if station.id == id then return station end
    end
end

function Scoot.Sequence(milliseconds)
    local t, k, g = math.max(0, milliseconds or 0), Config.Timeline, Config.Geometry
    local rise = smooth(fraction(t, k.riseStart, k.riseEnd) ^ (k.risePower or 1.0))
    local reset = smooth(fraction(t, k.resetStart, k.resetEnd))
    local bodyZ = g.plinth - g.height * (1.0 - rise + reset)
    local door = smoothCubic(fraction(t, k.doorStart, k.doorEnd))
        * (1.0 - smooth(fraction(t, k.closeStart, k.closeEnd)))
    local extend = smooth(fraction(t, k.extendStart, k.extendEnd))
    local clearance = smooth(fraction(g.extractDistance*extend,
        g.vehicleClearanceTravel or g.extractDistance, g.extractDistance))
    local lower = smooth(fraction(t, k.lowerStart, k.lowerEnd or k.release))
    local armReturn = smooth(fraction(t, k.armReturnStart or k.lowerStart, k.armReturnEnd or k.release))
    local presentedLift = g.vehiclePresentedLift or g.vehicleLift
    local lift = (g.vehicleLift+(presentedLift-g.vehicleLift)*clearance)*(1.0-lower)

    local rehome = smooth(fraction(g.extractDistance*armReturn, 0.0, g.gripRehomeTravel or 0.20))
    local released = t >= k.release
    local phase = 'preparing'
    if t >= k.riseStart then phase = 'rising' end
    if t >= k.riseEnd then phase = 'raised' end
    if t >= k.doorStart then phase = 'opening' end
    if t >= k.extendStart then phase = 'extracting' end
    if t >= k.extendEnd then phase = 'presenting' end
    if t >= k.lowerStart then phase = 'lowering' end
    if k.lowerEnd and t >= k.lowerEnd then phase = 'presented' end
    if k.armReturnStart and t >= k.armReturnStart then phase = 'arm_return' end
    if released then phase = 'released' end
    if t >= k.closeStart then phase = 'closing' end
    if t >= k.closeEnd then phase = 'waiting' end
    if t >= k.resetStart then phase = 'retracting' end
    if t >= k.resetEnd then phase = 'idle' end
    return {
        phase = phase, bodyZ = bodyZ, doorZ = bodyZ - door * g.doorTravel,
        trayX = -g.extractDistance * extend * (1.0-armReturn),
        trayZ = bodyZ,

        gripZ = bodyZ + lift - g.vehicleLift + rehome*g.vehicleLift,
        vehicleOffset = vector3(-g.extractDistance*extend, 0.0,
            g.vehicleGroundOffset + bodyZ + lift - g.plinth),
        released = released, complete = t >= k.resetEnd,
        retracting = t >= k.resetStart, doorOpen = door,
        vehicleLowered = lower, armReturned = armReturn,
    }
end

function Scoot.IdlePose()
    return Scoot.Sequence(0)
end
