## Strobe Tuner

A stroboscopic tuner written in Odin.


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
