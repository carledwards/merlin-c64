// Command gen writes the two binary blobs merlin.s pulls in via .incbin:
// rom.bin (the PC-LFSR-unscrambled MP3404 Merlin ROM) and sprites.bin
// (the MERLIN title sprite bitmaps). The ROM dump comes from the
// lets-go-merlin module's embed, so nothing ROM-shaped is vendored into
// this repo (both files are gitignored, same policy as the Klaus ROM).
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/carledwards/merlin-c64/romgen"
	"github.com/carledwards/merlin-c64/siddata"
	"github.com/carledwards/merlin-c64/songgen"
	"github.com/carledwards/merlin-c64/sprites"
	"github.com/carledwards/lets-go-merlin/roms"
)

func main() {
	out := flag.String("o", "rom.bin", "ROM output file")
	sprOut := flag.String("sprites", "sprites.bin", "sprite-bitmap output file")
	sidOut := flag.String("sid", "sidfreq.bin", "SID frequency table output file")
	songOut := flag.String("songs", "songs.bin", "transcribed sound table output file")
	flag.Parse()

	remapped, err := romgen.Remap(roms.MP3404)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	write(*out, remapped)
	write(*sprOut, sprites.Build())
	write(*sidOut, siddata.Build())
	write(*songOut, songgen.Build())
}

func write(name string, b []byte) {
	if err := os.WriteFile(name, b, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "%s: %d bytes\n", name, len(b))
}
