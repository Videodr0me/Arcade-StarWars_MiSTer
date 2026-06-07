# Star Wars + The Empire Strikes Back (Arcade, 1983 + 1985) for MiSTer FPGA

An FPGA implementation of Atari's classic color vector arcade games **Star Wars** and **The Empire Strikes Back** for the [MiSTer FPGA](https://github.com/MiSTer-devel/Main_MiSTer/wiki) platform.

Atari's 1983 Star Wars remains one of the most beloved arcade games ever made. With its glowing wire-frame Death Star trench, digitized voices of Obi-Wan and Darth Vader, and the iconic flight yoke controller, it was the closest thing to climbing into an X-wing cockpit — and for a generation of players, "Use the Force, Luke" still gives them chills.

## Support the Project
Hey, Videor0me here! If you're having a blast with this core, consider supporting the project: [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=flat-square&logo=buy-me-a-coffee)](https://buymeacoffee.com/Videodr0me)

---

## Original Hardware

The original Star Wars arcade machine (Atari part number 136021) is built from the following major components:

| Subsystem | Original Hardware | FPGA Implementation |
|---|---|---|
| **Main + Audio CPU** | Motorola MC6809E @ 1.5 MHz | Cavnex mc6809e Verilog core with AVMA/VMA wrapper |
| **Math Processor** | Custom TTL Mathbox (PROM-sequenced matrix processor, 74LS384 serial multiplier, 15-step restoring divider) | Fully modeled in `mathbox.sv` |
| **Vector Generator** | Atari Analog Vector Generator (AVG) with state machine PROM, 10-bit DACs, analog integrators | New cycle exact Digital AVG in `avg.vhd` based on schematics |
| **Sound** | 4× Atari C012294 POKEY + TI TMS5220 speech synthesizer | POKEY in VHDL + TMS5220 with variable rate (TMS5220C mode) |
| **Audio Filters** | TL084 quad op-amp low-pass filter + Reticon R5106 delay/reverb | Modeled in `audio_filter_tl084.sv` and `reticon_r5106.sv` |
| **Display** | Amplifone XY color vector monitor (RGB analog) | Output Resolution adaptive DDRAM framebuffer, `vector_fb_ddram.sv`|
| **Controls** | Custom flight yoke with analog potentiometers (2-axis) | Mapped to MiSTer analog stick inputs, with digital fallback |
| **Non-volatile RAM** | 256 bytes battery-backed NOVRAM (high scores, settings) | Saved to MiSTer SD card via NVRAM system |

For those interested in the inner workings of the original arcade PCB, I have included my hand-verified transcription of the original AVG logic in the research folder. It's the the exact blueprint I used to build the new AVG!

---
## Controls

Star Wars uses an analog flight yoke. The yoke's X and Y axes are mapped to the primary analog axes of your MiSTer controller (digital fallback input controls are available)

> **🕹️ Calibration Tip:** The game **auto-calibrates** to your controller's range. When you first start playing, **move the analog stick in a full circle through its extreme positions** — this lets the game learn your stick's full range of motion. You can do this at any time, but the stage select screen is the ideal moment. If you are using digital inputs, you must also calibrate by pressing up, down, left and right on the directional pad until the crosshair reaches the edges of the screen in all directions.

| Input | Function |
|---|---|
| **Analog Stick** | Move crosshairs (Pitch / Yaw) — proportional, recommended |
| **Fire (Button A)** | Fire lasers — also starts the game after inserting coins |
| **Shield (Button B)** | Shield button |
| **Aux Coin (Button Start)** | Auxiliary coin input (also used to navigate Test Mode menus) |
| **Coin L / Coin R** | Insert coins (mapped to R / L by default) |

If you do not have access to an analog control device, you can play with a digital D-Pad or keyboard using the core's built-in digital control option. You can configure its behavior in the **Input Controls** OSD menu:
- **Input**: Set to **Auto** to seamlessly engage digital control whenever you press a direction, or **Digital** to force it permanently.
- **Digital Sensitivity**: Adjusts how quickly the virtual yoke steers and re-centers.

> **Tip:** The original arcade machine has no "Start" button. After inserting a coin, pressing **Fire** on the yoke starts the game. An analog stick is strongly recommended for the best experience. You can also invert the **Y-Axis** in the Input Controls menu to accommodate unusual controllers or personal preference.


---

## Recommended MiSTer Video Settings

The MiSTer core automatically adapts to your chosen resolution and optimizes the video quality. It also features special modes for 15kHz and 31kHz CRT monitors.

For flat-panel displays, we highly recommend enabling the **HDR** option in the Mister.ini file, if your monitor supports it. You have two primary choices for the ultimate experience: **1080p 60Hz for High Resolution**, or **720p 120Hz for improved frame pacing and thicker vectors**. Both modes are ideally suited for **4K displays** because of the integer scaling ratio.

Append these settings to your `mister.ini` file under the exact `[Star Wars]` header. Please ensure there is only one Star Wars core file in your MiSTer's search paths. Note that scaler filters are no longer needed and should be left blank (as shown below) to ensure maximum crispness.

```ini
[Star Wars]
video_mode=8              ; 8 = 1080p or use 0 = 720p (enables 120Hz option)
vsync_adjust=0            ; set to 1 or 2 for 720p 120Hz
vscale_mode=0             ; Let the core's auto aspect ratio control scaling
hdmi_limited=0            ; Set to 1 if the image is too dark (e.g. on limited range TVs)
hdr=1                     ; HDR output — improves contrast/luminosity (Highly Recommended!)
vrr=0                     ; Try setting to 1 (or higher) if you experience display issues (e.g. 120Hz).
vfilter_default=          ; No filters needed! Leave blank.
vfilter_vertical_default= ; Override any global vertical filter
vfilter_scanlines_default=; Override any global scanline filter
```
> **Note:** Because 1080p resolution is high, the vector lines may appear slightly thin, which can make the overall picture look a little dark. If HDR is not an option or your Monitor/TVs controls do not yield satisfactory results, try setting `hdmi_limited=1` in your INI file.

> **Note:** The empty filter lines (`vfilter_default=` etc.) in the INI snippet ensure that any global scaler filters from your `[MiSTer]` section are overridden.

### 15kHz CRT / Pure Integer Scaling

If you are outputting to a 15kHz CRT (e.g. via direct_video or analog VGA) or I recommend forcing the core's exact native resolution and aspect ratio:

```ini
[Star Wars]
video_mode=640,240,60 ; Standard MiSTer 15kHz resolution. You can experiment with others, but ensure width >= 640 and height is around 240 e.g. video_mode=640,44,64,88,240,3,2,17,13150,-hsync,-vsync
vscale_mode=4
vsync_adjust=0 ; You might want to try all three modes 0, 1 & 2
```
> **Tip:** `For 31kHz monitors you can use the same ini addition, just bump video mode to 640,480,60.`
---

## OSD Options

### Display

| Option | Description |
|---|---|
| **Aspect Ratio** | **Optimized** (recommended) auto-detects HDMI resolution and picks the cleanest scale factor.<br>**Pixel Perfect** forces 1:1 pixel mapping.<br>**Stretched** fills the screen. |
| **Unbuffered Vectors** | When On, bypasses buffering and uses simple double-buffer ping-pong. Fakes a vector look, best used at 120Hz.|
| **120Hz (720p only)** | Doubles the refresh rate to ~120Hz. Reduces Frame Pacing Latency and improves the look of Unbuffered Vectors. |
| **Tone Mapping** | **Modern** (Recommended): Optimized for HDR displays. Even without HDR, it compresses the upper dynamic range less than legacy mode. This results in a slightly darker overall image but preserves intense highlights (e.g., hits on the red turrets in the tower sequence).<br>**Legacy**: The classic, older tone mapping style. |
| **CRT Dot Bloom** | Simulates the intense phosphor bloom of the original analog CRT when drawing single-pixel dots. Options include **Pixel**, **Double**, and **Ellipse**. Leave it on **Auto** to let the core automatically pick the best shape based on your resolution. |
| **CRT Flash Hit** | Emulates the extreme overdriven off-screen drawn vectors that shine like a flash of light when your shields are hit or the Death Star explodes. |

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
> **Note:** Star Wars only saves the top three high scores. ESB saves the top 10. 
---

## ROMs

```
                                *** Attention ***

ROMs are not included. In order to use this arcade core, you need to provide the correct ROMs (see mra for version).

Quick reference for folders and file placement on your MiSTer SD card:

/_Arcade/Star Wars (Rev 2).mra
/_Arcade/Empire Strikes Back.mra
/_Arcade/cores/Arcade-StarWars.rbf
/_Arcade/mame/starwars.zip
/_Arcade/mame/esb.zip
```

---

## Known Limitations

This core renders vectors as 1-pixel-wide lines on a raster framebuffer. A real Amplifone XY color vector monitor is an analog CRT where a focused electron beam traces each vector directly onto phosphor. Several visual characteristics of the original display are not (yet) reproduced:

| Area | Limitation | Detail |
|---|---|---|
| **Beam Velocity** | Not modeled | Perceived brightness is inversely proportional to beam velocity. This core draws all vectors at uniform brightness per Z-level regardless of length. |
| **Phosphor Persistence** | Not modeled | The P22 phosphor used in color vector CRTs has a visible afterglow decay (~1–10 ms depending on color channel). Moving objects leave fading trails. |
| **Beam Overlap** | Not modeled | Where two vectors cross or overlap on a real CRT, the phosphor is excited twice, producing additive brightness and enhanced bloom at the intersection. |
---

## Compilation

The project uses **Quartus Prime Lite** targeting the **Cyclone V** on the Terasic DE10-Nano.

1. Open `Arcade-StarWars.qpf` in Quartus
2. Run the full compilation flow (Analysis → Fitter → Assembler → Timing)
3. The output `Arcade-StarWars.rbf` is generated in `output_files/`

The `sys/` directory contains the standard MiSTer framework. All core-specific RTL is in `rtl/`.

---

## Credits & Acknowledgments

- **Star Wars (Arcade):** Mike Hally (project lead), Greg Rivera & Norm Avellar (programming), Jed Margolin (hardware engineering), Ed Rotberg (original concept) — Atari, 1983
- **Empire Strikes Back (Arcade):** Mike Hally (project lead), Greg Rivera & Norm Avellar (programming), Rob Row (technician), Dave Ralston (artist), Brad Fuller (sound effects) — Atari, 1985
- **Initial FPGA Foundation:** Jeroen Domburg (Black Widow MiSTer core)
- **6809 CPU Core:** Greg Miller (Cavnex mc6809e)
- **MiSTer Platform:** Sorgelig and the MiSTer community
- **Slapstick/Empire Strikes Back support:** derpyder
---

## License

This project is provided for educational and personal use. See individual source files for their respective licenses.