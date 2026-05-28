# Star Wars (Arcade, 1983) for MiSTer FPGA

An FPGA implementation of Atari's classic 1983 color vector arcade game **Star Wars** for the [MiSTer FPGA](https://github.com/MiSTer-devel/Main_MiSTer/wiki) platform.

Atari's 1983 Star Wars remains one of the most beloved arcade games ever made. With its glowing wire-frame Death Star trench, digitized voices of Obi-Wan and Darth Vader, and the iconic flight yoke controller, it was the closest thing to climbing into an X-wing cockpit — and for a generation of players, "Use the Force, Luke" still gives them chills.

## Support the Project
Hey, Videor0me here! If you're having a blast with this core, consider to [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=flat-square&logo=buy-me-a-coffee)](https://buymeacoffee.com/Videodr0me)

Your contributions show me that there is interest in these arcade projects. With enough support, I'd love to dedicate time to tackle other complex vector games like Tempest and The Empire Strikes Back or to improve the analog vector rendering effects.


---

## Original Hardware

The original Star Wars arcade machine (Atari part number 136021) is built from the following major components:

| Subsystem | Original Hardware | FPGA Implementation |
|---|---|---|
| **Main + Audio CPU** | Motorola MC6809E @ 1.5 MHz | Cavnex mc6809e Verilog core with AVMA/VMA wrapper |
| **Math Processor** | Custom TTL Mathbox (PROM-sequenced matrix processor, 74LS384 serial multiplier, 15-step restoring divider) | Fully modeled in `mathbox.sv` |
| **Vector Generator** | Atari Analog Vector Generator (AVG) with state machine PROM, 10-bit DACs, analog integrators | Digital AVG in `avg.vhd` driving a raster framebuffer |
| **Sound** | 4× Atari C012294 POKEY + TI TMS5220 speech synthesizer | POKEY in VHDL + TMS5220 with variable rate (TMS5220C mode) |
| **Audio Filters** | TL084 quad op-amp low-pass filter + Reticon R5106 delay/reverb line | Modeled in `audio_filter_tl084.sv` and `reticon_r5106.sv` |
| **Display** | Amplifone XY color vector monitor (RGB analog) | 980×700 DDRAM framebuffer, `vector_fb_ddram.sv`|
| **Controls** | Custom flight yoke with analog potentiometers (2-axis) | Mapped to MiSTer analog stick inputs |
| **Non-volatile RAM** | 256 bytes battery-backed NOVRAM (high scores, settings) | Saved to MiSTer SD card via NVRAM system |

---

## Controls

Star Wars uses an analog flight yoke. By default, **Controls > Yoke Input** is set to **Auto**: the analog stick drives the yoke normally, and pressing a digital direction automatically switches to the synthesized digital yoke until the analog stick is moved again. Set **Yoke Input** to **Digital** to force digital yoke control all the time. **Controls > Digital Sensitivity** adjusts how quickly the virtual yoke ramps toward the direction you are holding, and **Controls > Digital Y Axis** can reverse up/down. Releasing the d-pad recenters the virtual yoke at the selected sensitivity speed.

> **Calibration Tip:** The game learns yoke limits during its setup flow. If aiming is off after clearing NVRAM, run the normal game calibration with analog input before saving NVRAM.

| Input | Function |
|---|---|
| **Analog Stick** | Move crosshairs (Pitch / Yaw) — proportional, recommended |
| **Digital Stick / D-Pad** | Move crosshairs automatically in **Auto**, or all the time when **Yoke Input** is set to **Digital** |
| **Fire (Button A)** | Fire lasers — also starts the game after inserting coins |
| **Shield (Button B)** | Shield button |
| **Aux Coin (Button Start)** | Auxiliary coin input (also used to navigate Test Mode menus) |
| **Coin L / Coin R** | Insert coins (mapped to R / L by default) |

> **Tip:** The original arcade machine has no "Start" button. After inserting a coin, pressing **Fire** on the yoke starts the game. An analog stick is strongly recommended for the best experience.

---

## Recommended MiSTer Settings

### 720p — Best Quality (Recommended)

At 720p, the framebuffer maps perfectly the display without scaling and is also best for 4K TVs/Monitors (Aspect Ratio: Optimized or Pixel Perfect). This is the recommended setting and also enables the optional **120Hz mode** for ultra-smooth vector rendering.

Append these settings to your MiSTer INI file:

```
[Star Wars]
video_mode=0              ; 720p 60Hz — 1:1 pixel mapping in optimized and pixel perfect modes. Also ideal for 4K displays.
vsync_adjust=2            ; Low-latency — locks HDMI output to core timing
vscale_mode=0             ; Let the core's auto aspect ratio control scaling
hdmi_limited=0            ; Full range RGB (use 1 for TVs with limited range)
hdr=1                     ; HDR output — improves contrast/luminosity
vfilter_default=          ; No filters — 720p is pixel-perfect, filtering would blur the vectors
vfilter_vertical_default= ; Override any global vertical filter
vfilter_scanlines_default=; Override any global scanline filter
```

With these settings, you can also enable **120Hz (720p only)** in the core's OSD menu for double the refresh rate. Your display must support 720p @ 120Hz (most modern TVs and monitors do). There is no need to set 120Hz in MiSTer INI.

> **Tip:** The empty filter lines (`vfilter_default=` etc.) ensure that any global filters from your `[MiSTer]` section are overridden. Without them, a globally set bilinear or scanline filter would still apply and blur the crisp vector lines.

### 1080p — With Scaler Filtering

At 1080p, the framebuffer is scaled by 1.5×. Because 1.5× scaling means some lines are 1 pixel and others are 2 pixels wide, enabling the bilinear sharp filters is necessary:

```
[Star Wars]
video_mode=1920,1080,60   ; 1080p output
vsync_adjust=2            ; Low-latency — locks HDMI output to core timing
vscale_mode=0             ; Let the core's auto aspect control scaling
hdmi_limited=0            ; Full range RGB (use 1 for TVs with limited range)
hdr=1                     ; HDR output — improves contrast/luminosity
vfilter_default=Upscaling - SharpBilinear/SharpBilinear_100.txt ; Smooth 1.5x vertical scaling
vfilter_vertical_default= ; No additional vertical filter
vfilter_scanlines_default=; No scanline overlay — vectors don't have scanlines
```

> **Note:** The 120Hz option is automatically disabled and greyed out at resolutions above 720p.

---

## OSD Options

### Display

| Option | Description |
|---|---|
| **Aspect Ratio** | **Optimized** (recommended) auto-detects HDMI resolution and picks the cleanest scale factor.<br>**Pixel Perfect** forces 1:1 pixel mapping (980×700 centered).<br>**Stretched** fills the screen (not recommended). |
| **Unbuffered Vectors** | When On, bypasses buffering and uses simple double-buffer ping-pong. Fakes a vector look, best used at 120Hz.|
| **120Hz (720p only)** | Doubles the refresh rate to ~120Hz. Reduces Frame Pacing Latency and improves the look of Unbuffered Vectors. |

### Cabinet Audio Hardware

The original Star Wars arcade cabinet features analog audio processing that goes beyond simple DAC output. This core models Filter, Delay and Reverb stages, giving you an authentic stereo audio rendition like never before:

| Option | Default | Description |
|---|---|---|
| **TL 084 Filter** | On | Models the original TI TL084 quad op-amp low-pass filter on the audio output board. |
| **Reticon Del/Rev** | On | Models the Reticon R5106 analog delay line used in the original cabinet for spatial reverb effects. Adds a subtle authentic stereo "cockpit echo" to explosions and speech. |

The audio mixing stage models the original summing amplifier (TL084, 1/4 of IC 4C) with per-channel gain based on the schematic resistor values matching the original cabinet's audio balance.

> **Tip:** For the most authentic arcade sound experience, keep both options **On**. Turning the TL 084 Filter off yields a more modern Hi-Fi flavour of the audio.

---

## Game Setup — Use Test Mode, Not DIPs

The recommended way to change game settings is NOT through the DIP switches, but through the game's built-in **Test Mode menu**, just like arcade operators did on the original machine:

### How to Access Test Mode

1. Wait for Demo Loop and Open the MiSTer OSD (F12)
2. Go to **DIP Settings** → set **Test Mode** to **On**
3. Close the OSD — the game enters the game setup / diagnostic screen
4. Use the **flight yoke** (analog stick) to navigate the on-screen menu
5. Press **Fire** to select options
6. Configure difficulty, coinage, bonus shields, and other game parameters
7. The game saves your settings to NVRAM automatically
8. Set **Test Mode** back to **Off** in the OSD to return to normal gameplay

Settings changed through Test Mode are preserved in NVRAM alongside your high scores. Don't forget to save the NVRAM or use Auto Save. Auto Saves on entering the F12 Menu.
The DIP switches in the OSD can configure starting shields, difficulty, coinage, and other game parameters. However, **changing DIPs requires clearing NVRAM**, which **erases all saved high scores**.

---

## ROMs

```
                                *** Attention ***

ROMs are not included. In order to use this arcade core, you need to provide the
correct ROMs.

Quick reference for folders and file placement on your MiSTer SD card:

/_Arcade/Star Wars (Rev 2).mra
/_Arcade/cores/Arcade-StarWars.rbf
/_Arcade/mame/starwars.zip
```

---

## Known Limitations

This core renders vectors as 1-pixel-wide lines on a raster framebuffer. A real Amplifone XY color vector monitor is an analog CRT where a focused electron beam traces each vector directly onto phosphor. Several visual characteristics of the original display are not (yet) reproduced:

| Area | Limitation | Detail |
|---|---|---|
| **Vector Rendering** | Not cycle-exact | The AVG vector drawer does not run cycle-exact. There might be slight variance in speed compared to original hardware. |
| **Bloom & Spot Size** | Not modeled | Higher beam current increases the spot diameter, making bright vectors appear wider and softer with a visible luminous halo. |
| **Beam Velocity** | Not modeled | Perceived brightness is inversely proportional to beam velocity. This core draws all vectors at uniform brightness per Z-level regardless of length. |
| **Phosphor Persistence** | Not modeled | The P22 phosphor used in color vector CRTs has a visible afterglow decay (~1–10 ms depending on color channel). Moving objects leave fading trails. |
| **Beam Overlap** | Not modeled | Where two vectors cross or overlap on a real CRT, the phosphor is excited twice, producing additive brightness and enhanced bloom at the intersection. |
| **Overdrive & Saturation** | Not modeled | Extreme beam current events (e.g., the Death Star explosion) overdrive the CRT — the spot blooms dramatically, colors shift toward white, creating a diffuse full-screen glow. |
| **Intensity** | Limited Z-level support | The current implementation uses a simplified intensity mapping with fewer effective levels. |

---

## Compilation

The project uses **Quartus Prime Lite** targeting the **Cyclone V** on the Terasic DE10-Nano.

1. Open `Arcade-StarWars.qpf` in Quartus
2. Run the full compilation flow (Analysis → Fitter → Assembler → Timing)
3. The output `Arcade-StarWars.rbf` is generated in `output_files/`

The `sys/` directory contains the standard MiSTer framework. All core-specific RTL is in `rtl/`.

---

## Credits & Acknowledgments

- **Original Game:** Mike Hally (project lead), Greg Rivera & Norm Avellar (programming), Jed Margolin (hardware engineering), Ed Rotberg (original concept) — Atari, 1983
- **Initial FPGA Foundation:** Jeroen Domburg (Black Widow MiSTer core)
- **6809 CPU Core:** Greg Miller (Cavnex mc6809e)
- **MiSTer Platform:** Sorgelig and the MiSTer community

---

## License

This project is provided for educational and personal use. See individual source files for their respective licenses.
