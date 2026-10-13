fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'loop-scoot'
author 'LOOP Studios'
description 'Scooter rental stations and SCOOT collector job'
version '1.41.0'
repository 'https://github.com/loopfivem/loop-scoot'
license 'MIT'

dependencies { 'ox_lib', '/onesync' }
shared_scripts { '@ox_lib/init.lua', 'shared/locales.lua', 'shared/config.lua', 'shared/sequence.lua', 'shared/rider.lua', 'shared/collection_motion.lua', 'shared/collection_config.lua' }
client_scripts { 'client/bridge.lua', 'client/feedback.lua', 'client/ui_focus.lua', 'client/interact.lua', 'client/prompt_bus.lua', 'client/main.lua', 'client/kiosk.lua', 'client/collection.lua', 'client/scooter_display.lua', 'client/station_display.lua', 'client/scooter_energy.lua' }
server_scripts { 'server/bridge.lua', 'server/main.lua', 'server/collection.lua', 'server/scooter_energy.lua', 'server/diagnostics.lua', 'server/version.lua' }
server_export 'GetScootRentalBlips'
ui_page 'web/index.html'
files {
    'web/index.html', 'web/base.css', 'web/collection.css', 'web/collection.js', 'web/assets/*', 'web/mechanism.js',
    'web/loop-overlay.css', 'web/loop-overlay.js',
    'data/*.meta', 'stream/*.ytyp', 'web/scooter-display/*', 'web/station-display/*'
}
data_file 'DLC_ITYP_REQUEST' 'stream/loop_scoot.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/loop_scoot_collection.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/loop_scoot_site.ytyp'
this_is_a_map 'yes'
data_file 'HANDLING_FILE' 'data/handling.meta'
data_file 'VEHICLE_METADATA_FILE' 'data/vehicles.meta'
data_file 'VEHICLE_VARIATION_FILE' 'data/carvariations.meta'
data_file 'HANDLING_FILE' 'data/collection_handling.meta'
data_file 'VEHICLE_LAYOUTS_FILE' 'data/collection_vehiclelayouts.meta'

data_file 'VEHICLE_METADATA_FILE' 'data/collection_vehicles.meta'
data_file 'VEHICLE_VARIATION_FILE' 'data/collection_carvariations.meta'
