<div align="center">
  
# Strobie

A simple stroboscopic instrument tuner.

<img src="docs/demo.webp" width="300" alt="Strobie tuning a note">

</div>


Strobie is on the App Store for Mac and iPhone. The source is here to read and build yourself, see [Development](#development).

### Features

- Automatic pitch detection based on NSDF (McLeod Pitch Method).
- Smooth and responsive strobe display, the stripe sharpness adapts to the signal quality, no contrast or gain to set.
- Note lock: keeps the strobe on a note name, the octave still follows the detected pitch.
- Harmonic mode: shows the partials of the detected note on up to 5 strobe tracks.
- Track settings: tap a track to choose its partial (1× to 8×, or the fifth at 1½×), move its target by up to ±50 cents (e.g. for a stretched octave) and change its speed.
- Fine mode: a geared mode that shows the same fundamental frequency in each band, but with increasing sensitivity.
- Fast toggle: the strobe spins 4× faster per cent of detuning, for the final adjustment.
- Five displays: curved tracks, a spinning wheel, a trace of the cents over the last few seconds, a scope that draws the waveform synced to the strobe's frequency, and a ribbon, the classic strobe with stripes lit by the wave.
- Note offsets: tune a note up to ±25 cents off pitch, e.g. a ukulele's E a little flat or a guitar's B string a touch low, the strobe stands still at the offset note. Three slots hold a tuning each.
- Transpose for B♭, E♭, F and other transposing instruments.
- Concert A from 400 to 480 Hz.
- Hertz/Cents display.
- Four colorways (red, mint, amber, mono) and an optional retro lamp glow.



### License

Copyright ©️ 2025–2026 Davorin Šego <br />
Licensed under the GPL v3  <br />
https://www.gnu.org/licenses/gpl-3.0.en.html




### Third-Party Resources


- [PortAudio](https://portaudio.com/) ring buffer <br />
Portable Real-Time Audio Library <br />
Copyright (c) 1999-2011 Ross Bencina, Phil Burk <br />

- [PFFFT: a pretty fast FFT.](https://bitbucket.org/jpommier/pffft) <br />
Copyright (c) 2013  Julien Pommier (pommier@modartt.com) <br />
FFTPACK license <br />

- [The Inter typeface family](https://rsms.me/inter/) <br />
Copyright (c) 2016 The Inter Project Authors <br />
SIL Open Font License 1.1 <br />

- [Noto Sans](https://github.com/notofonts) <br />
Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic) <br />
SIL Open Font License, Version 1.1 . <br />

- [Raylib](https://www.raylib.com/) <br />
Copyright (c) 2013-2025 Ramon Santamaria (@raysan5) <br />
Zlib license

- [SDL](https://libsdl.org/) <br />
Copyright (C) 1997-2025 Sam Lantinga <br />
Zlib license <br />

- [miniaudio](https://miniaud.io/) <br />
Copyright 2025 David Reid <br />
Public domain (Unlicense) or MIT No Attribution <br />

- [stb](https://github.com/nothings/stb) <br />
Copyright (c) 2017 Sean Barrett <br />
Public domain or MIT license <br />

- [Phosphor Icons](https://phosphoricons.com/) <br />
Copyright (c) 2023 Phosphor Icons <br />
MIT license <br />

- [Virgil](https://github.com/excalidraw/virgil), the hand-drawn font in the signal path diagram <br />
Copyright (c) 2020 Excalidraw <br />
SIL Open Font License 1.1 <br />



### Development

You need [Odin](https://odin-lang.org/docs/install/), the [just](https://github.com/casey/just) command runner, git and clang (on macOS from the Xcode command line tools).

```sh
git clone https://github.com/dsego/strobe-tuner
cd strobe-tuner
just dev
```

The first run clones and compiles the dependencies into `external/`, later runs skip that.

| Command | What it does |
| --- | --- |
| `just dev` | Debug build with the raylib renderer (OpenGL), then runs it |
| `just dev sdl` | The same with the SDL3 GPU renderer and Metal shaders, needs `brew install sdl3` |
| `just dev stats` | Also shows the signal stats and NSDF plots |
| `just dev ios` | Builds for the iOS simulator and runs it there, needs Xcode |
| `just ipa` | Signed build for iPhone, see `ios/build-device.sh`, needs Xcode and a provisioning profile |
| `just build`, `just build sdl` | Optimized build with either renderer |
| `just test` | Unit tests of the pitch detection and strobe code |

Debug builds also have <kbd>Cmd</kbd><kbd>,</kbd> to open the config file and <kbd>Cmd</kbd><kbd>Shift</kbd><kbd>,</kbd> to reload it.

#### Linux

Only the raylib renderer, the SDL renderer only has Metal shaders. It needs the X11 headers for raylib, OpenGL and the audio libraries (PulseAudio, PipeWire through its PulseAudio server, or ALSA) are loaded at runtime. The first `just dev` also compiles Odin's vendored stb and miniaudio into the Odin folder, which has to be writable, the Linux install leaves them uncompiled.

```sh
sudo apt install clang git libx11-dev    # Debian, Ubuntu
sudo dnf install clang git libX11-devel  # Fedora
just dev
```

The config is saved to `$XDG_CONFIG_HOME/Strobie/config.ini`, or `~/.config/Strobie/config.ini`.


### How it works

<img src="docs/signal-path.svg" alt="Audio signal path: the audio thread high-passes the input into two ring buffers, the main thread reads one for pitch detection and the other for the strobe bands">

#### Pitch detection

The pitch detection algorithm uses autocorrelation via FFT, following the method described in _"A Smarter Way to Find Pitch" (Philip McLeod, Geoff Wyvill)_. It analyzes the waveform periodically to accurately identify the fundamental frequency, even in the presence of strong harmonics. A built-in clarity measure provides a confidence score for each detected pitch. Clarity and SNR (signal-to-noise ratio) help determine whether the pitch is strong or weak.

#### Stroboscopic effect

The strobe effect is driven by a lock-in amplifier (heterodyne) phase comparator built on a single-bin DFT tuned to the target note's reference frequency (e.g., 110 Hz). The idea is to extract the phase of the signal at a specific frequency, relative to a reference oscillator, and map that to a visually intuitive strobe motion.

Core steps:
- Filtering: The input is high-passed once (60 Hz by default) to remove DC, handling noise and low frequency rumble.
- Frequency targeting: Compute a windowed single-bin DFT over the newest samples, precisely tuned to the reference frequency.
- Demodulation: Rotate the DFT result by the phase of a reference oscillator running on an absolute sample clock. When the input pitch matches the reference, this phase stands still; a detuned signal makes it rotate at the frequency difference.
- Phase tracking: A small Kalman filter follows the phase and its rate. Each measurement is weighted by the band's signal-to-noise ratio, so a loud note is tracked closely and a fading note coasts on its last good frequency instead of wandering with the noise. Measurements taken while a fresh pluck is still inside the analysis window (when the pitch glides down from sharp) are trusted less.
- Stripe sharpness: The stripe edges are as sharp as the tracked phase is certain. A sharp edge on a jittery phase twitches and a soft edge on a clean one looks washed out, so the edge width follows the tracker's phase uncertainty (scaled by the band speed). The stripes fade out as the band's SNR drops into the background noise.

To maintain a consistent amount of visual drift across the frequency spectrum, the window length is based on musical pitch intervals (in cents) rather than absolute frequency, and the strobe phase is rescaled so each note spins at the same rate per cent of detuning.

The single-bin DFT also serves as a narrowband filter, providing a clean strobe signal while still allowing nearby frequencies to influence the display. The amount of visual drift per cent can be scaled directly by multiplying the tracked phase — allowing customizable strobe sensitivity.

In automatic mode a newly detected note has to be seen several times in a row (3 by default) before the strobe switches to it, so a single noisy detection of a decaying note doesn't reset the display.


#### Alternative approaches I have tried

Before the lock-in, I drew the strobe from the waveform itself, like an untriggered oscilloscope with its sweep synced to the reference period, so a detuned note drifts sideways:

- Time-aligned windowing with resampling - each band resampled so that one reference period fills the pattern.
- Time-aligned windowing with a sub-sample frame counter - instead of resampling, a fractional counter keeps the alignment and the number of samples per frame is rounded up or down.

Both ran into the same problems, which the lock-in doesn't have:

- Sensitivity: the drift is the actual phase the signal slips against the reference, so it can't be made slower or faster. The lock-in measures that phase, and the strobe turns by the phase times any factor, which is what the strobe response setting and the fine mode are built on.
- Shimmer: rounding each frame to whole samples moves the pattern by up to half a sample per frame. High notes have few samples per period, 12 at 4 kHz, so that's 15° of jitter. Resampling avoided the rounding, but with few samples per period the motion was blocky. The lock-in phase is continuous and the phase tracker smooths it, so the stripes move smoothly at any pitch.
- Band filters: each band needed an IIR bandpass, otherwise the other harmonics bled into its pattern. A narrow IIR shifts the phase steeply around its centre frequency, differently in each band, so the tracks were offset from each other and reacted at different speeds when the pitch moved, e.g. a pluck gliding down from sharp. The single-bin DFT is just as narrow a bandpass, but its window is symmetric, so its phase is linear, a plain delay with no phase distortion in any band.

A narrow filter takes time either way: the DFT window is about 0.6 s at 110 Hz, so the phase shown is from about 0.3 s ago. The phase tracker and the onset handling make up for most of it.


#### Noise floor

Each strobe band keeps an estimate of the background noise at its frequency (i.e. the noise floor), which gives the SNR used by the phase tracker and the display. The pitch detector keeps one the same way for the level of the whole signal, its SNR is part of telling a strong pitch from a weak one. It follows the level in dB while nothing louder is playing and pauses when the SNR is above a threshold, only creeping up slowly so it can catch up with a noisier environment. It's relearned when switching the input device and when the input is opened again, e.g. after the app was in the background.




