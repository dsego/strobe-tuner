// Steps a steady tone's pitch by a few cents and measures how long the strobe's stripes take to move at the
// new speed, and the readout's cents beside them. The fundamental's track, drawn like the app's on the
// desktop.
//
//   odin run sandbox/step_response -o:speed
//   odin run sandbox/step_response -o:speed -- -9     the note in semitones from A4, C2 (-33) by default
//
// From the newest sample the tuner heard, the screen and the audio input add their own latency on top.

package step_response

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"

import "../../src/core"

// The app's, see sandbox/replay
SAMPLERATE :: core.DEFAULT_SAMPLE_RATE
INTERVALS :: [?]f32{1, 2, 4}
STROBE_SPEED :: 0.025
FRAME_SAMPLES :: SAMPLERATE / 60
DESKTOP_PERIODS :: 12 // the strobe's stripes across the desktop's tracks

DEFAULT_NOTE :: -33 // C2

// A mic level, -20 dBFS RMS, after LEAD_IN_S of silence for the noise floors to learn
TONE_RMS :: 0.1
LEAD_IN_S :: 2

// The tone holds each pitch this long, in tune first, then steps by these cents without a jump in its phase
SEGMENT_S :: 2
SEGMENTS_CENTS :: [?]f32{0, 10, 0, -10, 0}

// The speeds and cents before and after a step, averaged over the end of each segment
SETTLED_S :: 0.5

// The first step's curve, printed this far after it at these times
CURVE_S :: 1.0
CURVE_STEP_S :: 0.05

// What the strobe showed each frame
Run :: struct {
    times_s:       [dynamic]f32, // the frame's newest sample, from the tone's start
    stripes_per_s: [dynamic]f32, // how fast the fundamental's track moved this frame
    readout_cents: [dynamic]f32, // NaN without a readout
}

main :: proc() {
    note_semitones := DEFAULT_NOTE
    if len(os.args) > 1 do note_semitones = strconv.parse_int(os.args[1]) or_else DEFAULT_NOTE

    note := core.cents_to_note(f32(100 * note_semitones), 440)
    samples := generate(note.frequency)
    defer delete(samples)

    run := run_tuner(samples)
    defer destroy_run(&run)

    fmt.printfln(
        "%v at %.2f Hz, a saw stepping by %v cents every %v s",
        core.note_name(note),
        note.frequency,
        SEGMENTS_CENTS,
        SEGMENT_S,
    )
    print_delays(run)
    print_curve(run)
}

// LEAD_IN_S of silence, then a band-limited saw at TONE_RMS holding each of SEGMENTS_CENTS for SEGMENT_S
generate :: proc(freq_hz: f32) -> []f32 {
    segments := SEGMENTS_CENTS
    lead_in := int(LEAD_IN_S * SAMPLERATE)
    segment_samples := int(SEGMENT_S * SAMPLERATE)
    samples := make([]f32, lead_in + len(segments) * segment_samples)

    // The partials under the Nyquist frequency, their power adds up, half of each one's amplitude squared
    harmonics := 0
    power: f64
    for f32(harmonics + 1) * freq_hz < 0.45 * SAMPLERATE {
        harmonics += 1
        power += 0.5 / f64(harmonics * harmonics)
    }
    gain := TONE_RMS / math.sqrt(power)

    // Added up sample by sample, a new pitch goes on from the phase the old one left
    phase: f64
    for cents, segment in segments {
        step := math.TAU * f64(core.freq_at_cents(freq_hz, cents)) / SAMPLERATE
        start := lead_in + segment * segment_samples
        for &sample in samples[start:start + segment_samples] {
            for harmonic in 1 ..= harmonics {
                sample += f32(gain * math.sin(phase * f64(harmonic)) / f64(harmonic))
            }
            phase += step
        }
    }
    return samples
}

// The samples through the tuner like sandbox/accuracy, the app's loop, and the fundamental's track drawn like
// track_phase in src/app/strobe_display.odin
run_tuner :: proc(samples: []f32) -> (run: Run) {
    detector := core.init_pitch_detector(440)
    defer core.destroy_pitch_detector(&detector)
    note_target := core.init_note_target(110, 440, true)

    intervals := INTERVALS
    strobe := core.init_strobe_lock_in(110, intervals[:], .HARMONIC)
    defer core.destroy_strobe_lock_in(strobe)
    retune :: proc(strobe: ^core.StrobeLockIn, freq_hz: f32) {
        core.set_strobe_lock_in_freq(strobe, freq_hz, 440, STROBE_SPEED, 2, .HARMONIC)
    }
    retune(strobe, note_target.target_note.frequency)

    drawn_phase: f32
    frame_time := f32(FRAME_SAMPLES) / SAMPLERATE
    wrap := f32(core.STROBE_PHASE_WRAP)

    readout_track := -1
    readout_ready := false
    for start := 0; start + FRAME_SAMPLES <= len(samples); start += FRAME_SAMPLES {
        frame := samples[start:start + FRAME_SAMPLES]
        core.audio_capture_write(&detector, frame)
        core.audio_capture_write(strobe, frame)
        pitch := core.run_pitch_detection(&detector, note_target.pitch)
        core.run_phase_detection(strobe, pitch.is_tonal)
        readout_track, readout_ready = core.strobe_readout_track(strobe, readout_track)
        if core.update_note_target(&note_target, pitch, core.strobe_shows_note(strobe)) {
            retune(strobe, note_target.target_note.frequency)
            readout_ready = false
        }

        append(&run.times_s, f32(start + FRAME_SAMPLES - LEAD_IN_S * SAMPLERATE) / SAMPLERATE)
        append(&run.readout_cents, strobe.bands[readout_track].err_cents if readout_ready else math.nan_f32())

        // As of the newest sample, without the app's guess ahead to the screen's frame, see
        // core.strobe_phase_ahead
        phase := strobe.bands[0].scaled_phase
        drawn_phase += wrap * math.round((phase - drawn_phase) / wrap)
        append(&run.stripes_per_s, (phase - drawn_phase) * DESKTOP_PERIODS / math.TAU / frame_time)
        drawn_phase = phase
    }
    return
}

destroy_run :: proc(run: ^Run) {
    delete(run.times_s)
    delete(run.stripes_per_s)
    delete(run.readout_cents)
}

// How long after each step the stripes' speed and the readout get halfway and 90% of the way to the new pitch's
print_delays :: proc(run: Run) {
    fmt.println("\nafter a step, the time to 50% and 90% of the way, the mean of the steps (fastest to slowest)")
    print_delay_row("stripes", run.times_s[:], run.stripes_per_s[:])
    print_delay_row("readout cents", run.times_s[:], run.readout_cents[:])

    print_delay_row :: proc(label: string, times, values: []f32) {
        fmt.printf("  %-16v", label)
        for fraction in ([?]f32{0.5, 0.9}) {
            sum, fastest, slowest: f32 = 0, math.INF_F32, 0
            count := 0
            for segment in 1 ..< len(SEGMENTS_CENTS) {
                delay_s := crossing_s(times, values, segment, fraction)
                if delay_s < 0 do continue

                sum += delay_s
                fastest, slowest = min(fastest, delay_s), max(slowest, delay_s)
                count += 1
            }
            if count == 0 {
                fmt.printf("  %.0f%%: never                ", 100 * fraction)
                continue
            }
            fmt.printf("  %.0f%%: %.2f s (%.2f to %.2f)", 100 * fraction, sum / f32(count), fastest, slowest)
        }
        fmt.println()
    }
}

// How far from the old pitch's speed or cents to the new one's, every CURVE_STEP_S after the first step
print_curve :: proc(run: Run) {
    fmt.println("\nthe first step, 0 the old pitch's and 1 the new one's")
    fmt.printfln("  %-8v%-9v%v", "time", "stripes", "readout")

    times := run.times_s[:]
    step_s := f32(SEGMENT_S)
    for after_s: f32 = 0; after_s <= CURVE_S + 0.001; after_s += CURVE_STEP_S {
        // The frame nearest that time
        index := 0
        for time_s, frame_index in times {
            if abs(time_s - step_s - after_s) < abs(times[index] - step_s - after_s) do index = frame_index
        }

        fmt.printf("  %-8v", fmt.tprintf("%.2f", after_s))
        fmt.printf("%-9v", fmt.tprintf("%.2f", progress(times, run.stripes_per_s[:], 1, index)))
        fmt.printfln("%.2f", progress(times, run.readout_cents[:], 1, index))
    }
}

// How long after the step into segment the values get fraction of the way from the old pitch's to the new
// one's, -1 if they don't within it
crossing_s :: proc(times, values: []f32, segment: int, fraction: f32) -> f32 {
    step_s := f32(segment * SEGMENT_S)
    for time_s, index in times {
        if time_s <= step_s || math.is_nan(values[index]) do continue
        if time_s > step_s + SEGMENT_S do break

        if progress(times, values, segment, index) >= fraction do return time_s - step_s
    }
    return -1
}

// How far the value at index is from the old pitch's to the new one's, each averaged over the last SETTLED_S
// of its segment
progress :: proc(times, values: []f32, segment: int, index: int) -> f32 {
    step_s := f32(segment * SEGMENT_S)
    old := settled(times, values, step_s)
    new := settled(times, values, step_s + SEGMENT_S)
    return (values[index] - old) / (new - old)
}

// The mean of the values over the SETTLED_S up to end_s
settled :: proc(times, values: []f32, end_s: f32) -> f32 {
    sum: f32
    count := 0
    for time_s, index in times {
        if time_s <= end_s - SETTLED_S || time_s > end_s || math.is_nan(values[index]) do continue

        sum += values[index]
        count += 1
    }
    return sum / f32(count)
}
