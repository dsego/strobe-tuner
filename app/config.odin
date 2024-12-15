package app

import "../core"

Config :: struct {
    pitch_standard:        f32,
    strobe_count:          int,
    pitch_detect_fft_size: int,
    samplerate:            int,
    strobe_window_size:    int,
    strobe_mode:           core.StrobeMode,
}

config := Config {
    pitch_standard        = 440.0,
    strobe_count          = 3,
    pitch_detect_fft_size = 4096,
    samplerate            = 48_000,
    strobe_window_size    = 9600,
    strobe_mode           = .VERNIER_MODE, // .HARMONIC_MODE
}
