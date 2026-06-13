// Package songgen transcribes Merlin's sounds from the (accurate, full
// speed) Go core into a compact table the C64 port plays back on SID.
//
// Each sound is a short sequence of square-wave notes. We drive the
// machine, watch the speaker line, and for every "episode" (a burst of
// notes separated by silence) record:
//
//   - a signature: the ROM caller that invoked the shared tone routine
//     (page + return address), which the C64 reads as tPB:tSR to know
//     *which* sound is starting; and
//   - the notes: each note's half-period (instructions between toggles,
//     used to index the C64's freq table) and its duration converted to
//     player frames (~16 ms each).
//
// Build() returns a binary blob:
//
//	[0]              NSONGS
//	[1 + i*4 .. ]    per song: callerPB, callerSR, offLo, offHi
//	                 (offset from blob start to that song's note data)
//	[data]           per song: (half, frames) pairs, $00 terminator
//
// The blob is byte-identical for the gen tool and the tests (one ROM,
// deterministic), so both produce the same bytes.
package songgen

import (
	"sort"
	"sync"

	"github.com/carledwards/lets-go-merlin/pkg/merlin"
	"github.com/carledwards/lets-go-merlin/roms"
)

const (
	instrHz     = 58333.0   // real TMS1100 instruction rate
	c64clk      = 1022727.0 // C64 system clock (NTSC); PAL is ~4% slower
	frameCycles = 16384.0   // CIA cycles per player frame (~16 ms)
	tonePage    = 0xE       // ROM page holding the shared tone routine

	gapMax  = 800  // half-period (instructions) still part of one note
	tolPct  = 25   // % half-period change that splits one note from the next
	epGap   = 6000 // silence (instructions) that ends a sound episode
	minTogs = 4    // ignore tones with fewer toggles (noise)
	maxNote = 32   // cap notes per song
)

// instrPerFrame is how many TMS instructions one ~16 ms player frame lasts.
const instrPerFrame = instrHz * frameCycles / c64clk

type note struct{ half, frames byte }

type song struct {
	pb, sr byte
	notes  []note
}

var (
	once   sync.Once
	cached []byte
)

// Build returns the song blob (see package doc). Cached after the first
// call so repeated test use doesn't re-run the emulator.
func Build() []byte {
	once.Do(func() { cached = build() })
	return cached
}

func build() []byte {
	m, err := merlin.New(roms.MP3404)
	if err != nil {
		panic(err)
	}
	c := newCapturer(m)

	run := func(n int) {
		for i := 0; i < n; i++ {
			m.Step()
			c.tick(m)
		}
	}
	tap := func(b merlin.Button) {
		m.Press(b)
		run(30_000)
		m.Release(b)
		run(220_000)
	}

	run(700_000) // power-on jingle
	tap(merlin.BtnNewGame)
	for _, pad := range []merlin.Button{merlin.Pad1, merlin.Pad2, merlin.Pad3,
		merlin.Pad4, merlin.Pad5, merlin.Pad6} {
		tap(merlin.BtnNewGame)
		tap(pad)
	}
	tap(merlin.Pad5)
	tap(merlin.BtnHitMe)
	tap(merlin.BtnCompTurn)

	return encode(c.songs())
}

// capturer groups speaker edges into episodes tagged by caller signature.
type capturer struct {
	step           int
	prevHigh       bool
	prevPA, prevPC byte
	callPA, callPC byte // most recent jump into the tone page

	lastStep int
	cur      *episode
	eps      []*episode
}

type episode struct {
	pb, sr byte
	edges  []edgeT
}

type edgeT struct{ step, gap int }

func newCapturer(m *merlin.Machine) *capturer {
	return &capturer{prevHigh: m.SpeakerHigh()}
}

func (c *capturer) tick(m *merlin.Machine) {
	cpu := m.CPU()
	pa, pc := cpu.PA(), cpu.PC()
	if pa == tonePage && c.prevPA != tonePage {
		c.callPA, c.callPC = c.prevPA, c.prevPC // the call site into the tone page
	}

	high := m.SpeakerHigh()
	if high != c.prevHigh {
		gap := c.step - c.lastStep
		if c.cur == nil || gap > epGap {
			// New episode: signature is the caller (page, return = callPC+1).
			c.cur = &episode{pb: c.callPA, sr: c.callPC + 1}
			c.eps = append(c.eps, c.cur)
		}
		c.cur.edges = append(c.cur.edges, edgeT{step: c.step, gap: gap})
		c.lastStep = c.step
		c.prevHigh = high
	}
	c.prevPA, c.prevPC = pa, pc
	c.step++
}

// keep is the whitelist of caller signatures we emit. Only self-contained,
// always-identical tunes belong here: the power-on / New Game jingle is the
// same melody every time, so a canned SID copy is faithful. The keypad and
// game-select callers produce *context-varying* tones in the ROM (different
// pitches per game/pad), so a single canned transcription would be wrong —
// they fall back to the pitch-correct passthrough instead. Add a signature
// here only once it's a fixed tune (e.g. a verified win/lose jingle).
var keep = map[[2]byte]bool{
	{0xF, 0x21}: true, // power-on / New Game rising triad
}

// songs segments every episode into notes and keeps the first whitelisted
// song seen for each distinct caller signature.
func (c *capturer) songs() []song {
	seen := map[[2]byte]bool{}
	var out []song
	for _, ep := range c.eps {
		key := [2]byte{ep.pb, ep.sr}
		if !keep[key] || seen[key] {
			continue
		}
		ns := segment(ep.edges)
		if len(ns) == 0 {
			continue
		}
		seen[key] = true
		out = append(out, song{pb: ep.pb, sr: ep.sr, notes: ns})
	}
	// Stable order by signature for deterministic output.
	sort.Slice(out, func(i, j int) bool {
		if out[i].pb != out[j].pb {
			return out[i].pb < out[j].pb
		}
		return out[i].sr < out[j].sr
	})
	return out
}

// segment turns an episode's edges into notes (same rule as soundcap: a
// note ends on a silence gap or a half-period change), converting each
// note's duration to player frames.
func segment(es []edgeT) []note {
	var out []note
	i := 0
	for i < len(es) && len(out) < maxNote {
		start := i
		i++
		ref, sum, cnt := 0, 0, 0
		for i < len(es) && es[i].gap <= gapMax {
			g := es[i].gap
			if ref == 0 {
				ref = g
			} else if abs(g-ref)*100 > ref*tolPct {
				break
			}
			sum += g
			cnt++
			i++
		}
		if cnt == 0 || cnt+1 < minTogs {
			continue
		}
		half := sum / cnt
		if half > 255 {
			half = 255
		}
		durInstr := es[i-1].step - es[start].step
		frames := int(float64(durInstr)/instrPerFrame + 0.5)
		if frames < 1 {
			frames = 1
		}
		if frames > 255 {
			frames = 255
		}
		out = append(out, note{half: byte(half), frames: byte(frames)})
	}
	return out
}

func encode(songs []song) []byte {
	n := len(songs)
	header := 1 + n*4
	out := make([]byte, header)
	out[0] = byte(n)
	off := header
	for i, s := range songs {
		out[1+i*4] = s.pb
		out[1+i*4+1] = s.sr
		out[1+i*4+2] = byte(off)
		out[1+i*4+3] = byte(off >> 8)
		for _, nt := range s.notes {
			out = append(out, nt.half, nt.frames)
		}
		out = append(out, 0)
		off += len(s.notes)*2 + 1
	}
	return out
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
