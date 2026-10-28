// How a strobe track's phase holds up by how far it is under the note's loudest track, over every sample: where
// the tracks stop measuring a partial and draw noise. A clean recording's noise floor learns digital silence,
// so there a track's SNR can't tell, its level against the note's own partials can.
//
//   odin run sandbox/partial_levels -o:speed                 every file in sandbox/samples
//   odin run sandbox/partial_levels -o:speed -- <folder>
//
// Per instrument, the files' names up to the first _, and over all of them, in steps of dB under the loudest
// track: how many track frames, how far each frame's phase strays from the track's rate in radians of its own
// partial, the gearing of the strobe left out, how much its advance shakes from the previous frame's, their
// mean SNR, and how many of them the strobe lights. A track in the noise stops fitting its rate, the stray then
// has the stale rate in it too: when the fit also stopped 35 dB under the loudest track, an exact tone's 4× kept
// the +12.7¢ of its attack, a third of a radian a frame. The shake has no rate in it, a steady one of any kind
// cancels.
//
// And how much noise alone would shake it, from the track's level over the noise between the partials: under
// complex Gaussian noise a sine's phase varies by 1 / (2 SNR) radians squared, the SNR a power ratio, and a
// frame's change of advance by 6 - 8 r1 + 2 r2 times that, r1 and r2 how much of the noise the windows a frame
// and two frames apart share. Where the two columns agree the shake is the noise, where the measured one is
// larger the partial itself moves.

package partial_levels

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import ma "vendor:miniaudio"

import "../../src/core"

// The app's, see sandbox/replay, with every partial up to the 5th for more of them to compare
INTERVALS :: [?]f32{1, 2, 3, 4, 5}
STROBE_SPEED :: 0.025
FPS :: 60
LEAD_IN_S :: 2

// Under this a room's noise would bury the recording, see sandbox/recordings
LIVE_FLOOR_DBFS :: -60

// A pluck swings the tracks for a while, measured from this long after their onset
SETTLE_S :: 0.3

STEP_DB :: 5
STEPS :: 16 // down to 80 dB under the loudest track, further down in the last

Step :: struct {
    frames:            int,
    stray_squares:     f64,
    snr_sum:           f64,
    lit:               int,
    // the change of advance from the previous frame, over the frames that have one
    shake_squares:     f64,
    shake_frames:      int,
    // the shake noise alone would cause, over the frames with the noise between the partials measured
    predicted_squares: f64,
    predicted_frames:  int,
}

Table :: [STEPS]Step

// By how far under the loudest track, and with the noise between the partials measured also by the SNR over
// it, in the same steps: there the shake noise alone would cause is checked against the measured one, apart
// from how loud the other partials are
Tables :: struct {
    by_level: Table,
    by_snr:   Table,
}

main :: proc() {
    folder := os.args[1] if len(os.args) > 1 else "sandbox/samples"
    files, err := os.read_all_directory_by_path(folder, context.allocator)
    if err != nil {
        fmt.eprintln("Can't read", folder, err)
        os.exit(1)
    }
    defer os.file_info_slice_delete(files, context.allocator)
    slice.sort_by(files, proc(first, second: os.File_Info) -> bool { return first.name < second.name })

    tables: map[string]Tables
    defer delete(tables)

    instruments: [dynamic]string
    defer delete(instruments)

    all: Tables
    for file in files {
        extension := strings.to_lower(os.ext(file.name), context.temp_allocator)
        if extension != ".wav" && extension != ".mp3" && extension != ".flac" do continue

        instrument := file.name[:strings.index_byte(file.name, '_')] if strings.contains(file.name, "_") else os.stem(file.name)
        if instrument not_in tables do append(&instruments, instrument)

        instrument_tables := tables[instrument]
        run_file(file.fullpath, &instrument_tables, &all)
        tables[instrument] = instrument_tables
        free_all(context.temp_allocator)
    }

    for instrument in instruments do print_table(instrument, tables[instrument].by_level)
    print_table("all", all.by_level)

    for instrument in instruments do print_noise_check(instrument, tables[instrument].by_snr)
    print_noise_check("all", all.by_snr)
}

// The file through the tuner like sandbox/replay, every settled track's frames into its step of both tables
run_file :: proc(path: string, tables, all: ^Tables) {
    samples, sample_rate, ok := decode(path, LEAD_IN_S)
    if !ok {
        fmt.eprintln("Can't decode", path)
        return
    }
    defer delete(samples)

    detector := core.init_pitch_detector(440, sample_rate)
    defer core.destroy_pitch_detector(&detector)
    note_target := core.init_note_target(110, 440, true)

    intervals := INTERVALS
    strobe := core.init_strobe_lock_in(110, intervals[:], .HARMONIC, sample_rate)
    defer core.destroy_strobe_lock_in(strobe)
    retune :: proc(strobe: ^core.StrobeLockIn, freq_hz: f32) {
        core.set_strobe_lock_in_freq(strobe, freq_hz, 440, STROBE_SPEED, 2, .HARMONIC)
    }
    retune(strobe, note_target.target_note.frequency)

    live_floor := math.pow(10, f32(LIVE_FLOOR_DBFS) / 20)
    fade := core.STROBE_FADE_SNR_DB
    lit_snr_db := 0.5 * (fade[0] + fade[1])

    onset_times: [core.MAX_BANDS]f32
    frame_samples := int(sample_rate) / FPS
    shared := window_overlap(strobe, frame_samples)
    shared_two := window_overlap(strobe, 2 * frame_samples)

    // Each track's advance the frame before, for the shake
    previous_advances: [core.MAX_BANDS]f64
    has_previous := false

    for start := 0; start + frame_samples <= len(samples); start += frame_samples {
        frame := samples[start:start + frame_samples]
        core.audio_capture_write(&detector, frame)
        core.audio_capture_write(strobe, frame)
        pitch := core.run_pitch_detection(&detector, note_target.pitch)

        // The rate each track was at, what this frame's advance strays from
        rates: [core.MAX_BANDS]f64
        for band, index in strobe.bands do rates[index] = band.rate
        core.run_phase_detection(strobe, pitch.is_tonal)

        // Each track's advance this frame in radians of its partial, the strobe's gearing taken back out
        advances: [core.MAX_BANDS]f64
        for band, index in strobe.bands do advances[index] = f64(band.phase_diff) / core.strobe_rescale(band.freq_hz)
        previous, had_previous := previous_advances, has_previous
        previous_advances, has_previous = advances, true

        time_s := f32(start + frame_samples) / sample_rate
        for band, index in strobe.bands {
            if band.onset do onset_times[index] = time_s
        }
        if core.update_note_target(&note_target, pitch, core.strobe_shows_note(strobe)) {
            retune(strobe, note_target.target_note.frequency)
            shared = window_overlap(strobe, frame_samples)
            shared_two = window_overlap(strobe, 2 * frame_samples)
            has_previous = false
            onset_times = time_s
            continue
        }
        if !note_target.active do continue

        squares: f32
        for sample in frame do squares += sample * sample
        if math.sqrt(squares / f32(len(frame))) < live_floor do continue

        loudest: f32
        for band in strobe.bands {
            if band.in_range do loudest = max(loudest, band.amp)
        }
        if loudest == 0 do continue

        for band, index in strobe.bands {
            if !band.in_range || band.amp <= 0 || time_s - onset_times[index] < SETTLE_S do continue

            under_db := 20 * math.log10(loudest / band.amp)
            level_step := min(int(under_db / STEP_DB), STEPS - 1)

            stray := core.wrap_phase(advances[index] - rates[index] * f64(strobe.available))
            shake := core.wrap_phase(advances[index] - previous[index])

            for counted in ([]^Step{&tables.by_level[level_step], &all.by_level[level_step]}) {
                counted.frames += 1
                counted.stray_squares += stray * stray
                counted.snr_sum += f64(band.snr_db)
                if band.envelope_snr_db >= lit_snr_db do counted.lit += 1
                if had_previous {
                    counted.shake_squares += shake * shake
                    counted.shake_frames += 1
                }
            }
            if !had_previous || band.noise_between == 0 do continue

            // What noise alone would shake it by, the track's level over the noise between the partials as a
            // power ratio
            snr := f64(band.amp / band.noise_between)
            predicted := (6 - 8 * shared + 2 * shared_two) / (2 * snr * snr)
            snr_step := clamp(int(20 * math.log10(snr) / STEP_DB), 0, STEPS - 1)

            for counted in ([]^Step{&tables.by_level[level_step], &all.by_level[level_step]}) {
                counted.predicted_squares += predicted
                counted.predicted_frames += 1
            }
            for counted in ([]^Step{&tables.by_snr[snr_step], &all.by_snr[snr_step]}) {
                counted.shake_squares += shake * shake
                counted.shake_frames += 1
                counted.predicted_squares += predicted
                counted.predicted_frames += 1
            }
        }
    }
}

// The shake noise alone would cause against the measured one, by the SNR over the noise between the partials
print_noise_check :: proc(name: string, table: Table) {
    fmt.printfln("\n%v, by the SNR between the partials", name)
    fmt.println("  SNR             frames   shake rad   noise rad")
    for step, index in table {
        if step.shake_frames == 0 do continue

        range := fmt.tprintf("%v-%v dB", index * STEP_DB, (index + 1) * STEP_DB) if index < STEPS - 1 else fmt.tprintf("%v+ dB", index * STEP_DB)
        if index == 0 do range = fmt.tprintf("under %v dB", STEP_DB)
        fmt.printfln(
            "  %-15v %-8v %-11v %.3f",
            range,
            step.shake_frames,
            fmt.tprintf("%.3f", math.sqrt(step.shake_squares / f64(step.shake_frames))),
            math.sqrt(step.predicted_squares / f64(step.predicted_frames)),
        )
    }
}

print_table :: proc(name: string, table: Table) {
    fmt.printfln("\n%v", name)
    fmt.println("  under loudest   frames   stray rad   shake rad   noise rad   mean SNR   lit")
    for step, index in table {
        if step.frames == 0 do continue

        range := fmt.tprintf("%v-%v dB", index * STEP_DB, (index + 1) * STEP_DB) if index < STEPS - 1 else fmt.tprintf("%v+ dB", index * STEP_DB)
        stray := math.sqrt(step.stray_squares / f64(step.frames))
        shake := math.sqrt(step.shake_squares / f64(max(step.shake_frames, 1)))
        predicted := "-"
        if step.predicted_frames > 0 {
            predicted = fmt.tprintf("%.3f", math.sqrt(step.predicted_squares / f64(step.predicted_frames)))
        }
        fmt.printfln(
            "  %-15v %-8v %-11v %-11v %-11v %-10v %v%%",
            range,
            step.frames,
            fmt.tprintf("%.3f", stray),
            fmt.tprintf("%.3f", shake),
            predicted,
            fmt.tprintf("%.1f dB", step.snr_sum / f64(step.frames)),
            100 * step.lit / step.frames,
        )
    }
}

// How much of the noise two of the tracks' windows lag apart share, the window's autocorrelation at that lag
// over its power: the noise one frame's phase has in common with the next doesn't move the stripes. The
// weights are the twiddles' magnitudes.
window_overlap :: proc(strobe: ^core.StrobeLockIn, lag: int) -> f64 {
    dft := strobe.bands[0].dft
    weight :: proc(dft: core.SingleFreqDFT, index: int) -> f64 {
        return math.sqrt(f64(dft.twiddles_real[index] * dft.twiddles_real[index] + dft.twiddles_imag[index] * dft.twiddles_imag[index]))
    }

    shared, power: f64
    for index in 0 ..< dft.window_size {
        power += weight(dft, index) * weight(dft, index)
        if index + lag < dft.window_size do shared += weight(dft, index) * weight(dft, index + lag)
    }
    return shared / power
}

// The whole file as mono at its own rate, after lead_in_s of silence, like sandbox/replay's
decode :: proc(path: string, lead_in_s: int) -> (samples: []f32, sample_rate: f32, ok: bool) {
    decoder: ma.decoder
    config := ma.decoder_config_init(.f32, 1, 0)
    cpath := fmt.ctprintf("%s", path)
    if ma.decoder_init_file(cpath, &config, &decoder) != .SUCCESS do return nil, 0, false
    defer ma.decoder_uninit(&decoder)

    length: u64
    ma.decoder_get_length_in_pcm_frames(&decoder, &length)
    file_rate := f32(decoder.outputSampleRate)
    lead_in := u64(lead_in_s) * u64(decoder.outputSampleRate)
    samples = make([]f32, lead_in + length)
    ma.decoder_read_pcm_frames(&decoder, raw_data(samples[lead_in:]), length, nil)

    decimator: core.Decimator
    decimator, sample_rate = core.init_decimator(file_rate)
    samples = samples[:core.decimate(&decimator, samples)]
    return samples, sample_rate, true
}
