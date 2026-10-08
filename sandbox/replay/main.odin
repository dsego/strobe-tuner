// Plays a recording through the tuner's pitch detection like the app hears it, and prints what it makes of
// it over time: the detected pitch, its clarity and SNR, and whether the tuner holds the note.
//
//   odin run sandbox/replay -- <file.wav|mp3|flac> [lead-in seconds]
//
// The lead-in is digital silence before the recording, 2 seconds by default, like a loopback input before
// the player starts. 0 starts on the recording, like opening the app while a note rings.
//
// At the file's own rate like the app at its input's, never resampled, a fast one decimated like the app's.
// miniaudio decodes wav, mp3 and flac, convert anything else first, e.g.
//   ffmpeg -i E1.m4a E1.wav

package replay

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import ma "vendor:miniaudio"

import "../../src/core"

// The app's, see src/app/app.odin
INTERVALS :: [?]f32{1, 2, 4}
STROBE_SPEED :: 0.025
DESKTOP_PERIODS :: 12 // the strobe's stripes across the desktop's tracks

// The pitch detection runs on every frame's new samples, e.g. -define:FPS=120 for the app's MAX_FPS
FPS :: #config(FPS, 60)
// e.g. -define:PRINT_EVERY_MS=20 to follow an attack frame by frame
PRINT_EVERY_MS :: #config(PRINT_EVERY_MS, 250)
// e.g. -define:PITCH_STANDARD=443 to tune the notes to a hum or an instrument off 440
PITCH_STANDARD :: f32(#config(PITCH_STANDARD, 440))

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

    samples, sample_rate, ok := decode(os.args[1], lead_in_s)
    if !ok {
        fmt.eprintln("Can't decode", os.args[1])
        os.exit(1)
    }
    defer delete(samples)

    detector := core.init_pitch_detector(PITCH_STANDARD, sample_rate)
    defer core.destroy_pitch_detector(&detector)
    tuner := core.init_tuner(110, PITCH_STANDARD, true)

    // The strobe tracks, following the tuner's note like in the app
    intervals := INTERVALS
    strobe := core.init_phase_comparator(110, intervals[:], .HARMONIC, sample_rate)
    defer core.destroy_phase_comparator(strobe)
    retune :: proc(strobe: ^core.PhaseComparator, freq_hz: f32) {
        core.set_phase_comparator_freq(strobe, freq_hz, PITCH_STANDARD, STROBE_SPEED, 2, .HARMONIC)
    }
    retune(strobe, tuner.target_note.frequency)

    fmt.println("   time      Hz  cents  note  clarity     SNR  pitch   tuner   readout   tracks: SNR, cents, drift, stripes a second")

    next_print: f32 = 0
    was_active := false
    readout_track := -1
    readout_ready := false
    frame_samples := int(sample_rate) / FPS
    for start := 0; start + frame_samples <= len(samples); start += frame_samples {
        frame := samples[start:start + frame_samples]
        core.audio_capture_write(&detector, frame)
        core.audio_capture_write(strobe, frame)
        pitch := core.run_pitch_detection(&detector, tuner.pitch)
        core.run_phase_detection(strobe, pitch.is_tonal)
        // Like the app's readout, and the strobe keeps the note lit while it shows it and moves up to the
        // partial the readout gives way to
        was_ready := readout_ready
        readout_track, readout_ready = core.strobe_readout_track(strobe, readout_track)
        if core.update_tuner(&tuner, pitch, core.strobe_shows_note(strobe)) {
            retune(strobe, tuner.target_note.frequency)
            readout_ready = false
        }
        if core.follow_readout_partial(&tuner, strobe, readout_track, readout_ready, was_ready) {
            retune(strobe, tuner.target_note.frequency)
            readout_ready = false
        }
        if !pitch.fresh do continue

        // Every so often, and whenever the tuner lets go of the note or picks it up
        t := f32(start + frame_samples) / sample_rate
        if t < next_print && tuner.active == was_active do continue
        next_print = t + PRINT_EVERY_MS / 1000.0
        was_active = tuner.active

        kind := "strong" if pitch.is_strong_pitch else "weak" if pitch.is_weak_pitch else "-"
        note := "-"
        if pitch.detected_freq > 0 do note = core.note_name(pitch.detected_note)
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
        // None until a track settles, like the app's
        readout := "-"
        if readout_ready && abs(strobe.bands[readout_track].err_cents) <= core.READOUT_RANGE_CENTS {
            // The note the app names, the target's, it moves up to the partial the readout gives way to
            band := strobe.bands[readout_track]
            readout = fmt.tprintf("%+.1f¢ %v× %v", band.err_cents, band.interval, core.note_name(tuner.target_note))
        }
        fmt.printf("%-13v ", readout)
        // The stripes fade out between 16 and 8 dB, see core.STROBE_FADE_SNR_DB. And by their speed, the
        // desktop's stripes a second by the drift, they fade from a quarter of a stripe a frame, see the app's
        // STROBE_ALIAS_FADE_STRIPES.
        for band in strobe.bands {
            drift_hz := core.freq_at_cents(band.freq_hz, band.drift_cents) - band.freq_hz
            stripes_per_s := DESKTOP_PERIODS * drift_hz * f32(core.strobe_rescale(band.freq_hz)) * band.speed
            fmt.printf(
                "  %v× %-7v %-6v %-6v %-5v",
                band.interval,
                fmt.tprintf("%.1fdB", band.snr_db),
                fmt.tprintf("%+.1f¢", band.err_cents),
                fmt.tprintf("~%.0f¢", band.drift_cents),
                fmt.tprintf("%.1f/s", stripes_per_s),
            )
        }
        fmt.println()
    }
}

// The whole file as mono at its own rate, after lead_in_s of silence. A fast one decimated like the app's
// input, sample_rate is what comes out.
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
    fmt.printfln("%v at %v Hz, measured at %v Hz", path, file_rate, sample_rate)
    return samples, sample_rate, true
}
