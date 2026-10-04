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
import "core:slice"
import "core:testing"


// Tuned on test recordings with the sandbox tools, not in the settings

PITCH_FFT_SIZE :: 8192 // the window is half of it, 4096 samples

// Under a guitar's low E (82 Hz), it takes out DC and low frequency rumble. A lower note like a bass's E1
// (41 Hz) loses its fundamental here, it's still found from its harmonics.
PITCH_HIGHPASS_HZ :: 60

// A strong pitch is this clear at least and this far over the noise floor, a weak one less clear than
// PITCH_CLARITY_LOW
PITCH_CLARITY_LOW :: 0.9
PITCH_CLARITY_HIGH :: 0.98
PITCH_MIN_SNR_DB :: 2

// A strong pitch stays strong down to this far under PITCH_MIN_SNR_DB, so a decaying note doesn't flicker
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
    using node:     AudioCaptureNode,
    nsdf:           NSDF,
    samples:        []f32,
    // DC and rumble lift the NSDF so it doesn't dip between periods, hiss blurs it, see PITCH_LOWPASS_HZ.
    // Only here, the strobe's tracks are narrow and the scope wants the wave as it is.
    highpass:       Biquad,
    lowpass:        Biquad,
    noise_floor:    NoiseFloor, // of the RMS
    snr_db:         f32,
    pitch_standard: f32, // A4, detected notes are named against it
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


init_pitch_detector :: proc(pitch_standard: f32 = 440.0) -> (self: PitchDetector) {
    self.samples = make([]f32, PITCH_FFT_SIZE / 2)
    self.highpass = init_highpass(PITCH_HIGHPASS_HZ, SAMPLERATE)
    self.lowpass = init_lowpass(PITCH_LOWPASS_HZ, SAMPLERATE)
    self.nsdf = init_nsdf(PITCH_FFT_SIZE)
    self.noise_floor = init_noise_floor()
    self.pitch_standard = pitch_standard

    init_audio_capture_node(&self, "pitch")
    return
}

destroy_pitch_detector :: proc(self: ^PitchDetector) {
    destroy_nsdf(&self.nsdf)
    destroy_audio_capture_node(self)
    delete(self.samples)
}

// Another input's signal is unrelated to the previous one's: the window starts out silent like at launch,
// the filters from rest and the noise floor is learned again
reset_pitch_detector :: proc(self: ^PitchDetector) {
    slice.zero(self.samples)
    self.highpass.z1, self.highpass.z2 = 0, 0
    self.lowpass.z1, self.lowpass.z2 = 0, 0
    reset_noise_floor(&self.noise_floor)
}

// Takes the previous detection to repeat when there are no new samples, the Tuner keeps the history
run_pitch_detection :: proc(self: ^PitchDetector, prev_info: PitchInfo) -> PitchInfo {
    info := PitchInfo{}

    // Once a display frame's worth of new samples is in, the read wants more than its minimum
    read, elapsed := audio_capture_read(self, self.samples, SAMPLERATE / DETECTIONS_PER_SECOND - 1)

    // Samples went by that the window didn't get, the filters start from rest on the new ones
    if i64(read) < elapsed {
        self.highpass.z1, self.highpass.z2 = 0, 0
        self.lowpass.z1, self.lowpass.z2 = 0, 0
    }

    if read == 0 {
        stale := prev_info
        stale.fresh = false
        return stale
    }

    // The new samples are at the end, the older ones were filtered on the way in before
    new_samples := self.samples[len(self.samples) - read:]
    biquad_process(&self.highpass, new_samples, new_samples)
    biquad_process(&self.lowpass, new_samples, new_samples)

    info.measured = true
    info.fresh = true
    info.detected_freq, info.nsdf_peak = run_nsdf(&self.nsdf, self.samples)
    info.clarity = info.nsdf_peak.y
    info.shortest_period = self.nsdf.chosen_peak == 0
    info.rms = max(calculate_rms(self.samples), MIN_RMS_TRACKABLE)
    info.rms_dbfs = dbfs(info.rms)

    dt := f32(elapsed) / SAMPLERATE
    info.elapsed_s = dt

    // Down to A0, flat by up to half a semitone, at the pitch standard
    min_freq := cents_to_freq(LOWEST_NOTE * 100 - 50, self.pitch_standard)
    mains := false

    for mains_hz in MAINS_HZ {
        if abs(cents_deviation(info.detected_freq, mains_hz)) <= MAINS_CENTS do mains = true
    }

    // A clear pitch is a note, not the background, even before the floor knows how loud that is
    info.is_tonal = info.detected_freq >= min_freq && info.clarity >= PITCH_CLARITY_HIGH && !mains
    self.snr_db = update_noise_floor(&self.noise_floor, info.rms, dt, is_tonal = info.is_tonal)
    info.snr_db = self.snr_db
    info.noise_floor = self.noise_floor.level

    // No peak gives 0 Hz, which has no note
    if info.detected_freq > 0 {
        info.detected_note = freq_to_note(info.detected_freq, self.pitch_standard)
        info.err_cents = cents_deviation(info.detected_freq, info.detected_note.frequency)
    }

    weak_snr_db: f32 = PITCH_MIN_SNR_DB - SNR_HYSTERESIS_DB
    strong_snr_db: f32 = weak_snr_db if prev_info.is_strong_pitch else PITCH_MIN_SNR_DB

    info.is_strong_pitch = info.is_tonal && info.snr_db >= strong_snr_db
    info.is_weak_pitch =
        mains ||
        info.detected_freq < min_freq ||
        info.clarity < PITCH_CLARITY_LOW ||
        info.snr_db < weak_snr_db

    return info
}

calculate_rms :: proc(samples: []f32) -> f32 {
    square_sum: f32 = 0
    for sample in samples do square_sum += sample * sample

    return math.sqrt(square_sum / f32(len(samples)))
}

// Of an RMS level, against a full scale sine's RMS so a full scale sine is 0 dBFS
dbfs :: proc(signal: $T) -> T {
    return 20.0 * math.log10(signal * math.sqrt(cast(T)2.0))
}


// Hum with its harmonics doesn't name a note at either mains frequency, the notes either side of it do
@(test)
test_mains_hum :: proc(t: ^testing.T) {
    detect :: proc(fundamental: f32) -> PitchInfo {
        detector := init_pitch_detector()
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
            audio_capture_write(&detector, frame[:])
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
