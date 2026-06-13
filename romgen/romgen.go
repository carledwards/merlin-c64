// Package romgen unscrambles the TMS1100 MP3404 mask ROM for the 6502
// interpreter, exactly as lets-go-merlin/pkg/tms1100 does at load time
// (remapROM there is unexported, so the two transforms are restated
// here; the differential test pins them against that core anyway).
//
// The TMS1100 program counter is a 6-bit LFSR, not a linear counter.
// Pre-unscrambling lets the emulated PC simply increment.
package romgen

import "fmt"

// pcSequence[logical] is the physical low-6-bit ROM address the CPU
// presents on the Nth step within a 64-byte page.
var pcSequence = [64]byte{
	0x00, 0x01, 0x03, 0x07, 0x0F, 0x1F, 0x3F, 0x3E,
	0x3D, 0x3B, 0x37, 0x2F, 0x1E, 0x3C, 0x39, 0x33,
	0x27, 0x0E, 0x1D, 0x3A, 0x35, 0x2B, 0x16, 0x2C,
	0x18, 0x30, 0x21, 0x02, 0x05, 0x0B, 0x17, 0x2E,
	0x1C, 0x38, 0x31, 0x23, 0x06, 0x0D, 0x1B, 0x36,
	0x2D, 0x1A, 0x34, 0x29, 0x12, 0x24, 0x08, 0x11,
	0x22, 0x04, 0x09, 0x13, 0x26, 0x0C, 0x19, 0x32,
	0x25, 0x0A, 0x15, 0x2A, 0x14, 0x28, 0x10, 0x20,
}

// Remap reorders every 64-byte page by pcSequence and rewrites the
// 6-bit operand of each branch/call (opcode bit 7 set) from physical
// to logical, so branches land correctly after the reorder.
func Remap(raw []byte) ([]byte, error) {
	if len(raw) == 0 || len(raw)%64 != 0 {
		return nil, fmt.Errorf("romgen: ROM size %d is not a positive multiple of 64", len(raw))
	}
	var inv [64]byte
	for logical, physical := range pcSequence {
		inv[physical] = byte(logical)
	}
	out := make([]byte, len(raw))
	for i := range raw {
		out[i] = raw[(i & ^0x3F)|int(pcSequence[i&0x3F])]
		if out[i]&0x80 != 0 {
			out[i] = (out[i] & 0xC0) | inv[out[i]&0x3F]
		}
	}
	return out, nil
}
