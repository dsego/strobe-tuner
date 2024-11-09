//
//  PhaseTracker.c
//  StrobeTuner
//
//  Created by Davorin on 09.11.2024..
//

#include "PhaseTracker.h"

PhaseTracker PhaseTracker_init(float baseFreqHz, float samplerate, int bandCount) {
    PhaseTracker self = {};
    
    
    self.windowSize = 4096
    
}

void PhaseTracker_destroy(PhaseTracker *self);

void PhaseTracker_setFreq(PhaseTracker *self, float baseFreqHz);

void PhaseTracker_audioCallback(PhaseTracker *self, float *input, int input_len);

void PhaseTracker_generateStrobes(PhaseTracker *self);
