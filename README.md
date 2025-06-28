## Strobe Tuner

A stroboscopic tuner written in Odin.

Copyright ©️ 2025 Davorin Šego
Licensed under the GPL v3

<img src="" alt="screenshots/Screenshot%202025-06-28%20at%2018.48.25.png" width="600" height="672" class="shrinkToFit transparent">



#### Third-Party Resources

[PortAudio](https://portaudio.com/)
Portable Real-Time Audio Library
Copyright (c) 1999-2011 Ross Bencina, Phil Burk

[portaudio bindings for odin-lang](https://github.com/jockus/odin-portaudio)
Copyright (c) 2021, Joakim Hentula
BSD-2-Clause license

[PFFFT: a pretty fast FFT.](https://bitbucket.org/jpommier/pffft)
Copyright (c) 2013  Julien Pommier (pommier@modartt.com)
FFTPACK license

[The Inter typeface family](https://rsms.me/inter/)
Copyright (c) 2016 The Inter Project Authors
SIL Open Font License 1.1

[Noto Sans](https://github.com/notofonts)
Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic)
SIL Open Font License, Version 1.1 .



#### Instructions

1. Clone git repo

```
git clone git@github.com:dsego/strobe-tuner.git
```

2. Pull in and compile external dependencies:
- https://github.com/jockus/odin-portaudio
- https://github.com/spatialaudio/portaudio-binaries
- https://github.com/PortAudio/portaudio
- https://github.com/dsego/odin-pa_ringbuffer/
- https://github.com/dsego/odin-pffft
- https://bitbucket.org/jpommier/pffft/



4. Run the app
```
odin run app -extra-linker-flags="-L."
```

Or alternatively build the binary
```
odin build app -o:speed -extra-linker-flags="-L."
```


To compile mac icons:
```
➜ iconutil -c icns AppIcon.iconset
➜ mv AppIcon.icns StrobeTuner.app/Contents/Resources
```
