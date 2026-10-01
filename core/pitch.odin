// Copyright (C) 2025  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


package core


import "core:math"
import "core:testing"


// A strong pitch stays strong down to this far under min_snr_db, so a decaying note doesn't flicker
// between strong and weak around the threshold
SNR_HYSTERESIS_DB :: 1.5

// Mains hum repeats as steadily as a held note, and the grid holds it to a few cents of 50 or 60 Hz where
// no note is tuned: G1 +35 ¢, A♯1 +50 ¢, B1 -49 ¢. It's the background, a string tuned through it loses
// its note for a moment.
MAINS_HZ :: [?]f32{50, 60}
MAINS_CENTS :: 8

// The window moves on by a display frame at 60 fps, the 8192 point FFT is cheap. The tuner confirms a note by
// time, so the rate only changes how soon it's seen.
DETECTIONS_PER_SECOND :: 60

// The pitch detection hears up to here, above C8 (4186 Hz). Hiss and pick noise over it only blur the
// period, the strobe still gets the whole band.
PITCH_LOWPASS_HZ :: 5000


PitchDetector :: struct {
    using node:                   AudioCaptureNode,
    nsdf:                         NSDFConfig,
    samples:                      []f32,
    // DC and rumble lift the NSDF so it doesn't dip between periods, hiss blurs it, see PITCH_LOWPASS_HZ.
    // Only here, the strobe's tracks are narrow and the scope wants the wave as it is.
    highpass:                     Biquad,
    lowpass:                      Biquad,
    clarity_high:                f32,
    clarity_low:                  f32,
    noise_floor:                  NoiseFloor, // of the RMS
    min_snr_db:                   f32,
    snr_db:                       f32,
    pitch_standard:               f32, // A4, detected notes are named against it
}


PitchInfo :: struct {
    measured:        bool,
    fresh:           bool, // a new measurement this frame, false when repeating the previous one
    elapsed_s:       f32, // the new audio since the previous measurement
    detected_freq:   f32,
    detected_note:   Note,
    clarity:         f32,
    nsdf_peak:       Vec2,
    shortest_period: bool, // the first NSDF peak, not a guess at a multiple of the period
    rms:             f32,
    rms_dbfs:        f32,
    err_cents:       f32,
    is_strong_pitch: bool,
    is_weak_pitch:   bool,
    is_tonal:        bool, // a clear pitch whatever its level, the noise floors don't learn it as the background
    snr_db:          f32,
    noise_floor:     f32,
}


init_pitch_detector :: proc(
    samplerate: int,
    fft_size: int,
    clarity_high: f32,
    clarity_low: f32,
    min_snr_db: f32,
    noise_floor_snr_db_threshold: f32,
    highpass_cutoff_hz: f32,
) -> (
    self: PitchDetector,
) {
    self.samples = make([]f32, fft_size / 2)
    self.highpass = init_highpass(highpass_cutoff_hz, f32(samplerate))
    self.lowpass = init_lowpass(PITCH_LOWPASS_HZ, f32(samplerate))
    self.nsdf = nsdf_init(fft_size, samplerate)
    self.clarity_high = clarity_high
    self.clarity_low = clarity_low
    self.min_snr_db = min_snr_db
    self.noise_floor = init_noise_floor(noise_floor_snr_db_threshold)
    self.pitch_standard = 440.0

    init_audio_capture_node(&self, "pitch")
    return
}

destroy_pitch_detector :: proc(self: ^PitchDetector) {
    nsdf_destroy(&self.nsdf)
    destroy_audio_capture_node(self)
    delete(self.samples)
}

// Another input's signal is unrelated to the previous one's, the filters start from rest
reset_pitch_filters :: proc(self: ^PitchDetector) {
    self.highpass.z1, self.highpass.z2 = 0, 0
    self.lowpass.z1, self.lowpass.z2 = 0, 0
}

// Takes the previous detection to repeat when there are no new samples, the Tuner keeps the history
run_pitch_detection :: proc(self: ^PitchDetector, prev_info: PitchInfo) -> PitchInfo {
    info := PitchInfo{}

    // Once a display frame's worth of new samples is in, the read wants more than its minimum
    available := audio_capture_read(self, self.samples, i32(self.nsdf.samplerate / DETECTIONS_PER_SECOND) - 1)

    // no new audio samples available, skip pitch detection
    if available <= 0 {
        stale := prev_info
        stale.fresh = false
        return stale
    }

    // The new samples are at the end, the older ones were filtered on the way in before
    new_samples := self.samples[max(len(self.samples) - int(available), 0):]
    biquad_process(&self.highpass, new_samples, new_samples)
    biquad_process(&self.lowpass, new_samples, new_samples)

    info.measured = true
    info.fresh = true
    info.detected_freq, info.nsdf_peak = nsdf_pitch_detect(&self.nsdf, self.samples)
    info.clarity = info.nsdf_peak.y
    info.shortest_period = self.nsdf.chosen_peak_idx == 0
    info.rms = math.max(calculate_rms(self.samples), MIN_RMS_TRACKABLE)
    info.rms_dbfs = dbfs(info.rms)

    dt := f32(available) / f32(self.nsdf.samplerate)
    info.elapsed_s = dt
    // Down to A0, flat by up to half a semitone, at the pitch standard
    min_freq := cents_to_freq(LOWEST_NOTE * 100 - 50, self.pitch_standard)
    mains := false
    for mains_hz in MAINS_HZ {
        if abs(cents_deviation(info.detected_freq, mains_hz)) <= MAINS_CENTS do mains = true
    }
    // A clear pitch is a note, not the background, even before the floor knows how loud that is
    info.is_tonal = info.detected_freq >= min_freq && info.clarity >= self.clarity_high && !mains
    self.snr_db = update_noise_floor(&self.noise_floor, info.rms, dt, is_tonal = info.is_tonal)
    info.snr_db = self.snr_db
    info.noise_floor = self.noise_floor.level
    // No peak gives 0 Hz, which has no note
    if info.detected_freq > 0 {
        info.detected_note = find_note(info.detected_freq, self.pitch_standard)
        info.err_cents = cents_deviation(info.detected_freq, info.detected_note.frequency)
    }

    weak_snr_db := self.min_snr_db - SNR_HYSTERESIS_DB
    strong_snr_db := weak_snr_db if prev_info.is_strong_pitch else self.min_snr_db

    info.is_strong_pitch =
        info.detected_freq >= min_freq &&
        info.clarity >= self.clarity_high &&
        info.snr_db >= strong_snr_db &&
        !mains

    info.is_weak_pitch =
        mains ||
        info.detected_freq < min_freq ||
        info.clarity < self.clarity_low ||
        info.snr_db < weak_snr_db

    return info
}

calculate_rms :: proc(samples: []f32) -> f32 {
    square_sum: f32 = 0
    for s in samples do square_sum += s * s
    return math.sqrt(square_sum / f32(len(samples)))
}

dbfs :: proc(signal: $T) -> T {
    return 20.0 * math.log10(signal * math.sqrt(cast(T)2.0))
}


// Hum with its harmonics doesn't name a note at either mains frequency, the notes either side of it do
@(test)
test_mains_hum :: proc(t: ^testing.T) {
    SAMPLERATE :: 48_000
    FFT_SIZE :: 8192

    detect :: proc(fundamental: f32) -> PitchInfo {
        detector := init_pitch_detector(SAMPLERATE, FFT_SIZE, 0.98, 0.9, 2, 10, 60)
        defer destroy_pitch_detector(&detector)
        // Half a second a display frame at a time like the app, the high-pass settles from its start
        FRAME :: SAMPLERATE / DETECTIONS_PER_SECOND
        info: PitchInfo
        for start := 0; start < SAMPLERATE / 2; start += FRAME {
            frame: [FRAME]f32
            for &sample, i in frame {
                for partial in 1 ..= 5 {
                    phase := math.TAU * f64(partial) * f64(fundamental) * f64(start + i) / SAMPLERATE
                    sample += f32(0.01 * math.sin(phase))
                }
            }
            audio_capture_callback(&detector, frame[:])
            info = run_pitch_detection(&detector, info)
        }
        return info
    }

    for mains_hz in MAINS_HZ {
        hum := detect(mains_hz)
        testing.expectf(t, hum.is_weak_pitch && !hum.is_strong_pitch && !hum.is_tonal, "%v Hz hum: %v", mains_hz, hum)
    }
    for note_hz in ([]f32{49.0, 61.74}) {
        note := detect(note_hz)
        testing.expectf(t, note.is_strong_pitch && note.is_tonal, "%v Hz note: %v", note_hz, note)
    }
}
