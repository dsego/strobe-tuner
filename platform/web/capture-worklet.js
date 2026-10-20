// Copyright (C) 2026  Davorin Šego
// Licensed under the GPL v3, see LICENSE

// On the audio thread: the microphone's samples in chunks to the page's thread, see strobie.js. A render
// quantum is 128 samples, a few go together so the page isn't sent hundreds of messages a second.
const CHUNK_SAMPLES = 256;

class StrobieCapture extends AudioWorkletProcessor {
    constructor() {
        super();
        this.chunk = new Float32Array(CHUNK_SAMPLES);
        this.filled = 0;
    }

    process(inputs) {
        // The first channel, a mono microphone's only one. Nothing while the input isn't connected.
        const channel = inputs[0] && inputs[0][0];
        if (!channel) return true;

        let read = 0;
        while (read < channel.length) {
            const count = Math.min(channel.length - read, CHUNK_SAMPLES - this.filled);
            this.chunk.set(channel.subarray(read, read + count), this.filled);
            this.filled += count;
            read += count;

            if (this.filled == CHUNK_SAMPLES) {
                // Handed over, a new one for the next samples
                this.port.postMessage(this.chunk, [this.chunk.buffer]);
                this.chunk = new Float32Array(CHUNK_SAMPLES);
                this.filled = 0;
            }
        }
        return true;
    }
}

registerProcessor("strobie-capture", StrobieCapture);
