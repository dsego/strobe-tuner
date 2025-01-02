package app

import "../core"


Config :: struct {
    // eg A 440Hz
    pitch_standard:         f32,

    // how many spinning bands to show
    strobe_count:           int,

    // FFT length for the pitch detector, e.g. 4092 samples
    pitch_detect_fft_size:  int,

    // audio card sampling rate, e.g. 44.100 Hz
    samplerate:             int,

    // how many samples to use for single bin phase detection
    strobe_window_size:     int,

    // harmonic to track multiple frequencies or "vernier" to track one pitch at different sensitivities
    strobe_mode:            core.StrobeMode,

    // the sensitivity the base strobe band,
    // i.e. how fast should the spinning effect be in response to the phase difference
    base_sensitivity:       f32,

    // if multiple strobe bands, this sensitivity multiplier will be applied to subsequent spinning bands
    sensitivity_multiplier: f32,

    // auto detection vs manual selection of note to track
    note_detection_mode:    NoteDetectionMode,

    // How to render the strobe effect
    strobe_display_type:    StrobeDisplayType,
}

config :: Config {
    pitch_standard         = 440.0,
    strobe_count           = 3,
    pitch_detect_fft_size  = 4096,
    samplerate             = 48_000,
    strobe_window_size     = 9600,
    strobe_mode            = .VERNIER_MODE, // .HARMONIC_MODE
    note_detection_mode    = .AUTO,
    base_sensitivity       = 0.01,
    sensitivity_multiplier = 2.0,
    strobe_display_type    = .CURVED_TRACKS,
}
