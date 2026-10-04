// EXPERIMENT: picks the note with a hidden Markov model over every NSDF peak, like pYIN, next to the tuner's
// rules, and scores both on a recording of notes 4 seconds apart.
//
//   odin run sandbox/hmm -- <file.wav> <note> <note> ... [-v]
//
// Each note is the one expected in its 4 seconds, e.g. A2 E1 A4. -v prints what both show over time.

package hmm

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import ma "vendor:miniaudio"

import "../../src/core"

// The app's defaults, see config_defaults in src/app/config.odin
SAMPLERATE :: 48_000
FFT_SIZE :: 8192
CLARITY_HIGH :: 0.98
CLARITY_LOW :: 0.9
MIN_SNR_DB :: 2
NOISE_FLOOR_SNR_DB :: 10
note_switch_s: f32 = 0.05 // NOTE_SWITCH_S in the environment tries another
HIGHPASS_HZ :: 60
INTERVALS :: [?]f32{1, 2, 4}
STROBE_SPEED :: 0.0125
FRAME_SAMPLES :: SAMPLERATE / 60

LEAD_IN_S :: 2
SEGMENT_S :: 4
SETTLE_S :: 0.3 // the start of a note isn't scored, only how long it takes to show

// The notes from A0, the last state is no note
STATES :: core.NOTE_COUNT + 1
UNVOICED :: core.NOTE_COUNT
// Set with environment variables of the same name to try others
// A note holds from one detection to the next. At 0.97 with TO_UNVOICED it never moves straight to another
// note, it goes through no note first.
stay := 0.97
TO_UNVOICED :: 0.03
UNVOICED_STAY :: 0.9
sharpness := 8.0 // clarity raised to this, 0.99 is 0.92 and 0.9 is 0.43
LATER_PEAK :: 0.5 // each further NSDF peak, a guess at a multiple of the period, counts this much less
WEAK_SNR :: 0.1 // under the SNR threshold the notes are this much less likely

Belief :: [STATES]f64

hmm_step :: proc(belief: ^Belief, peaks: []core.Vec2, snr_db: f32) {
    voiced: f64
    for state in 0 ..< core.NOTE_COUNT do voiced += belief[state]
    unvoiced := belief[UNVOICED]

    prior: Belief
    for state in 0 ..< core.NOTE_COUNT {
        prior[state] =
            stay * belief[state] +
            (1 - stay - TO_UNVOICED) * voiced / core.NOTE_COUNT +
            (1 - UNVOICED_STAY) * unvoiced / core.NOTE_COUNT
    }
    prior[UNVOICED] = TO_UNVOICED * voiced + UNVOICED_STAY * unvoiced

    emission: Belief
    for &value in emission do value = 1e-3
    weight := 1.0
    best := 0.0
    for peak in peaks {
        if peak.x <= 0 do continue
        freq := SAMPLERATE / peak.x
        weight_now := weight
        weight *= LATER_PEAK
        mains := false
        for mains_hz in core.MAINS_HZ {
            if abs(core.cents_deviation(freq, mains_hz)) <= core.MAINS_CENTS do mains = true
        }
        if mains do continue
        index, ok := core.note_index(core.freq_to_note(freq))
        if !ok do continue
        likelihood := math.pow(f64(clamp(peak.y, 0, 1)), sharpness)
        emission[index] = max(emission[index], weight_now * likelihood)
        best = max(best, likelihood)
    }
    if snr_db < MIN_SNR_DB {
        for state in 0 ..< core.NOTE_COUNT do emission[state] *= WEAK_SNR
    }
    emission[UNVOICED] = max(1 - best, 0.05)

    total: f64
    for state in 0 ..< STATES {
        belief[state] = prior[state] * emission[state]
        total += belief[state]
    }
    for &value in belief do value /= total
}

Score :: struct {
    right, wrong, frames: int,
    first_right_s:        f32,
}

main :: proc() {
    if len(os.args) < 3 {
        fmt.eprintln("usage: odin run sandbox/hmm -- <file.wav> <note> <note> ... [-v]")
        os.exit(1)
    }
    if value, found := os.lookup_env("STAY", context.temp_allocator); found do stay = strconv.parse_f64(value) or_else stay
    if value, found := os.lookup_env("SHARPNESS", context.temp_allocator); found do sharpness = strconv.parse_f64(value) or_else sharpness

    if value, found := os.lookup_env("NOTE_SWITCH_S", context.temp_allocator); found do note_switch_s = strconv.parse_f32(value) or_else note_switch_s

    verbose := os.args[len(os.args) - 1] == "-v"
    expected := os.args[2:len(os.args) - 1] if verbose else os.args[2:]

    samples, ok := decode(os.args[1])
    if !ok {
        fmt.eprintln("Can't decode", os.args[1])
        os.exit(1)
    }
    defer delete(samples)

    detector := core.init_pitch_detector(SAMPLERATE, FFT_SIZE, CLARITY_HIGH, CLARITY_LOW, MIN_SNR_DB, NOISE_FLOOR_SNR_DB, HIGHPASS_HZ)
    defer core.destroy_pitch_detector(&detector)
    tuner := core.init_tuner(110, 440, note_switch_s, true)

    intervals := INTERVALS
    strobe := core.init_phase_comparator(110, SAMPLERATE, intervals[:], .HARMONIC, NOISE_FLOOR_SNR_DB)
    defer core.destroy_phase_comparator(strobe)
    retune :: proc(strobe: ^core.PhaseComparator, freq_hz: f32) {
        core.set_phase_comparator_freq(strobe, freq_hz, 440, STROBE_SPEED, 2, .HARMONIC)
    }
    retune(strobe, 110)

    belief: Belief
    belief[UNVOICED] = 1

    tuner_scores := make([]Score, len(expected))
    hmm_scores := make([]Score, len(expected))
    for &score in tuner_scores do score.first_right_s = -1
    for &score in hmm_scores do score.first_right_s = -1

    for start := 0; start + FRAME_SAMPLES <= len(samples); start += FRAME_SAMPLES {
        frame := samples[start:start + FRAME_SAMPLES]
        core.audio_capture_write(&detector, frame)
        core.audio_capture_write(strobe, frame)
        pitch := core.run_pitch_detection(&detector, tuner.pitch)
        core.run_phase_detection(strobe, true, pitch.is_tonal)
        if core.update_tuner(&tuner, pitch, core.strobe_shows_note(strobe)) do retune(strobe, tuner.target_note.frequency)
        if !pitch.fresh do continue

        hmm_step(&belief, detector.nsdf.peaks[:], pitch.snr_db)

        tuner_shows := core.note_name(tuner.detected_note) if tuner.active else "-"
        best_state := UNVOICED
        for state in 0 ..< core.NOTE_COUNT {
            if belief[state] > belief[best_state] do best_state = state
        }
        hmm_shows := "-"
        if best_state != UNVOICED && belief[best_state] > 0.5 {
            hmm_shows = core.note_name(core.cents_to_note(f32((best_state + core.LOWEST_NOTE) * 100)))
        }

        t := f32(start + FRAME_SAMPLES) / SAMPLERATE - LEAD_IN_S
        if verbose {
            chosen := core.note_name(pitch.detected_note) if pitch.detected_freq > 0 else "-"
            fmt.printfln("%6.2fs  nsdf %-4v %.3f  tuner %-4v  hmm %-4v %.2f", t, chosen, pitch.clarity, tuner_shows, hmm_shows, belief[best_state])
        }

        segment := int(t / SEGMENT_S)
        if t < 0 || segment >= len(expected) do continue
        since := t - f32(segment) * SEGMENT_S
        for pair in ([2]struct {
                    scores: []Score,
                    shows:  string,
                }{{tuner_scores, tuner_shows}, {hmm_scores, hmm_shows}}) {
            score := &pair.scores[segment]
            right := pair.shows == expected[segment]
            if right && score.first_right_s < 0 do score.first_right_s = since
            if since < SETTLE_S do continue
            score.frames += 1
            if right do score.right += 1
            else if pair.shows != "-" do score.wrong += 1
        }
    }

    fmt.println("note    tuner: shown right / wrong note / first right     hmm: shown right / wrong note / first right")
    for note, i in expected {
        print :: proc(score: Score) {
            fmt.printf("%5.0f%% %5.0f%% %7v       ", 100 * f32(score.right) / f32(score.frames), 100 * f32(score.wrong) / f32(score.frames), fmt.tprintf("%.2fs", score.first_right_s) if score.first_right_s >= 0 else "never")
        }
        fmt.printf("%-6v  ", note)
        print(tuner_scores[i])
        fmt.print("         ")
        print(hmm_scores[i])
        fmt.println()
    }
}

// The whole file as mono at the app's sample rate, after the lead-in's silence
decode :: proc(path: string) -> (samples: []f32, ok: bool) {
    decoder: ma.decoder
    config := ma.decoder_config_init(.f32, 1, SAMPLERATE)
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
