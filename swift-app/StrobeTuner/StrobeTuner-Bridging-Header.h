//
//  StrobeTuner-Bridging-Header.h
//  StrobeTuner
//
//  Created by Davorin on 10.11.2024..
//

#ifndef StrobeTuner_Bridging_Header_h
#define StrobeTuner_Bridging_Header_h

typedef struct _PhaseTracker *PhaseTracker;

PhaseTracker c_init_phase_tracker(float base_freq_hz, float samplerate, int band_count);

void c_destroy_phase_tracker(PhaseTracker self);

void c_phase_tracker_audio_callback(PhaseTracker self, float *input, int input_len);


typedef struct {
    float freq_hz;
    float norm_freq;
    float freq_diff_hz;
    float estimated_freq_hz;
    float time_stretch;
    float phase;
    float amp;
} StrobeInfo ;

typedef struct {
    float phase_correction;
    float time_reference;
    int band_count;
    StrobeInfo strobes[8];
} PhaseInfo;

PhaseInfo c_run_dft_analysis(PhaseTracker self);

#endif /* StrobeTuner_Bridging_Header_h */
