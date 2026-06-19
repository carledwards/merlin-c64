package lockstep

import (
	"os"
	"testing"

	"github.com/carledwards/go6asm/asm"
	"github.com/carledwards/go6sim/sim"
	"github.com/carledwards/lets-go-merlin/roms"
	"github.com/carledwards/merlin-c64/romgen"
	"github.com/carledwards/merlin-c64/siddata"
	"github.com/carledwards/merlin-c64/songgen"
	"github.com/carledwards/merlin-c64/sprites"
)

// TestDisplayLayout checks the static screen the interpreter paints
// before any TMS activity: the centered title, the self-documenting
// keypad (each unlit pad shows its key glyph), and the game list. It
// guards the drawstr ASCII->screen-code fold and the parallel position
// tables, which are easy to knock out of alignment.
func TestDisplayLayout(t *testing.T) {
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

	m := sim.New(sim.NMOS)
	m.StoreBytes(r.Origin, r.Image)
	m.StoreByte(0xDC01, 0xFF)
	m.SetPC(syms["init"])
	for m.PC() != syms["loop"] { // stop at first fetch: init done, pads unlit
		m.Step()
	}

	// readScreen returns n screen codes at (row,col), folded back to ASCII
	// for letters/digits so assertions read naturally.
	readText := func(row, col, n int) string {
		out := make([]byte, n)
		for i := 0; i < n; i++ {
			sc := m.LoadByte(0x0400+uint16(row*40+col+i)) & 0x3F
			switch {
			case sc >= 1 && sc <= 26:
				out[i] = 'A' + (sc - 1)
			default:
				out[i] = sc // space, digits, punctuation are identity under &$3F
			}
		}
		return string(out)
	}

	// The title is now six hardware sprites, not screen text. Check the
	// VIC was set up: sprites 0-5 enabled, the first letter's data pointer
	// and position, and that the first sprite byte was copied to $3000.
	if got := m.LoadByte(0xD015); got != 0x3F {
		t.Errorf("sprite enable $D015 = $%02X, want $3F", got)
	}
	if got := m.LoadByte(0x07F8); got != 0xC0 {
		t.Errorf("sprite 0 pointer = $%02X, want $C0 ($3000/64)", got)
	}
	if got := m.LoadByte(0xD000); got != 100 {
		t.Errorf("sprite 0 X = %d, want 100", got)
	}
	if got := m.LoadByte(0xD010); got != 0x20 {
		t.Errorf("sprite X MSB $D010 = $%02X, want $20 (letter N at 260)", got)
	}
	if got := m.LoadByte(0x3000); got != sprites.Build()[0] {
		t.Errorf("sprite data at $3000 = $%02X, want $%02X", got, sprites.Build()[0])
	}

	if got := readText(24, 21, 12); got != "6 MINDBENDER" {
		t.Errorf("game line = %q, want %q", got, "6 MINDBENDER")
	}
	if got := readText(17, 7, 10); got != "N=NEW GAME" {
		t.Errorf("legend = %q, want %q", got, "N=NEW GAME")
	}

	// The keypad middle cells: left-arrow ($1F), digits 1..9, then '0'.
	wantGlyph := []byte{0x1F, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x30}
	scrLo := syms["scrLo"]
	scrHi := syms["scrHi"]
	for pad := 0; pad < 11; pad++ {
		cell := uint16(m.LoadByte(scrLo+uint16(pad))) | uint16(m.LoadByte(scrHi+uint16(pad)))<<8
		if got := m.LoadByte(cell + 1); got != wantGlyph[pad] {
			t.Errorf("pad %d glyph = $%02X, want $%02X", pad, got, wantGlyph[pad])
		}
	}
}
