## Strobe Tuner

A stroboscopic tuner written in Odin.


#### Instructions

1. Clone git repo with submodules

```
git clone --recurse-submodules git@github.com:dsego/strobe-tuner.git
cd strobe-tuner
```

2. Install portaudio (on Mac)
```
brew install portaudio 
```

3. Build pffft & pa ringbuffer and copy over `.a` files to their respective vendor directories.

- `pffft.a` https://github.com/dsego/odin-pffft?tab=readme-ov-file#building-pffft-on-macos
- `pa_ringbuffer.a` https://github.com/dsego/odin-pa_ringbuffer/?tab=readme-ov-file#build-portaudio-ringbuffer-on-macos

4. Run app
```
odin run app
```
