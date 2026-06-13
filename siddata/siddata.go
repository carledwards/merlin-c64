// Package siddata builds the lookup table that converts a Merlin tone's
// half-period (instructions between speaker-line toggles) into a SID
// frequency register value. Doing it as a table means the interpreter
// never has to divide at run time.
//
// A tone's real pitch is freq = instrHz / (2*half). SID plays freq when
// its 16-bit frequency word is Fn = freq * 2^24 / sidClk. Combining:
// Fn = (instrHz * 2^24) / (2 * sidClk * half) = K / half. We tabulate
// Fn for every half-period 1..255.
package siddata

const (
	instrHz = 58333.0  // real TMS1100 instruction rate in Merlin
	sidClk  = 985248.0 // SID master clock (PAL); NTSC is ~4% higher
)

// Build returns 512 bytes: low bytes of Fn for half = 0..255, then the
// high bytes. Index 0 is unused (a real half-period is at least 1).
func Build() []byte {
	out := make([]byte, 512)
	for half := 1; half < 256; half++ {
		freq := instrHz / (2 * float64(half))
		fn := int(freq*16777216/sidClk + 0.5)
		if fn > 0xFFFF {
			fn = 0xFFFF
		}
		out[half] = byte(fn)
		out[256+half] = byte(fn >> 8)
	}
	return out
}
