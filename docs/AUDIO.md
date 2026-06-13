# Merlin audio on the C64 — how it works and what's hard

Merlin has no sound chip. The TMS1100 makes every tone by toggling a
single output pin — the speaker line, `O` bit 0 — as a square wave. The
*pitch* is the toggle rate; the *duration and rhythm* are produced by the
ROM busy-waiting in instruction-counting delay loops. There is no note
data anywhere: sound is an emergent side effect of how fast the ROM flips
that pin.

## The core problem: we run ~6× too slow

Real Merlin executes ~58,000 TMS instructions/second. Our interpreter, a
TMS1100 emulator written in 6502 running on a 1 MHz C64, manages ~10,000.
Since both pitch and rhythm are timed in *instructions*, naively
reproducing the speaker pin would come out ~6× too low and ~6× too slow —
a droning, drawn-out mess.

We can't close that gap: the interpreter is already tuned (~100 cycles per
TMS instruction), and a 1 MHz 6502 can't emulate a 350 kHz TMS1100 in real
time. So the audio strategy works *around* the speed gap rather than
fixing it.

## Two layers

The `USE_HLE` constant in `merlin.s` selects between them (set it to 0 for
pure passthrough).

### 1. Passthrough (the fallback)

At the one place the speaker line changes (`hTDO`), we measure each
toggle's half-period in instructions and play the matching pitch on a SID
pulse voice. `half-period → SID frequency` is a generated lookup table
(`sidfreq.bin`), so there is no run-time division.

The win: **SID has its own oscillator**, so the *pitch is correct* no
matter how slow the interpreter runs — we've offloaded waveform generation
to hardware. The catch: **tempo is still stretched** ~6×, because *when*
notes start and stop is still driven by the slow ROM. Passthrough sounds
recognizable but drawn-out.

### 2. Override / HLE (the good path)

Every Merlin tone is emitted by *one shared ROM routine*. The TMS1100 has
a one-deep call stack, so when that routine runs, the *caller* it will
return to sits in `tPB:tSR` — and that caller identifies which higher-level
sound is playing. (`soundcap` reverse-engineered this; `$F:$21` is the
power-on / New Game jingle, etc.)

So `songgen` drives the accurate Go core, watches the speaker, and
transcribes each whitelisted sound into a note table (`songs.bin`:
per-song caller signature + `(half-period, frames)` notes). This is the
"sample it and convert to MIDI" idea, done from ground truth instead of by
ear. At run time, when the ROM enters its tone routine we look the caller
up; on a hit we play the transcribed tune on SID **in real time** — clocked
by a chained CIA #2 timer (steady ~16 ms frames, independent of the wobbly
interpreter), and mute the ROM's stretched version until it goes quiet.
Pitch *and* tempo are correct.

## Why we can't just "can" everything

Canning only works for a sound that is **a fixed melody — identical every
time**. Most Merlin sounds aren't:

- **Power-on / New Game jingle** — always the same rising triad. *Cannable*
  (and currently the only entry in `songgen`'s `keep` whitelist).
- **Win / lose jingles** — fixed tunes, but only triggered during real
  play, so they aren't captured yet. *Cannable once captured.*
- **Keypad / per-pad tones, Echo, Music Machine** — **generated at
  runtime**: Echo plays a *random* sequence that differs every game, Music
  Machine plays whatever you press, and a lit pad plays its own pitch from
  game state. The *same* ROM caller emits *different* pitches depending on
  context, so a single canned transcription is simply wrong (that was the
  "odd triple beep" on game-select — one canned blip standing in for many
  context-varying tones). These **must** stay live (passthrough).

So the rule is: **can the fixed tunes, synthesize the dynamic ones live.**
Add a signature to the `keep` set only once it's verified to be a fixed
tune.

## The residual limitation

Dynamic sounds play through passthrough, which gets pitch right but tempo
stretched. The only ways to improve *those* would be:

- give each live note a fixed short SID envelope so its *duration* is
  right (helps the "drawn out" feel, though note *spacing* stays stretched
  by the slow interpreter); or
- fast-forward the ROM's delay loops so the sound stretches run closer to
  real time — a larger, riskier change.

Neither is implemented. Today: the jingle is crisp and correct; everything
else is pitch-correct but slow. That is the documented state of the audio.

## PAL / NTSC

`sidfreq.bin` is built with the PAL SID clock (985248 Hz). On an NTSC
machine pitches read ~4% sharp. Making it switchable is a small change if
it ever matters.

## Tools

- `soundcap/` — prints the human-readable catalog (pitch, duration, caller
  signatures) and the code-context analysis used to design all this.
- `songgen/` — transcribes whitelisted sounds into `songs.bin`.
