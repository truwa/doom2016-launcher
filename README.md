# DOOM (2016) on Mac

This is a small launcher for the GOG version of DOOM (2016). It is a bare-minimum Wine and Vulkan wrapper, and it uses KosmicKrisp. The game is not in the download.

You can point it at a GOG folder you already have, or install that copy from the app menu. The first launch downloads Wine and sets up the Windows side, including Microsoft's C++ runtime. On Apple silicon it also asks to install Rosetta if the Mac does not have it.

## Install and run

1. Download the zip from the [latest release](https://github.com/truwa/doom2016-launcher/releases/latest) and unzip it.
2. Right-click `Doom2016GOG.app` and choose Open. The app is signed, but Apple has not notarized it, so a normal double-click is blocked the first time.
3. If macOS still refuses, open System Settings, go to Privacy & Security, and allow the app there. The button usually says Open Anyway.
4. On Apple silicon, say yes if it asks to install Rosetta. That needs an administrator password.
5. Choose the GOG folder that contains `DOOMx64vk.exe`, or use Install Doom from GOG in the app menu. The first Play downloads Wine, which takes a few minutes.
6. Press Play.

Xbox controllers already work. DualSense, DualSense Edge, and DualShock 4 pads are mapped so the game treats them as Xbox controllers. The button icons stay Xbox.

Macs before the M5 need a patched KosmicKrisp. Without it, DOOM dies while creating the Vulkan device. That patched build is included here, and it was tried on an M4.

Full screen and Command-Tab do not get along. The game just closes. Borderless is the one that stays up when you switch apps.

There is also a Metal performance HUD, a way to try another Vulkan game with the same setup, a check for a newer launcher, and a GOG save sync in the app menu.

## Credits and licenses

DOOM (2016) is by id Software and Bethesda. It is not included. You need a GOG copy you own.

Wine is LGPL-2.1-or-later. The app downloads a macOS build from [Gcenx](https://github.com/Gcenx/macOS_Wine_builds/releases/latest) the first time it runs.

Microsoft's Visual C++ 2015–2022 runtime is downloaded from Microsoft on that same first run. Wine's own copy of that runtime crashes this game.

KosmicKrisp is part of Mesa and is MIT. The patched build in this app is what lets the game create a Vulkan device on Macs before the M5. Mesa's notes are at [docs.mesa3d.org](https://docs.mesa3d.org/drivers/kosmickrisp.html).

The GOG download tool is [gogdl](https://github.com/Heroic-Games-Launcher/heroic-gogdl) v1.3.1 from Heroic Games Launcher, under GPL-3.0. It is used to sign in, download the game you own, and sync saves when you ask it to.

The launcher itself is MacGameTest. [youtube.com/@MacGameTest](https://www.youtube.com/@MacGameTest)
