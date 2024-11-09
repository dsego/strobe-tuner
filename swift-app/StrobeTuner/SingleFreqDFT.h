//
//  SingleFreqDFT.h
//  StrobeTuner
//
//  Created by Davorin on 09.11.2024..
//

#ifndef SingleFreqDFT_h
#define SingleFreqDFT_h

#include <stdio.h>
#include <complex.h>


typedef struct {
    int size;
    float *window;  // eg Blackmann window
    float complex *twiddleLookup;
} SingleFreqDFT;


SingleFreqDFT SingleFreqDFT_init(int size);

void SingleFreqDFT_setFreq(SingleFreqDFT *self, float normFreq);

void SingleFreqDFT_destroy(SingleFreqDFT *self);

float complex SingleFreqDFT_run(SingleFreqDFT *self, float *samples);

#endif /* SingleFreqDFT_h */
