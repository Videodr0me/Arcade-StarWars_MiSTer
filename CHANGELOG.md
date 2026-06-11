# Changelog
All notable changes to this project will be documented in this file.

## Release [20260611]

### Added
- **CRT Additive Blending (Phosphor Bloom)**: Crossing vectors now mathematically accumulate their colors and intensities, perfectly simulating how real CRT phosphors pool light together. Intersecting lines and dense clusters now glow brightly like the real arcade cabinet!
- **Extended Viewport**: Opened up the bottom boundary of the render window. You can now see much more of the X-Wing, Snowspeeder, and Millennium Falcon cockpit art at the bottom of the screen.
- **ESB Hit Flashes**: The CRT extreme overdrive hit/flash effect is now fully supported and enabled for *Empire Strikes Back*.

### Changed
- **Tone Mapping Options**: Completely overhauled the Z-axis intensity tone mapping. Added 4 new selectable profiles in the OSD: Linear 1 (Default), Linear 2, Bright (HDR-style LUT), and Off.
- **HD Render Resolutions**: Bumped the internal video targets to true 1080p and 720p formats for sharper scaling and timing alignment on modern displays.
- **Subpixel Precision**: Rewrote the vector coordinate pipeline to support true subpixel offsets for Stars and Diagonals, eliminating displacement artifacts at HD resolutions.
- **MRA Updates**: Changed the MRA files to drop the "arcade-" prefix when requesting the `.rbf` core file.

## Release [20260607]

### Added
- **High Performance 32bpp HD Renderer**: A highly optimized rendering engine featuring full support for the Z-axis intensity channel. Enjoy the game's glorious, slow fade-to-black transitions in all their beauty.

### Changed
- **Video Timings**: Minor tweaks to 480p and 240p timings.
- **Tone Mapping**: Legacy tone mapping is now the default (you may have to adjust your setting).
- **15kHz Modlines**: Added 15kHz modlines and some tips for video settings to readme file.
## Release [20260603]

### Added
- **CRT Dot Effect**: Simulates how phosphor bloom increases the size of dots on a real CRT. This allows you to increase the size of background stars to compensate for the lack of bloom on modern digital displays (toggleable via OSD option).
- **CRT Overdrive Hit Flash Effect**: Emulated the CRT's extreme off-screen overdrive that triggers a full-screen flash when your shields are hit (toggleable via OSD option).
- **New HD render mode** for 1080p displays (auto selected based on resolution)
- **CRT Monitor Support**: Added support for 31kHz and 15kHz (untested) monitors
- **Digital Input**: Added support for digital input fall back (thanks Sliff2000)
- **Empire Strikes Back (ESB) Support**: Added Slapstick and ESB support (thanks to derpyder)

### Changed
- **Cycle-Accurate Rendering**: New cycle-accurate Analog Vector Generator (AVG) state machine based on schematics (includes normalization substates).
- **Tone Mapping**: Added new "Modern" tone mapping to preserve more intense highlights and upper dynamic range (selectable between "Modern" and "Legacy" via OSD option).
- **Documentation**: Updated README.md

### Fixed
- **Cycle Accuracy**: Bonus music after death star destruction plays to the end without beeing cut off.
- **Video Timings**: Changed video timings to more display friendly values.

## Release [20260527]

- Initial release: Star Wars Arcade for MiSTer FPGA
