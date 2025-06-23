#!/bin/bash

git clone git@github.com:jockus/odin-portaudio.git ./external/odin-portaudio
git clone git@github.com:spatialaudio/portaudio-binaries.git ./external/portaudio-binaries
mkdir ./external/odin-portaudio/portaudio/
cp ./external/portaudio-binaries/libportaudio.dylib libportaudio.dylib


git clone git@github.com:PortAudio/portaudio.git ./external/portaudio
git clone git@github.com:dsego/odin-pa_ringbuffer.git ./external/odin-pa_ringbuffer
cc ./external/portaudio/src/common/pa_ringbuffer.c ./external/portaudio/src/common/pa_ringbuffer.h -c -O2 -Os -fPIC
ar rcs ./external/odin-pa_ringbuffer/pa_ringbuffer.a pa_ringbuffer.o


git clone git@github.com:dsego/odin-pffft.git ./external/odin-pffft
git clone https://bitbucket.org/jpommier/pffft.git ./external/pffft
cc ./external/pffft/pffft.c ./external/pffft/pffft.h -c -O2 -Os -fPIC
ar rcs ./external/odin-pffft/pffft.a pffft.o

