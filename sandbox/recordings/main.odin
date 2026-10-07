// Plays real recordings through the tuner like sandbox/replay, each one again shifted by a known number of
// cents, and checks the readout moves by exactly that much. How the player tuned doesn't matter, both runs
// hear the same performance, its vibrato and drift cancel out.
//
//   odin run sandbox/recordings -o:speed -- [folder] [csv]
//
// Every wav, mp3 and flac in the folder, sandbox/samples by default, one note per file named at the end of
// the filename, e.g. bass_E1.wav, middle C as C4. A folder in MIDDLE_C3_FOLDERS names middle C as C3 and
// reads an octave up, a %23 in a filename reads as #. csv prints the runs as CSV instead, to diff two commits.
//
// The shift decodes at SAMPLERATE × 2^(−cents/1200) and plays at SAMPLERATE, the pitch rises by the cents
// and the length shrinks by the same ratio. Report only, nothing fails the run.
//
// The note an octave up counts apart from a wrong note, the readout is the same in any octave. A
// spectrum of each original, made without the tuner, shows why, e.g. a bass string with a weak fundamental:
// the 1x dB column is the fundamental's level from the strongest harmonic.

package recordings

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import ma "vendor:miniaudio"

import "../../src/core"

// The app's, see sandbox/replay
SAMPLERATE :: core.SAMPLERATE
INTERVALS :: [?]f32{1, 2, 4}
STROBE_SPEED :: 0.025
FRAME_SAMPLES :: SAMPLERATE / 60

TOLERANCE_CENTS :: 1 // like the generated tones', see sandbox/accuracy

LEAD_IN_S :: 2

// Named with middle C as C3, as Yamaha, Ableton and many sample libraries do
MIDDLE_C3_FOLDERS :: [?]string{"sandbox/samples"}

// ±100 lands on the next note
SHIFTS_CENTS :: [?]f32{0.5, -0.5, 3, -3, 7, -7, 23, -23, 49, -49, 100, -100}

// One more, an instrument tuned to A=442 and the tuner set to it, the readout should stay put
SHIFTED_STANDARD :: f32(442)

// The sustain, from this long after the note lights until it goes dark, without the window's last part
SUSTAIN_FROM_S :: 0.5
SUSTAIN_TRIM :: 0.1

// A live input's room and mic noise never gets this quiet, the sustain ends where the recording falls
// under it for good. A tail cleaner than the app ever hears isn't measured, e.g. a hum 50dB under the
// note that the tuner follows once the string is gone, inaudible but over a digitally silent floor.
LIVE_FLOOR_DBFS :: -60
// The level's RMS over this long
LEVEL_WINDOW_S :: 0.05

// A lit track drifting the other way than it should this fast, its stripes turn the wrong way. Each track
// is checked against its own drift at the same moment of the original plus the shift, a real string's
// partials run sharp of its fundamental and wander, they don't agree with the readout or each other.
WRONG_WAY_MIN_HZ :: 1
// Only while the original is within this of its loudest, a fading tail rings with a weak partial or two
// that wander, e.g. a bass whose fundamental still carries the level but can't be heard any more
WRONG_WAY_WITHIN_DB :: 15
// Nor after a partial's null, its level falling this far this fast: two close components of it cancel and
// hand over, the phase of their sum jumps half a turn either way and the drift carries it a while
NULL_DROP_DB :: 20
NULL_FALL_S :: 0.15
NULL_HOLD_S :: 3 * core.DRIFT_SMOOTH_S
// -define:SHOW_WRONG_WAY=true prints every detection with a track turning the wrong way
SHOW_WRONG_WAY :: #config(SHOW_WRONG_WAY, false)

// The named note's harmonics the spectrum looks at, the half one for a filename an octave too high
HARMONICS :: [?]f32{0.5, 1, 2, 3, 4, 5, 6}
// -define:SHOW_SPECTRA=true prints every harmonic of each original, the report shows the fundamental's
SHOW_SPECTRA :: #config(SHOW_SPECTRA, false)
// Each peak searched this far either side of its harmonic, a real string's partials run sharp
PEAK_SEARCH_CENTS :: 50
PEAK_STEP_CENTS :: 2
// The named note looks an octave too low with its 1x and 3x both this far under the strongest, a real
// note's 3x stays even when its fundamental is weak
NAMED_LOW_DB :: -40

Spectrum :: struct {
    file:          string,
    note:          int,
    levels_db:     [len(HARMONICS)]f32, // the peak's, from the strongest
    offsets_cents: [len(HARMONICS)]f32, // the peak's from its harmonic
    named_low:     bool, // see NAMED_LOW_DB
}

Track :: struct {
    lit:        bool,
    freq_hz:    f32,
    drift_hz:   f32,
    snr_db:     f32,
    after_null: bool, // see NULL_DROP_DB
}

// A fresh detection, the pitch in cents from A4 as the readout shows it
Detection :: struct {
    time_s:     f32,
    active:     bool,
    note_cents: int, // the target note's
    // The readout's track's over the note, the note's shown that much higher, see core.readout_octaves
    octaves:    int,
    read:       bool, // a readout, none until a strobe track settled, like the app's
    cents:      f32, // the note's plus the readout
    tracks:     [len(INTERVALS)]Track,
}

Run :: struct {
    file:           string,
    shift_cents:    f32, // the decode rate's, rounded to a whole Hz
    pitch_standard: f32,
    expected_cents: f32, // how far the pitch should move from the original's
    error_cents:    f32,
    // The median of the readout's move minus the shift, each detection against the original's at the same
    // moment of the performance, the note's drift cancels moment by moment
    aligned_cents:  f32,
    unread:         int, // detections in the sustain lit without a readout
    expected_note:  int,
    shown_note:     int, // the most common in the sustain
    wrong_note:     int, // detections in the sustain on another note, or none
    octave:         int, // on the note an octave up, the others count as a wrong note
    partial:        int, // on the note, shown in the octave of the partial the readout measures
    fundamental_db: f32, // the original's, from its strongest harmonic, see measure_spectrum
    // The original's 2nd harmonic louder than its fundamental, showing the octave up is following it
    second_louder:  bool,
    wrong_way:      [len(INTERVALS)]int, // detections per track
    // of the readout over the sustain, from the 10th to the 90th percentile. An octave off counts as the
    // note, the readout is the same cents in any octave.
    spread_cents:   f32,
    lit_s:          f32,
    measured:       int, // detections in the sustain
}

main :: proc() {
    folder := "sandbox/samples"
    csv := false
    for arg in os.args[1:] {
        if arg == "csv" {
            csv = true
        } else {
            folder = arg
        }
    }

    files, err := os.read_all_directory_by_path(folder, context.allocator)
    if err != nil {
        fmt.eprintln("Can't read", folder, err)
        os.exit(1)
    }
    defer os.file_info_slice_delete(files, context.allocator)
    slice.sort_by(files, proc(first, second: os.File_Info) -> bool { return first.name < second.name })

    named_octave_cents := 0
    for c3_folder in MIDDLE_C3_FOLDERS {
        if strings.trim_right(folder, "/") == c3_folder do named_octave_cents = 1200
    }

    runs: [dynamic]Run
    defer delete(runs)

    spectra: [dynamic]Spectrum
    defer delete(spectra)

    for file in files {
        extension := strings.to_lower(os.ext(file.name), context.temp_allocator)
        if extension != ".wav" && extension != ".mp3" && extension != ".flac" do continue

        if !csv do fmt.eprintln("Playing", file.name)
        run_file(&runs, &spectra, file.fullpath, file.name, named_octave_cents)
    }

    if csv {
        print_csv(runs[:])
    } else {
        print_report(runs[:])
        when SHOW_SPECTRA do print_spectra(spectra[:])
    }

    for spectrum in spectra {
        if spectrum.named_low do fmt.eprintfln("%v: %v looks an octave low, nothing at its 1x and 3x", spectrum.file, note_name(spectrum.note))
    }
}

// The original, then every shift against it
run_file :: proc(runs: ^[dynamic]Run, spectra: ^[dynamic]Spectrum, path, name: string, named_octave_cents: int) {
    original := play(path, 0, 440)
    defer delete(original)

    samples, decoded := decode(path, SAMPLERATE)
    if !decoded do return
    defer delete(samples)

    first_lit, last_lit: f32 = -1, -1
    for detection in original {
        if !detection.active do continue
        if first_lit < 0 do first_lit = detection.time_s
        last_lit = detection.time_s
    }
    levels := levels_db(samples)
    defer delete(levels)

    sustain := [2]f32{first_lit + SUSTAIN_FROM_S, min(last_lit, last_above_floor(levels))}
    sustain[1] -= SUSTAIN_TRIM * (sustain[1] - sustain[0])
    if first_lit < 0 || sustain[1] <= sustain[0] {
        fmt.eprintln("  no sustain, the note is lit and over", LIVE_FLOOR_DBFS, "dBFS for under", SUSTAIN_FROM_S, "seconds")
        return
    }

    // The note in the filename, after the last underscore, or the one the original shows
    stem, _ := strings.replace_all(os.stem(name), "%23", "#", context.temp_allocator)
    filename_note, named := core.parse_note(stem[strings.last_index_byte(stem, '_') + 1:])
    expected_note := filename_note.cents + named_octave_cents
    if !named {
        unfolded, _ := median_cents(original[:], sustain, nil)
        expected_note = 100 * int(math.round(unfolded / 100))
    }
    original_cents, _ := median_cents(original[:], sustain, expected_note)

    spectrum := measure_spectrum(samples, sustain, expected_note)
    spectrum.file = name
    append(spectra, spectrum)
    // A shift moves every harmonic by the same cents, their levels stay the original's
    harmonics := HARMONICS
    fundamental_index, _ := slice.linear_search(harmonics[:], 1)
    second_index, _ := slice.linear_search(harmonics[:], 2)
    fundamental_db := spectrum.levels_db[fundamental_index]
    second_louder := spectrum.levels_db[second_index] > fundamental_db

    original_run := measure(original[:], sustain, expected_note, nil)
    original_run.file = name
    original_run.fundamental_db = fundamental_db
    original_run.second_louder = second_louder
    original_run.pitch_standard = 440
    original_run.lit_s = lit_s(original[:])
    append(runs, original_run)

    shift_cases: [len(SHIFTS_CENTS) + 1][2]f32
    for shift, index in SHIFTS_CENTS do shift_cases[index] = {shift, 440}
    shift_cases[len(SHIFTS_CENTS)] = {core.freq_to_cents(SHIFTED_STANDARD), SHIFTED_STANDARD}

    for shift_case in shift_cases {
        wanted_cents, pitch_standard := shift_case[0], shift_case[1]
        decode_rate := u32(math.round(SAMPLERATE * math.pow(2, -wanted_cents / 1200)))
        shift_cents := 1200 * math.log2(f32(SAMPLERATE) / f32(decode_rate))
        ratio := f32(decode_rate) / SAMPLERATE

        shifted := play(path, decode_rate, pitch_standard)
        defer delete(shifted)

        // The same part of the performance, it plays faster or slower after the lead-in
        scaled := LEAD_IN_S + (sustain - LEAD_IN_S) * ratio
        // The tuner set to A=442 measures from it
        expected_cents := shift_cents - core.freq_to_cents(pitch_standard)
        // In the original's octave, a hop away from it is already a wrong note
        note := 100 * int(math.round((original_cents + expected_cents) / 100))

        reference := Reference{original[:], expected_note, ratio, expected_cents, levels, slice.max(levels) - WRONG_WAY_WITHIN_DB}
        run := measure(shifted[:], scaled, note, reference)
        shifted_cents, _ := median_cents(shifted[:], scaled, note)
        run.file = name
        run.fundamental_db = fundamental_db
        run.second_louder = second_louder
        run.shift_cents = shift_cents
        run.pitch_standard = pitch_standard
        run.expected_cents = expected_cents
        run.error_cents = shifted_cents - original_cents - expected_cents
        run.lit_s = lit_s(shifted[:])
        append(runs, run)
    }
}

// The original for a shifted run to compare its tracks with, at the same moment of the performance
Reference :: struct {
    detections: []Detection,
    note:       int,
    ratio:      f32, // the shifted run's length over the original's
    cents:      f32, // the shift the tracks should move by
    levels_db:  []f32, // the original's, see levels_db
    loud_db:    f32, // the tracks turn the wrong way only at or over it, see WRONG_WAY_WITHIN_DB
}

// The tracks turning the wrong way only with the original to compare with
measure :: proc(detections: []Detection, sustain: [2]f32, expected_note: int, reference: Maybe(Reference)) -> (run: Run) {
    run.expected_note = expected_note

    cents: [dynamic]f32
    defer delete(cents)
    aligned_errors: [dynamic]f32
    defer delete(aligned_errors)
    note_counts: map[int]int
    defer delete(note_counts)

    cursor := 0
    for detection in detections {
        if detection.time_s < sustain[0] || detection.time_s > sustain[1] do continue

        run.measured += 1
        if !detection.active {
            run.wrong_note += 1
            continue
        }

        note_counts[detection.note_cents + 1200 * detection.octaves] += 1
        if detection.read {
            append(&cents, fold_octave(detection.cents, expected_note))
        } else {
            run.unread += 1
        }

        // The original at the same moment of the performance
        original, aligned := reference.?
        then: Detection
        loud := false
        if aligned {
            original_s := LEAD_IN_S + (detection.time_s - LEAD_IN_S) / original.ratio
            for cursor + 1 < len(original.detections) && original.detections[cursor + 1].time_s <= original_s {
                cursor += 1
            }
            then = original.detections[cursor]

            level := original.levels_db[clamp(int(original_s / LEVEL_WINDOW_S), 0, len(original.levels_db) - 1)]
            loud = level >= original.loud_db
        }

        // The readout's pitch on any note, e.g. the neighbour half way between them
        if detection.read && then.active && then.read {
            moved := fold_octave(detection.cents, expected_note) - fold_octave(then.cents, original.note)
            append(&aligned_errors, moved - original.cents)
        }

        // On another note the tracks are other partials
        if detection.note_cents != expected_note {
            if detection.note_cents - expected_note == 1200 {
                run.octave += 1
            } else {
                run.wrong_note += 1
            }
            continue
        }
        if detection.octaves != 0 do run.partial += 1

        if !then.active || then.note_cents != original.note || !loud do continue

        // The readout on another partial than the original's, the recording hops between them there and
        // the tracks don't follow the same partials moment by moment
        if detection.read && then.read && detection.octaves != then.octaves do continue

        for track, index in detection.tracks {
            partial := then.tracks[index]
            if !track.lit || !partial.lit || track.after_null || partial.after_null do continue

            // The original's partial moved by the shift, from the note this run measures from
            partial_cents := core.cents_deviation(partial.freq_hz + partial.drift_hz, partial.freq_hz)
            expected_cents := f32(original.note - expected_note) + partial_cents + original.cents
            expected_hz := track.freq_hz * (math.pow(2, expected_cents / 1200) - 1)
            if abs(expected_hz) < WRONG_WAY_MIN_HZ || track.drift_hz * expected_hz >= 0 do continue

            run.wrong_way[index] += 1
            when SHOW_WRONG_WAY {
                intervals := INTERVALS
                fmt.eprintfln(
                    "  %.2fs %v× drifts %+.1f¢ at %.1fdB, the original's %+.1f¢ at %.1fdB, %+.1f¢ expected",
                    detection.time_s,
                    intervals[index],
                    core.cents_deviation(track.freq_hz + track.drift_hz, track.freq_hz),
                    track.snr_db,
                    partial_cents,
                    partial.snr_db,
                    expected_cents,
                )
            }
        }
    }

    most := 0
    run.shown_note = expected_note
    for note, count in note_counts {
        if count > most do run.shown_note, most = note, count
    }

    if len(cents) > 0 {
        slice.sort(cents[:])
        run.spread_cents = percentile(cents[:], 0.9) - percentile(cents[:], 0.1)
    }
    if len(aligned_errors) > 0 {
        slice.sort(aligned_errors[:])
        run.aligned_cents = percentile(aligned_errors[:], 0.5)
    }
    return
}

// Of the lit detections with a readout in the sustain, folded into the note's octave, or as they are without one
median_cents :: proc(detections: []Detection, sustain: [2]f32, note: Maybe(int)) -> (median: f32, ok: bool) {
    cents: [dynamic]f32
    defer delete(cents)

    for detection in detections {
        if !detection.active || !detection.read || detection.time_s < sustain[0] || detection.time_s > sustain[1] do continue

        if reference, folded := note.?; folded {
            append(&cents, fold_octave(detection.cents, reference))
        } else {
            append(&cents, detection.cents)
        }
    }
    if len(cents) == 0 do return 0, false

    slice.sort(cents[:])
    return percentile(cents[:], 0.5), true
}

fold_octave :: proc(cents: f32, note: int) -> f32 {
    return cents - 1200 * math.round((cents - f32(note)) / 1200)
}

percentile :: proc(sorted: []f32, fraction: f32) -> f32 {
    return sorted[int(math.round(fraction * f32(len(sorted) - 1)))]
}

// The original's sustain through a plain Hann windowed DFT, nothing of the tuner's, the peak near each
// harmonic of the note
measure_spectrum :: proc(samples: []f32, sustain: [2]f32, note: int) -> (spectrum: Spectrum) {
    spectrum.note = note

    segment := samples[int(sustain[0] * SAMPLERATE):min(int(sustain[1] * SAMPLERATE), len(samples))]
    windowed := make([]f64, len(segment))
    defer delete(windowed)
    for sample, index in segment {
        window := 0.5 - 0.5 * math.cos(2 * math.PI * f64(index) / f64(len(segment) - 1))
        windowed[index] = f64(sample) * window
    }

    note_hz := f64(core.cents_to_freq(f32(note)))
    harmonics := HARMONICS
    powers: [len(HARMONICS)]f64
    for harmonic, index in harmonics {
        for offset := -PEAK_SEARCH_CENTS; offset <= PEAK_SEARCH_CENTS; offset += PEAK_STEP_CENTS {
            power := dft_power(windowed, note_hz * f64(harmonic) * math.pow(2, f64(offset) / 1200))
            if power > powers[index] do powers[index], spectrum.offsets_cents[index] = power, f32(offset)
        }
    }

    strongest := slice.max(powers[:])
    for power, index in powers do spectrum.levels_db[index] = f32(10 * math.log10(power / strongest))

    fundamental_index, _ := slice.linear_search(harmonics[:], 1)
    third_index, _ := slice.linear_search(harmonics[:], 3)
    spectrum.named_low = spectrum.levels_db[fundamental_index] < NAMED_LOW_DB && spectrum.levels_db[third_index] < NAMED_LOW_DB
    return
}

// The power at one frequency, the phase turned by a running rotation instead of a sin and cos per sample
dft_power :: proc(samples: []f64, freq_hz: f64) -> f64 {
    angle := 2 * math.PI * freq_hz / SAMPLERATE
    step := complex(math.cos(angle), -math.sin(angle))
    rotation := complex128(1)
    sum: complex128
    for sample in samples {
        sum += complex(sample, 0) * rotation
        rotation *= step
    }
    return real(sum) * real(sum) + imag(sum) * imag(sum)
}

// The RMS in dBFS of each LEVEL_WINDOW_S from the start
levels_db :: proc(samples: []f32) -> []f32 {
    window := int(LEVEL_WINDOW_S * SAMPLERATE)
    levels := make([]f32, len(samples) / window)
    for &level, index in levels {
        sum: f32
        for sample in samples[index * window:(index + 1) * window] do sum += sample * sample
        level = 10 * math.log10(max(sum / f32(window), 1e-12))
    }
    return levels
}

// The end of the last window at or over LIVE_FLOOR_DBFS
last_above_floor :: proc(levels: []f32) -> (time_s: f32) {
    for level, index in levels {
        if level >= LIVE_FLOOR_DBFS do time_s = f32(index + 1) * LEVEL_WINDOW_S
    }
    return
}

lit_s :: proc(detections: []Detection) -> (lit: f32) {
    for detection in detections {
        if detection.active do lit += 1.0 / core.DETECTIONS_PER_SECOND
    }
    return
}

// The recording decoded at decode_rate, the original's at 0, through the app's loop like sandbox/replay
play :: proc(path: string, decode_rate: u32, pitch_standard: f32) -> (detections: [dynamic]Detection) {
    // Every retune makes its window's weights there
    defer free_all(context.temp_allocator)

    samples, ok := decode(path, decode_rate if decode_rate > 0 else SAMPLERATE)
    if !ok {
        fmt.eprintln("Can't decode", path)
        return
    }
    defer delete(samples)

    detector := core.init_pitch_detector(pitch_standard)
    defer core.destroy_pitch_detector(&detector)
    tuner := core.init_tuner(110, pitch_standard, true)

    intervals := INTERVALS
    strobe := core.init_phase_comparator(110, intervals[:], .HARMONIC)
    defer core.destroy_phase_comparator(strobe)
    retune :: proc(strobe: ^core.PhaseComparator, freq_hz, pitch_standard: f32) {
        core.set_phase_comparator_freq(strobe, freq_hz, pitch_standard, STROBE_SPEED, 2, .HARMONIC)
    }
    retune(strobe, tuner.target_note.frequency, pitch_standard)

    readout_track := -1
    readout_ready := false
    for start := 0; start + FRAME_SAMPLES <= len(samples); start += FRAME_SAMPLES {
        frame := samples[start:start + FRAME_SAMPLES]
        core.audio_capture_write(&detector, frame)
        core.audio_capture_write(strobe, frame)
        pitch := core.run_pitch_detection(&detector, tuner.pitch)
        core.run_phase_detection(strobe, pitch.is_tonal)
        readout_track, readout_ready = core.strobe_readout_track(strobe, readout_track)
        if core.update_tuner(&tuner, pitch, core.strobe_shows_note(strobe)) {
            retune(strobe, tuner.target_note.frequency, pitch_standard)
            readout_ready = false
        }
        if !pitch.fresh do continue

        // The strobe's track from the target, none until one settled, see src/app/app.odin
        detection := Detection {
            time_s     = f32(start + FRAME_SAMPLES) / SAMPLERATE,
            active     = tuner.active,
            note_cents = tuner.target_note.cents,
        }
        if readout_ready && abs(strobe.bands[readout_track].err_cents) <= core.READOUT_RANGE_CENTS {
            band := strobe.bands[readout_track]
            detection.read = true
            detection.cents = f32(tuner.target_note.cents) + band.err_cents
            detection.octaves = core.readout_octaves(band, tuner.target_note.frequency)
        }
        // Lit like sandbox/accuracy counts it, an instrument's partials are whole multiples
        fade := core.STROBE_FADE_SNR_DB
        for band, index in strobe.bands[:len(detection.tracks)] {
            lit := band.in_range && band.snr_db >= 0.5 * (fade[0] + fade[1])
            lit &&= band.interval == math.round(band.interval)
            detection.tracks[index] = {lit = lit, freq_hz = band.freq_hz, drift_hz = band.drift_hz, snr_db = band.snr_db}
        }
        append(&detections, detection)
    }

    mark_nulls(detections[:])
    return
}

// Each track's detections up to NULL_HOLD_S after its level fell NULL_DROP_DB within NULL_FALL_S
mark_nulls :: proc(detections: []Detection) {
    for track_index in 0 ..< len(INTERVALS) {
        null_s := f32(-1)
        for &detection, index in detections {
            track := &detection.tracks[track_index]
            for earlier := index - 1; earlier >= 0; earlier -= 1 {
                if detection.time_s - detections[earlier].time_s > NULL_FALL_S do break
                if detections[earlier].tracks[track_index].snr_db - track.snr_db >= NULL_DROP_DB {
                    null_s = detection.time_s
                    break
                }
            }
            track.after_null = null_s >= 0 && detection.time_s - null_s <= NULL_HOLD_S
        }
    }
}

// The whole file as mono decoded at decode_rate, after LEAD_IN_S of silence at the app's sample rate
decode :: proc(path: string, decode_rate: u32) -> (samples: []f32, ok: bool) {
    decoder: ma.decoder
    config := ma.decoder_config_init(.f32, 1, decode_rate)
    // The linear resampler's images land far above the pitch detection's lowpass, its filter keeps them down
    config.resampling.linear.lpfOrder = 8
    cpath := fmt.ctprintf("%s", path)
    if ma.decoder_init_file(cpath, &config, &decoder) != .SUCCESS do return nil, false
    defer ma.decoder_uninit(&decoder)

    length: u64
    ma.decoder_get_length_in_pcm_frames(&decoder, &length)
    lead_in := u64(LEAD_IN_S * SAMPLERATE)
    samples = make([]f32, lead_in + length)
    ma.decoder_read_pcm_frames(&decoder, raw_data(samples[lead_in:]), length, nil)
    return samples, true
}

// An octave up only when the recording explains it, its 2nd harmonic louder than the fundamental
passed :: proc(run: Run) -> bool {
    if run.octave > 0 && !run.second_louder do return false

    return run.wrong_note == 0 && abs(run.aligned_cents) <= TOLERANCE_CENTS && run.wrong_way == {}
}

// "ok", "ok 2x>1x" when it showed the octave up the recording explains, empty when it failed
status_text :: proc(run: Run) -> string {
    if !passed(run) do return ""
    return "ok 2x>1x" if run.octave > 0 else "ok"
}

// The tracks turning the wrong way and in how many detections, e.g. "4×110", "-" for none
wrong_way_text :: proc(run: Run) -> string {
    builder := strings.builder_make(context.temp_allocator)
    intervals := INTERVALS
    for count, index in run.wrong_way {
        if count == 0 do continue
        if strings.builder_len(builder) > 0 do strings.write_byte(&builder, ' ')
        fmt.sbprintf(&builder, "%vx%v", intervals[index], count)
    }
    return strings.to_string(builder) if strings.builder_len(builder) > 0 else "-"
}

print_report :: proc(runs: []Run) {
    sorted := slice.clone(runs, context.temp_allocator)
    // The worst first
    slice.sort_by(sorted, proc(first, second: Run) -> bool {
        if first.wrong_note != second.wrong_note do return first.wrong_note > second.wrong_note
        return abs(first.aligned_cents) > abs(second.aligned_cents)
    })

    fmt.print(`
Each recording plays as it is ("original"), then sped up or slowed down so its pitch moves by a known
number of cents, and once more as an instrument tuned to A=442 with the tuner set to 442. The readout
should move by exactly the shift, however the player tuned. Worst runs first, c is cents.

  shift c      how far the pitch was moved, from the decode rate, so not exactly a round number
  A            the pitch standard the tuner was set to
  error c      readout's move minus the shift, the medians over the sustain
  aligned      the same, each detection against the original's at the same moment of the performance,
               the note's drift cancels, within 1c passes
  unread       detections in the sustain lit without a readout, before a track settled or one more than
               half a semitone off, report only
  shown/named  the note the tuner showed most, then the filename's note if they differ
  wrong note   detections in the sustain on another note or dark, out of all of them in the sustain,
               an octave down or two up count here too
  octave up    detections on the right note one octave up, the readout is the same there
  partial      detections on the right note named after the partial the readout measures, e.g. B3
               for a B2 once its fundamental died down under the 2nd harmonic, right
  1x dB        the original's fundamental from its strongest harmonic, measured without the tuner
  wrong way    strobe tracks whose stripes turned the wrong way and in how many detections, 4x8 is the
               4th harmonic's track 8 times, while the original is within 15dB of its loudest, both
               read the same partial and neither track just fell 20dB through a null
  spread c     readout from the 10th to the 90th percentile over the sustain, the player's vibrato too
  lit s        seconds the note was lit
  ok           passed: no wrong note, aligned within 1c, no track turning the wrong way
  ok 2x>1x     passed showing the octave up, the original's 2nd harmonic is louder than its
               fundamental so the tuner follows it, e.g. a bass with a weak fundamental. An octave
               up on a recording whose fundamental is the louder fails.

  +-49c lands half way between two notes, which note shows is a coin toss there.
`)

    // Plain ASCII, the padding counts bytes and a ¢ is two
    rule := "+-----------------+----------+-----+---------+---------+------------+-------------+------------+------------+------------+-------+------------+---------+-------+----------+"
    fmt.println()
    fmt.println(rule)
    fmt.println("| file            | shift c  | A   | error c | aligned | unread     | shown/named | wrong note | octave up  | partial    | 1x dB | wrong way  | spread c| lit s |          |")
    fmt.println(rule)
    for run in sorted {
        note := note_name(run.shown_note)
        if run.shown_note != run.expected_note do note = fmt.tprintf("%v/%v", note, note_name(run.expected_note))
        fmt.printfln(
            // Odin pads a width on a float with zeros, they go in as text
            "| %-15v | %8v | %3v | %7v | %7v | %10v | %-11v | %10v | %10v | %10v | %5v | %-10v | %7v | %5v | %-8v |",
            os.stem(run.file),
            "original" if run.shift_cents == 0 else fmt.tprintf("%+.2f", run.shift_cents),
            fmt.tprintf("%.0f", run.pitch_standard),
            fmt.tprintf("%+.2f", run.error_cents),
            "-" if run.shift_cents == 0 else fmt.tprintf("%+.2f", run.aligned_cents),
            fmt.tprintf("%v/%v", run.unread, run.measured),
            note,
            fmt.tprintf("%v/%v", run.wrong_note, run.measured),
            fmt.tprintf("%v/%v", run.octave, run.measured),
            fmt.tprintf("%v/%v", run.partial, run.measured),
            fmt.tprintf("%.0f", run.fundamental_db),
            wrong_way_text(run),
            fmt.tprintf("%.1f", run.spread_cents),
            fmt.tprintf("%.1f", run.lit_s),
            status_text(run),
        )
    }
    fmt.println(rule)

    failed := 0
    for run in runs {
        if !passed(run) do failed += 1
    }
    fmt.printfln("\n%v of %v runs off by more than %v¢, on another note or turning the wrong way", failed, len(runs), TOLERANCE_CENTS)
}

// Each original's harmonics of the named note, the level from the strongest and the peak's cents from it
print_spectra :: proc(spectra: []Spectrum) {
    harmonics := HARMONICS
    rule := strings.builder_make(context.temp_allocator)
    header := strings.builder_make(context.temp_allocator)
    strings.write_string(&rule, "+-----------------+------")
    strings.write_string(&header, "| file            | note ")
    for harmonic in harmonics {
        strings.write_string(&rule, "+-----------")
        fmt.sbprintf(&header, "| %-9v ", fmt.tprintf("%vx dB c", harmonic))
    }
    strings.write_byte(&rule, '+')
    strings.write_byte(&header, '|')

    fmt.println("\nThe originals' spectra without the tuner, each harmonic's peak in dB from the strongest, cents off it")
    fmt.println(strings.to_string(rule))
    fmt.println(strings.to_string(header))
    fmt.println(strings.to_string(rule))
    for spectrum in spectra {
        fmt.printf("| %-15v | %-4v ", os.stem(spectrum.file), note_name(spectrum.note))
        for level, index in spectrum.levels_db {
            fmt.printf("| %9v ", fmt.tprintf("%.0f %+.0f", level, spectrum.offsets_cents[index]))
        }
        fmt.println("|")
    }
    fmt.println(strings.to_string(rule))
}

print_csv :: proc(runs: []Run) {
    fmt.println("file,shift_cents,pitch_standard,error_cents,aligned_cents,unread,expected_note,shown_note,wrong_note,octave,partial,measured,fundamental_db,wrong_way,spread_cents,lit_s")
    for run in runs {
        fmt.printfln(
            "%v,%.3f,%.0f,%.3f,%.3f,%v,%v,%v,%v,%v,%v,%v,%.1f,%v,%.2f,%.2f",
            run.file,
            run.shift_cents,
            run.pitch_standard,
            run.error_cents,
            run.aligned_cents,
            run.unread,
            note_name(run.expected_note),
            note_name(run.shown_note),
            run.wrong_note,
            run.octave,
            run.partial,
            run.measured,
            run.fundamental_db,
            wrong_way_text(run),
            run.spread_cents,
            run.lit_s,
        )
    }
}

note_name :: proc(cents: int) -> string {
    return core.note_name(core.cents_to_note(f32(cents)))
}
