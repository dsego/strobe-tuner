# SonicStrobe

A stroboscopic instrument tuner written in [Odin](https://odin-lang.org/).

<img src="screenshots/Screenshot 2025-06-28 at 18.48.25.png" width="300" height="336" class="shrinkToFit transparent">

### Download

[Latest release on GitHub](https://github.com/dsego/strobe-tuner/releases)

### Features

- Automatic pitch detection based on NSDF (McLeod Pitch Method).
- Smooth and responsive strobe display.
- Manual target note selection.
- Harmonic mode: shows the partials of the detected note across multiple strobe bands.
- Vernier mode: shows the same fundamental frequency in each band, but with increasing sensitivity. When the central band is stationary, outer bands may still move.
- Contrast and strobe sensitivity (speed) sliders.
- Hertz/Cents display.



### Keyboard shortcuts
- <kbd>←</kbd><kbd>→</kbd> &nbsp;  left/right arrow to move selected note up or down chromatically.
- <kbd>↑</kbd><kbd>↓</kbd> &nbsp;  up/down arrow to move selected note up and down by octave.
- <kbd>tab</kbd> &nbsp;  switch the strobe display type to a full wheel.



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



### Developing

Install the just command runner (https://github.com/casey/just) to run the various dev commands.

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
