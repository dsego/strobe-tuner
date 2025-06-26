#!/bin/bash

git clone https://github.com/jockus/odin-portaudio ./external/odin-portaudio
git clone https://github.com/spatialaudio/portaudio-binaries ./external/portaudio-binaries
cp ./external/portaudio-binaries/libportaudio.dylib libportaudio.dylib


git clone https://github.com/PortAudio/portaudio ./external/portaudio
git clone https://github.com/dsego/odin-pa_ringbuffer ./external/odin-pa_ringbuffer
cc ./external/portaudio/src/common/pa_ringbuffer.c ./external/portaudio/src/common/pa_ringbuffer.h -c -O2 -Os -fPIC
ar rcs ./external/odin-pa_ringbuffer/pa_ringbuffer.a pa_ringbuffer.o


git clone https://github.com/dsego/odin-pffft ./external/odin-pffft
git clone https://bitbucket.org/jpommier/pffft ./external/pffft
cc ./external/pffft/pffft.c ./external/pffft/pffft.h -c -O2 -Os -fPIC
ar rcs ./external/odin-pffft/pffft.a pffft.o

