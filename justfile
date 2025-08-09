# use with https://github.com/casey/just
# Cross platform shebang

shebang := if os() == "windows" { "powershell.exe" } else { "/usr/bin/env sh" }

set windows-shell := ["powershell"]

default:
    @just --list

install-deps:
    #!{{ shebang }}
    cd external
    git clone https://github.com/jockus/odin-portaudio/
    git clone https://github.com/PortAudio/portaudio/
    git clone https://github.com/dsego/odin-pa_ringbuffer/
    git clone https://github.com/dsego/odin-pffft
    git clone https://bitbucket.org/jpommier/pffft/

build-pffft:
    #!{{ shebang }}
    cd external/pffft
    clang pffft.c pffft.h -c -O2 -Os -fPIC
    ar rcs pffft.a pffft.o
    cp pffft.a ../odin-pffft/

build-pffft-win:
    #!{{ shebang }}
    Set-Location "external\pffft"
    cl /c /O2 /Fo:pffft.obj pffft.c
    lib /OUT:pffft.lib pffft.obj
    Copy-Item -Path ".\pffft.lib" -Destination "..\odin-pffft"

build-pa_ringbuffer:
    #!{{ shebang }}
    cd external/portaudio/src/common
    clang pa_ringbuffer.c pa_ringbuffer.h -c -O2 -Os -fPIC
    ar rcs pa_ringbuffer.a pa_ringbuffer.o
    cp pa_ringbuffer.a ../../../odin-pa_ringbuffer/

build-pa_ringbuffer-win:
    #!{{ shebang }}
    Set-Location "external\portaudio\src\common"
    cl /c /O2 /Fo:pa_ringbuffer.obj pa_ringbuffer.c
    lib /OUT:pa_ringbuffer.lib pa_ringbuffer.obj
    Copy-Item -Path ".\pa_ringbuffer.lib" -Destination "..\..\..\odin-pa_ringbuffer"

build-portaudio:
    #!{{ shebang }}
    cd external/portaudio
    mkdir build
    cd build
    cmake ..
    cmake --build . --config Release
    cp libportaudio.a ../../../

build-portaudio-win:
    #!{{ shebang }}
    Set-Location "external\portaudio"
    New-Item -ItemType Directory -Path "build"
    Set-Location ".\build"
    cmake .. -G "Visual Studio 17 2022"
    cmake --build . --config Release
    Set-Location "..\..\odin-portaudio"
    New-Item -ItemType Directory -Path ".\portaudio"
    Copy-Item -Path "..\portaudio\build\Release\portaudio.lib" -Destination ".\portaudio\portaudio_x64.lib"

dev:
    odin run app -debug -extra-linker-flags="-L. -framework AudioToolbox -framework CoreAudio"

build:
    odin build app -o:speed -microarch:native -extra-linker-flags="-L. -framework AudioToolbox -framework CoreAudio"

# Run on Win 11
dev-win:
    odin run app -debug --extra-linker-flags="/FORCE:MULTIPLE"

build-win:
    rc app.rc
    odin build app -o:speed -microarch:native --extra-linker-flags="/FORCE:MULTIPLE app.res" -subsystem:windows
