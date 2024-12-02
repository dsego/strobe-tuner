package app

import "../shared"

Config :: struct {
    strobe_count:          int,
    pitch_detect_fft_size: int,
    samplerate:            int,
    strobe_window_size:    int,
    strobe_mode:           shared.StrobeMode,
}

config := Config {
    strobe_count          = 3,
    pitch_detect_fft_size = 4096,
    samplerate            = 48_000,
    strobe_window_size    = 8192, // vs 16_384 ??
    strobe_mode           = .VERNIER_MODE, // .HARMONIC_MODE
}
