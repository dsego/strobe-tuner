// Copyright (C) 2026  Davorin Šego
// Licensed under the GPL v3, see LICENSE

// Starts strobie.wasm with odin.js, see src/gfx/web.odin. What Odin's runtime doesn't have comes from here:
// the microphone for src/audio/web.odin and the config's storage for src/app/web.odin.
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
        chunks: [], // Float32Arrays from the worklet, the first one read from offset on
        offset: 0,
        waiting: 0, // samples in chunks
    };

    // The microphone without the browser's processing for calls, at the rate it runs at
    async function openInput() {
        if (input.state == INPUT_STATES.OPENING || input.state == INPUT_STATES.RUNNING) return;

        closeInput();
        input.state = INPUT_STATES.OPENING;
        console.log("Asking for the microphone");
        try {
            input.stream = await navigator.mediaDevices.getUserMedia({
                audio: {
                    echoCancellation: false,
                    noiseSuppression: false,
                    autoGainControl: false,
                    channelCount: 1,
                },
            });
        } catch (error) {
            console.log("No microphone:", error);
            input.state = error.name == "NotAllowedError" ? INPUT_STATES.DENIED : INPUT_STATES.FAILED;
            return;
        }

        try {
            // At the microphone's own rate, the browser would resample it to the output's
            const rate = input.stream.getAudioTracks()[0].getSettings().sampleRate;
            input.context = rate ? new AudioContext({ sampleRate: rate }) : new AudioContext();
            await input.context.audioWorklet.addModule("capture-worklet.js");

            const source = input.context.createMediaStreamSource(input.stream);
            const capture = new AudioWorkletNode(input.context, "strobie-capture", {
                numberOfInputs: 1,
                numberOfOutputs: 0,
                channelCount: 1,
                channelCountMode: "explicit",
            });
            capture.port.onmessage = (message) => keepChunk(message.data);
            source.connect(capture);
        } catch (error) {
            console.log("The input didn't open:", error);
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
        if (input.stream) input.stream.getTracks().forEach((track) => track.stop());
        if (input.context) input.context.close();

        input.stream = null;
        input.context = null;
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

    // The browser starts audio only after a tap or a key
    function resumeInput() {
        if (input.context && input.context.state == "suspended") input.context.resume();
    }
    window.addEventListener("pointerdown", resumeInput, true);
    window.addEventListener("keydown", resumeInput, true);

    // Hidden, the page gets no frames to take them
    document.addEventListener("visibilitychange", () => {
        if (document.hidden) dropWaiting();
    });

    const CONFIG_KEY = "strobie.config";

    function storedConfig() {
        try {
            return localStorage.getItem(CONFIG_KEY);
        } catch (error) {
            return null;
        }
    }

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
        strobie_storage: {
            // In UTF-8 bytes, -1 without one
            config_length: () => {
                const config = storedConfig();
                return config == null ? -1 : new TextEncoder().encode(config).length;
            },
            load_config_text: (buffer, capacity) => {
                const bytes = new TextEncoder().encode(storedConfig() ?? "");
                const count = Math.min(bytes.length, capacity);
                memory.loadU8Array(buffer, count).set(bytes.subarray(0, count));
                return count;
            },
            save_config_text: (text, length) => {
                try {
                    localStorage.setItem(CONFIG_KEY, memory.loadString(text, length));
                } catch (error) {
                    console.log("The config wasn't saved:", error);
                }
            },
        },
    };

    odin.runWasm("strobie.wasm", null, imports, memory);
})();
