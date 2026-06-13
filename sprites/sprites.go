// Package sprites builds the C64 hardware-sprite bitmaps for the MERLIN
// title: one sprite per letter, each slanted into italics by the old
// trick of shifting successive pixel rows to the right. The output is
// six 64-byte sprite blocks (63 bytes used), ready to copy into
// VIC-visible RAM. Pure data (stdlib only) so the gen tool and the
// tests build identical bytes.
package sprites

// font holds an 8x8 (MSB = leftmost pixel) glyph per title letter.
var font = map[rune][8]string{
	'M': {
		"#.....#.",
		"##...##.",
		"#.#.#.#.",
		"#..#..#.",
		"#.....#.",
		"#.....#.",
		"#.....#.",
		"........",
	},
	'E': {
		"#######.",
		"#.......",
		"#.......",
		"#####...",
		"#.......",
		"#.......",
		"#######.",
		"........",
	},
	'R': {
		"######..",
		"#.....#.",
		"#.....#.",
		"######..",
		"#...#...",
		"#....#..",
		"#.....#.",
		"........",
	},
	'L': {
		"#.......",
		"#.......",
		"#.......",
		"#.......",
		"#.......",
		"#.......",
		"#######.",
		"........",
	},
	'I': {
		"#######.",
		"...#....",
		"...#....",
		"...#....",
		"...#....",
		"...#....",
		"#######.",
		"........",
	},
	'N': {
		"#.....#.",
		"##....#.",
		"#.#...#.",
		"#..#..#.",
		"#...#.#.",
		"#....##.",
		"#.....#.",
		"........",
	},
}

// Letters is the title, left to right (one sprite each).
const Letters = "MERLIN"

// shift is how far each glyph row leans right (pixels). Top rows lean
// most, so the letters slant forward like italics.
var shift = [8]uint{3, 3, 2, 2, 1, 1, 0, 0}

// Build returns len(Letters)*64 bytes: each letter's 8 glyph rows
// placed at the top of a sprite (3 bytes/row, 21 rows), italicized by
// shifting each row right within the 24-pixel sprite width.
func Build() []byte {
	out := make([]byte, len(Letters)*64)
	for i, ch := range Letters {
		g := font[ch]
		base := i * 64
		for r := 0; r < 8; r++ {
			var glyph byte
			for c := 0; c < 8; c++ {
				if g[r][c] == '#' {
					glyph |= 1 << (7 - uint(c))
				}
			}
			s := shift[r]
			out[base+r*3+0] = glyph >> s             // high byte
			out[base+r*3+1] = byte(uint16(glyph) << (8 - s)) // bits shifted past byte 0
			out[base+r*3+2] = 0
		}
	}
	return out
}
