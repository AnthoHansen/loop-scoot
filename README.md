<p align="center">
  <img src=".github/media/banner.jpg" alt="LOOP Scoot" width="100%">
</p>

<p align="center">
  <a href="https://github.com/loopfivem/loop-scoot/releases/latest"><img src="https://img.shields.io/github/v/release/loopfivem/loop-scoot?style=flat-square&color=2fd6c4" alt="Release"></a>
  <a href="https://github.com/loopfivem/loop-scoot/releases"><img src="https://img.shields.io/github/downloads/loopfivem/loop-scoot/total?style=flat-square&color=2fd6c4" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/loopfivem/loop-scoot?style=flat-square" alt="License"></a>
  <a href="https://discord.gg/loopdev"><img src="https://img.shields.io/badge/Discord-support-5865F2?style=flat-square&logo=discord&logoColor=white" alt="Discord"></a>
</p>

<p align="center">
  Free scooter rental stations and a scooter collector job for FiveM.<br>
  ESX, QBCore, Qbox, ox_core or standalone. No escrow, no obfuscation.
</p>

<p align="center">
  <a href="https://github.com/loopfivem/loop-scoot/releases/latest"><b>Download</b></a> ·
  <a href="https://youtu.be/F-ArhJNoNGI"><b>Video</b></a> ·
  <a href="https://discord.gg/loopdev"><b>Discord</b></a> ·
  <a href="https://loopstudios.fr"><b>Website</b></a>
</p>

<p align="center">
  <img src=".github/media/preview.gif" alt="Preview" width="560">
</p>

## Features

- 6 rental stations in Los Santos with a capacity each, placed in game with an admin command
- Kiosk dialog to rent, return or leave, free or paid rentals
- Electric scooter with its own handling, battery range and engine toggle
- Collector job: clock in, work outfit, work truck with 7 scooter slots, pickups on the map, pay per scooter
- Custom depot site in La Mesa with its own collision and interior
- Framework bridge for ESX, QBCore, Qbox, ox_core and standalone
- Vehicle key adapters for the common key resources
- English and French, automatic language
- `scootdoctor` console report to check the setup

## Video

<a href="https://youtu.be/F-ArhJNoNGI"><img src="https://img.youtube.com/vi/F-ArhJNoNGI/maxresdefault.jpg" alt="LOOP Scoot video" width="720"></a>

## Screenshots

| | |
| --- | --- |
| ![Station](.github/media/station.jpg) | ![Ride](.github/media/ride.jpg) |
| ![Depot](.github/media/depot.jpg) | ![Truck](.github/media/truck.jpg) |
| ![Manager](.github/media/manager.jpg) | ![Lockers](.github/media/lockers.jpg) |

## Requirements

| | |
| --- | --- |
| Server | OneSync enabled |
| Library | `ox_lib` |
| Framework | ESX, QBCore, Qbox, ox_core (with `ox_inventory`), or standalone |
| Game build | GTA V Legacy |

## Installation

1. Download `loop-scoot.zip` from the [latest release](https://github.com/loopfivem/loop-scoot/releases/latest). Do not use the green **Code > Download ZIP** button: it gives a `loop-scoot-main` folder.
2. Extract the `loop-scoot` folder into `resources/`. Do not rename it.
3. In `server.cfg`, after `ox_lib`, your framework and your vehicle keys resource:

   ```cfg
   ensure loop-scoot
   ```

4. Restart the server completely. The resource streams vehicles, props and an interior, so a full restart is safer than a live restart.

No SQL file is needed. The resource does not create any database table.

The server prints a message in the console when a new release is out. Set `setr loop_scoot_versioncheck false` to turn it off.

Run `scootdoctor` in the server console after the first start. It prints a configuration report (framework, keys, economy) and does not touch money or player data. It does not test gameplay.

## Configuration

| File | Purpose |
| --- | --- |
| `shared/config.lua` | Rental: price, account, duration, stations, speed, rider, keys, framework, UI, battery |
| `shared/collection_config.lua` | Collector job: command, pay, allowed job, workers, depot, truck, uniform, fleet points |
| `shared/locales.lua` | English and French texts (`Config.Language = 'auto'`, `'en'` or `'fr'`) |
| `client/bridge.lua` | Client side vehicle keys and engine key bridge |
| `server/bridge.lua` | Framework bridge (money, jobs, admin, identity) and vehicle keys |
| `client/feedback.lua` | Notifications and progress bars (`loop`, `ox`, `esx`, `qb`) |

| Key | Default | Purpose |
| --- | --- | --- |
| `Config.Price` | `0` | Rental price. `0` means free rentals |
| `Config.Account` | `'money'` | Account charged for a rental |
| `Config.RentalDuration` | `30 * 60` | Rental duration in seconds |
| `Config.MaxSpeed` | `48.0 / 3.6` | Scooter top speed (48 km/h) |
| `Config.Stations` | 6 stations | Vespucci Beach, Del Perro Pier, Legion Square, Pillbox Hill, Mirror Park, Vinewood Blvd, with a capacity each |
| `Config.Bridge.framework` | `'auto'` | `auto`, `esx`, `qbcore`, `qbox`, `ox` or `standalone` |
| `Config.Bridge.vehicleKeys` | `'auto'` | `auto`, `none`, a supported system, or a `{ give, remove }` table |
| `Config.UI.notify` | `'loop'` | `loop`, `ox`, `esx` or `qb` |
| `Config.NativePhone` | `false` | `{ resource = 'name' }` to open the station dialog from your own phone resource (`open` and `isPhoneOpen` exports) |
| `Config.ScooterEnergy.rangeKm` | `55` | Battery range of a rental scooter |
| `Config.Collection.payPerScooter` | `35` | Pay per scooter handed in |
| `Config.Collection.allowedJob` | `nil` | Restrict the collector job to one framework job |
| `Config.Collection.maxWorkers` | `8` | Workers on duty at the same time |

`auto` picks the first started framework in this order: ESX, Qbox, QBCore, ox, then standalone. Set the framework explicitly on a production server.

### Frameworks

| Framework | Economy |
| --- | --- |
| `esx` | ESX accounts, `money` is cash |
| `qbcore` | `Player.Functions`, `money` becomes `cash` |
| `qbox` | `qbx_core` server money exports |
| `ox` | `money` item in `ox_inventory` (accounts `money` or `cash` only) |
| `standalone` | Your own adapter: `Config.Bridge.standaloneMoney = { get, add, remove }` in a server-only file loaded before `server/bridge.lua` |

Amounts are whole numbers. For a fully free standalone setup, set `Config.Price = 0` and `Config.Collection.payPerScooter = 0`.

### Vehicle keys

Adapters: `qbx_vehiclekeys`, `qb-vehiclekeys`, `qs-vehiclekeys`, `Renewed-Vehiclekeys`, `wasabi_carlock`, `MrNewbVehicleKeys`. Test giving and removing temporary keys with your version.

## Commands and keys

| Command / key | Effect |
| --- | --- |
| **E** near a station | Open the SCOOT-E station dialog: rent, return my scooter, leave |
| **E** near your scooter | Ride the scooter |
| Middle mouse button | Start or stop the engine (rebindable in FiveM key bindings) |
| `/scoot` | Open the station dialog at the nearest station |
| `/scootjob` | Set a GPS route to the depot, or talk to the manager when you are next to him |
| `/scootmoteur` | Start or stop the work truck engine |
| `/scootjobclose` | Close the job screen if it gets stuck |
| `/scootplace <station>` | Admin: move a station to your position |
| `/scootjobplace` | Admin: save the depot position |
| `scootdoctor` | Server console: configuration report |

Admin commands use the bridge admin check or the ACE `loop.scoot.admin`:

```cfg
add_ace group.admin loop.scoot.admin allow
```

`/scootplace` writes `station_overrides.json` inside the resource folder. Delete that file to go back to the positions from `config.lua`.

## Collector job

Go to the SCOOT depot (`/scootjob`), talk to the manager to clock in, change into the work outfit at the lockers, take the work truck, pick up scooters marked on the map, load them in the 7 truck slots and hand the load in at the depot. Abandoned customer rentals can be collected. Your personal outfit is restored at the end of the shift.

The work outfit uses vanilla freemode components, defined in `Config.Collection.uniform` (`shared/collection_config.lua`). The default is vanilla top number 0 (component 11) with default arms, trousers and shoes. Change the drawable and texture numbers to any vanilla piece you prefer, or point `collection` at a clothing pack of your own. The default numbers were not tested in game and may need tuning.

## Depot site

The depot replaces the original building at its site (around x 772, y -1264, z 25 in La Mesa) with its own collision, building drawables and occlusion file, shipped in `stream` (`id2_06_*`, `id2_occl_00.ymap`). Do not run it alongside another map that also replaces this building.

## Test checklist for your server

1. Depot and stations: rendering, collisions, doors.
2. Free and paid rental, exact balance, keys, ride, return.
3. Refused payment and refund.
4. Clock in, pickup, 7 truck slots, hand-in, pay.
5. Two players at the same time, disconnect during a rental.

## FAQ

**The station or the depot is invisible or I fall through the floor.**
Check the folder name is exactly `loop-scoot`, that OneSync is on, and restart the whole server instead of restarting the resource.

**Rentals are free, how do I charge money?**
Set `Config.Price` in `shared/config.lua` and pick the account with `Config.Account`.

**Players get no keys.**
Set `Config.Bridge.vehicleKeys` to your key resource, or to `none` if your server does not use keys.

**Can I edit it, sell it in a pack, or use it on a paid server?**
Yes, the MIT license allows it. Keep the license file.

## Support

Questions and help: [Discord](https://discord.gg/loopdev). Bugs and ideas: [issues](https://github.com/loopfivem/loop-scoot/issues). If the script helps your server, a star on the repo helps us a lot.

## Français

Script gratuit de location de trottinettes avec un job de collecte, pour ESX, QBCore, Qbox, ox et standalone. Téléchargez `loop-scoot.zip` dans la [dernière release](https://github.com/loopfivem/loop-scoot/releases/latest), placez le dossier `loop-scoot` dans `resources/`, ajoutez `ensure loop-scoot` après `ox_lib` et redémarrez le serveur. Les textes sont en français et en anglais (`Config.Language`). Aide sur le [Discord](https://discord.gg/loopdev).

## Credits and license

Created by LOOP Studios, released under the MIT license (`LICENSE`). Third-party notes are in `ASSETS.md`. Barlow Condensed and Poppins fonts are under the SIL Open Font License.

LOOP Scoot is not affiliated with Rockstar Games, Take-Two Interactive, Cfx.re or any other server or community.
