// Compares the strobe tracks turned by the lock-in with the ones turned by the lamp (lamp_comparator in
// src/app/scope_display.odin) on a recording, at the same speed: how much each track's stripes move from frame
// to frame, and how much of that is jitter.
//
//   odin run sandbox/lamp_jitter -- <file.wav|mp3|flac>
//
// Both turn by their phase advance, rescaled so all notes spin at the same rate per cent, times the
// strobe's speed. The tracks measure it with their DFT on the samples, at a few widths of their band, the
// lamp with a DFT of the scope's screen from above, at a few persistences of the screen.
//
// Only the frames where the app's tracks show: the tuner holds the note and the lamp's screen has settled.
// Apart where the stripes are fully lit and where they fade out with the note, by the SNR of the app's
// tracks, so every row measures the same moments.
//
//   speed  - the mean movement, in fundamental stripes a second, both should agree
//   jitter - the RMS of the change of the movement from one frame to the next over √2, in percent of a
//            fundamental stripe, the part of the movement that isn't a steady drift

package lamp_jitter

import "core:fmt"
import "core:math"
import "core:os"
import ma "vendor:miniaudio"

import "../../src/core"

// The app's, see src/app/app.odin
SAMPLERATE :: core.DEFAULT_SAMPLE_RATE
STROBE_SPEED :: 0.0125
SCOPE_COLUMNS :: 488 // STROBE_WIDTH
SCOPE_ROWS :: 240
TRACKS_PERIODS :: 12 // DESKTOP_TRACKS_PERIODS, the fundamental's stripes across the circle

HARMONICS :: 3
INTERVALS :: [HARMONICS]f32{1, 2, 3}
PERSISTENCES_MS :: [?]f64{0, 40, 100, 200}
BAND_WIDTHS_CENTS :: [?]int{core.DFT_RESOLUTION_CENTS, 50, 25} // the app's first, see W in the app

// Listed as they happen, a frame's advance of a harmonic over this, at the app's default persistence
APP_PERSISTENCE_MS :: 40
JUMP_RADIANS :: math.PI / 2

FRAME_SAMPLES :: SAMPLERATE / 60
// The screen fills in after a new reference, this long of it counts as one
SETTLE_S :: 0.25

// Where a frame's stripes are, by the app's tracks
Region :: enum {
    LIT, // the SNR where they're fully lit
    TAIL, // fading out, still showing
    DARK,
}

REGION_NAMES :: [Region]string {
    .LIT  = "fully lit",
    .TAIL = "fading out",
    .DARK = "dark",
}

// The movement of a track over the frames it was measured in
Movement :: struct {
    count:        int,
    sum:          f64,
    change_sq:    f64,
    changes:      int,
    previous:     f64,
    has_previous: bool,
}

add_movement :: proc(self: ^Movement, step: f64) {
    self.count += 1
    self.sum += step
    if self.has_previous {
        self.change_sq += (step - self.previous) * (step - self.previous)
        self.changes += 1
    }
    self.previous = step
    self.has_previous = true
}

// A frame it wasn't measured in, the next change is from the frame after
skip_movement :: proc(self: ^Movement) {
    self.has_previous = false
}

// A frame's movement into its region's, the others skip it
add_in_region :: proc(movements: ^[Region]Movement, region: Region, step: f64) {
    for &movement, each in movements {
        if each == region do add_movement(&movement, step)
        else do skip_movement(&movement)
    }
}

Lamp :: struct {
    scope:     core.Scope,
    phases:    [HARMONICS]f64,
    freq_hz:   f64,
    settle:    f64, // seconds left
    movements: [HARMONICS][Region]Movement,
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: odin run sandbox/lamp_jitter -- <file.wav|mp3|flac>")
        os.exit(1)
    }
    samples, ok := decode(os.args[1])
    if !ok {
        fmt.eprintln("Can't decode", os.args[1])
        os.exit(1)
    }
    defer delete(samples)

    detector := core.init_pitch_detector()
    defer core.destroy_pitch_detector(&detector)
    tuner := core.init_tuner(110, 440, true)

    intervals := INTERVALS
    widths := BAND_WIDTHS_CENTS
    strobes: [len(widths)]^core.PhaseComparator
    retune :: proc(strobe: ^core.PhaseComparator, freq_hz: f32) {
        core.set_phase_comparator_freq(strobe, freq_hz, 440, STROBE_SPEED, 2, .HARMONIC)
    }
    for &strobe, index in strobes {
        strobe = core.init_phase_comparator(110, intervals[:], .HARMONIC)
        strobe.band_cents = widths[index]
        retune(strobe, 110)
    }
    defer for strobe in strobes do core.destroy_phase_comparator(strobe)

    // The app's, the tuner follows it and its SNR places the frames
    strobe := strobes[0]
    tracks: [len(widths)][HARMONICS][Region]Movement

    persistences := PERSISTENCES_MS
    lamps: [len(persistences)]Lamp
    for &lamp, index in lamps {
        lamp.scope = core.init_scope(SCOPE_COLUMNS, SCOPE_ROWS)
        lamp.scope.persistence_seconds = persistences[index] / 1000
    }
    defer for &lamp in lamps do core.destroy_scope(&lamp.scope)

    fully_lit := core.STROBE_FADE_SNR_DB[1]
    frame_s := f64(FRAME_SAMPLES) / SAMPLERATE

    for start := 0; start + FRAME_SAMPLES <= len(samples); start += FRAME_SAMPLES {
        frame := samples[start:start + FRAME_SAMPLES]
        core.audio_capture_write(&detector, frame)
        for each in strobes do core.audio_capture_write(each, frame)
        for &lamp in lamps do core.audio_capture_write(&lamp.scope, frame)

        // Like the app, see sandbox/replay
        pitch := core.run_pitch_detection(&detector, tuner.pitch)
        for each in strobes do core.run_phase_detection(each, pitch.is_tonal)
        if core.update_tuner(&tuner, pitch, core.strobe_shows_note(strobe)) {
            for each in strobes do retune(each, tuner.target_note.frequency)
        }

        regions: [HARMONICS]Region
        for band, index in strobe.bands {
            regions[index] = .DARK
            if !tuner.active do continue

            if band.snr_db >= fully_lit do regions[index] = .LIT
            else if band.snr_db > core.STROBE_FADE_SNR_DB[0] do regions[index] = .TAIL
        }

        // The tracks, as strobe_tracks turns them, in fundamental stripes: a track's phase moves its
        // stripes by the phase over its partial
        for each, width_index in strobes {
            for band, index in each.bands {
                step := f64(band.phase_diff * band.speed) * TRACKS_PERIODS / f64(band.interval) / math.TAU
                add_in_region(&tracks[width_index][index], regions[index], step)
            }
        }

        // The lamp's, as lamp_comparator turns them
        for &lamp, lamp_index in lamps {
            scope := &lamp.scope
            strobe_hz := f64(strobe.base_freq_hz)
            if scope.freq_hz != strobe_hz do core.set_scope_freq(scope, strobe_hz)
            scope.noise_floor = detector.noise_floor.level
            core.update_scope(scope)

            periods := [HARMONICS]int{2, 4, 6} // SCOPE_PERIODS times the intervals
            harmonics: [HARMONICS]core.ScopePartial
            noise := max(core.scope_partials(scope, periods[:], harmonics[:]), 1e-9)
            measuring := lamp.freq_hz == scope.freq_hz
            lamp.freq_hz = scope.freq_hz
            if !measuring do lamp.settle = SETTLE_S
            lamp.settle -= frame_s

            for harmonic, index in harmonics {
                advance := core.wrap_phase(harmonic.phase - lamp.phases[index]) if measuring else 0
                lamp.phases[index] = harmonic.phase

                band := strobe.bands[index]
                snr_db := 20 * math.log10(max(harmonic.level, 1e-9) / noise)

                // At the app's persistence, a jump of the lamp's track while its stripes show at all, and
                // the tracks' advance on the same frame for comparison
                visible := min(snr_db, f64(pitch.snr_db)) > f64(core.STROBE_FADE_SNR_DB[0])
                if persistences[lamp_index] == APP_PERSISTENCE_MS && visible && abs(advance) > JUMP_RADIANS {
                    track_advance := f64(band.phase_diff) * f64(band.freq_hz) / core.STROBE_REFERENCE_HZ
                    fmt.printf(
                        "jump %-7v %v×  lamp %-6v tracks %-6v screen %-7v signal %-7v since the reference %v\n",
                        fmt.tprintf("%.2fs", f64(start + FRAME_SAMPLES) / SAMPLERATE),
                        index + 1,
                        fmt.tprintf("%+.0f°", math.to_degrees(advance)),
                        fmt.tprintf("%+.0f°", math.to_degrees(track_advance)),
                        fmt.tprintf("%.1fdB", snr_db),
                        fmt.tprintf("%.1fdB", pitch.snr_db),
                        fmt.tprintf("%.2fs", SETTLE_S - lamp.settle),
                    )
                }

                // phase_diff times the speed, the harmonic's rescale and speed cancel out
                phase := advance * core.STROBE_REFERENCE_HZ / scope.freq_hz * STROBE_SPEED
                region := regions[index] if lamp.settle <= 0 else .DARK
                add_in_region(&lamp.movements[index], region, phase * TRACKS_PERIODS / f64(index + 1) / math.TAU)
            }
        }
    }

    // An exponential screen lags by its persistence, the tracks' window by its mean age and half the comb, at
    // the last note
    fmt.println(os.args[1])
    comb_samples := core.comb_periods(strobe.bands[:], .HARMONIC) * SAMPLERATE / strobe.base_freq_hz
    for width in widths {
        // The gamma window's mean age, the box adds half its length
        gamma_size := core.dft_window_size(strobe.base_freq_hz, SAMPLERATE, width)
        lag_samples := core.GAMMA_WINDOW_DELAY * f32(gamma_size) + comb_samples / 2
        lag_ms := 1000 * f64(lag_samples) / SAMPLERATE
        fmt.printf("  tracks %vc lag %.0fms at %.1f Hz\n", width, lag_ms, strobe.base_freq_hz)
    }
    print_movement :: proc(name: string, harmonic: int, movement: Movement, frame_s: f64) {
        if movement.count == 0 || movement.changes == 0 {
            fmt.printf("  %-16v %v×  -\n", name, harmonic)
            return
        }
        speed := movement.sum / f64(movement.count) / frame_s
        jitter := math.sqrt(movement.change_sq / f64(movement.changes) / 2) * 100
        // fmt pads numbers with zeros, the text pads with spaces
        fmt.printf("  %-16v %v×  %-24v %-22v frames %v\n", name, harmonic, fmt.tprintf("%+.3f", speed), fmt.tprintf("%.3f", jitter), movement.count)
    }
    names := REGION_NAMES
    for region in Region.LIT ..= Region.TAIL {
        fmt.printf("\n%-21v speed (stripes/s)        jitter (%% of a stripe)\n", names[region])
        for index in 0 ..< HARMONICS {
            for width, width_index in widths {
                print_movement(fmt.tprintf("tracks %vc", width), index + 1, tracks[width_index][index][region], frame_s)
            }
            for lamp, lamp_index in lamps {
                print_movement(fmt.tprintf("lamp %vms", persistences[lamp_index]), index + 1, lamp.movements[index][region], frame_s)
            }
        }
    }
}

// The whole file as mono, after 2 seconds of silence like sandbox/replay. Only at SAMPLERATE, miniaudio's
// resampler would leave images of the notes, see core.DEFAULT_SAMPLE_RATE.
decode :: proc(path: string) -> (samples: []f32, ok: bool) {
    decoder: ma.decoder
    config := ma.decoder_config_init(.f32, 1, 0)
    cpath := fmt.ctprintf("%s", path)
    if ma.decoder_init_file(cpath, &config, &decoder) != .SUCCESS do return nil, false
    defer ma.decoder_uninit(&decoder)

    if decoder.outputSampleRate != SAMPLERATE {
        fmt.eprintfln("%v is at %v Hz, convert it to %v Hz first", path, decoder.outputSampleRate, SAMPLERATE)
        return nil, false
    }

    length: u64
    ma.decoder_get_length_in_pcm_frames(&decoder, &length)
    lead_in := u64(2 * SAMPLERATE)
    samples = make([]f32, lead_in + length)
    ma.decoder_read_pcm_frames(&decoder, raw_data(samples[lead_in:]), length, nil)
    return samples, true
}
