GO6ASM = go run github.com/carledwards/go6asm/cmd/go6asm

.PHONY: all test clean

all: merlin.prg

# gen emits the blobs merlin.s pulls in: the unscrambled MP3404 ROM (raw
# dump from the lets-go-merlin embed), the MERLIN title sprite bitmaps,
# and the SID half-period -> frequency table. None is committed here.
rom.bin sprites.bin sidfreq.bin songs.bin: gen/main.go romgen/romgen.go sprites/sprites.go siddata/siddata.go songgen/songgen.go
	go run ./gen -o rom.bin -sprites sprites.bin -sid sidfreq.bin -songs songs.bin

merlin.prg: merlin.s rom.bin sprites.bin sidfreq.bin songs.bin
	$(GO6ASM) -prg -o merlin.prg merlin.s rom.bin sprites.bin sidfreq.bin songs.bin

# Lockstep differential against the lets-go-merlin Go core.
# GO6ASM_MERLIN_STEPS=2000000 make test for a deeper soak.
test:
	go test ./...

clean:
	rm -f merlin.prg rom.bin sprites.bin sidfreq.bin songs.bin
