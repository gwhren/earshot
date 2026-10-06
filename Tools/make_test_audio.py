#!/usr/bin/env python3
"""Writes a WAV of speech-like bursts separated by pauses, for exercising Earshot
without a microphone. For real speech on a Mac, use `say` instead:

    say -v Monica -o hola.aiff "Hola a todos. Bienvenidos a la demostración."
    afconvert -f WAVE -d LEI16@16000 hola.aiff hola.wav
"""

import math
import random
import struct
import sys
import wave


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "speech.wav"
    rate = 16_000
    random.seed(1)
    pieces = [("pause", 1.0), ("voice", 1.6), ("pause", 1.2), ("voice", 2.2), ("pause", 1.2), ("voice", 1.0), ("pause", 1.5)]
    frames = bytearray()
    for kind, seconds in pieces:
        for index in range(int(seconds * rate)):
            if kind == "voice":
                envelope = 0.6 + 0.4 * math.sin(2 * math.pi * 4 * index / rate)
                value = 0.3 * envelope * math.sin(2 * math.pi * 220 * index / rate)
            else:
                value = random.uniform(-0.0005, 0.0005)
            frames += struct.pack("<h", int(max(-1.0, min(1.0, value)) * 32767))
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(bytes(frames))
    print(path)


if __name__ == "__main__":
    main()
