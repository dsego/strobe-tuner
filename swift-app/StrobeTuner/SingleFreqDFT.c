//
//  SingleFreqDFT.c
//  StrobeTuner
//
//  Created by Davorin on 09.11.2024..
//

#include "SingleFreqDFT.h"
#include <stdlib.h>
#include <math.h>
#include <assert.h>

#define TAU 6.28318530717958647692528676655900576

float blackmannWindow(float k, float size) {
    float a0 = 0.42;
    float a1 = 0.5;
    float a2 = 0.08;

    float l = TAU * k / (size - 1.0);
    return a0 - a1 * cosf(l) + a2 * cosf(2.0 * l);
}


SingleFreqDFT SingleFreqDFT_init(int size) {
    SingleFreqDFT self = {};
    self.size = size;
    self.window = calloc(size, sizeof(float));
    self.twiddleLookup = calloc(size, sizeof(float complex));
    
    // Generate the Blackmann window
    for (int i = 0; i < size; i++) {
        self.window[i] = blackmannWindow((float) i, (float) size);
    }
    return self;
}


void SingleFreqDFT_destroy(SingleFreqDFT *self) {
    free(self->window);
    free(self->twiddleLookup);
}


void SingleFreqDFT_setFreq(SingleFreqDFT *self, float normFreq) {
    float phaseDelta = TAU;
    
    // Calculate the twiddle factors for each time step
    for (int i = 0; i < self->size; i++) {
        float time = (float) i;
        float phase = phaseDelta + time * normFreq;
        self->twiddleLookup[i] = CMPLX(self->window[i], 0) * CMPLX(cosf(phase), sinf(phase));
    }
}


float complex SingleFreqDFT_run(SingleFreqDFT *self, float *samples) {
    float complex dft = CMPLX(0, 0);
    for (int i = 0; i < self->size; i++) {
        dft += CMPLX(samples[i], self->twiddleLookup[i]);
    }
    return dft;
}
