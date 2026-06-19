// The Merlin-on-C64 differential: assemble merlin.s with go6asm, run it
// on go6sim's NMOS interpretive core (the C64's 6510 is NMOS), and lock
// the 6502 TMS1100 interpreter step-for-step to the lets-go-merlin Go
// core running the same ROM. Every architectural register the Go core
// exposes is compared at every TMS instruction boundary, plus the
// R0-R10 latches that drive the LED pads.
// Lives in its own package because the Go toolchain would otherwise try
// to build ../merlin.s as Go assembly.
package lockstep

import (
	"os"
	"strconv"
	"testing"

	"github.com/carledwards/go6asm/asm"
	"github.com/carledwards/go6sim/sim"
	"github.com/carledwards/lets-go-merlin/pkg/tms1100"
	"github.com/carledwards/lets-go-merlin/roms"
	"github.com/carledwards/merlin-c64/romgen"
	"github.com/carledwards/merlin-c64/siddata"
	"github.com/carledwards/merlin-c64/songgen"
	"github.com/carledwards/merlin-c64/sprites"
)

// tmsSteps is how many TMS1100 instructions the lockstep run covers.
// The ROM's power-on sequence (RAM clear, matrix scan spin-up, the
// first LED activity) is comfortably inside this window.
const tmsSteps = 100_000 // override with GO6ASM_MERLIN_STEPS for a deeper soak

func TestLockstepAgainstGoCore(t *testing.T) {
	rom, err := romgen.Remap(roms.MP3404)
	if err != nil {
		t.Fatal(err)
	}
	src, err := os.ReadFile("../merlin.s")
	if err != nil {
		t.Fatal(err)
	}

	r := asm.Assemble(asm.Input{
		Entry: "merlin.s",
		Files: []asm.SourceFile{
			{Name: "merlin.s", Content: src},
			{Name: "rom.bin", Content: rom},
			{Name: "sprites.bin", Content: sprites.Build()},
			{Name: "sidfreq.bin", Content: siddata.Build()},
			{Name: "songs.bin", Content: songgen.Build()},
		},
	})
	if !r.Ok() {
		t.Fatalf("assemble: %v", r.Errors)
	}
	if r.Origin != 0x0801 {
		t.Fatalf("origin $%04X, want $0801", r.Origin)
	}

	syms := make(map[string]uint16, len(r.Symbols))
	for _, s := range r.Symbols {
		syms[s.Name] = s.Addr
	}
	sym := func(name string) uint16 {
		v, ok := syms[name]
		if !ok {
			t.Fatalf("symbol %q not in assembly output", name)
		}
		return v
	}

	m := sim.New(sim.NMOS)
	m.StoreBytes(r.Origin, r.Image)
	m.StoreByte(0xDC01, 0xFF) // keyboard rows idle (active low) = no key held
	m.SetPC(sym("init"))

	ref, err := tms1100.New(roms.MP3404)
	if err != nil {
		t.Fatal(err)
	}
	ref.SetK(0) // no buttons wired on the C64 side either

	loop := sym("loop")
	rlines := sym("rlines")

	// One pass of the interpreter loop per TMS instruction: run the 6502
	// until it is back at the fetch label. The first c.Step() moves off
	// the label so a PC already parked there doesn't return immediately.
	runToLoop := func() {
		const maxInstr = 100_000 // one TMS step is ~30 6502 instructions
		for i := 0; i < maxInstr; i++ {
			m.Step()
			if m.PC() == loop {
				return
			}
		}
		t.Fatalf("6502 never returned to the interpreter loop (PC=$%04X)", m.PC())
	}

	b2 := func(b bool) byte {
		if b {
			return 1
		}
		return 0
	}
	zp := func(name string) byte { return m.LoadByte(sym(name)) }

	compare := func(step int) {
		type reg struct {
			name string
			got  byte
			want byte
		}
		regs := []reg{
			{"A", zp("tA"), ref.A()},
			{"X", zp("tXr"), ref.X()},
			{"Y", zp("tYr"), ref.Y()},
			{"PC", zp("tPC"), ref.PC()},
			{"PA", zp("tPA"), ref.PA()},
			{"PB", zp("tPB"), ref.PB()},
			{"CA", zp("tCA"), ref.CA()},
			{"CB", zp("tCB"), ref.CB()},
			{"S", zp("tS"), b2(ref.S())},
			{"SL", zp("tSL"), b2(ref.SL())},
			{"CL", zp("tCL"), b2(ref.CL())},
			{"O", zp("tO"), ref.O()},
		}
		for _, x := range regs {
			if x.got != x.want {
				t.Fatalf("step %d: %s = $%02X, Go core has $%02X", step, x.name, x.got, x.want)
			}
		}
		for i := 0; i < 11; i++ {
			if got, want := m.LoadByte(rlines+uint16(i)), b2(ref.R(i)); got != want {
				t.Fatalf("step %d: R%d = %d, Go core has %d", step, i, got, want)
			}
		}
	}

	runToLoop() // init complete, zero TMS steps executed
	compare(0)

	steps := tmsSteps
	if s := os.Getenv("GO6ASM_MERLIN_STEPS"); s != "" {
		v, err := strconv.Atoi(s)
		if err != nil {
			t.Fatalf("bad GO6ASM_MERLIN_STEPS=%q: %v", s, err)
		}
		steps = v
	}

	ledSeen := false
	for step := 1; step <= steps; step++ {
		ref.Step()
		runToLoop()
		compare(step)
		if !ledSeen {
			for i := 0; i < 11; i++ {
				if ref.R(i) {
					ledSeen = true
					break
				}
			}
		}
	}
	if !ledSeen {
		t.Errorf("no R line went high in %d steps; expected LED scan activity", steps)
	}
}
