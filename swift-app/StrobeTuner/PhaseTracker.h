//
//  PhaseTracker.h
//  StrobeTuner
//
//  Created by Davorin on 09.11.2024..
//

#ifndef PhaseTracker_h
#define PhaseTracker_h

#include <stdio.h>
#include "pa_ringbuffer.h"

#include "./SingleFreqDFT.h"


typedef struct {
    float freqHz;
    float normFreq;
    float freqDiffHz;
    float estimatedFreqHz;
    float angle;
    float timeStretch;
    float phase;
    float amp;
    SingleFreqDFT dft;
} StrobeBand;

typedef struct {
    float *sampleBuffer;
    int windowSize;
    PaUtilRingBuffer ringbuffer;
    char *ringbufferData;
    float phaseCorrection;
    float timeReference;
    StrobeBand *bands;
    float samplerate;
} PhaseTracker;


PhaseTracker PhaseTracker_init(float baseFreqHz, float samplerate, int bandCount);

void PhaseTracker_destroy(PhaseTracker *self);

void PhaseTracker_setFreq(PhaseTracker *self, float baseFreqHz);

void PhaseTracker_audioCallback(PhaseTracker *self, float *input, int input_len);

void PhaseTracker_generateStrobes(PhaseTracker *self);


#endif /* PhaseTracker_h */
