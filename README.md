<div align="center">
  
# SonicStrobe

A simple stroboscopic instrument tuner.

<img src="screenshots/Screenshot 2025-06-28 at 18.48.25.png" width="300" height="336" class="shrinkToFit transparent">

</div>


### Download

[Latest release on GitHub](https://github.com/dsego/strobe-tuner/releases)

### Features

- Automatic pitch detection based on NSDF (McLeod Pitch Method).
- Smooth and responsive strobe display with adaptive auto-gain for consistent visual feedback across signal levels.
- Manual target note selection.
- Harmonic mode: shows the partials of the detected note across multiple strobe bands.
- Vernier mode: shows the same fundamental frequency in each band, but with increasing sensitivity. When the central band is stationary, outer bands may still move.
- Contrast and strobe sensitivity (speed) sliders.
- Hertz/Cents display.



### Keyboard shortcuts
- <kbd>←</kbd><kbd>→</kbd> &nbsp;  left/right arrow to move selected note up or down chromatically.
- <kbd>↑</kbd><kbd>↓</kbd> &nbsp;  up/down arrow to move selected note up and down by octave.
- <kbd>tab</kbd> &nbsp;  switch the strobe display type to a full wheel.
- <kbd>space</kbd> &nbsp; switch note detection modes between auto & manual.



### License

Copyright ©️ 2025 Davorin Šego <br />
Licensed under the GPL v3  <br />
https://www.gnu.org/licenses/gpl-3.0.en.html




### Third-Party Resources


- [PortAudio](https://portaudio.com/) <br />
Portable Real-Time Audio Library <br />
Copyright (c) 1999-2011 Ross Bencina, Phil Burk <br />

- [portaudio bindings for odin-lang](https://github.com/jockus/odin-portaudio) <br />
Copyright (c) 2021, Joakim Hentula <br />
BSD-2-Clause license <br />

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



### Development

Install the `just` command runner (https://github.com/casey/just) to run the various dev commands.

```sh

# Clone this source code repository
git clone https://github.com/dsego/strobe-tuner/

# Change working directory
cd strobe-tuner

# Install necessary dependencies into the /external sub-directory
just install-deps

# Build deps
just build-pffft
just build-portaudio
just build-pa_ringubffer

# Compile & run the app code
just dev
```


### How it works

#### Pitch detection

The pitch detection algorithm uses autocorrelation via FFT, following the method described in _"A Smarter Way to Find Pitch" (Philip McLeod, Geoff Wyvill)_. It analyzes the waveform periodically to accurately identify the fundamental frequency, even in the presence of strong harmonics. A built-in clarity measure provides a confidence score for each detected pitch. Clarity and SNR (signal-to-noise ratio) help determine whether the pitch is strong or weak.

#### Stroboscopic effect

The strobe effect is driven by a phase comparator algorithm based on two successive single-bin DFTs, both tuned to the target note's reference frequency (e.g., 110 Hz). The idea is to extract the phase evolution of the signal at a specific frequency and map that to a visually intuitive strobe motion.

Core steps:
- Frequency targeting: Compute a windowed single-bin DFT precisely tuned to the reference frequency.
- Phase tracking: Track the phase difference between successive DFT results to determine the strobe’s rotational “spin.”
- Amplitude mapping: The signal amplitude controls brightness or contrast, making the strobe effect visually respond to signal strength.

When the input pitch matches the reference, the phase remains stable, and the strobe appears stationary. Pitch deviations cause the phase to advance or lag, creating a visually drifting effect proportional to the tuning error.

To maintain consistent similar amount of visual drift across the frequency spectrum, the algorithm adjusts hop size and window length based on musical pitch intervals (in cents) rather than absolute frequency. 

The single-bin DFT also serves as a narrowband filter, providing a clean strobe signal while still allowing nearby frequencies to influence the display. The amount of visual drift per cent can be scaled directly by multiplying the measured phase difference — allowing customizable strobe sensitivity.


#### Alternative approaches I have tried

- Time-aligned windowing with resampling - emulates a classic untriggered oscilloscope synced to the signal’s period. This approach required resampling and IIR bandpass filtering for each strobe band. The visual resolution was tied to the number of samples per cycle, fewer samples per period resulted in blocky motion. The visual sensitivity couldn’t be adjusted. A strong bandpass filter introduced latency, but without it the harmonics would bleed into the strobe pattern.

- Time-aligned windowing with sub-sample frame counter - instead of resampling, this approach maintains alignment by advancing a fractional counter and rounding the number of samples per frame up or down. Still requires a bandpass filter and interpolation at display or window boundaries.


#### Auto gain

Auto-gain (AGC) is applied to the strobe visualization to maintain visibility as the signal fades. The algorithm continuously estimates the background noise (i.e. the noise floor) and uses an SNR threshold to decide when to trigger gain adjustments. This ensures the strobe display maintains high visual contrast, even as the note loses volume.




