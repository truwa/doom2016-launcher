# DOOM (2016) on Mac

This is a small launcher for the GOG version of DOOM (2016). It is a bare-minimum Wine and Vulkan wrapper, and it uses KosmicKrisp. The game is not in the download.

You can point it at a GOG folder you already have, or install that copy from the app menu. The first launch downloads Wine and sets up the Windows side, including Microsoft's C++ runtime. On Apple silicon it also asks to install Rosetta if the Mac does not have it (requires an admin password).

<a href="https://www.youtube.com/watch?v=xcSXmYcd-Fg">
  <img src="https://img.youtube.com/vi/xcSXmYcd-Fg/hqdefault.jpg" width="480" alt="DOOM (2016) on Mac performance test">
</a>

[▶ Watch the M5 Pro and M4 performance test on YouTube](https://youtu.be/xcSXmYcd-Fg)

## Requirements
- Apple silicon Mac (M1 or later). Intel Macs are not supported.
- macOS 26 Tahoe or later. KosmicKrisp needs Metal 4, so it won't run on macOS 15 Sequoia or older.


## Install and run

1. Download the zip from the [latest release](https://github.com/truwa/doom2016-launcher/releases/latest) and unzip it.
2. Open `Doom2016GOG.app`. The release is notarized, so a double-click opens it.
3. Choose the GOG folder that contains `DOOMx64vk.exe`, or use Install Doom from GOG in the app menu.
4. Press Play. The first launch downloads Wine and sets things up, which takes a few minutes. Later launches are quick.

If macOS still blocks the app, open System Settings, go to Privacy & Security, and click Open Anyway.

Xbox controllers already work. DualSense, DualSense Edge, and DualShock 4 pads are mapped so the game treats them as Xbox controllers. The button icons stay Xbox.

Macs before the M5 need a patched KosmicKrisp, which is included int this app. Stock KosmicKrisp refuses to create the Vulkan device on M1–M4 because DOOM turns on depthBounds without asking whether the GPU has it.

There is also a Metal performance HUD, a way to try another Vulkan game with the same setup, a check for a newer launcher, and a GOG save sync in the app menu.


## Notes

- Tested on M5 Pro and M4 with macOS 27.
- The GOG download can sometimes stall. If it stops moving, pause or cancel it, then start it again. It downloads only the remaining files upon cancel/start.
- Full screen and Command-Tab do not get along. The game just closes. Borderless is the one that stays up when you switch apps.
  

## Credits and licenses

DOOM (2016) is by id Software and Bethesda. It is not included. You need a GOG copy you own.

Wine is LGPL-2.1-or-later. The app downloads a macOS build from [Gcenx](https://github.com/Gcenx/macOS_Wine_builds/releases/latest) the first time it runs.

Microsoft's Visual C++ 2015–2022 runtime is downloaded from Microsoft on that same first run. Wine's own copy of that runtime crashes this game.

KosmicKrisp is part of Mesa and is MIT. The patched build in this app is what lets the game create a Vulkan device on Macs before the M5. Mesa's notes are at [docs.mesa3d.org](https://docs.mesa3d.org/drivers/kosmickrisp.html).

The app downloads [gogdl](https://github.com/Heroic-Games-Launcher/heroic-gogdl) v1.3.1 from Heroic Games Launcher the first time you sign in to GOG, install the game, or sync saves. It is GPL-3.0, its download is checked against a SHA-256 hash, and it is used to sign in, download the game you own, and sync saves when you ask it to.

The launcher itself is MacGameTest. [youtube.com/@MacGameTest](https://www.youtube.com/@MacGameTest)
