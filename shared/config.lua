Config = {}
Config.Model = 'loop_scooter'
Config.VehicleType = 'bike'
Config.VehicleLoadTimeout = 20000
Config.VehicleHeadingOffset = 90.0
Config.Price = 0
Config.Account = 'money'
Config.RentalDuration = 30 * 60
Config.InteractionDistance = 4.5
Config.ReturnDistance = 6.0
Config.LostGraceMs = 15000
Config.ResetClearance = 1.3
Config.SpawnTimeout = 5000
Config.StreamDistance = 125.0
Config.UnloadDistance = 155.0
Config.MaxSpeed = 48.0 / 3.6
Config.Rider = {
    enabled = true,
    autoStartEngine = false,
    engineCommand = 'scootengine',
    engineKey = '',
    enginePromptKey = 'M3',
    launchStyle = 'electric',
    launchDuration = 350,
    maxMountSpeed = 0.55,
    maxDismountSpeed = 1.1,
    maxTransitionTilt = 4.0,
    pushDuration = 1400,
    stopDuration = 700,
    pushMaxSpeed = 3.0,
    minHold = 240,
    retryMs = 2000,

    steeringPoses = false,
    brakePose = false,
    steerFollow = true,
    steerLock = 32.0,
    steerPivotOffset = 0.13,

    resumeMs = 3000,
    transitionTimeoutMs = 12000,
}
Config.Delivery = {
    prepareTimeout = 15000,
    startLead = 300,
    phoneCloseDelay = 1400,
}
Config.OpenCommand = 'scoot'
Config.OpenKey = ''
Config.AdminAce = 'loop.scoot.admin'
Config.Debug = false
Config.Language = 'auto'
Config.Models = {
    base = 'loop_scoot_base', body = 'loop_scoot_body',
    door = 'loop_scoot_door', tray = 'loop_scoot_tray',
    grip = 'loop_scoot_grip',
    rail_a = 'loop_scoot_rail_a', rail_b = 'loop_scoot_rail_b'
}

Config.RailTravel = { rail_a = 0.34, rail_b = 0.67 }

Config.Geometry = {
    height = 1.622, plinth = 0.08,
    doorTravel = 1.442,
    extractDistance = 1.82,
    vehicleLift = 0.16,
    vehiclePresentedLift = 0.035,
    vehicleClearanceTravel = 1.58,
    gripRehomeTravel = 0.20,
    vehicleGroundOffset = 0.0
}

Config.Timeline = {
    riseStart = 50, riseEnd = 2900,
    risePower = 0.772,
    doorStart = 3850, doorEnd = 6280,

    extendStart = 6033, extendEnd = 8333,
    lowerStart = 9167, lowerEnd = 9367,
    armReturnStart = 9733, armReturnEnd = 10200, release = 10200,
    closeStart = 12300, closeEnd = 13933,
    resetStart = 30000, resetEnd = 32633
}
Config.Stations = {
    { id = 'vespucci',  label = 'Vespucci Beach',  capacity = 8,
      coords = vector3(-1216.85, -1503.73, 3.37),  heading = 35.0 },
    { id = 'delperro',  label = 'Del Perro Pier',  capacity = 6,
      coords = vector3(-1603.60, -1016.60, 12.15), heading = 145.0 },
    { id = 'legion',    label = 'Legion Square',   capacity = 10,
      coords = vector3(215.20, -880.50, 30.49),    heading = 250.0 },
    { id = 'pillbox',   label = 'Pillbox Hill',    capacity = 6,
      coords = vector3(303.60, -600.40, 43.28),    heading = 70.0 },
    { id = 'mirrorpark', label = 'Mirror Park',    capacity = 6,
      coords = vector3(1136.80, -639.90, 56.72),   heading = 180.0 },
    { id = 'vinewood',  label = 'Vinewood Blvd',   capacity = 6,
      coords = vector3(297.40, 200.30, 104.38),    heading = 340.0 },
}
Config.NativePhone = false

Config.Bridge = {
    framework = 'auto',
    vehicleKeys = 'auto',
    standaloneMoney = nil,
}

Config.UI = {
    notify = 'loop',
    progress = 'loop',
    notifyDuration = 4500,
}

Config.Standalone = {
    engineMapper = 'MOUSE_BUTTON',
    engineKey = 'MOUSE_MIDDLE',
    interact = {
        range = 6.0,
        promptRange = 2.0,
        k = 54.0,
        labelMinScale = 0.85,
        fade = 183,
        followTick = 33,
        maxMarkers = 6,
        centerHysteresis = 24,
        inVehicle = false,
    },
}

Config.StationDisplay = { enabled = false, distance = 9.0 }
Config.ScooterDisplay = { enabled = false, distance = 6.0 }
Config.ScooterEnergy = { enabled = true, rangeKm = 55, sampleMs = 1000, publishMs = 5000 }
