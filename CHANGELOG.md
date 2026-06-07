# Changelog
All notable changes to this project will be documented in this file.

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
