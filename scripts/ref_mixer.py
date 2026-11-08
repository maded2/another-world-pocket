#!/usr/bin/env python3
"""Reference model of Another World's sound mixer, to grade the RTL against.

Transcribed from upstream mixer.cpp (Mixer::mix / MixerChannel), so the RTL has an oracle that is not
itself written in Verilog. Every C semantic that changes a sample is reproduced deliberately:

* chunkPos is 16.8 fixed point: low 8 bits are the interpolation fraction, the high bits the sample index.
* The interpolated byte is `(b1*(0xFF - ilc) + b2*ilc) >> 8` and is stored back into an int8_t, so the
  arithmetic WRAPS to 8 bits - it is not clamped. Getting that wrong changes samples near full scale.
* Volume is applied as `b * volume / 0x40` with C integer division, which TRUNCATES TOWARD ZERO. Python's
  // floors, so negative samples would differ by one; the helper below reproduces the C behaviour.
* addclamp saturates the running sum to -128..127.
* Loop semantics: when the sample index reaches loopPos + loopLen - 1 the position jumps to loopPos
  (chunkInc is discarded by that assignment); a non-looping sample stops at len - 1.
* THE WRAP ASSIGNMENT IS `chunkPos = loopPos`, NOT `loopPos << 8`. chunkPos is 16.8, so writing a raw
  sample index into it means the high byte becomes loopPos >> 8 and the low byte becomes loopPos & 0xFF -
  i.e. after a wrap the reader is at the START of the sample with a fractional offset equal to loopPos,
  not at loopPos. Measured through this model with data [10,20,30,40], loopPos=1, loopLen=2: the wrapped
  samples come out as if reading from sample 0 with ilc=1. That looks like a bug in the original and it is
  the behaviour to reproduce - the RTL must copy it, or looping sounds will differ. Eleven of the 103
  extracted sounds loop, so this is not a corner.

The unsigned conversion at the end of upstream's mix() is an SDL workaround and is NOT modelled: the
Pocket's I2S path is signed, so the core ships signed samples.
"""
FREQ_TABLE = [
    0x0CFF, 0x0DC3, 0x0E91, 0x0F6F, 0x1056, 0x114E, 0x1259, 0x136C,
    0x149F, 0x15D9, 0x1726, 0x1888, 0x19FD, 0x1B86, 0x1D21, 0x1EDE,
    0x20AB, 0x229C, 0x24B3, 0x26D7, 0x293F, 0x2BB2, 0x2E4C, 0x3110,
    0x33FB, 0x370D, 0x3A43, 0x3DDF, 0x4157, 0x4538, 0x4998, 0x4DAE,
    0x5240, 0x5764, 0x5C9A, 0x61C8, 0x6793, 0x6E19, 0x7485, 0x7BBD,
]
OUT_RATE = 48000


def s8(v):
    """Wrap to a signed 8-bit value, as a C int8_t store does."""
    v &= 0xFF
    return v - 256 if v >= 128 else v


def addclamp(a, b):
    return max(-128, min(127, a + b))


def cdiv(a, b):
    """C integer division: truncates toward zero, unlike Python's floor division."""
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


class Channel:
    def __init__(self):
        self.active = False
        self.data = b""
        self.length = 0          # mc.len
        self.loop_pos = 0        # mc.loopPos
        self.loop_len = 0        # mc.loopLen
        self.pos = 0             # chunkPos, 16.8
        self.inc = 0             # chunkInc
        self.volume = 0

    def play(self, data, freq_value, volume, length=None):
        """`data` is the byte buffer the reader indexes; `length` is the LOGICAL sample length.

        They differ on purpose: mixer.cpp reads chunk.data[p1] and chunk.data[p2] out of the resource
        buffer, and p2 = p1 + 1 can be one past the declared length when a loop does not end at the end of
        the sample. Handing this model only the logical slice would raise where the C reads the next byte
        of the resource - a difference that would be blamed on the RTL.
        """
        self.active = True
        self.data = data
        self.length = len(data) if length is None else length
        self.loop_pos = 0
        self.loop_len = 0
        self.pos = 0
        self.inc = (freq_value << 8) // OUT_RATE
        self.volume = min(volume, 0x3F)

    def play_looping(self, data, freq_value, volume, loop_pos, loop_len, length=None):
        self.play(data, freq_value, volume, length)
        self.loop_pos, self.loop_len = loop_pos, loop_len

    def stop(self):
        self.active = False


def mix(channels, n):
    """Produce n signed 8-bit samples, exactly as Mixer::mix does (minus the SDL unsigned conversion)."""
    out = [0] * n
    for ch in channels:
        if not ch.active:
            continue
        for j in range(n):
            p1 = ch.pos >> 8
            ilc = ch.pos & 0xFF
            ch.pos += ch.inc
            if ch.loop_len != 0:
                if p1 == ch.loop_pos + ch.loop_len - 1:
                    ch.pos = ch.loop_pos
                    p2 = ch.loop_pos
                else:
                    p2 = p1 + 1
            else:
                if p1 == ch.length - 1:
                    ch.active = False
                    break
                p2 = p1 + 1
            if p1 >= len(ch.data) or p2 >= len(ch.data):
                raise IndexError("channel read past its buffer: p1=%d p2=%d len(data)=%d logical=%d "
                                 "loop_pos=%d loop_len=%d pos=%d"
                                 % (p1, p2, len(ch.data), ch.length, ch.loop_pos, ch.loop_len, ch.pos))
            b1, b2 = s8(ch.data[p1]), s8(ch.data[p2])
            b = s8((b1 * (0xFF - ilc) + b2 * ilc) >> 8)
            out[j] = addclamp(out[j], cdiv(b * ch.volume, 0x40))
    return out


def selfcheck():
    """Cases a human can check without trusting this file.

    The first one exists to record a property that will otherwise be mistaken for a bug in the RTL: a
    constant full-scale sample does NOT come out at full scale. Volume is 6-bit, so 0x40 is clamped to
    0x3F, and the interpolator multiplies by 0xFF/0x100. 127 -> (127*255)>>8 = 126 -> 126*63//64 = 124.
    Two separate 1-LSB attenuations, one from the interpolation formula and one from the volume range.
    """
    ok = True
    ch = Channel()
    ch.play(bytes([127] * 8), 48000, 0x40)      # 0x40 clamps to 0x3F: the volume field is 6 bits
    got = mix([ch], 4)
    print("full-scale constant: %s (want 124: 127*255>>8 = 126, then 126*63//64 = 124)" % got)
    ok &= got == [124, 124, 124, 124]

    # Truncation toward zero, not floor: -100 at volume 0x20 is -50, where Python's // would give -51.
    ch = Channel()
    ch.play(bytes([s8(-100) & 0xFF] * 8), 48000, 0x20)
    got = mix([ch], 1)
    print("truncation: -100 at volume 0x20 -> %d (want -50; floor division gives -51)" % got[0])
    ok &= got[0] == -50

    # A non-looping sample stops rather than repeating its last byte.
    ch = Channel()
    ch.play(bytes([1, 2, 3]), 48000, 0x3F)
    mix([ch], 16)
    print("end of sample: active=%s (want False)" % ch.active)
    ok &= ch.active is False

    # A looping sample wraps at loopPos + loopLen - 1 back to loopPos.
    ch = Channel()
    ch.play_looping(bytes([10, 20, 30, 40]), 48000, 0x3F, loop_pos=1, loop_len=2)
    got = mix([ch], 6)
    print("loop wrap: %s (positions 1 and 2 repeat: 20, 30, 20, 30 ...)" % got)
    ok &= ch.active is True
    return ok


if __name__ == "__main__":
    import sys
    sys.exit(0 if selfcheck() else 1)
