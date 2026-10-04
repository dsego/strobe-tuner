// Plays a recording through the tuner's pitch detection like the app hears it, and prints what it makes of
// it over time: the detected pitch, its clarity and SNR, and whether the tuner holds the note.
//
//   odin run sandbox/replay -- <file.wav|mp3|flac> [lead-in seconds]
//
// The lead-in is digital silence before the recording, 2 seconds by default, like a loopback input before
// the player starts. 0 starts on the recording, like opening the app while a note rings.
//
// miniaudio decodes wav, mp3 and flac, convert anything else first, e.g.
//   ffmpeg -i E1.m4a E1.wav

package replay

import "core:fmt"
import "core:os"
import "core:strconv"
import ma "vendor:miniaudio"

import "../../src/core"

// The app's, see src/app/app.odin
SAMPLERATE :: core.SAMPLERATE
INTERVALS :: [?]f32{1, 2, 4}
STROBE_SPEED :: 0.0125

// The app draws at 60 fps and the pitch detection runs on every frame's new samples
FRAME_SAMPLES :: SAMPLERATE / 60
// e.g. -define:PRINT_EVERY_MS=20 to follow an attack frame by frame
PRINT_EVERY_MS :: #config(PRINT_EVERY_MS, 250)

LEAD_IN_S :: 2

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("usage: odin run sandbox/replay -- <file.wav|mp3|flac> [lead-in seconds]")
        os.exit(1)
    }

    lead_in_s := LEAD_IN_S
    if len(os.args) > 2 {
        lead_in_s = strconv.parse_int(os.args[2]) or_else LEAD_IN_S
    }

    samples, ok := decode(os.args[1], lead_in_s)
    if !ok {
        fmt.eprintln("Can't decode", os.args[1])
        os.exit(1)
    }
    defer delete(samples)

    detector := core.init_pitch_detector()
    defer core.destroy_pitch_detector(&detector)
    tuner := core.init_tuner(110, 440, true)

    // The strobe tracks, following the tuner's note like in the app
    intervals := INTERVALS
    strobe := core.init_phase_comparator(110, intervals[:], .HARMONIC)
    defer core.destroy_phase_comparator(strobe)
    retune :: proc(strobe: ^core.PhaseComparator, freq_hz: f32) {
        core.set_phase_comparator_freq(strobe, freq_hz, 440, STROBE_SPEED, 2, .HARMONIC)
    }
    retune(strobe, 110)

    fmt.println("   time      Hz  cents  note  clarity     SNR  pitch   tuner   readout   tracks: SNR, cents")

    next_print: f32 = 0
    was_active := false
    readout_track := -1
    readout_ready := false
    for start := 0; start + FRAME_SAMPLES <= len(samples); start += FRAME_SAMPLES {
        frame := samples[start:start + FRAME_SAMPLES]
        core.audio_capture_write(&detector, frame)
        core.audio_capture_write(strobe, frame)
        pitch := core.run_pitch_detection(&detector, tuner.pitch)
        core.run_phase_detection(strobe, pitch.is_tonal)
        // Like the app's readout, and the strobe keeps the note lit while it shows it
        readout_track, readout_ready = core.strobe_readout_track(strobe, readout_track)
        if core.update_tuner(&tuner, pitch, core.strobe_shows_note(strobe)) do retune(strobe, tuner.target_note.frequency)
        // Like the app, an octave off strobe follows the target once its own note is dark
        off_target := strobe.base_freq_hz != tuner.target_note.frequency
        if off_target && !core.strobe_shows_note(strobe, fundamental_only = true) do retune(strobe, tuner.target_note.frequency)
        if !pitch.fresh do continue

        // Every so often, and whenever the tuner lets go of the note or picks it up
        t := f32(start + FRAME_SAMPLES) / SAMPLERATE
        if t < next_print && tuner.active == was_active do continue
        next_print = t + PRINT_EVERY_MS / 1000.0
        was_active = tuner.active

        kind := "strong" if pitch.is_strong_pitch else "weak" if pitch.is_weak_pitch else "-"
        note := "-"
        if pitch.detected_freq > 0 {
            n := pitch.detected_note
            note = fmt.tprintf("%v%v%v", n.name, "#" if n.is_accidental else "", n.octave)
        }
        // From the strobe's note, to compare with the tracks
        cents := core.cents_deviation(pitch.detected_freq, tuner.target_note.frequency) if pitch.detected_freq > 0 else 0
        fmt.printf(
            "%-7v %-7v %-6v %-4v  %.3f %-7v  %-6v  %-6v ",
            // fmt pads numbers with zeros, the text pads with spaces
            fmt.tprintf("%.2fs", t),
            fmt.tprintf("%.1f", pitch.detected_freq),
            fmt.tprintf("%+.1f¢", cents),
            note,
            pitch.clarity,
            fmt.tprintf("%.1fdB", pitch.snr_db),
            kind,
            "active" if tuner.active else "-",
        )
        steady := core.tuner_readout(&tuner)
        readout := fmt.tprintf("%+.1f¢", steady.err_cents)
        if readout_ready && abs(steady.err_cents) <= core.READOUT_RANGE_CENTS {
            band := strobe.bands[readout_track]
            readout = fmt.tprintf("%+.1f¢ %v×", band.err_cents, band.interval)
        }
        fmt.printf("%-9v ", readout)
        // The stripes fade out between 16 and 8 dB, see core.STROBE_FADE_SNR_DB
        for band in strobe.bands {
            fmt.printf("  %v× %-7v %-6v", band.interval, fmt.tprintf("%.1fdB", band.snr_db), fmt.tprintf("%+.1f¢", band.err_cents))
        }
        fmt.println()
    }
}

// The whole file as mono at the app's sample rate, after lead_in_s of silence
decode :: proc(path: string, lead_in_s: int) -> (samples: []f32, ok: bool) {
    decoder: ma.decoder
    config := ma.decoder_config_init(.f32, 1, SAMPLERATE)
    cpath := fmt.ctprintf("%s", path)
    if ma.decoder_init_file(cpath, &config, &decoder) != .SUCCESS do return nil, false
    defer ma.decoder_uninit(&decoder)

    length: u64
    ma.decoder_get_length_in_pcm_frames(&decoder, &length)
    lead_in := u64(lead_in_s * SAMPLERATE)
    samples = make([]f32, lead_in + length)
    ma.decoder_read_pcm_frames(&decoder, raw_data(samples[lead_in:]), length, nil)
    return samples, true
}
