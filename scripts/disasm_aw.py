#!/usr/bin/env python3
"""Linear disassembler for the Another World bytecode, used to find the audio calls.

WHY A DISASSEMBLER AND NOT A SCAN: scanning every byte offset for 0x18/0x1A matched operands as if they
were opcodes - 1186 "playSound" sites with 308 distinct resource ids when only 103 sounds exist, freq
indices up to 255 where the mixer asserts < 40. The earlier part-change scan got away with it only because
0x3E8x is a rare 16-bit value.

The argument lengths are DERIVED from the interpreter (counted from fetchByte/fetchWord in vm.cpp's
op_* handlers, in the order of staticres.cpp's dispatch table), not guessed here.

Self-check: the VM itself treats an opcode with bits 7 and 6 clear and a value above 0x1A as invalid
(vm.si "op_invalid ... FATAL"), so a desync announces itself instead of producing plausible nonsense.
Opcodes with bit 6 or 7 set are legal to the VM but their lengths are not constant in the source, so this
walk reports them as UNKNOWN and stops there - coverage is stated as bytes decoded, not implied to be the
whole program.
"""
import struct
import sys

# opcode -> argument bytes, derived from vm.cpp (see the docstring).
ARGLEN = {
    0x00: 3, 0x01: 2, 0x02: 2, 0x03: 3, 0x04: 2, 0x05: 0, 0x06: 0, 0x07: 2,
    0x08: 3, 0x09: 3, 0x0B: 2, 0x0C: 3, 0x0D: 1, 0x0E: 2, 0x0F: 2,
    0x10: 1, 0x11: 0, 0x12: 5, 0x13: 2, 0x14: 3, 0x15: 3, 0x16: 3, 0x17: 3,
    0x18: 5, 0x19: 2, 0x1A: 5,
}
NAMES = {0x18: "playSound", 0x19: "updateMemList", 0x1A: "playMusic"}


def arglen(code, i):
    """Length of the instruction at i, or None if this walk cannot know it.

    0x0A op_condJmp is VARIABLE, and counting its fetchByte calls in vm.cpp gives 10 - which is wrong and
    desynced this walk at the first conditional in every part. Its real shape (vm.cpp op_condJmp):
        1  opcode 0x0A
        1  inner opcode (condition in bits 0-2, operand kind in bits 6-7)
        1  variable index
        1 or 2  operand: 1 if bit7 set (a variable index) or neither bit set (an immediate byte),
                         2 if bit6 set only (an immediate word)
        2  jump target
    """
    op = code[i]
    if op == 0x0A:
        if i + 2 >= len(code):
            return None
        inner = code[i + 1]
        return 1 + 1 + 1 + (2 if (inner & 0x40) and not (inner & 0x80) else 1) + 2
    if op & 0x80:
        # Inline polygon pseudo-opcode: opcode is the HIGH byte of a word offset, then the low byte,
        # then x and y. Fixed 4 bytes (vm.cpp executeThread, "1000 0000 is set").
        return 4
    if op & 0x40:
        # Inline polygon with a variable operand encoding: bits 5,4 pick how x is given (a high byte,
        # or a variable index, or nothing) and bits 3,2 do the same for y. Bit 0/1 decide whether zoom
        # is present - and in the two "zoom is implied" cases the interpreter DECREMENTS pc, so the
        # byte it fetched is really the next opcode and the instruction is one byte shorter. Derived
        # from vm.cpp's "0100 0000 is set" branch, not guessed.
        n = 1 + 2 + 1                                  # opcode, off word, x low
        if not (op & 0x20) and not (op & 0x10):
            n += 1                                     # x high byte
        n += 1                                         # y low
        if not (op & 0x08) and not (op & 0x04):
            n += 1                                     # y high byte
        n += 1                                         # the byte fetched as zoom
        if (not (op & 0x02) and not (op & 0x01)) or ((op & 0x02) and (op & 0x01)):
            n -= 1                                     # pc-- : that byte belongs to the next opcode
        return n
    a = ARGLEN.get(op)
    return None if a is None else 1 + a      # TOTAL instruction length: the opcode byte plus its args


def bytecode(path):
    d = open(path, "rb").read()
    offs = struct.unpack("<4I", d[0x1FFFE0:0x1FFFF0])   # four little-endian u32 segment offsets
    end = min(o for o in offs if o)
    return d[0:end]


def decode(code, i):
    """(total_length, [branch targets], falls_through) for the instruction at i.

    Branch semantics taken from vm.cpp: op_call/op_jmp carry a word target and change pc; op_jnz carries
    a var byte and a word target and either jumps or falls through; op_condJmp carries its target last and
    likewise falls through; op_ret returns to the caller (nothing static to follow); op_pauseThread ends
    the thread's turn and op_killThread parks pc at 0xFFFF, so both end a block.
    """
    op = code[i]
    n = arglen(code, i)
    if n is None:
        return None, [], False
    if op == 0x07:                                  # jmp
        return n, [(code[i+1] << 8) | code[i+2]], False
    if op == 0x04:                                  # call
        return n, [(code[i+1] << 8) | code[i+2]], True
    if op == 0x09:                                  # jnz: var byte then word target
        return n, [(code[i+2] << 8) | code[i+3]], True
    if op == 0x0A:                                  # condJmp: target is the last two bytes
        return n, [(code[i+n-2] << 8) | code[i+n-1]], True
    if op == 0x08:                                  # setSetVect: threadId byte, then the thread's PC
        # THIS is the entry model. vm.cpp op_setSetVect writes
        #   threadsData[REQUESTED_PC_OFFSET][threadId] = pcOffsetRequested
        # and checkThreadRequests later moves that into the thread's PC - so every thread entry point is a
        # constant in the instruction stream, and a walk that ignores it misses the whole body of any part
        # written as threads. That is exactly why parts 1 and 2 stopped after a dozen instructions at an
        # op_ret: their real code starts at a thread PC, not at offset 0.
        return n, [(code[i+2] << 8) | code[i+3]], True
    if op in (0x05, 0x06, 0x11):                    # ret / pauseThread / killThread
        return n, [], False
    return n, [], True


def walk(code):
    """Yield (offset, opcode) for every REACHABLE instruction, following branches.

    A linear walk cannot work on this bytecode: after a jump the following bytes can be inline data, which
    is why the earlier version always died on a byte in 0x1B..0x3F that the VM itself calls invalid. This
    seeds a worklist with the entry point and adds every branch/call target.
    """
    seen = set()
    stack = [0]
    while stack:
        i = stack.pop()
        while 0 <= i < len(code) and i not in seen:
            seen.add(i)
            n, targets, falls = decode(code, i)
            if n is None:
                yield ("unknown", i, code[i])
                break
            yield ("op", i, code[i])
            for t in targets:
                if t not in seen:
                    stack.append(t)
            if not falls:
                break
            i += n

def report(path):
    code = bytecode(path)
    sounds, music, memlist = [], [], []
    decoded = 0
    stop = None
    for kind, i, op in walk(code):
        if kind == "unknown":
            stop = (i, op)
            break
        decoded = i
        if op == 0x18:
            rid = (code[i+1] << 8) | code[i+2]
            sounds.append((i, rid, code[i+3], code[i+4], code[i+5]))
        elif op == 0x1A:
            num = (code[i+1] << 8) | code[i+2]
            delay = (code[i+3] << 8) | code[i+4]
            music.append((i, num, delay, code[i+5]))
        elif op == 0x19:
            memlist.append((i, (code[i+1] << 8) | code[i+2]))
    return code, decoded, stop, sounds, music, memlist


def main():
    packs = sys.argv[1:] or ["ports/another-world/packs/part%d.bin" % n for n in range(8)]
    for p in packs:
        code, decoded, stop, sounds, music, memlist = report(p)
        tag = p.split("/")[-1]
        print("%s: %d/%d bytes decoded%s" %
              (tag, decoded, len(code),
               "" if stop is None else "  STOPPED at 0x%X (opcode 0x%02X: legal to the VM, unknown length)"
               % stop))
        if sounds:
            ids = [s[1] for s in sounds]
            print("   playSound  %3d sites, %2d distinct ids (max %d), freq %d..%d, vol %d..%d, ch %s"
                  % (len(sounds), len(set(ids)), max(ids),
                     min(s[2] for s in sounds), max(s[2] for s in sounds),
                     min(s[3] for s in sounds), max(s[3] for s in sounds),
                     sorted(set(s[4] for s in sounds))))
        if music:
            print("   playMusic  %3d sites, ids %s" % (len(music), sorted(set(m[1] for m in music))))
        if memlist:
            print("   updateMem  %3d sites, %2d distinct ids (max %d)"
                  % (len(memlist), len(set(m[1] for m in memlist)), max(m[1] for m in memlist)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
