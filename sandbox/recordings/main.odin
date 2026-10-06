// Plays real recordings through the tuner like sandbox/replay, each one again shifted by a known number of
// cents, and checks the readout moves by exactly that much. How the player tuned doesn't matter, both runs
// hear the same performance, its vibrato and drift cancel out.
//
//   odin run sandbox/recordings -o:speed -- [folder] [csv]
//
// Every wav, mp3 and flac in the folder, sandbox/media by default, one note per file named at the end of
// the filename, e.g. bass_E1.wav. csv prints the runs as CSV instead, to diff two commits.
//
// The shift decodes at SAMPLERATE × 2^(−cents/1200) and plays at SAMPLERATE, the pitch rises by the cents
// and the length shrinks by the same ratio. Report only, nothing fails the run.

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

// ±100 lands on the next note
SHIFTS_CENTS :: [?]f32{0.5, -0.5, 3, -3, 7, -7, 23, -23, 49, -49, 100, -100}

// One more, an instrument tuned to A=442 and the tuner set to it, the readout should stay put
SHIFTED_STANDARD :: f32(442)

// The sustain, from this long after the note lights until it goes dark, without the window's last part
SUSTAIN_FROM_S :: 0.5
SUSTAIN_TRIM :: 0.1

// A lit track drifting the other way than it should this fast, its stripes turn the wrong way. Each track
// is checked against its own drift at the same moment of the original plus the shift, a real string's
// partials run sharp of its fundamental and wander, they don't agree with the readout or each other.
WRONG_WAY_MIN_HZ :: 1
// -define:SHOW_WRONG_WAY=true prints every detection with a track turning the wrong way
SHOW_WRONG_WAY :: #config(SHOW_WRONG_WAY, false)

Track :: struct {
    lit:      bool,
    freq_hz:  f32,
    drift_hz: f32,
    snr_db:   f32,
}

// A fresh detection, the pitch in cents from A4 as the readout shows it
Detection :: struct {
    time_s:     f32,
    active:     bool,
    note_cents: int, // the target note's
    cents:      f32, // the note's plus the readout
    tracks:     [len(INTERVALS)]Track,
}

Run :: struct {
    file:           string,
    shift_cents:    f32, // the decode rate's, rounded to a whole Hz
    pitch_standard: f32,
    expected_cents: f32, // how far the pitch should move from the original's
    error_cents:    f32,
    expected_note:  int,
    shown_note:     int, // the most common in the sustain
    wrong_note:     int, // detections in the sustain on another note, or none
    wrong_way:      [len(INTERVALS)]int, // detections per track
    // of the readout over the sustain, from the 10th to the 90th percentile. An octave off counts as the
    // note, the readout is the same cents in any octave.
    spread_cents:   f32,
    lit_s:          f32,
    measured:       int, // detections in the sustain
}

main :: proc() {
    folder := "sandbox/media"
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

    runs: [dynamic]Run
    defer delete(runs)

    for file in files {
        extension := strings.to_lower(os.ext(file.name), context.temp_allocator)
        if extension != ".wav" && extension != ".mp3" && extension != ".flac" do continue

        if !csv do fmt.eprintln("Playing", file.name)
        run_file(&runs, file.fullpath, file.name)
    }

    if csv {
        print_csv(runs[:])
    } else {
        print_report(runs[:])
    }
}

// The original, then every shift against it
run_file :: proc(runs: ^[dynamic]Run, path, name: string) {
    original := play(path, 0, 440)
    defer delete(original)

    first_lit, last_lit: f32 = -1, -1
    for detection in original {
        if !detection.active do continue
        if first_lit < 0 do first_lit = detection.time_s
        last_lit = detection.time_s
    }
    sustain := [2]f32{first_lit + SUSTAIN_FROM_S, last_lit}
    sustain[1] -= SUSTAIN_TRIM * (sustain[1] - sustain[0])
    if first_lit < 0 || sustain[1] <= sustain[0] {
        fmt.eprintln("  no sustain, the note is lit for under", SUSTAIN_FROM_S, "seconds")
        return
    }

    // The note in the filename, after the last underscore, or the one the original shows
    stem := os.stem(name)
    filename_note, named := core.parse_note(stem[strings.last_index_byte(stem, '_') + 1:])
    expected_note := filename_note.cents
    if !named {
        unfolded, _ := median_cents(original[:], sustain, nil)
        expected_note = 100 * int(math.round(unfolded / 100))
    }
    original_cents, _ := median_cents(original[:], sustain, expected_note)

    original_run := measure(original[:], sustain, expected_note, nil)
    original_run.file = name
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

        run := measure(shifted[:], scaled, note, Reference{original[:], expected_note, ratio, expected_cents})
        shifted_cents, _ := median_cents(shifted[:], scaled, note)
        run.file = name
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
}

// The tracks turning the wrong way only with the original to compare with
measure :: proc(detections: []Detection, sustain: [2]f32, expected_note: int, reference: Maybe(Reference)) -> (run: Run) {
    run.expected_note = expected_note

    cents: [dynamic]f32
    defer delete(cents)
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

        note_counts[detection.note_cents] += 1
        append(&cents, fold_octave(detection.cents, expected_note))
        // On another note the tracks are other partials
        if detection.note_cents != expected_note {
            run.wrong_note += 1
            continue
        }

        original, aligned := reference.?
        if !aligned do continue

        original_s := LEAD_IN_S + (detection.time_s - LEAD_IN_S) / original.ratio
        for cursor + 1 < len(original.detections) && original.detections[cursor + 1].time_s <= original_s {
            cursor += 1
        }
        then := original.detections[cursor]
        if !then.active || then.note_cents != original.note do continue

        for track, index in detection.tracks {
            partial := then.tracks[index]
            if !track.lit || !partial.lit do continue

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
    return
}

// Of the lit detections in the sustain, folded into the note's octave, or as they are without one
median_cents :: proc(detections: []Detection, sustain: [2]f32, note: Maybe(int)) -> (median: f32, ok: bool) {
    cents: [dynamic]f32
    defer delete(cents)

    for detection in detections {
        if !detection.active || detection.time_s < sustain[0] || detection.time_s > sustain[1] do continue

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
    retune(strobe, 110, pitch_standard)

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
        }
        off_target := strobe.base_freq_hz != tuner.target_note.frequency
        if off_target && !core.strobe_shows_note(strobe, fundamental_only = true) {
            retune(strobe, tuner.target_note.frequency, pitch_standard)
        }
        if !pitch.fresh do continue

        steady := core.tuner_readout(&tuner)
        readout := steady.err_cents
        if readout_ready && abs(steady.err_cents) <= core.READOUT_RANGE_CENTS {
            readout = strobe.bands[readout_track].err_cents
        }

        detection := Detection {
            time_s     = f32(start + FRAME_SAMPLES) / SAMPLERATE,
            active     = tuner.active,
            note_cents = tuner.target_note.cents,
            cents      = f32(tuner.target_note.cents) + readout,
        }
        // Lit like sandbox/accuracy counts it, an instrument's partials are whole multiples
        fade := core.STROBE_FADE_SNR_DB
        for band, index in strobe.bands[:len(detection.tracks)] {
            lit := band.in_range && band.snr_db >= 0.5 * (fade[0] + fade[1])
            lit &&= band.interval == math.round(band.interval)
            detection.tracks[index] = {lit, band.freq_hz, band.drift_hz, band.snr_db}
        }
        append(&detections, detection)
    }
    return
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

passed :: proc(run: Run) -> bool {
    return run.wrong_note == 0 && abs(run.error_cents) <= TOLERANCE_CENTS && run.wrong_way == {}
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
        return abs(first.error_cents) > abs(second.error_cents)
    })

    // Plain ASCII, the padding counts bytes and a ¢ is two
    rule := "+-----------------+----------+-----+---------+-------------+------------+------------+---------+-------+----+"
    fmt.println()
    fmt.println(rule)
    fmt.println("| file            | shift c  | A   | error c | shown/named | wrong note | wrong way  | spread c| lit s |    |")
    fmt.println(rule)
    for run in sorted {
        note := note_name(run.shown_note)
        if run.shown_note != run.expected_note do note = fmt.tprintf("%v/%v", note, note_name(run.expected_note))
        fmt.printfln(
            // Odin pads a width on a float with zeros, they go in as text
            "| %-15v | %8v | %3v | %7v | %-11v | %10v | %-10v | %7v | %5v | %-2v |",
            os.stem(run.file),
            "original" if run.shift_cents == 0 else fmt.tprintf("%+.2f", run.shift_cents),
            fmt.tprintf("%.0f", run.pitch_standard),
            fmt.tprintf("%+.2f", run.error_cents),
            note,
            fmt.tprintf("%v/%v", run.wrong_note, run.measured),
            wrong_way_text(run),
            fmt.tprintf("%.1f", run.spread_cents),
            fmt.tprintf("%.1f", run.lit_s),
            "ok" if passed(run) else "",
        )
    }
    fmt.println(rule)

    failed := 0
    for run in runs {
        if !passed(run) do failed += 1
    }
    fmt.printfln("\n%v of %v runs off by more than %v¢, on another note or turning the wrong way", failed, len(runs), TOLERANCE_CENTS)
}

print_csv :: proc(runs: []Run) {
    fmt.println("file,shift_cents,pitch_standard,error_cents,expected_note,shown_note,wrong_note,measured,wrong_way,spread_cents,lit_s")
    for run in runs {
        fmt.printfln(
            "%v,%.3f,%.0f,%.3f,%v,%v,%v,%v,%v,%.2f,%.2f",
            run.file,
            run.shift_cents,
            run.pitch_standard,
            run.error_cents,
            note_name(run.expected_note),
            note_name(run.shown_note),
            run.wrong_note,
            run.measured,
            wrong_way_text(run),
            run.spread_cents,
            run.lit_s,
        )
    }
}

note_name :: proc(cents: int) -> string {
    return core.note_name(core.cents_to_note(f32(cents)))
}
