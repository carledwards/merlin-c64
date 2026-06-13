// Command soundcap reverse-engineers Merlin's sounds for the C64 port.
//
// Merlin has no sound chip: the TMS1100 makes tones by toggling one
// output pin (the speaker line = O bit 0) as a square wave, timed by
// instruction-counting delay loops. This tool drives the (fast) Go core
// through power-on and each game, watches that line, and segments the
// toggles into discrete notes — reporting each note's pitch, duration,
// toggle count, and the ROM PC/PA/CA where it started.
//
// The result is the catalog we need to decide how to resynthesize the
// sounds on the C64's SID at the correct pitch/tempo (the interpreter
// itself runs ~6x slower than real Merlin, so replaying the raw toggles
// would be ~6x too low and too slow).
//
//	go run ./soundcap            # full catalog to stdout
//	go run ./soundcap -gapmax 800 -tol 25   # tune segmentation
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/carledwards/lets-go-merlin/pkg/merlin"
	"github.com/carledwards/lets-go-merlin/roms"
)

// instrHz is the real TMS1100 instruction rate in Merlin (~350 kHz / 6
// cycles). All pitch/duration figures are reported as they would sound
// on real hardware, independent of how fast any emulator runs.
const instrHz = 58333.0

var (
	gapMax = flag.Int("gapmax", 800, "max half-period (instructions) still counted as a tone; larger = silence/rest")
	tolPct = flag.Int("tol", 25, "percent half-period change that splits one note from the next")
	minTog = flag.Int("mintoggles", 4, "ignore tones with fewer toggles than this (noise)")
)

// edge is one observed speaker-line transition.
type edge struct {
	step       int  // instruction index when it flipped
	gap        int  // instructions since the previous edge (= half-period)
	pc, pa, ca byte // ROM context at the flip
}

// note is a segmented run of edges at a consistent pitch.
type note struct {
	label      string
	startStep  int
	endStep    int
	toggles    int
	avgHalf    float64
	pc, pa, ca byte
}

// recorder watches the machine and collects edges, tagged by the current
// phase label.
type recorder struct {
	step     int
	prevHigh bool
	lastStep int
	label    string
	edges    map[string][]edge
	order    []string

	// Context: which ROM code drives each sound. tonePage is where the
	// shared toggle routine lives; drv collects the *other* pages running
	// while a sound is active (the melody driver), and call records the
	// (page,pc) just before the CPU first jumps into the tone page.
	tonePage byte
	lastTog  int
	prevPA   byte
	prevPC   byte
	drv      map[string]map[byte]bool
	call     map[string][2]byte
}

func newRecorder(m *merlin.Machine) *recorder {
	return &recorder{prevHigh: m.SpeakerHigh(), edges: map[string][]edge{},
		tonePage: 0xE, drv: map[string]map[byte]bool{}, call: map[string][2]byte{}}
}

func (r *recorder) tick(m *merlin.Machine) {
	c := m.CPU()
	pa, pc := c.PA(), c.PC()

	high := m.SpeakerHigh()
	if high != r.prevHigh {
		if _, seen := r.edges[r.label]; !seen {
			r.order = append(r.order, r.label)
		}
		r.edges[r.label] = append(r.edges[r.label], edge{
			step: r.step, gap: r.step - r.lastStep, pc: pc, pa: pa, ca: c.CA(),
		})
		r.lastStep = r.step
		r.lastTog = r.step
		r.prevHigh = high
	}

	// Capture the call site into the tone page, and the driver pages
	// active within ~3000 instructions of a toggle (a live sound).
	if pa == r.tonePage && r.prevPA != r.tonePage {
		if _, ok := r.call[r.label]; !ok {
			r.call[r.label] = [2]byte{r.prevPA, r.prevPC}
		}
	}
	if r.step-r.lastTog < 3000 && pa != r.tonePage {
		if r.drv[r.label] == nil {
			r.drv[r.label] = map[byte]bool{}
		}
		r.drv[r.label][pa] = true
	}
	r.prevPA, r.prevPC = pa, pc
	r.step++
}

// run advances n instructions under the given phase label.
func (r *recorder) run(m *merlin.Machine, label string, n int) {
	r.label = label
	for i := 0; i < n; i++ {
		m.Step()
		r.tick(m)
	}
}

// segment turns a phase's edge list into notes: a note ends when the
// half-period jumps past gapMax (a rest/silence) or changes by more than
// tolPct (a new pitch).
func segment(label string, es []edge) []note {
	var out []note
	i := 0
	for i < len(es) {
		start := i
		i++ // consume the leading edge (its gap is the rest before the tone)
		ref, sum, cnt := 0, 0, 0
		for i < len(es) && es[i].gap <= *gapMax {
			g := es[i].gap
			if ref == 0 {
				ref = g
			} else if abs(g-ref)*100 > ref**tolPct {
				break
			}
			sum += g
			cnt++
			i++
		}
		if cnt == 0 {
			continue // isolated edge, not a sustained tone
		}
		n := note{
			label: label, startStep: es[start].step, endStep: es[i-1].step,
			toggles: cnt + 1, avgHalf: float64(sum) / float64(cnt),
			pc: es[start].pc, pa: es[start].pa, ca: es[start].ca,
		}
		if n.toggles >= *minTog {
			out = append(out, n)
		}
	}
	return out
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

func main() {
	flag.Parse()

	m, err := merlin.New(roms.MP3404)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	r := newRecorder(m)

	// tap holds a button long enough to register (the core forces a
	// ~4000-step minimum hold), then lets the resulting sound play out.
	tap := func(b merlin.Button, label string) {
		m.Press(b)
		r.run(m, label, 30_000)
		m.Release(b)
		r.run(m, label, 220_000)
	}

	r.run(m, "power-on", 700_000)

	games := []merlin.Button{merlin.Pad1, merlin.Pad2, merlin.Pad3,
		merlin.Pad4, merlin.Pad5, merlin.Pad6}
	names := []string{"tic-tac-toe", "music-machine", "echo",
		"blackjack-13", "magic-square", "mindbender"}
	for i, pad := range games {
		tap(merlin.BtnNewGame, fmt.Sprintf("game%d-%s/new", i+1, names[i]))
		tap(pad, fmt.Sprintf("game%d-%s/select", i+1, names[i]))
	}

	// A few interactions that should make Merlin beep.
	tap(merlin.Pad5, "press-pad")
	tap(merlin.BtnHitMe, "press-hit-me")
	tap(merlin.BtnCompTurn, "press-comp-turn")

	fmt.Printf("Merlin sound catalog  (real rate %.0f instr/s; gapmax=%d tol=%d%%)\n\n",
		instrHz, *gapMax, *tolPct)
	fmt.Printf("%-26s %8s %8s %7s %9s  %s\n",
		"phase", "freq(Hz)", "dur(ms)", "toggles", "half(ins)", "PC/PA/CA  @t(s)")

	total := 0
	for _, label := range r.order {
		ns := segment(label, r.edges[label])
		if len(ns) == 0 {
			continue
		}
		for _, n := range ns {
			freq := instrHz / (2 * n.avgHalf)
			durMs := float64(n.endStep-n.startStep) / instrHz * 1000
			fmt.Printf("%-26s %8.1f %8.1f %7d %9.1f  $%02X/%X/%d  %6.2f\n",
				label, freq, durMs, n.toggles, n.avgHalf,
				n.pc, n.pa, n.ca, float64(n.startStep)/instrHz)
			total++
		}
	}
	fmt.Printf("\n%d notes across %d phases (%d instructions run)\n",
		total, len(r.order), r.step)

	// Context: can we tell sounds apart by ROM address? Tone routine lives
	// in page $E; "driver pages" are the other pages running during a
	// sound, and "call site" is where the CPU jumps into the tone page.
	fmt.Printf("\nCode context per phase (tone routine = page $%X)\n", r.tonePage)
	fmt.Printf("%-26s %-22s %s\n", "phase", "driver pages (PA)", "call site PA:PC")
	for _, label := range r.order {
		if len(segment(label, r.edges[label])) == 0 {
			continue
		}
		var pages []byte
		for p := byte(0); p < 16; p++ {
			if r.drv[label][p] {
				pages = append(pages, p)
			}
		}
		cs := r.call[label]
		fmt.Printf("%-26s %-22v $%X:$%02X\n", label, pages, cs[0], cs[1])
	}
}
