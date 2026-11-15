# Another World for the Analogue Pocket — v1.0.0

The first public release: the original Another World engine running on the Analogue Pocket, with
the game's own sound effects and music, and working chapter switching.

This archive contains **the core and its platform only**. It deliberately contains **no game data** —
no ROM, no packs, no dataslot image. Another World is a commercial game; you need your own copy.

## What you need

- An Analogue Pocket with an up-to-date openFPGA firmware.
- **Another World, PC (DOS) version** — you must own it.

## Install

1. Copy `Cores/` and `Platforms/` from this archive to the **root of the Pocket's microSD card**.
   Merge with what is there; do not replace the folders.
2. Build the game image from your own copy of the data:

   ```bash
   git clone https://github.com/maded2/another-world-pocket
   cd another-world-pocket
   mkdir -p gamedata && cp /path/to/your/anotherworld/{bank*,memlist.bin} gamedata/
   make image          # once: the Quartus build image (~15 GB)
   make rom            # -> build/aw-all-audio.bin, verified byte-for-byte
   ```

   `make rom` prints the image's size and sha256. (No build tools on the machine you play from?
   Build it anywhere with Docker and copy the single file across.)
3. Put the image on the card at:

   ```
   Assets/anotherworld/common/aw-all-audio.bin
   ```

4. On the Pocket: **openFPGA → Another World**, then in the core's menu choose the dataslot file
   **`aw-all-audio.bin`** and launch.

## What works

- **The whole game in one file.** One dataslot upload carries all eight parts (3.64 MiB): the eight
  2 MiB views share their identical 32 KiB frames in a pool, so the game plus its audio fits
  comfortably inside what the framework will load.
- **Picture** — the original renderer at 320×200, 4:3, 60 Hz.
- **Sound** — the original 4-channel 8-bit mixer at 48 kHz over I2S, including looping samples.
- **Music** — the game's music modules played by an RTL tracker, verified sample-for-sample against
  a transcription of the original player.
- **Chapters** — the game asks for the next chapter itself, exactly as on the original machine, and
  `Game part` in the OSD can move between parts **while the game is running**: the switch restarts
  the VM cleanly and renders the new chapter. No upload, no relaunch.
- **Controls** — D-pad to move, A or B to act. Single player; the Dock is declared, analog output is
  not. Save states are not supported.

## Known issues

- Menu music/effects timing is sample-accurate at the module's 8 ms row rate; at one faster row rate
  (4 ms) a small number of samples differ by ±1 from the reference renderer. Not audible, tracked in
  the port log.
- Only a few hardware runs have exercised a mid-game chapter change so far; a long soak is the next
  thing worth doing rather than a defect we know of.

## Checksums (v1.0.0)

| file | sha256 |
|---|---|
| `another-world-pocket-v1.0.0.zip` | `cd3b59bddf89926c97a789a1527b893c96a6745a8b3e267c3d3270cc18d09493` |
| `Cores/Eddie Chan.Another World/bitstream.rbf_r` | `8badd5210d28b0034a78965ee323ac6cb261e9b8bd552db8236a37d8740f05a3` |

The bitstream announces itself as **AW 1065** on the console line (`AW 1065a up`, 115200 baud on the
Pocket's USB-C debug port).

## Credits and licence

- Core, RTL additions and build scripts: **MIT** (see `LICENSE`), © 2026 Eddie Chan.
- The engine implementation is [sylefeb/a5k](https://github.com/sylefeb/a5k) (MIT), a Silice port of
  the original interpreter and renderer.
- **Another World** / *Out of This World* is © Delphine Software International, designed by Éric
  Chahi. All game data, graphics, sound and music remain the property of their owners and are **not**
  distributed here.
- Unofficial, non-commercial port; not affiliated with or endorsed by Analogue, Delphine Software or
  Éric Chahi.
