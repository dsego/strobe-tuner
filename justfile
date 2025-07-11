# use with https://github.com/casey/just

default:
  @just --list

install-deps:
  #!/usr/bin/env bash
  cd external
  git clone https://github.com/jockus/odin-portaudio/
  git clone https://github.com/PortAudio/portaudio/
  git clone https://github.com/dsego/odin-pa_ringbuffer/
  git clone https://github.com/dsego/odin-pffft
  git clone https://bitbucket.org/jpommier/pffft/

build-pffft:
  #!/usr/bin/env bash
  cd external/pffft
  clang pffft.c pffft.h -c -O2 -Os -fPIC
  ar rcs pffft.a pffft.o
  cp pffft.a ../odin-pffft/

build-pa_ringubffer:
  #!/usr/bin/env bash
  cd external/portaudio/src/common
  clang pa_ringbuffer.c pa_ringbuffer.h -c -O2 -Os -fPIC
  ar rcs pa_ringbuffer.a pa_ringbuffer.o
  cp pa_ringbuffer.a ../../../odin-pa_ringbuffer/


build-portaudio:
  #!/usr/bin/env bash
  cd external/portaudio
  mkdir build
  cd build
  cmake ..
  cmake --build . --config Release
  cp libportaudio.a ../../../

dev:
  odin run app -debug  -extra-linker-flags="-L. -framework AudioToolbox -framework CoreAudio"

build:
  odin build app -o:speed  -extra-linker-flags="-L. -framework AudioToolbox -framework CoreAudio"
