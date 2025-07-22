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
import "core:time"

MIN_RMS_TRACKABLE :: 1e-6
MIN_NOISE_FLOOR :: 1e-6


// Keep an up-to-date estimate of background noise (i.e. when no note is playing)
update_noise_floor :: proc(
    noise_floor: ^f32,
    last_quiet_time: ^time.Tick,
    rms: f32,
    min_rms_level: f32,
    min_snr_db: f32,
    decay_time_ms: f64,
) {
    EPS :: 1e-8 // to avoid divide by zero
    snr_db: f32 = 20.0 * math.log10((rms + EPS) / (noise_floor^ + EPS))

    // If the overall RMS is very low (i.e., quiet scene), assume it's just background noise and allow updating
    quiet_rms := rms < min_rms_level

    // Pause updating when signal is loud, based on an SNR threshold
    low_snr := snr_db < min_snr_db

    // time-based decay
    since_last_quiet := time.tick_since(last_quiet_time^)
    time_based_decay := time.duration_milliseconds(since_last_quiet) > decay_time_ms

    if quiet_rms || low_snr || time_based_decay {
        last_quiet_time^ = time.tick_now()

        // Set noise floor based on minimum RMS
        if rms < noise_floor^ {
            // Fast update downward, but reject near-zero values to avoid getting stuck at its lowest value
            noise_floor^ = math.max(rms, MIN_NOISE_FLOOR)
        } else {
            // Slow upward adaptation to avoid overreaction
            ALPHA: f32 : 0.01
            noise_floor^ += ALPHA * (rms - noise_floor^)
        }
    }
}
