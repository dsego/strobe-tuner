
// C exports for shared library

package core

import "base:runtime"


// -------------------------------------------------------------------------------------------------
//  Note
// -------------------------------------------------------------------------------------------------

@(export)
c_find_note :: proc "c" (freq: f32, pitch_standard: f32 = 440.0) -> Note {
    return c_find_note(freq, pitch_standard)
}



// -------------------------------------------------------------------------------------------------
//  Phase Tracker
// -------------------------------------------------------------------------------------------------

// @(export)
// c_init_phase_tracker :: proc "c" (
//     base_freq_hz: f32,
//     samplerate: f32,
//     band_count: int,
// ) -> ^PhaseTracker {
//     context = runtime.default_context()
//     return init_phase_tracker(base_freq_hz, samplerate, band_count)
// }

// @(export)
// c_destroy_phase_tracker :: proc "c"(self: ^PhaseTracker) {
//     context = runtime.default_context()
//     destroy_phase_tracker( self)
// }

// @(export)
// c_set_phase_tracker_freq :: proc (self: ^PhaseTracker, base_freq_hz: f32) {
//     set_phase_tracker_freq( self, base_freq_hz)
// }

// @(export)
// c_phase_tracker_audio_callback :: proc "c" (self: ^PhaseTracker, input: [^]f32, input_len: int) {
//     context = runtime.default_context()
//     phase_tracker_audio_callback(self, input[:input_len])
// }

// @(export)
// c_run_dft_analysis :: proc (self: ^PhaseTracker) -> Maybe(PhaseInfo) {
//     return run_dft_analysis(self)
// }
