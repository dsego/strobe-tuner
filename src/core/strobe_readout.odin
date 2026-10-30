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

// The readout follows a track this loud, where its stripes are fully there
READOUT_MIN_SNR_DB :: STROBE_FADE_SNR_DB[1]
// The track's own reading this far off its partial, as far as a note holds past halfway to the next one
// (NOTE_HOLD_CENTS) and the tracks were measured to read, see sandbox/accuracy and sandbox/recordings. Further
// out the readout has none.
READOUT_RANGE_CENTS :: NOTE_HOLD_CENTS
READOUT_SETTLE_S :: 0.05 // the track's fit since the pluck before the readout follows it

// The track the readout follows, the fundamental's while it's clean enough to read, over READOUT_MIN_SNR_DB,
// however far under its partials. Otherwise the loudest octave partial's that is. The partials read a few cents
// apart, so once its track is ready the readout stays on it and keeps its last reading as it fades, until a pluck
// or another note starts the tracks over. Only a track still fully lit takes the readout on when the held one's
// stripes fade, e.g. a low string's fundamental dies down first. Only an octave track reads out, its cents from
// its partial are the note's. -1 for none.
//
// ready once its track has fitted a little since the pluck, until then the readout is the pitch detection's.
strobe_readout_track :: proc(self: ^StrobeLockIn, current: int) -> (track: int, ready: bool) {
    settled :: proc(band: PhaseBand) -> bool {
        return band.rate_time_s >= READOUT_SETTLE_S
    }
    // Settled in this frame's samples
    just_settled :: proc(self: ^StrobeLockIn, band: PhaseBand) -> bool {
        return settled(band) && band.rate_time_s - f32(self.available) / self.sample_rate < READOUT_SETTLE_S
    }

    // A pluck lifts the loudest partial, a faint one's level wobbling isn't one. The fundamental's track settling
    // picks again too, it wasn't there to pick yet: after a retune the noise between the partials still has the
    // pluck in it, and a low note's fundamental, quieter than its 2nd partial, clears it a few tenths of a second
    // later. Only then, so a fundamental that fades never takes the readout back.
    loudest, fundamental := readout_candidates(self)
    pick_again := loudest >= 0 && self.bands[loudest].onset
    pick_again ||= fundamental >= 0 && just_settled(self, self.bands[fundamental])

    // Held, unless a pluck brings another track to pick or the held one's stripes fade while another's are lit. By
    // the envelope like the stripes, a beating partial's dip doesn't hand the readout on.
    held := current >= 0 && current < len(self.bands) && measures_band(self, current) && settled(self.bands[current])
    if held && !pick_again {
        faded := self.bands[current].envelope_snr_db < READOUT_MIN_SNR_DB
        if !faded || loudest < 0 do return current, true

        return loudest, settled(self.bands[loudest])
    }

    if loudest < 0 do return -1, false

    track = fundamental if fundamental >= 0 else loudest
    return track, settled(self.bands[track])
}

// The loudest track the readout can follow and the fundamental's, -1 for none. The loudest by level at the
// envelope, not by SNR, each track's is over its own band's noise.
readout_candidates :: proc(self: ^StrobeLockIn) -> (loudest, fundamental: int) {
    loudest, fundamental = -1, -1
    for band, index in self.bands {
        if !measures_band(self, index) || !is_octave_track(band) do continue
        if !hears_note(band, self.band_cents) || band.snr_db < READOUT_MIN_SNR_DB do continue

        if loudest < 0 || band.envelope > self.bands[loudest].envelope do loudest = index
        if band.interval == 1 do fundamental = index
    }
    return
}

// The fundamental's or an octave's track, the others' partials are another note, e.g. a fifth
is_octave_track :: proc(band: PhaseBand) -> bool {
    octaves := math.log2(band.interval)
    return band.interval > 0 && abs(octaves - math.round(octaves)) < 0.01
}

// A track hears its note while it drifts less than its window is wide, band_cents, a semitone. Further out
// it's another note leaking in.
hears_note :: proc(band: PhaseBand, band_cents: int) -> bool {
    return band.in_range && band.drift_cents <= f32(band_cents)
}

// Whether any track's stripes are at least half faded in, the note is still ringing. The noise stays under it,
// the room's and the note's own between its partials. By the envelopes, as the stripes fade.
strobe_shows_note :: proc(self: ^StrobeLockIn) -> bool {
    fade := STROBE_FADE_SNR_DB
    for band in self.bands {
        if hears_note(band, self.band_cents) && band.envelope_snr_db >= 0.5 * (fade[0] + fade[1]) do return true
    }
    return false
}
