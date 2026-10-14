#!/usr/bin/env python3
"""生成 Resources/silence.wav —— 保活用的静音音频。

WAV / 16bit / 8kHz / 单声道 / 1 秒。纯静音，循环播放时完全不发声，
但足以让 iOS 认为 App 正在播放音频，从而获得后台运行时间。

用法：python3 Scripts/make_silence.py
"""
import os
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "silence.wav")

SECONDS = 1.0
RATE = 8000


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    frames = int(SECONDS * RATE)

    with wave.open(OUT, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(struct.pack("<%dh" % frames, *([0] * frames)))

    print("wrote %s (%d bytes)" % (OUT, os.path.getsize(OUT)))


if __name__ == "__main__":
    main()
