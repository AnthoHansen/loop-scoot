# Changelog - LOOP Scoot

## 1.41.0 - GitHub release

- Published on GitHub: https://github.com/loopfivem/loop-scoot
- New release check in the server console, turned off with `setr loop_scoot_versioncheck false`.
- License file is now the standard MIT text (`LICENSE`), third-party notes moved to `ASSETS.md`.

## 1.40.9 - public open-source release

- Released free and open source under the MIT license. No Asset Escrow, no encrypted file, no minified interface file.
- Removed the third-party work polo (models, textures, clothing metadata and manifest entries) and the clothing diagnostic command. The collector uniform now uses vanilla freemode components (see `Config.Collection.uniform`).
- Interface assets renamed: `web/loop-overlay.css` and `web/loop-overlay.js`, fonts `LS Loop Display` and `LS Loop Text`, CSS variables `--lo-*`, NUI messages `loop:*` (Lua and JavaScript sides).
- Removed the optional integration with an external base resource (notifications, progress bar, prompts, phone, rental contracts, key bridge). Standalone, ESX, QBCore, Qbox and ox paths are unchanged. `Config.NativePhone` is `false` by default; set `{ resource = 'your-phone' }` to use a phone that exports `isPhoneOpen` and opens the station dialog through the `open` export.
- Key mapping labels translated to English.
- Support and downloads: https://discord.gg/loopdev
