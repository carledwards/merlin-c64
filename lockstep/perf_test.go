package lockstep

import (
	"os"
	"testing"

	"github.com/beevik/go6502/cpu"
	"github.com/carledwards/go6asm/asm"
	"github.com/carledwards/merlin-c64/romgen"
	"github.com/carledwards/merlin-c64/siddata"
	"github.com/carledwards/merlin-c64/songgen"
	"github.com/carledwards/merlin-c64/sprites"
	"github.com/carledwards/lets-go-merlin/roms"
)

// TestCyclesPerStep reports the average 6502 cycle cost of one
// interpreted TMS1100 instruction, and the resulting Merlin instruction
// rate on a stock 1 MHz C64. It is a measurement, not a pass/fail gate
// (no threshold), but it fails loudly if the interpreter ever stops
// returning to its fetch label. Run with -v to see the number.
func TestCyclesPerStep(t *testing.T) {
	rom, err := romgen.Remap(roms.MP3404)
	if err != nil {
		t.Fatal(err)
	}
	src, err := os.ReadFile("../merlin.s")
	if err != nil {
		t.Fatal(err)
	}
	r := asm.Assemble(asm.Input{Entry: "merlin.s", Files: []asm.SourceFile{
		{Name: "merlin.s", Content: src}, {Name: "rom.bin", Content: rom},
		{Name: "sprites.bin", Content: sprites.Build()},
		{Name: "sidfreq.bin", Content: siddata.Build()},
		{Name: "songs.bin", Content: songgen.Build()}}})
	if !r.Ok() {
		t.Fatalf("assemble: %v", r.Errors)
	}
	syms := make(map[string]uint16, len(r.Symbols))
	for _, s := range r.Symbols {
		syms[s.Name] = s.Addr
	}

	mem := cpu.NewFlatMemory()
	mem.StoreBytes(r.Origin, r.Image)
	mem.StoreByte(0xDC01, 0xFF) // keyboard rows idle = no key held
	c := cpu.NewCPU(cpu.NMOS, mem)
	c.SetPC(syms["init"])
	loop := syms["loop"]

	for c.Reg.PC != loop { // run init out to the first fetch
		c.Step()
	}

	const n = 500_000
	start := c.Cycles
	for steps := 0; steps < n; {
		c.Step()
		if c.Reg.PC == loop {
			steps++
		}
	}
	cyc := c.Cycles - start
	perStep := float64(cyc) / n
	t.Logf("%.1f 6502 cycles per TMS step  =>  ~%.0f Merlin instr/sec on a 1 MHz C64",
		perStep, 1e6/perStep)
}
