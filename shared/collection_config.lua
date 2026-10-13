local Motion = ScootCollectionMotion
Config.Collection = {
    enabled = true,
    command = 'scootjob',
    bucket = 0,
    allowedJob = nil,
    payPerScooter = 35,
    payAccount = 'money',
    maxWorkers = 8,
    interactionDistance = 1.8,
    snapshotMs = 3000,
    actionTimeoutMs = 12000,
    respawnMs = 10 * 60 * 1000,
    pickupMs = 1900, loadMs = Motion.durations.load,
    unloadMs = Motion.durations.unload, dropMs = 1900, serviceMs = 2200,
    scooterModel = 'loop_scooter',
    carryModel = 'loop_scoot_carry',
    carryModels = { 'loop_scoot_carry', 'loop_scoot_carry_fold1', 'loop_scoot_carry_fold' },

    animations = {
        pickup = { dict = 'pickup_object', clip = 'pickup_low', flag = 2, vanilla = true, blendIn = 3.0, blendOut = -3.0 },
        carry  = { dict = 'anim@heists@narcotics@trash', clip = 'idle', flag = 49, vanilla = true, blendIn = 3.0, blendOut = -3.0 },
        load   = { dict = 'loop_scoot_collection_v1290', clip = 'collect_load', flag = 2, sided = true },
        unload = { dict = 'loop_scoot_collection_v1290', clip = 'collect_unload', flag = 2, sided = true },
        drop   = { dict = 'pickup_object', clip = 'pickup_low', flag = 2, vanilla = true, blendIn = 3.0, blendOut = -3.0 },
    },

    carryPose = {
        bone = 57005, yaw = 14.0,
        grip = { x = 0.0, y = 0.0, z = 0.53 },
        palm = { x = 0.02, y = 0.08, z = -0.06 },
        fallback = { x = 0.47, y = 0.09, z = -0.59 },
        pickup = { stage2 = 0.28, stage3 = 0.38, liftFrom = 0.40, liftTo = 0.78 },
        drop = { lowerFrom = 0.18, lowerTo = 0.42, stage2 = 0.44, stage1 = 0.52, groundAt = 0.52 },
        stepMs = 150,
    },

    carryAttach = Motion.carry,
    pickupDistance = 0.55,

    collectRentals = true, rentalGuardRadius = 40.0,
    -- Pay per collected customer rental. Keep it at 0 while rentals are free (Config.Price = 0),
    -- or two players can rent and hand in the same scooter for money.
    payPerRental = 0,

    depot = { x = 772.2295, y = -1264.0328, z = 25.368, heading = 180.0, nativeMlo = true,

        model = 'loop_scoot_site_shell', manager = { x = 6.10, y = 6.10, z = 0.03, heading = 180.0 },
        managerPed = { x = 4.85, y = 6.10, z = 0.03, heading = 180.0 },
        managerChair = { model = 'loop_scoot_off48_chair', x = 4.85, y = 6.10, z = 0.03, heading = 180.0,
            originOffsetZ = 0.0, seatHeight = 0.45908 },
        locker = { x = 1.15, y = 8.7, z = 0.03 },
        returns = { x = 0.0, y = -6.5, z = 0.0 },
        truckSpawn = { x = -0.26, y = 4.10, z = 0.13, heading = 180.0 },

        shutter = { model = 'loop_scoot_site_shutter', x = 0.0, y = 0.06, z = 0.03,
            heading = 0.0, automaticDistance = 8.0, movementRate = 0.8, travel = 3.26 },
        officeDoor = { model = 'loop_scoot_off48_frontdoor', x = 4.1257245283, y = 0.12, z = 1.180039,
            heading = 0.0, automaticDistance = 0.0, movementRate = 1.0, yaw = -95 },
        innerDoor = { model = 'loop_scoot_off48_door', x = 4.1257245283, y = 9.32, z = 1.19,
            heading = 0.0, automaticDistance = 0.0, movementRate = 1.0,
            yaw = 90.0, openDistance = 2.35, closeDelayMs = 1200, degreesPerSecond = 90.0 },
        rack = { model = 'loop_scoot_site_rack', x = -0.2, y = 13.25, z = 0.03, placedInMlo = true },
        lightPoints = {},
        streamDistance = 150.0,
    },
    managerModel = 's_m_m_autoshop_01',
    truck = { model = 'loop_scoot_truck', type = 'automobile', capacity = 7,
        displayName = 'SCOOT CARGO 26',
        primaryColour = {226,232,235}, secondaryColour = {21,26,31}, dirtLevel = 0.0,
        maxLoadSpeed = 0.15, maxTilt = 8.0, bedZ = -0.04893,

        groundOffset = 1.2554745, approachSide = 1.95, promptSide = 1.60,
        transfer = { depositPhase = Motion.paths.load_left.attachTruckFrom },

        slots = {
            {x=0.0,y=0.90,z=-0.03393,heading=90.0}, {x=0.0,y=0.25,z=-0.03393,heading=90.0},
            {x=0.0,y=-0.40,z=-0.03393,heading=90.0}, {x=0.0,y=-1.05,z=-0.03393,heading=90.0},
            {x=0.0,y=-1.70,z=-0.03393,heading=90.0}, {x=0.0,y=-2.35,z=-0.03393,heading=90.0},
            {x=0.0,y=-3.00,z=-0.03393,heading=90.0},
        },
    },

    uniform = {
        keepOwnOutfit = false,
        male = {
            components = {
                {11, collection = '', drawable = 0, texture = 0},
                {3, collection = '', drawable = 0, texture = 0},
                {8, collection = '', drawable = 15, texture = 0},
                {4, collection = '', drawable = 4, texture = 0},
                {6, collection = '', drawable = 1, texture = 0},
            },
            props = {},
        },
        female = {
            components = {
                {11, collection = '', drawable = 0, texture = 0},
                {3, collection = '', drawable = 14, texture = 0},
                {8, collection = '', drawable = 15, texture = 0},
                {4, collection = '', drawable = 3, texture = 0},
                {6, collection = '', drawable = 3, texture = 0},
            },
            props = {},
        },
    },

    fleet = {

        {id='depot_front',x=777.70,y=-1259.00,z=25.40,heading=0.0},
        {id='cypress_01',x=934.70,y=-2530.50,z=28.30,heading=35.0},
        {id='cypress_02',x=859.70,y=-2150.60,z=30.20,heading=180.0},
        {id='la_mesa_01',x=786.35,y=-1370.60,z=26.35,heading=270.0},
        {id='mission_row_01',x=415.30,y=-1023.30,z=29.30,heading=180.0},
        {id='legion_01',x=216.20,y=-903.20,z=30.70,heading=50.0},
        {id='pillbox_01',x=279.80,y=-610.20,z=43.25,heading=65.0},
        {id='vespucci_01',x=-1195.30,y=-1515.10,z=4.37,heading=125.0},
        {id='little_seoul_01',x=-700.20,y=-917.50,z=19.20,heading=270.0},
        {id='davis_01',x=152.50,y=-1711.40,z=29.30,heading=45.0},
        {id='airport_01',x=-1009.50,y=-2695.30,z=13.98,heading=155.0},
    },
}

ScootCollection = {}
function ScootCollection.World(origin, offset)
    local angle = math.rad(origin.heading or 0)
    return { x = origin.x + offset.x * math.cos(angle) - offset.y * math.sin(angle),
        y = origin.y + offset.x * math.sin(angle) + offset.y * math.cos(angle),
        z = origin.z + (offset.z or 0), heading = ((origin.heading or 0) + (offset.heading or 0)) % 360 }
end
function ScootCollection.Distance(a,b)
    return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)
end
