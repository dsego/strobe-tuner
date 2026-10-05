// Plays generated tones through the tuner like sandbox/replay plays a recording, and checks what it makes
// of them: the right note, the readout within TOLERANCE_CENTS of the tone's offset, and no note at all in
// noise alone. Prints a summary per waveform and noise level, then every failed case.
//
//   odin run sandbox/accuracy -o:speed
//   odin run sandbox/accuracy -o:speed -- full     every note from B0 to C8 and three concert pitches
//
// The tones are steady, a plucked note's attack and decay are for sandbox/replay with a recording.

package accuracy

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"

import "../../src/core"

// The app's, see sandbox/replay
SAMPLERATE :: core.SAMPLERATE
INTERVALS :: [?]f32{1, 2, 4}
STROBE_SPEED :: 0.025
// The app draws at 60 fps, e.g. -define:FRAME_SAMPLES=1024 for iOS's chunks of audio arriving every other frame
FRAME_SAMPLES :: #config(FRAME_SAMPLES, SAMPLERATE / 60)

TOLERANCE_CENTS :: 1

// A mic level, -20 dBFS RMS
TONE_RMS :: 0.1

// The room before the tone, long enough for the noise floors to learn it (see core.NOISE_FLOOR_WARMUP_S),
// then the tone, measured over its last second
LEAD_IN_S :: 2
TONE_S :: 2.5
MEASURE_S :: 1.0

// 28 just inside the strobe's readout range, see core.READOUT_RANGE_CENTS
OFFSETS_CENTS :: [?]f32{0, 0.5, -0.5, 5, -5, 20, -20, 28, -28, 45, -45}

// A lit track drifting the other way than the tone this fast, its stripes turn the wrong way
WRONG_WAY_MIN_HZ :: 1

// White noise this far under the tone, 0 for none
NOISE_SNRS_DB :: [?]f32{0, 20, 10}

Waveform :: enum {
    SINE,
    SAW,
    SQUARE,
    WEAK_FUNDAMENTAL, // a low string on a small speaker, the overtones of a saw over a fundamental 26 dB down
}

// Higher up the overtones are past the pitch detection's lowpass, a weak fundamental is all that's left
WEAK_FUNDAMENTAL_HIGHEST :: -5 // E4

Case :: struct {
    waveform:       Waveform,
    note_semitones: int, // from A4
    offset_cents:   f32,
    pitch_standard: f32,
    noise_snr_db:   f32,
}

Result :: struct {
    using test_case: Case,
    wrong_note:      int, // measured detections on another note, or none
    worst_cents:     f32, // the readout's furthest from the offset
    wrong_way:       int, // measured detections with a lit track drifting the other way
}

main :: proc() {
    full := len(os.args) > 1 && os.args[1] == "full"

    // B0 for a 5-string bass, then every fifth semitone up to C8, every note with full
    lowest, highest := -46, 39
    step := 1 if full else 5
    pitch_standards := [?]f32{440, 415, 466} if full else [?]f32{440, 0, 0}

    results: [dynamic]Result
    defer delete(results)

    for pitch_standard in pitch_standards {
        if pitch_standard == 0 do continue

        for waveform in Waveform {
            for noise_snr_db in NOISE_SNRS_DB {
                for note_semitones := lowest; note_semitones <= highest; note_semitones += step {
                    if waveform == .WEAK_FUNDAMENTAL && note_semitones > WEAK_FUNDAMENTAL_HIGHEST do break

                    for offset_cents in OFFSETS_CENTS {
                        append(&results, run_case({waveform, note_semitones, offset_cents, pitch_standard, noise_snr_db}))
                    }
                }
            }
        }
    }

    print_summary(results[:])

    false_notes := 0
    for noise_snr_db in NOISE_SNRS_DB {
        if noise_snr_db == 0 do continue

        active_s := run_noise_only(noise_snr_db)
        if active_s > 0 do false_notes += 1
        fmt.printf("Noise alone at the %.0f dB case's level: a note shown for %.2fs\n", noise_snr_db, active_s)
    }

    failed := 0
    for result in results {
        if !passed(result) do failed += 1
    }
    fmt.printf("\n%v of %v cases failed, %v noise levels showed a note\n", failed, len(results), false_notes)
    if failed + false_notes > 0 do os.exit(1)
}

passed :: proc(result: Result) -> bool {
    return result.wrong_note == 0 && abs(result.worst_cents) <= TOLERANCE_CENTS && result.wrong_way == 0
}

run_case :: proc(test_case: Case) -> (result: Result) {
    result.test_case = test_case

    note := core.cents_to_note(f32(100 * test_case.note_semitones), test_case.pitch_standard)
    freq_hz := note.frequency * math.pow(2, test_case.offset_cents / 1200)
    samples := generate(test_case.waveform, freq_hz, test_case.noise_snr_db)
    defer delete(samples)

    detector := core.init_pitch_detector(test_case.pitch_standard)
    defer core.destroy_pitch_detector(&detector)
    tuner := core.init_tuner(110, test_case.pitch_standard, true)

    intervals := INTERVALS
    strobe := core.init_phase_comparator(110, intervals[:], .HARMONIC)
    defer core.destroy_phase_comparator(strobe)
    retune :: proc(strobe: ^core.PhaseComparator, freq_hz, pitch_standard: f32) {
        core.set_phase_comparator_freq(strobe, freq_hz, pitch_standard, STROBE_SPEED, 2, .HARMONIC)
    }
    retune(strobe, 110, test_case.pitch_standard)

    measure_from := len(samples) - int(MEASURE_S * SAMPLERATE)
    readout_track := -1
    readout_ready := false
    for start := 0; start + FRAME_SAMPLES <= len(samples); start += FRAME_SAMPLES {
        // Like sandbox/replay, the app's loop
        frame := samples[start:start + FRAME_SAMPLES]
        core.audio_capture_write(&detector, frame)
        core.audio_capture_write(strobe, frame)
        pitch := core.run_pitch_detection(&detector, tuner.pitch)
        core.run_phase_detection(strobe, pitch.is_tonal)
        readout_track, readout_ready = core.strobe_readout_track(strobe, readout_track)
        if core.update_tuner(&tuner, pitch, core.strobe_shows_note(strobe)) {
            retune(strobe, tuner.target_note.frequency, test_case.pitch_standard)
        }
        off_target := strobe.base_freq_hz != tuner.target_note.frequency
        if off_target && !core.strobe_shows_note(strobe, fundamental_only = true) {
            retune(strobe, tuner.target_note.frequency, test_case.pitch_standard)
        }
        if !pitch.fresh || start < measure_from do continue

        if !tuner.active || tuner.target_note.cents != note.cents {
            result.wrong_note += 1
            continue
        }

        // Lit like core.strobe_shows_note counts it, on a partial the tone has. A sine's empty tracks can light
        // up from its leakage, their drift is the fundamental's and says nothing about the stripes.
        fade := core.STROBE_FADE_SNR_DB
        for band in strobe.bands {
            if !band.in_range || band.snr_db < 0.5 * (fade[0] + fade[1]) do continue
            if !has_partial(test_case.waveform, band.interval) do continue

            expected_hz := band.freq_hz * (math.pow(2, test_case.offset_cents / 1200) - 1)
            if abs(expected_hz) >= WRONG_WAY_MIN_HZ && band.drift_hz * expected_hz < 0 {
                result.wrong_way += 1
                break
            }
        }

        steady := core.tuner_readout(&tuner)
        readout := steady.err_cents
        if readout_ready && abs(steady.err_cents) <= core.READOUT_RANGE_CENTS {
            readout = strobe.bands[readout_track].err_cents
        }
        error_cents := readout - test_case.offset_cents
        if abs(error_cents) > abs(result.worst_cents) do result.worst_cents = error_cents
    }
    return
}

// For how long the tuner shows a note in white noise alone, at the level of the noise under a tone
run_noise_only :: proc(noise_snr_db: f32) -> (active_s: f32) {
    samples := generate(.SINE, 0, noise_snr_db)
    defer delete(samples)

    detector := core.init_pitch_detector()
    defer core.destroy_pitch_detector(&detector)
    tuner := core.init_tuner(110, 440, true)

    for start := 0; start + FRAME_SAMPLES <= len(samples); start += FRAME_SAMPLES {
        core.audio_capture_write(&detector, samples[start:start + FRAME_SAMPLES])
        pitch := core.run_pitch_detection(&detector, tuner.pitch)
        core.update_tuner(&tuner, pitch)
        if tuner.active do active_s += f32(FRAME_SAMPLES) / SAMPLERATE
    }
    return
}

has_partial :: proc(waveform: Waveform, interval: f32) -> bool {
    if interval != math.round(interval) do return false

    switch waveform {
    case .SINE:
        return interval == 1
    case .SQUARE:
        return int(interval) % 2 == 1
    case .SAW, .WEAK_FUNDAMENTAL:
        return true
    }
    return false
}

// LEAD_IN_S of silence then TONE_S of the waveform at TONE_RMS, and white noise noise_snr_db under that
// throughout. A frequency of 0 is the noise alone.
generate :: proc(waveform: Waveform, freq_hz, noise_snr_db: f32) -> []f32 {
    tone_start := int(LEAD_IN_S * SAMPLERATE)
    samples := make([]f32, tone_start + int(TONE_S * SAMPLERATE))

    if freq_hz > 0 {
        // Band-limited, the partials under the Nyquist frequency
        amplitudes: [64]f32
        for &amplitude, index in amplitudes {
            harmonic := f32(index + 1)
            if harmonic * freq_hz >= 0.45 * SAMPLERATE do break

            switch waveform {
            case .SINE:
                if index == 0 do amplitude = 1
            case .SAW:
                amplitude = 1 / harmonic
            case .SQUARE:
                if index % 2 == 0 do amplitude = 1 / harmonic
            case .WEAK_FUNDAMENTAL:
                amplitude = 0.05 if index == 0 else 1 / harmonic
            }
        }

        // The partials' power adds up, half of each one's amplitude squared
        power: f32
        for amplitude in amplitudes do power += 0.5 * amplitude * amplitude
        gain := TONE_RMS / math.sqrt(power)

        phase_step := f64(freq_hz) / SAMPLERATE
        for &sample, index in samples[tone_start:] {
            phase := math.TAU * phase_step * f64(index)
            for amplitude, harmonic in amplitudes {
                if amplitude == 0 do continue
                sample += gain * amplitude * f32(math.sin(phase * f64(harmonic + 1)))
            }
        }
    }

    if noise_snr_db > 0 {
        // Uniform noise between -1 and 1 has an RMS of 1/√3
        noise_rms := TONE_RMS * math.pow(10, -noise_snr_db / 20)
        random := u32(0x9e3779b9)
        for &sample in samples {
            // xorshift, the same noise every run
            random ~= random << 13
            random ~= random >> 17
            random ~= random << 5
            uniform := f32(random) / f32(max(u32)) * 2 - 1
            sample += noise_rms * math.SQRT_THREE * uniform
        }
    }
    return samples
}

print_summary :: proc(results: []Result) {
    fmt.println("waveform          noise   cases  failed  worst cents")
    for waveform in Waveform {
        for noise_snr_db in NOISE_SNRS_DB {
            cases, failed := 0, 0
            worst: f32
            for result in results {
                if result.waveform != waveform || result.noise_snr_db != noise_snr_db do continue

                cases += 1
                if !passed(result) do failed += 1
                if result.wrong_note == 0 && abs(result.worst_cents) > abs(worst) do worst = result.worst_cents
            }
            noise := "clean" if noise_snr_db == 0 else fmt.tprintf("%.0fdB", noise_snr_db)
            fmt.printf("%-17v %-7v %-6v %-7v %+.2f\n", waveform, noise, cases, failed, worst)
        }
    }

    failures: [dynamic]Result
    defer delete(failures)
    for result in results {
        if !passed(result) do append(&failures, result)
    }
    if len(failures) == 0 do return

    // The worst first
    slice.sort_by(failures[:], proc(first, second: Result) -> bool {
        if first.wrong_note != second.wrong_note do return first.wrong_note > second.wrong_note
        return abs(first.worst_cents) > abs(second.worst_cents)
    })
    fmt.println("\nfailed cases:")
    for result in failures {
        note := core.cents_to_note(f32(100 * result.note_semitones), result.pitch_standard)
        name := fmt.tprintf("%v%v%v", note.name, "#" if note.is_accidental else "", note.octave)
        noise := "clean" if result.noise_snr_db == 0 else fmt.tprintf("%.0fdB", result.noise_snr_db)
        fmt.printf(
            "  %-17v %-4v %+5.1f¢  A=%.0f  %-6v",
            result.waveform,
            name,
            result.offset_cents,
            result.pitch_standard,
            noise,
        )
        if result.wrong_note > 0 {
            fmt.printf("  wrong or no note in %v detections\n", result.wrong_note)
        } else {
            fmt.printf("  readout off by %+.2f¢", result.worst_cents)
            if result.wrong_way > 0 do fmt.printf(", stripes turn the wrong way in %v detections", result.wrong_way)
            fmt.println()
        }
    }
}
