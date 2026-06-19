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

// wireKeyMatrix models just enough of CIA1 to test the keyboard scan: a
// write to $DC00 latches the active-low column select, and a read of
// $DC01 returns the rows (a held key in a selected column reads 0).
// Everything else stays in the flat 64K space. pressed[c64col] is the OR
// of (1<<c64row) for keys held in that column.
func wireKeyMatrix(m *sim.Machine, pressed [8]byte) {
	colSel := byte(0xFF)
	m.OnWrite(0xDC00, func(v byte) { colSel = v })
	m.OnRead(0xDC01, func() byte {
		rows := byte(0xFF)
		for col := 0; col < 8; col++ {
			if colSel&(1<<col) == 0 { // column driven low = selected
				rows &^= pressed[col]
			}
		}
		return rows
	})
}

// TestKeyboardMatrix holds each Merlin button via its mapped C64 key and
// checks the interpreter synthesizes exactly the K-column/bit that
// merlin/matrix.go's computeK specifies — proving the whole keyboard ->
// K path, scan tables included.
func TestKeyboardMatrix(t *testing.T) {
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
	kcol := syms["kcol"]
	init := syms["init"]
	loop := syms["loop"]

	cases := []struct {
		name     string
		c64col   int
		c64row   int
		wantCol  int  // kcol index (Merlin scan column O0..O3)
		wantBits byte // expected K bits in that column
	}{
		{"pad0 (left-arrow)", 7, 1, 0, 0x1},
		{"pad1 (1)", 7, 0, 0, 0x2},
		{"pad2 (2)", 7, 3, 0, 0x8},
		{"pad3 (3)", 1, 0, 0, 0x4},
		{"pad4 (4)", 1, 3, 1, 0x1},
		{"pad5 (5)", 2, 0, 1, 0x2},
		{"pad6 (6)", 2, 3, 1, 0x8},
		{"pad7 (7)", 3, 0, 1, 0x4},
		{"pad8 (8)", 3, 3, 2, 0x1},
		{"pad9 (9)", 4, 0, 2, 0x2},
		{"pad10 (0)", 4, 3, 2, 0x8},
		{"same game (S)", 1, 5, 2, 0x4},
		{"comp turn (C)", 2, 4, 3, 0x2},
		{"new game (N)", 4, 7, 3, 0x8},
		{"hit me (H)", 3, 5, 3, 0x4},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := sim.New(sim.NMOS)
			m.StoreBytes(r.Origin, r.Image)
			var pressed [8]byte
			pressed[tc.c64col] = 1 << tc.c64row
			wireKeyMatrix(m, pressed)
			m.SetPC(init)

			// Run well past two scankbd cycles (every 256 steps) so kcol
			// reflects the held key.
			for steps := 0; steps < 1000; {
				m.Step()
				if m.PC() == loop {
					steps++
				}
			}

			for i := 0; i < 4; i++ {
				got := m.Peek(kcol + uint16(i))
				want := byte(0)
				if i == tc.wantCol {
					want = tc.wantBits
				}
				if got != want {
					t.Errorf("kcol[%d] = $%02X, want $%02X", i, got, want)
				}
			}
		})
	}
}
