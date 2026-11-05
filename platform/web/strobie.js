// Copyright (C) 2026  Davorin Šego
// Licensed under the GPL v3, see LICENSE

// Starts strobie.wasm with odin.js, see src/gfx/web.odin. What Odin's runtime doesn't have comes from here:
// the microphone for src/audio/web.odin.
(function () {
    "use strict";

    const memory = new odin.WasmMemoryInterface();

    // The same numbers as InputState in src/audio/web.odin
    const INPUT_STATES = {
        CLOSED: 0,
        OPENING: 1,
        WAITING_FOR_TAP: 2,
        RUNNING: 3,
        DENIED: 4,
        FAILED: 5,
    };

    // Samples waiting for the next frame, half a second at most: a page in the background gets no frames
    const MAX_WAITING_S = 0.5;

    const input = {
        state: INPUT_STATES.CLOSED,
        context: null,
        stream: null,
        capture: null, // the worklet's node, closing the input stops the chunks it still had on the way
        chunks: [], // Float32Arrays from the worklet, the first one read from offset on
        offset: 0,
        waiting: 0, // samples in chunks
        hidden: false, // closed because the page was hidden, opened again when it shows
        opening: 0, // counts the openings, one closed meanwhile lets its microphone go
    };

    // The microphone without the browser's processing for calls, at the rate it runs at. again is after the
    // page was hidden: the browser may want a tap for that, which isn't the permission being off.
    async function openInput(again = false) {
        if (input.state == INPUT_STATES.OPENING || input.state == INPUT_STATES.RUNNING) return;

        closeInput();
        input.opening += 1;
        const opening = input.opening;
        input.state = INPUT_STATES.OPENING;
        console.log("Asking for the microphone");
        let stream;
        try {
            stream = await navigator.mediaDevices.getUserMedia({
                audio: {
                    echoCancellation: false,
                    noiseSuppression: false,
                    autoGainControl: false,
                    channelCount: 1,
                },
            });
        } catch (error) {
            console.log("No microphone:", error);
            if (opening != input.opening) return;

            if (error.name != "NotAllowedError") input.state = INPUT_STATES.FAILED;
            else input.state = again ? INPUT_STATES.WAITING_FOR_TAP : INPUT_STATES.DENIED;
            return;
        }
        if (opening != input.opening) {
            stream.getTracks().forEach((track) => track.stop());
            return;
        }
        input.stream = stream;

        try {
            // At the microphone's own rate, the browser would resample it to the output's
            const rate = input.stream.getAudioTracks()[0].getSettings().sampleRate;
            input.context = rate ? new AudioContext({ sampleRate: rate }) : new AudioContext();
            await input.context.audioWorklet.addModule("capture-worklet.js");
            if (opening != input.opening) return;

            const source = input.context.createMediaStreamSource(input.stream);
            const capture = new AudioWorkletNode(input.context, "strobie-capture", {
                numberOfInputs: 1,
                numberOfOutputs: 0,
                channelCount: 1,
                channelCountMode: "explicit",
            });
            capture.port.onmessage = (message) => keepChunk(message.data);
            input.capture = capture;
            source.connect(capture);
        } catch (error) {
            console.log("The input didn't open:", error);
            if (opening != input.opening) return;

            closeInput();
            input.state = INPUT_STATES.FAILED;
            return;
        }

        console.log(`Microphone open at ${input.context.sampleRate} Hz`);
        followContextState();
        input.context.onstatechange = followContextState;
    }

    function followContextState() {
        if (!input.context) return;

        input.state = input.context.state == "running" ? INPUT_STATES.RUNNING : INPUT_STATES.WAITING_FOR_TAP;
        console.log(`Audio ${input.context.state}`);
    }

    function closeInput() {
        input.opening += 1;
        if (input.stream) input.stream.getTracks().forEach((track) => track.stop());
        if (input.context) input.context.close();
        if (input.capture) input.capture.port.onmessage = null;

        input.stream = null;
        input.context = null;
        input.capture = null;
        input.state = INPUT_STATES.CLOSED;
        dropWaiting();
    }

    function keepChunk(chunk) {
        input.chunks.push(chunk);
        input.waiting += chunk.length;

        const max = MAX_WAITING_S * input.context.sampleRate;
        while (input.waiting - input.chunks[0].length >= max) {
            input.waiting -= input.chunks[0].length - input.offset;
            input.chunks.shift();
            input.offset = 0;
        }
    }

    function dropWaiting() {
        input.chunks = [];
        input.offset = 0;
        input.waiting = 0;
    }

    function takeSamples(buffer, capacity) {
        const out = memory.loadF32Array(buffer, capacity);
        let count = 0;
        while (count < capacity && input.chunks.length > 0) {
            const chunk = input.chunks[0];
            const taken = Math.min(capacity - count, chunk.length - input.offset);
            out.set(chunk.subarray(input.offset, input.offset + taken), count);
            count += taken;
            input.offset += taken;
            input.waiting -= taken;

            if (input.offset == chunk.length) {
                input.chunks.shift();
                input.offset = 0;
            }
        }
        return count;
    }

    // The browser starts audio only after a tap or a key, and may want one to open the microphone again after
    // the page was hidden. Refused on a tap, the permission is off.
    function resumeInput() {
        if (input.context && input.context.state == "suspended") input.context.resume();
        else if (!input.context && input.state == INPUT_STATES.WAITING_FOR_TAP) openInput();
    }
    window.addEventListener("pointerdown", resumeInput, true);
    window.addEventListener("keydown", resumeInput, true);

    // Hidden, the microphone is let go: nothing runs for a page in the background and the browser's recording
    // light goes off. Shown again it's opened again, or waits for a tap where the browser wants one for that.
    document.addEventListener("visibilitychange", () => {
        if (document.hidden) {
            const open = input.state == INPUT_STATES.OPENING || input.state == INPUT_STATES.RUNNING || input.state == INPUT_STATES.WAITING_FOR_TAP;
            closeInput();
            input.hidden = open;
        } else if (input.hidden) {
            input.hidden = false;
            openInput(true);
        }
    });

    const imports = {
        strobie_audio: {
            open_input: () => {
                openInput();
            },
            close_input: closeInput,
            input_state: () => input.state,
            input_rate: () => (input.context ? input.context.sampleRate : 0),
            take_samples: takeSamples,
        },
    };

    odin.runWasm("strobie.wasm", null, imports, memory);
})();
