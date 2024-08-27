package app


// NOTE: Needs to be a power of 2 for portaudio ring buffers
DEFAULT_RB_SIZE :: 65536

// Simplify by using a constant number of ringbuffers instead of a dynamic list.
STROBE_COUNT :: 1

// FFT size for pitch detection
FFT_SIZE :: 4096


STROBE_SAMPLE_SIZE :: 4096

SAMPLERATE :: 44100

SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768


MAX_SPECTRUM_DISPLAY_LEN :: 4096


MIN_FREQ :: 20.0
MAX_FREQ :: 8000.0
