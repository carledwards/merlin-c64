; merlin.s — Parker Brothers Merlin (1978) on the Commodore 64.
;
; A TMS1100 interpreter running the original MP3404 mask ROM, with the
; 11 light-up pads rendered as a column of cells on the C64 screen:
;
;        [ ]        pad 0
;     [ ][ ][ ]     pads 1 2 3
;     [ ][ ][ ]     pads 4 5 6
;     [ ][ ][ ]     pads 7 8 9
;        [ ]        pad 10
;
; Input: the C64 keyboard drives the Merlin K matrix (we own the scan,
; since we SEI away the KERNAL IRQ). Key map:
;
;        LEFT-ARROW = top pad (pad 0)
;        1 2 3 / 4 5 6 / 7 8 9 = the 3x3 grid (pads 1..9)
;        0          = bottom pad (pad 10)
;        H = Hit Me   N = New Game   C = Comp Turn   S = Same Game
;
; Audio: Merlin makes tones by toggling the speaker line (O bit 0) as a
; square wave. We watch that line in hTDO, measure each toggle's
; half-period in instructions, and play the matching pitch on SID voice 1
; (table-driven, no run-time divide). Pitch is correct; tempo is a touch
; stretched because the interpreter runs ~6x slower than real Merlin.
;
; The interpreter is a literal port of lets-go-merlin/pkg/tms1100
; (itself a port of the C++ reference). The ROM image "rom.bin" is the
; PC-LFSR-unscrambled MP3404 produced by `go run ./gen` (see romgen);
; the emulated PC then increments linearly, exactly as the Go core does.
;
; Build:  go6asm -prg -o merlin.prg merlin.s rom.bin   (absolute mode; .org $0801)
; Run:    LOAD"MERLIN.PRG",8,1 : RUN   (BASIC stub SYSes the entry point)

; --- TMS1100 state, zero page -------------------------------------------
; All 4-bit unless noted. Free under a SYS that never returns to BASIC
; (we SEI and loop forever, so the KERNAL IRQ never touches them either).

tA    = $02             ; accumulator
tXr   = $03             ; 3-bit RAM page select
tYr   = $04             ; RAM/output index
tPC   = $05             ; 6-bit program counter (linear; ROM is unscrambled)
tPA   = $06             ; current ROM page
tPB   = $07             ; branch/call target page
tSR   = $08             ; 6-bit subroutine return address
tCA   = $09             ; 1-bit current chapter
tCB   = $0A             ; 1-bit chapter buffer
tCS   = $0B             ; 1-bit chapter save
tS    = $0C             ; status (0/1)
tSL   = $0D             ; status latch (drives O bit 4 via TDO)
tCL   = $0E             ; call latch (one-deep nesting)
tO    = $0F             ; O output value (bit 0 = speaker line)
lastS = $10             ; previous instruction's status (branches consume it)
opc   = $11             ; opcode being executed
stepc = $12             ; step counter; LED tick every 256 steps
vec   = $13             ; $13/$14: dispatch vector
ptr   = $15             ; $15/$16: screen cell pointer
romp  = $17             ; $17/$18: cached ROM page base = romdat + (CA<<10 | PA<<6).
                        ; The fetch is (romp),PC; only BR/CALL/RETN move the page,
                        ; so this is recomputed there instead of every instruction.
kcol  = $19             ; $19..$1C: K response per scan column (O = 0,4,8,12),
                        ; rebuilt from the keyboard ~40x/sec by scankbd.
cptr  = $1D             ; $1D/$1E: color-RAM pointer (mirrors ptr at +$D400)
msgp  = $1F             ; $1F/$20: source pointer for drawstr
clr   = $21             ; current text color for drawstr
sndPrev  = $22          ; last speaker-line bit (0/1), to detect toggles
sndLast  = $23          ; stepc at the last toggle (for the half-period)
sndState = $24          ; 0 = silent, 1 = first edge seen, 2 = note playing
sndPitch = $25          ; half-period of the note currently playing
sndSil   = $26          ; ledticks since the last toggle (gates the note off)
sndMode  = $27          ; 0 = passthrough, 1 = override tune is playing
lastTLo  = $28          ; CIA timer at the last frame advance (low/high)
lastTHi  = $29
songP    = $2A          ; $2A/$2B: pointer to the playing song's note data
songStep = $2C          ; index of the current note within the song
songFrm  = $2D          ; player frames left in the current note
tnowLo   = $2E          ; scratch: current CIA timer reading
tnowHi   = $2F
kHold    = $30          ; $30..$33: per-scan-column key-hold countdown
freshK   = $34          ; $34..$37: this scan's raw K columns (pre-hold)
tmp8     = $38          ; scratch byte
tmpP     = $39          ; $39/$3A: scratch pointer (song/credits text)
shimMode = $3B          ; 0 = idle (counting), 1 = a shimmer wave is sweeping
shimCnt  = $3C          ; idle ledticks since the last shimmer
shimPhase = $3D         ; wave position across the MERLIN letters
shimSub  = $3E          ; sub-counter: ledticks per wave step

scrn   = $0400          ; default screen matrix
color  = $D800          ; color RAM (parallel to screen; +$D400 from $0400)
border = $D020
bkgnd  = $D021

; SID voice 1 registers. Merlin's tones are square waves, so we drive one
; pulse voice: set the frequency from the measured half-period, gate it
; while the ROM is toggling the speaker, release it when the tone stops.
SIDFLO = $D400          ; voice 1 frequency low
SIDFHI = $D401          ; voice 1 frequency high
SIDPWHI = $D403         ; voice 1 pulse width high (duty)
SIDCTL = $D404          ; voice 1 control: bit6 pulse, bit0 gate
SIDAD  = $D405          ; attack/decay
SIDSR  = $D406          ; sustain/release
SIDVOL = $D418          ; master volume
SIDON  = $41            ; pulse waveform + gate on
SIDOFF = $40            ; pulse waveform, gate off (release)
SNDTOL = 6              ; half-period jitter (instructions) treated as one note
                        ; — under half the gap between Merlin's distinct pitches

; Audio mode. USE_HLE=1 adds "override" sound: when the ROM enters its
; tone routine we read the caller (tPB:tSR), look it up in the transcribed
; song table, and play that tune in real time on SID (pitch AND tempo
; correct, not stretched 6x). Unrecognized callers fall back to the raw
; pitch-correct passthrough. Set to 0 for pure passthrough.
USE_HLE  = 1
SILEXIT  = 4            ; ledticks of speaker silence that end an override

; SONG player clock. CIA #2 Timer A free-runs with a ~16 ms period;
; Timer B is chained to count Timer A underflows, so Timer B decrements
; exactly once per frame. Reading Timer B gives whole frames elapsed with
; no fast wrap (~17 min), steady regardless of the wobbly interpreter pace.
FRAMELO = $00           ; Timer A period = $4000 = 16384 cycles (~16 ms)
FRAMEHI = $40
CIA2ALO = $DD04         ; Timer A latch/counter (the ~16 ms tick)
CIA2AHI = $DD05
CIA2BLO = $DD06         ; Timer B = frame counter (counts A underflows)
CIA2BHI = $DD07
CIA2CRA = $DD0E         ; Timer A control
CIA2CRB = $DD0F         ; Timer B control

RELOAD = 16             ; LED freshness reload; 16 ticks x 256 steps ~= the
                        ; Go core's 4000-step decay window, in step time
NKEYS  = 15             ; 11 pads + 4 game buttons in the keyboard scan table
NMSG   = 11             ; static labels: 4 key legends + header + 6 games
NCRED  = 7              ; lines on the credits screen
KHOLD  = 20             ; scankbds (~5000 steps) a tapped key is held "down" so
                        ; the ROM's instruction-timed debounce sees it — without
                        ; this, brief taps are missed (the interpreter is ~6x slow)

; C64 color codes used by the renderer.
COFF   = $0B            ; dark gray    (an unlit pad's key glyph)
CON    = $0A            ; light red    (a lit pad — Merlin's lamps are red)
CKEYS  = $03            ; cyan         (the N/S/H/C legend)
CHDR   = $07            ; yellow       (section header)
CGAME  = $0F            ; light gray   (game list)
CPANEL = $02            ; red          (the keypad faceplate, via reverse video)

; Keypad faceplate rectangle (the red panel behind the pads), in screen
; cells: top-left and size. The pads occupy rows 5-13, cols 16-24; the
; panel adds a red row above (4) and below (14) to box the grid in.
PANROWS = 11
PANCOLS = 9
PANTL   = scrn + 4*40 + 16      ; screen top-left of the panel
PANTLC  = color + 4*40 + 16     ; matching color-RAM top-left

; MERLIN title: six hardware sprites (one per letter). VIC reads sprite
; data from $3000 (within the default VIC bank 0); the CPU copies the
; .incbin'd bitmaps there at init because the program itself overlaps the
; $1000-$1FFF char-ROM shadow the VIC can't see as data.
SPRDST  = $3000
SPRPAGE = SPRDST / 64           ; sprite pointer value (= $C0)
SPRPTR  = scrn + $3F8           ; sprite pointers ($07F8..)
SPRY    = 54                    ; y of every title sprite
NLET    = 6                     ; letters in MERLIN
VSPR    = $D000                 ; VIC sprite X/Y position registers
SPRCOL  = $D027                 ; sprite 0 color (0..5 are the title letters)

; Title shimmer: a colour wave that sweeps the MERLIN letters every few
; seconds while idle. SHIMIDLE ledticks between waves; SHIMSTEP ledticks
; per wave position; the wave is SHIMW cells wide (see waveTab).
SHIMIDLE = 190                  ; ~5 s at ~38 ledticks/s
SHIMSTEP = 2                    ; ledticks per wave step (~50 ms)
SHIMW    = 7                    ; waveTab width
SHIMEND  = NLET + SHIMW         ; wave positions until it clears the word

; --- BASIC stub: 10 SYS 2061 --------------------------------------------

        .org $0801

        .byte $0B, $08          ; next BASIC line at $080B
        .byte $0A, $00          ; line number 10
        .byte $9E               ; SYS token
        .byte $32, $30, $36, $31 ; "2061" = $080D
        .byte $00               ; end of line
        .byte $00, $00          ; end of program

; --- init ----------------------------------------------------------------

init:
        sei                     ; no KERNAL IRQ: no keyboard, all zp ours
        lda #$00
        sta border
        sta bkgnd

        jsr drawGame            ; static screen: panel, pads, legend, games
        jsr title               ; MERLIN sprite banner

        ; TMS1100 power-on state (tms1100.Reset: the 0xAA fill pattern)
        lda #$0A
        sta tA
        sta tYr
        lda #$02
        sta tXr
        lda #$0F
        sta tPA
        sta tPB
        lda #$00
        sta tPC
        sta tSR
        sta tCA
        sta tCB
        sta tCS
        sta tS
        sta tSL
        sta tCL
        sta tO
        sta stepc

        ldx #$7F                ; RAM: every nibble 0x0A
        lda #$0A
rfill:  sta mram,x
        dex
        bpl rfill

        ldx #10                 ; R latches + LED freshness clear
        lda #$00
lfill:  sta rlines,x
        sta fresh,x
        dex
        bpl lfill

        lda #$FF                ; CIA1 DDRA = output (drive column select);
        sta $DC02               ; we scan the keyboard ourselves now that the
        lda #$00                ; KERNAL IRQ is off (SEI above).
        sta $DC03               ; CIA1 DDRB = input (read key rows)
        sta kcol+0              ; no keys held until the first scankbd
        sta kcol+1
        sta kcol+2
        sta kcol+3
        sta kHold+0
        sta kHold+1
        sta kHold+2
        sta kHold+3

        lda #$0F                ; SID: full volume, ~50% pulse, hold envelope
        sta SIDVOL
        lda #$08
        sta SIDPWHI             ; pulse width ~50% duty
        lda #$00
        sta SIDAD               ; attack 0, decay 0
        lda #$F5
        sta SIDSR               ; sustain 15, release 5
        lda #SIDOFF
        sta SIDCTL              ; pulse waveform, gate off
        lda #$00                ; speaker-tracking + override state: idle
        sta sndPrev
        sta sndState
        sta sndLast
        sta sndPitch
        sta sndSil
        sta sndMode
        sta songStep
        sta songFrm
        sta shimMode            ; title shimmer: idle, counting toward the first wave
        sta shimCnt
        sta shimPhase
        sta shimSub

        lda #FRAMELO            ; CIA #2 Timer A: ~16 ms period, continuous
        sta CIA2ALO
        lda #FRAMEHI
        sta CIA2AHI
        lda #$FF                ; Timer B: frame counter from $FFFF
        sta CIA2BLO
        sta CIA2BHI
        lda #$11                ; A: start + force-load, continuous, phi2
        sta CIA2CRA
        lda #$51                ; B: start + force-load, continuous, count A
        sta CIA2CRB             ;    underflows (one decrement per frame)

        jsr setRomp             ; seed the cached page base (PA=$0F, CA=0)

; --- main loop: one TMS1100 instruction per pass --------------------------

loop:
        ldy tPC                 ; fetch: romp already = page base, PC is 0..63
        lda (romp),y
        sta opc
        tax                     ; keep the opcode in X across the prologue

        iny                     ; increment_pc: 6-bit wrap
        tya
        and #$3F
        sta tPC

        lda tS                  ; "last status": branches see the previous
        sta lastS               ; instruction's S; ALU ops may clear the new 1
        lda #$01
        sta tS

        cpx #$80
        bcs brcall              ; $80-$BF BR, $C0-$FF CALL
        lda opLoTab,x
        sta vec
        lda opHiTab,x
        sta vec+1
        jmp (vec)

; --- BR / CALL / step epilogue (kept adjacent for branch range) -----------

brcall: lda lastS
        beq done                ; not taken
        lda opc
        and #$40
        bne docall
        lda tCB                 ; BR: CA=CB, PC=operand, PA=PB unless in call
        sta tCA
        lda opc
        and #$3F
        sta tPC
        lda tCL
        bne doneR               ; CA moved even when CL pins PA
        lda tPB
        sta tPA
        jmp doneR
docall: lda tCL
        beq cl0
        lda tPA                 ; nested CALL: only PB=PA
        sta tPB
        jmp cfin
cl0:    lda tCA                 ; first-level CALL: save return state,
        sta tCS                 ; swap PA<->PB, set the latch
        lda tPC
        sta tSR
        ldx tPA
        lda tPB
        sta tPA
        stx tPB
        lda #$01
        sta tCL
cfin:   lda tCB
        sta tCA
        lda opc
        and #$3F
        sta tPC

doneR:  jsr setRomp             ; PA/CA moved: refresh the cached page base
done:   inc stepc
        beq tick
        jmp loop
tick:   jsr ledtick             ; every 256 steps
        jmp loop

; setRomp recomputes romp = romdat + (CA<<10 | PA<<6). Called only from
; the three ops that move the page, and once at init. Carry from the low
; add survives the ldx/branch/ora (none touch it) into the high add.
setRomp:
        ldx tPA
        lda paLoTab,x           ; (PA & 3) << 6
        clc
        adc #<romdat
        sta romp
        lda paHiTab,x           ; PA >> 2
        ldx tCA
        beq sr0
        ora #$04                ; CA << 2 (the <<10 high bits)
sr0:    adc #>romdat
        sta romp+1
        rts

; --- LED decay + render ----------------------------------------------------
; The ROM scans the pad matrix via the R latches far faster than the eye;
; mirroring raw R to the screen would flicker. Same smoothing as the Go
; core's ledState: reload a per-pad counter while its R line reads high,
; decay otherwise, draw lit while the counter is nonzero.

ledtick:
        inc sndSil              ; ledticks since the last speaker toggle
        lda sndMode
        beq ltpass              ; passthrough: release the note after silence
        jsr sndPlayer           ; override tune: advance it on the steady clock
        jmp lts1
ltpass: lda sndSil
        cmp #$03
        bcc lts1
        lda sndState
        beq lts1                ; already silent
        lda #SIDOFF
        sta SIDCTL              ; release the note
        lda #$00
        sta sndState
        sta sndPrev
lts1:   jsr scankbd             ; refresh kcol from the keyboard (~40x/sec)
        jsr credCheck           ; a non-Merlin key pops the credits screen
        ldx #10
lt1:    lda rlines,x            ; reload freshness while R reads high,
        beq lt2                 ; otherwise decay it
        lda #RELOAD
        sta fresh,x
        bne lt3
lt2:    lda fresh,x
        beq lt3
        dec fresh,x
lt3:    jsr padPtr
        ldy #$01
        lda fresh,x
        beq lt4
        lda #$51                ; lit: filled ball, in red
        sta (ptr),y
        lda #CON
        sta (cptr),y
        jmp lt5
lt4:    lda padGlyph,x          ; unlit: the key glyph, dimmed
        sta (ptr),y
        lda #COFF
        sta (cptr),y
lt5:    dex
        bpl lt1
        jmp shimmer             ; animate the title, then return (rts in shimmer)

; --- title shimmer ---------------------------------------------------------
; Idle for SHIMIDLE ledticks, then sweep a colour wave (waveTab) across the
; six MERLIN sprites: each letter goes white -> yellow -> orange -> red and
; back as the wave passes. Returns for ledtick (tail-called).
shimmer:
        lda shimMode
        bne shsweep
        inc shimCnt             ; idle: wait, then launch a wave
        lda shimCnt
        cmp #SHIMIDLE
        bcc shrts
        lda #$01
        sta shimMode
        lda #$00
        sta shimPhase
        sta shimSub
        sta shimCnt
        jmp shdraw
shsweep:
        inc shimSub
        lda shimSub
        cmp #SHIMSTEP
        bcc shdraw             ; hold this wave position a few ledticks
        lda #$00
        sta shimSub
        inc shimPhase
        lda shimPhase
        cmp #SHIMEND
        bcc shdraw
        lda #$00               ; wave finished: back to idle, all letters white
        sta shimMode
        ldx #NLET-1
shw:    lda #$01
        sta SPRCOL,x
        dex
        bpl shw
        rts
shdraw:                        ; colour letter X = waveTab[phase - X], else white
        ldx #$00
shd:    txa
        eor #$FF
        sec
        adc shimPhase          ; A = shimPhase - X (mod 256)
        cmp #SHIMW
        bcc shin               ; 0..SHIMW-1 -> inside the wave
        lda #$01               ; outside -> white
        bne shset
shin:   tay
        lda waveTab,y
shset:  sta SPRCOL,x
        inx
        cpx #NLET
        bne shd
shrts:  rts

; clrScreen fills the 1000 screen cells with spaces.
clrScreen:
        ldx #$00
        lda #$20
csl:    sta scrn,x
        sta scrn+$100,x
        sta scrn+$200,x
        sta scrn+$2E8,x
        inx
        bne csl
        rts

; drawGame paints the static game screen: red faceplate, the pads (brackets
; + key glyph), and the legend/game-list text. Used at init and to restore
; the screen when leaving the credits.
drawGame:
        jsr clrScreen
        lda #<PANTL             ; red faceplate: a block of reversed spaces
        sta ptr
        lda #>PANTL
        sta ptr+1
        lda #<PANTLC
        sta cptr
        lda #>PANTLC
        sta cptr+1
        ldx #PANROWS
dgpr:   ldy #PANCOLS-1
dgpc:   lda #$A0
        sta (ptr),y
        lda #CPANEL
        sta (cptr),y
        dey
        bpl dgpc
        clc
        lda ptr
        adc #40
        sta ptr
        bcc dgp1
        inc ptr+1
dgp1:   clc
        lda cptr
        adc #40
        sta cptr
        bcc dgp2
        inc cptr+1
dgp2:   dex
        bne dgpr
        ldx #10                 ; pads: reversed [ ] brackets + key glyph
dgfr:   jsr padPtr
        ldy #$00
        lda #$9B
        sta (ptr),y
        lda #CPANEL
        sta (cptr),y
        ldy #$02
        lda #$9D
        sta (ptr),y
        lda #CPANEL
        sta (cptr),y
        ldy #$01
        lda padGlyph,x
        sta (ptr),y
        lda #COFF
        sta (cptr),y
        dex
        bpl dgfr
        jmp drawUI              ; legend + game list (rts via drawUI)

; credCheck pops the credits screen when a key that is NOT a Merlin control
; is held: "a Merlin key is down" = kcol nonzero; "any key down" = a full
; matrix scan (drive every column low, any zero row bit = a key).
credCheck:
        lda kcol+0
        ora kcol+1
        ora kcol+2
        ora kcol+3
        bne ccno                ; a mapped key -> gameplay, not credits
        lda #$00
        sta $DC00               ; select all columns
        lda $DC01
        cmp #$FF
        beq ccno                ; nothing down
        jmp showCredits         ; some other key -> credits (rts there)
ccno:   rts

; showCredits pauses the game (we simply don't return to the main loop
; until a key is pressed), shows the credits, then restores the screen.
showCredits:
        lda #$00
        sta $D015               ; hide the title sprites
        lda #SIDOFF
        sta SIDCTL              ; silence any held note
        jsr clrScreen
        jsr drawCredits
        jsr waitNoKey           ; let the triggering key go up
        jsr waitKey             ; wait for any key
        jsr waitNoKey           ; and its release
        jsr drawGame            ; restore the game screen
        lda #$3F
        sta $D015               ; sprites back
        rts

waitKey:                        ; block until any key is down
        lda #$00
        sta $DC00
        lda $DC01
        cmp #$FF
        beq waitKey
        rts
waitNoKey:                      ; block until all keys are up
        lda #$00
        sta $DC00
        lda $DC01
        cmp #$FF
        bne waitNoKey
        rts

; drawCredits writes the credit lines from the parallel cred* tables.
drawCredits:
        ldx #NCRED-1
dcl:    lda credLo,x
        sta msgp
        lda credHi,x
        sta msgp+1
        lda credScrLo,x
        sta ptr
        sta cptr
        lda credScrHi,x
        sta ptr+1
        clc
        adc #$D4
        sta cptr+1
        lda credClr,x
        sta clr
        jsr drawstr
        dex
        bpl dcl
        rts

; --- helpers ---------------------------------------------------------------

; RAMX leaves the CURR_RAM index (tXr<<4 | tYr) in X. It is a macro, not a
; subroutine: the memory-touching handlers run it constantly, so inlining
; saves the 12-cycle jsr/rts on every RAM access. Clobbers A and X.
.macro RAMX
        ldx tXr
        lda xshTab,x
        ora tYr
        tax
.endmacro

; padPtr points ptr at pad X's '[' on the screen and cptr at the matching
; color-RAM cell ($D800 = $0400 + $D400). Preserves X.
padPtr: lda scrLo,x
        sta ptr
        sta cptr
        lda scrHi,x
        sta ptr+1
        clc
        adc #$D4
        sta cptr+1
        rts

; drawstr copies the zero-terminated string at msgp to the screen at ptr
; (color cptr, value clr). Source is plain ASCII; AND #$3F folds the
; printable range $20-$5F to C64 screen codes. Preserves X.
drawstr:
        ldy #$00
ds1:    lda (msgp),y
        beq ds2
        and #$3F
        sta (ptr),y
        lda clr
        sta (cptr),y
        iny
        bne ds1
ds2:    rts

; drawUI paints every static label (title, key legend, game list) from
; the parallel msg* tables.
drawUI: ldx #NMSG-1
du1:    lda msgLo,x
        sta msgp
        lda msgHi,x
        sta msgp+1
        lda msgScrLo,x
        sta ptr
        sta cptr
        lda msgScrHi,x
        sta ptr+1
        clc
        adc #$D4
        sta cptr+1
        lda msgClr,x
        sta clr
        jsr drawstr
        dex
        bpl du1
        rts

; title sets up the six MERLIN letter sprites: copy the bitmaps into
; VIC-visible RAM at $3000, point the six sprites at them, place them in
; a row, expand them 2x, and enable. Single-color white.
title:  ldx #$00                ; copy 6*64 = 384 bytes to $3000
tcp:    lda spriteSrc,x
        sta SPRDST,x
        lda spriteSrc+128,x
        sta SPRDST+128,x
        lda spriteSrc+256,x
        sta SPRDST+256,x
        inx
        cpx #128
        bne tcp

        lda #$00
        sta $D010               ; sprite X bit-8 flags, built per letter below
        ldx #NLET-1             ; per letter: data pointer + X/Y position
tpos:   txa
        clc
        adc #SPRPAGE
        sta SPRPTR,x            ; pointer = block ($C0 + letter)
        txa
        asl a
        tay                     ; Y = 2*letter -> VIC X/Y register pair
        lda sprXlo,x
        sta VSPR,y             ; sprite X (low 8 bits)
        lda #SPRY
        sta VSPR+1,y           ; sprite Y
        lda sprXhi,x           ; X bit 8 (for positions >= 256)
        beq tp1
        lda $D010
        ora bitTab,x
        sta $D010
tp1:    dex
        bpl tpos

        lda #$00
        sta $D01C               ; hi-res (not multicolor)
        sta $D01B               ; sprites in front of the background
        lda #$3F
        sta $D015               ; enable sprites 0-5
        sta $D017               ; expand 0-5 vertically
        sta $D01D               ; expand 0-5 horizontally
        ldx #NLET-1             ; all letters white
        lda #$01
tclr:   sta $D027,x
        dex
        bpl tclr
        rts

; getK returns in A the 4-bit K response for the current O scan column.
; The ROM drives O to exactly 0/4/8/12 while scanning the keypad; any
; other O reads nothing. kcol[0..3] are kept fresh by scankbd. Mirrors
; merlin/matrix.go computeK, with the column chosen by O instead of a Go
; switch.
getK:   lda tO
        beq gk0
        cmp #$04
        beq gk1
        cmp #$08
        beq gk2
        cmp #$0C
        beq gk3
        lda #$00                ; O is not a keypad scan column
        rts
gk0:    lda kcol+0
        rts
gk1:    lda kcol+1
        rts
gk2:    lda kcol+2
        rts
gk3:    lda kcol+3
        rts

; scankbd reads the C64 keyboard matrix into freshK[0..3], then merges it
; into kcol[0..3] with a per-column hold: a column that reads keys reloads
; its hold timer; a column that reads empty keeps its last value until the
; timer expires. This mirrors the Go core's minimum-hold (a tap is seen by
; the ROM's slow debounce even after the key is physically released).
; Table: per button, the CIA1 column-select to drive low, the row bit
; (0 = pressed), which scan column it feeds, and the k-bit to set.
scankbd:
        lda #$00
        sta freshK+0
        sta freshK+1
        sta freshK+2
        sta freshK+3
        ldy #NKEYS-1
skb1:   lda kbCol,y
        sta $DC00               ; drive one keyboard column low
        lda $DC01               ; read the eight rows (0 = pressed)
        and kbRow,y
        bne skb2                ; row high -> this key is up
        ldx kbIdx,y
        lda kbBit,y
        ora freshK,x
        sta freshK,x
skb2:   dey
        bpl skb1

        ldx #$03                ; merge freshK -> kcol with per-column hold
skh:    lda freshK,x
        beq skh0                ; column empty this scan
        sta kcol,x              ; keys down -> use them, reload the hold timer
        lda #KHOLD
        sta kHold,x
        jmp skh3
skh0:   lda kHold,x
        beq skh2                ; hold expired -> release the column
        dec kHold,x             ; still holding -> keep kcol,x as last value
        jmp skh3
skh2:   sta kcol,x              ; A is 0 here
skh3:   dex
        bpl skh
        rts

adca:                           ; A=val: tA += val (4-bit); S = carry out
        clc
        adc tA
        tax
        and #$0F
        sta tA
        cpx #$10                ; C = (sum >= 16)
        lda #$00
        rol a
        sta tS
        rts

adcy:                           ; A=val: tYr += val (4-bit); S = carry out
        clc
        adc tYr
        tax
        and #$0F
        sta tYr
        cpx #$10
        lda #$00
        rol a
        sta tS
        rts

; --- opcode handlers --------------------------------------------------------
; Mirrors lets-go-merlin/pkg/tms1100/ops.go one-to-one. S is preset to 1
; by the main loop; compare-style ops clear it when their condition fails.

hMNEA:  RAMX                    ; S = (ram != A)
        lda mram,x
        cmp tA
        bne hd1
        lda #$00
        sta tS
hd1:    jmp done

hALEM:  RAMX                    ; S = (A <= ram)
        lda mram,x
        cmp tA                  ; C = (ram >= A)
        lda #$00
        rol a
        sta tS
        jmp done

hYNEA:  lda #$01                ; S = SL = (A != Y)
        ldx tA
        cpx tYr
        bne yn1
        lda #$00
yn1:    sta tS
        sta tSL
        jmp done

hXMA:   RAMX                    ; swap A <-> ram
        lda mram,x
        tay
        lda tA
        sta mram,x
        sty tA
        jmp done

hDYN:   lda #$0F                ; Y -= 1; S = (Y >= 1)
        jmp adcyd
hIYC:   lda #$01                ; Y += 1; S = carry
adcyd:  jsr adcy
        jmp done

hAMAAC: RAMX                    ; A += ram; S = carry
        lda mram,x
        jsr adca
        jmp done

hDMAN:  RAMX                    ; A = ram - 1; S = (ram >= 1)
        lda mram,x
        sta tA
        lda #$0F
        jsr adca
        jmp done

hTKA:   jsr getK                ; A = K for the current scan column (tO)
        sta tA
        jmp done

hCOMX:  lda tXr                 ; X ^= 4
        eor #$04
        sta tXr
        jmp done

hTDO:   lda tA                  ; O = A | SL<<4
        ldy tSL
        beq td1
        ora #$10
td1:    sta tO
        and #$01                ; speaker line (bit 0)
        cmp sndPrev
        beq tdret               ; no edge -> nothing to do (the common case)
        sta sndPrev             ; speaker toggled: a sound is happening
        lda stepc               ; half-period = instructions since last edge
        sec
        sbc sndLast
        tax                     ; X = half-period (mod 256)
        lda stepc
        sta sndLast
        lda #$00
        sta sndSil              ; an edge happened, so not silent
        lda sndMode
        bne tdret               ; an override tune owns SID; just tracked the edge
        ldy sndState
        beq tdfirst             ; 0: first edge -> period not yet known
        cpy #$02
        beq tdplay              ; 2: already playing
tdnote: lda freqLo,x            ; 1: start the note at this pitch
        sta SIDFLO
        lda freqHi,x
        sta SIDFHI
        stx sndPitch
        lda #$02
        sta sndState
        jsr sidRetrig
        jmp done
tdplay: txa                     ; playing: retrigger only if the pitch moved
        sec                     ; more than the jitter tolerance
        sbc sndPitch            ; A = half-period - playing pitch
        bpl tdp1
        eor #$FF                ; abs()
        clc
        adc #$01
tdp1:   cmp #SNDTOL
        bcc tdret               ; within tolerance -> same note, keep playing
        jmp tdnote              ; moved enough -> a new note
tdfirst: lda #$01               ; first edge of a sound
        sta sndState
        lda #USE_HLE
        beq tdret
        jsr findSong            ; does the caller (tPB:tSR) match a known song?
        beq tdret               ; no -> let passthrough handle it
        lda #$00                ; yes -> take over with the transcribed tune
        sta songStep
        sta songFrm
        lda #$01
        sta sndMode
        jsr sndClockReset       ; timebase = now
        jsr sndFrame            ; start note 0 immediately
tdret:  jmp done

; sidRetrig restarts voice 1's envelope (gate off then on). Frequency is
; already set by the caller. Shared by the passthrough and the tune player.
sidRetrig:
        lda #SIDOFF
        sta SIDCTL
        lda #SIDON
        sta SIDCTL
        rts

; findSong searches the transcribed song table for the tone routine's
; caller (tPB:tSR). On a hit, points songP at that song's note data and
; returns A != 0; on a miss, A = 0. The table (songBlob, .incbin) is:
;   [0] count, then count x (PB, SR, offLo, offHi) headers (offset from
;   songBlob start to the note data), then the (half,frames..,0) data.
findSong:
        lda #<(songBlob+1)
        sta tmpP
        lda #>(songBlob+1)
        sta tmpP+1
        ldx songBlob            ; song count
        beq fsno
fsl:    ldy #$00
        lda (tmpP),y
        cmp tPB
        bne fsnx
        iny
        lda (tmpP),y
        cmp tSR
        bne fsnx
        ldy #$02                ; match: songP = songBlob + offset
        lda (tmpP),y
        clc
        adc #<songBlob
        sta songP
        iny
        lda (tmpP),y
        adc #>songBlob
        sta songP+1
        lda #$01
        rts
fsnx:   lda tmpP                ; next 4-byte header entry
        clc
        adc #$04
        sta tmpP
        bcc fsnx2
        inc tmpP+1
fsnx2:  dex
        bne fsl
fsno:   lda #$00
        rts

; sndClockReset snapshots the CIA #2 Timer B frame counter, so the next
; advance measures frames from now.
sndClockReset:
        lda CIA2BLO
        sta lastTLo
        lda CIA2BHI
        sta lastTHi
        rts

; sndPlayer advances the override tune by however many whole frames have
; elapsed (Timer B decrements once per ~16 ms frame). Steady tempo, not
; tied to the wobbly ledtick rate. Called per ledtick while sndMode=1.
sndPlayer:
        lda CIA2BLO             ; read frame counter (latches high on lo read)
        sta tnowLo
        lda CIA2BHI
        sta tnowHi
        lda lastTLo             ; frames due = lastTB - nowTB (B counts down)
        sec
        sbc tnowLo
        sta tmp8
        lda lastTHi
        sbc tnowHi
        beq spfd                ; high byte 0 -> frames due = tmp8
        lda #$FF
        sta tmp8                ; clamp (more than 255 frames: shouldn't happen)
spfd:   lda tmp8
        beq spdone              ; no whole frame elapsed yet
        lda tnowLo              ; consume them: timebase = now
        sta lastTLo
        lda tnowHi
        sta lastTHi
spadv:  jsr sndFrame            ; clobbers A/X/Y, so the loop counts in memory
        dec tmp8
        bne spadv
spdone: rts

; sndFrame advances the tune one frame: hold the current note, or load the
; next. The $00 terminator releases the voice and, once the ROM has gone
; quiet, hands SID back to passthrough.
sndFrame:
        lda songFrm
        beq sfnext
        dec songFrm
        rts
sfnext: lda songStep
        asl a
        tay
        lda (songP),y           ; note half-period ($00 = end)
        bne sfplay
        lda #SIDOFF
        sta SIDCTL
        lda sndSil
        cmp #SILEXIT
        bcc sfdone              ; ROM still toggling -> stay muted
        lda #$00                ; quiet -> back to passthrough, fresh
        sta sndMode
        sta sndState
        sta sndPrev
sfdone: rts
sfplay: tax                     ; X = half-period -> SID frequency
        lda freqLo,x
        sta SIDFLO
        lda freqHi,x
        sta SIDFHI
        iny
        lda (songP),y           ; frame count for this note
        sta songFrm
        inc songStep
        jmp sidRetrig

hCOMC:  lda tCB                 ; CB ^= 1
        eor #$01
        sta tCB
        jmp done

hRSTR:  lda #$00                ; R[Y] = 0  (if X<=3 && Y<=10)
        beq setr1
hSETR:  lda #$01                ; R[Y] = 1  (if X<=3 && Y<=10)
setr1:  ldx tXr
        cpx #$04
        bcs sr1
        ldx tYr
        cpx #$0B
        bcs sr1
        sta rlines,x
sr1:    jmp done

hKNEZ:  jsr getK                ; S = (K != 0)
        bne kn1                 ; K nonzero: S stays preset to 1
        sta tS                  ; K == 0 (A holds 0): S = 0
kn1:    jmp done

hRETN:  lda tPB                 ; PA = PB; pop if the call latch is set
        sta tPA
        lda tCL
        beq rt1
        lda tCS
        sta tCA
        lda tSR
        sta tPC
        lda #$00
        sta tCL
rt1:    jmp doneR               ; PA (and maybe CA) moved

hLDP:   ldx opc                 ; PB = const
        lda constTab,x
        sta tPB
        jmp done

hTAY:   lda tA                  ; Y = A
        sta tYr
        jmp done

hTMA:   RAMX                    ; A = ram
        lda mram,x
        sta tA
        jmp done

hTMY:   RAMX                    ; Y = ram
        lda mram,x
        sta tYr
        jmp done

hTYA:   lda tYr                 ; A = Y
        sta tA
        jmp done

hTAMDYN:                        ; ram = A; S = (Y >= 1); Y -= 1
        RAMX    
        lda tA
        sta mram,x
        ldy tYr
        bne tdy1
        lda #$00
        sta tS
tdy1:   dey
        tya
        and #$0F
        sta tYr
        jmp done

hTAMIYC:                        ; ram = A; S = (Y == 15); Y += 1
        RAMX    
        lda tA
        sta mram,x
        ldy tYr
        cpy #$0F
        beq tiy1
        lda #$00
        sta tS
tiy1:   iny
        tya
        and #$0F
        sta tYr
        jmp done

hTAMZA: RAMX                    ; ram = A; A = 0
        lda tA
        sta mram,x
        lda #$00
        sta tA
        jmp done

hTAM:   RAMX                    ; ram = A
        lda tA
        sta mram,x
        jmp done

hLDX:   ldx opc                 ; X = const
        lda constTab,x
        sta tXr
        jmp done

hSBIT:  RAMX                    ; ram |= mask (constTab holds the mask)
        ldy opc
        lda constTab,y
        ora mram,x
        sta mram,x
        jmp done

hRBIT:  RAMX                    ; ram &= ~mask (4-bit)
        ldy opc
        lda constTab,y
        eor #$0F
        and mram,x
        sta mram,x
        jmp done

hTBIT1: RAMX                    ; S = (ram & mask) != 0
        ldy opc
        lda constTab,y
        and mram,x
        bne tb1
        lda #$00
        sta tS
tb1:    jmp done

hSAMAN: RAMX                    ; A = ram - A (4-bit); S = (ram >= A)
        lda mram,x
        sec
        sbc tA                  ; C = no borrow = (ram >= A)
        and #$0F
        sta tA
        lda #$00
        rol a
        sta tS
        jmp done

hCPAIZ: lda tA                  ; A = -A (4-bit); S = (A was 0)
        bne cpz1
        jmp done                ; A stays 0, S stays 1
cpz1:   lda #$10
        sec
        sbc tA
        and #$0F
        sta tA
        lda #$00
        sta tS
        jmp done

hIMAC:  RAMX                    ; A = ram + 1; S = carry
        lda mram,x
        sta tA
        lda #$01
        jsr adca
        jmp done

hMNEZ:  RAMX                    ; S = (ram != 0)
        lda mram,x
        bne mz1
        lda #$00
        sta tS
mz1:    jmp done

hTCY:   ldx opc                 ; Y = const
        lda constTab,x
        sta tYr
        jmp done

hYNEC:  ldx opc                 ; S = (Y != const)
        lda constTab,x
        cmp tYr
        bne yc1
        lda #$00
        sta tS
yc1:    jmp done

hTCMIY: RAMX                    ; ram = const; Y += 1 (no status)
        ldy opc
        lda constTab,y
        sta mram,x
        lda tYr
        clc
        adc #$01
        and #$0F
        sta tYr
        jmp done

hAAAC:  ldx opc                 ; A += const; S = carry
        lda constTab,x
        jsr adca
        jmp done

hCLA:   lda #$00                ; A = 0
        sta tA
        jmp done

; --- tables -----------------------------------------------------------------

; Dispatch for opcodes $00-$7F (BR/CALL are decoded by sign bit above).
opLoTab:
        .byte <hMNEA,  <hALEM,  <hYNEA,  <hXMA,   <hDYN,   <hIYC,   <hAMAAC, <hDMAN
        .byte <hTKA,   <hCOMX,  <hTDO,   <hCOMC,  <hRSTR,  <hSETR,  <hKNEZ,  <hRETN
        .byte <hLDP,   <hLDP,   <hLDP,   <hLDP,   <hLDP,   <hLDP,   <hLDP,   <hLDP
        .byte <hLDP,   <hLDP,   <hLDP,   <hLDP,   <hLDP,   <hLDP,   <hLDP,   <hLDP
        .byte <hTAY,   <hTMA,   <hTMY,   <hTYA,   <hTAMDYN,<hTAMIYC,<hTAMZA, <hTAM
        .byte <hLDX,   <hLDX,   <hLDX,   <hLDX,   <hLDX,   <hLDX,   <hLDX,   <hLDX
        .byte <hSBIT,  <hSBIT,  <hSBIT,  <hSBIT,  <hRBIT,  <hRBIT,  <hRBIT,  <hRBIT
        .byte <hTBIT1, <hTBIT1, <hTBIT1, <hTBIT1, <hSAMAN, <hCPAIZ, <hIMAC,  <hMNEZ
        .byte <hTCY,   <hTCY,   <hTCY,   <hTCY,   <hTCY,   <hTCY,   <hTCY,   <hTCY
        .byte <hTCY,   <hTCY,   <hTCY,   <hTCY,   <hTCY,   <hTCY,   <hTCY,   <hTCY
        .byte <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC
        .byte <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC,  <hYNEC
        .byte <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY
        .byte <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY, <hTCMIY
        .byte <hAAAC,  <hAAAC,  <hAAAC,  <hAAAC,  <hAAAC,  <hAAAC,  <hAAAC,  <hAAAC
        .byte <hAAAC,  <hAAAC,  <hAAAC,  <hAAAC,  <hAAAC,  <hAAAC,  <hAAAC,  <hCLA

opHiTab:
        .byte >hMNEA,  >hALEM,  >hYNEA,  >hXMA,   >hDYN,   >hIYC,   >hAMAAC, >hDMAN
        .byte >hTKA,   >hCOMX,  >hTDO,   >hCOMC,  >hRSTR,  >hSETR,  >hKNEZ,  >hRETN
        .byte >hLDP,   >hLDP,   >hLDP,   >hLDP,   >hLDP,   >hLDP,   >hLDP,   >hLDP
        .byte >hLDP,   >hLDP,   >hLDP,   >hLDP,   >hLDP,   >hLDP,   >hLDP,   >hLDP
        .byte >hTAY,   >hTMA,   >hTMY,   >hTYA,   >hTAMDYN,>hTAMIYC,>hTAMZA, >hTAM
        .byte >hLDX,   >hLDX,   >hLDX,   >hLDX,   >hLDX,   >hLDX,   >hLDX,   >hLDX
        .byte >hSBIT,  >hSBIT,  >hSBIT,  >hSBIT,  >hRBIT,  >hRBIT,  >hRBIT,  >hRBIT
        .byte >hTBIT1, >hTBIT1, >hTBIT1, >hTBIT1, >hSAMAN, >hCPAIZ, >hIMAC,  >hMNEZ
        .byte >hTCY,   >hTCY,   >hTCY,   >hTCY,   >hTCY,   >hTCY,   >hTCY,   >hTCY
        .byte >hTCY,   >hTCY,   >hTCY,   >hTCY,   >hTCY,   >hTCY,   >hTCY,   >hTCY
        .byte >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC
        .byte >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC,  >hYNEC
        .byte >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY
        .byte >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY, >hTCMIY
        .byte >hAAAC,  >hAAAC,  >hAAAC,  >hAAAC,  >hAAAC,  >hAAAC,  >hAAAC,  >hAAAC
        .byte >hAAAC,  >hAAAC,  >hAAAC,  >hAAAC,  >hAAAC,  >hAAAC,  >hAAAC,  >hCLA

; Embedded constants per opcode (ops.go's opConst). For SBIT/RBIT/TBIT1
; ($30-$3B) this holds the *mask* (1 << bit), not the bit number.
constTab:
        .byte 0, 0, 0, 0, 0, 0, 0, 0           ; $00-$07
        .byte 0, 0, 0, 0, 0, 0, 0, 0           ; $08-$0F
        .byte 0, 8, 4, 12, 2, 10, 6, 14        ; $10-$1F LDP
        .byte 1, 9, 5, 13, 3, 11, 7, 15
        .byte 0, 0, 0, 0, 0, 0, 0, 0           ; $20-$27
        .byte 0, 4, 2, 6, 1, 5, 3, 7           ; $28-$2F LDX
        .byte 1, 4, 2, 8                       ; $30-$33 SBIT masks
        .byte 1, 4, 2, 8                       ; $34-$37 RBIT masks
        .byte 1, 4, 2, 8                       ; $38-$3B TBIT1 masks
        .byte 0, 0, 0, 0                       ; $3C-$3F
        .byte 0, 8, 4, 12, 2, 10, 6, 14        ; $40-$4F TCY
        .byte 1, 9, 5, 13, 3, 11, 7, 15
        .byte 0, 8, 4, 12, 2, 10, 6, 14        ; $50-$5F YNEC
        .byte 1, 9, 5, 13, 3, 11, 7, 15
        .byte 0, 8, 4, 12, 2, 10, 6, 14        ; $60-$6F TCMIY
        .byte 1, 9, 5, 13, 3, 11, 7, 15
        .byte 1, 9, 5, 13, 3, 11, 7, 15        ; $70-$7E A*AAC
        .byte 2, 10, 6, 14, 4, 12, 8, 0        ; ($7F is CLA)

paLoTab:                                       ; (PA & 3) << 6
        .byte $00, $40, $80, $C0, $00, $40, $80, $C0
        .byte $00, $40, $80, $C0, $00, $40, $80, $C0
paHiTab:                                       ; PA >> 2
        .byte 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3
xshTab:                                        ; X << 4
        .byte $00, $10, $20, $30, $40, $50, $60, $70

; Keyboard scan table (NKEYS entries). Per Merlin button: the CIA1
; column-select byte (~(1<<c64col)), the row bit to test on $DC01, the
; target kcol (0..3 = scan columns O0..O3), and the k-bit to OR in. The
; k-bit assignments reproduce merlin/matrix.go computeK exactly.
;            button   C64 key   (col,row)   kcol  kbit
kbCol:  .byte $7F  ; pad1  '1'       7,0       0     2
        .byte $7F  ; pad0  LEFT-ARR  7,1       0     1
        .byte $7F  ; pad2  '2'       7,3       0     8
        .byte $FD  ; pad3  '3'       1,0       0     4
        .byte $FD  ; pad4  '4'       1,3       1     1
        .byte $FD  ; same  'S'       1,5       2     4
        .byte $FB  ; pad5  '5'       2,0       1     2
        .byte $FB  ; pad6  '6'       2,3       1     8
        .byte $FB  ; comp  'C'       2,4       3     2
        .byte $F7  ; pad7  '7'       3,0       1     4
        .byte $F7  ; pad8  '8'       3,3       2     1
        .byte $F7  ; hit   'H'       3,5       3     4
        .byte $EF  ; pad9  '9'       4,0       2     2
        .byte $EF  ; pad10 '0'       4,3       2     8
        .byte $EF  ; new   'N'       4,7       3     8
kbRow:  .byte $01, $02, $08, $01, $08, $20, $01, $08, $10, $01, $08, $20, $01, $08, $80
kbIdx:  .byte 0,   0,   0,   0,   1,   2,   1,   1,   3,   1,   2,   3,   2,   2,   3
kbBit:  .byte 2,   1,   8,   4,   1,   4,   2,   8,   2,   4,   1,   4,   2,   8,   8

; Screen address of each pad's '[' (key cell is +1, ']' is +2). The
; cluster sits high on the screen; the legend and game list go below.
scrLo:
        .byte <(scrn+5*40+19)                   ; pad 0  (top)
        .byte <(scrn+7*40+16),  <(scrn+7*40+19),  <(scrn+7*40+22)
        .byte <(scrn+9*40+16),  <(scrn+9*40+19),  <(scrn+9*40+22)
        .byte <(scrn+11*40+16), <(scrn+11*40+19), <(scrn+11*40+22)
        .byte <(scrn+13*40+19)                  ; pad 10 (bottom)
scrHi:
        .byte >(scrn+5*40+19)
        .byte >(scrn+7*40+16),  >(scrn+7*40+19),  >(scrn+7*40+22)
        .byte >(scrn+9*40+16),  >(scrn+9*40+19),  >(scrn+9*40+22)
        .byte >(scrn+11*40+16), >(scrn+11*40+19), >(scrn+11*40+22)
        .byte >(scrn+13*40+19)

; The key glyph shown in each pad's middle cell while it is unlit
; (screen codes): pad0 = left-arrow, pads 1..9 = digits, pad10 = '0'.
padGlyph:
        .byte $1F                              ; pad 0  : left-arrow
        .byte $31, $32, $33                    ; pads 1-3
        .byte $34, $35, $36                    ; pads 4-6
        .byte $37, $38, $39                    ; pads 7-9
        .byte $30                              ; pad 10 : '0'

; Sprite X positions (MERLIN letters, left to right), as low byte + bit 8.
; The last letter sits at 260, so its high bit is set in $D010 via bitTab.
sprXlo: .byte 100, 132, 164, 196, 228, 4     ; 4 = 260 - 256
sprXhi: .byte 0,   0,   0,   0,   0,   1
bitTab: .byte 1, 2, 4, 8, 16, 32             ; 1<<sprite, for the $D010 flags

; Static labels: parallel address / screen-position / color tables, plus
; the strings themselves (ASCII; drawstr folds them to screen codes).
; The title is drawn with sprites, so it is not in this table.
msgLo:    .byte <sNew, <sSame, <sHit, <sComp, <sHdr
          .byte <sG1, <sG2, <sG3, <sG4, <sG5, <sG6
msgHi:    .byte >sNew, >sSame, >sHit, >sComp, >sHdr
          .byte >sG1, >sG2, >sG3, >sG4, >sG5, >sG6
msgScrLo: .byte <(scrn+17*40+7),  <(scrn+17*40+21)
          .byte <(scrn+18*40+7),  <(scrn+18*40+21)
          .byte <(scrn+20*40+7)                ; GAMES header
          .byte <(scrn+22*40+5),  <(scrn+23*40+5),  <(scrn+24*40+5)
          .byte <(scrn+22*40+21), <(scrn+23*40+21), <(scrn+24*40+21)
msgScrHi: .byte >(scrn+17*40+7),  >(scrn+17*40+21)
          .byte >(scrn+18*40+7),  >(scrn+18*40+21)
          .byte >(scrn+20*40+7)
          .byte >(scrn+22*40+5),  >(scrn+23*40+5),  >(scrn+24*40+5)
          .byte >(scrn+22*40+21), >(scrn+23*40+21), >(scrn+24*40+21)
msgClr:   .byte CKEYS, CKEYS, CKEYS, CKEYS, CHDR
          .byte CGAME, CGAME, CGAME, CGAME, CGAME, CGAME

sNew:   .asciiz "N=NEW GAME"
sSame:  .asciiz "S=SAME GAME"
sHit:   .asciiz "H=HIT ME"
sComp:  .asciiz "C=COMP TURN"
sHdr:   .asciiz "GAMES - PRESS N THEN 1-6"
sG1:    .asciiz "1 TIC-TAC-TOE"
sG2:    .asciiz "2 MUSIC MACHINE"
sG3:    .asciiz "3 ECHO"
sG4:    .asciiz "4 BLACKJACK 13"
sG5:    .asciiz "5 MAGIC SQUARE"
sG6:    .asciiz "6 MINDBENDER"

; Title shimmer wave (SHIMW entries): as it sweeps, each letter steps
; white(idle) -> yellow -> orange -> red -> orange -> yellow -> white.
waveTab: .byte $07, $08, $02, $08, $07, $01, $01

; Credits screen: parallel address / screen-position / colour tables and
; the lines (must be UPPERCASE — drawstr folds ASCII to screen codes).
credLo:    .byte <sCr1, <sCr2, <sCr3, <sCr4, <sCr5, <sCr6, <sCr7
credHi:    .byte >sCr1, >sCr2, >sCr3, >sCr4, >sCr5, >sCr6, >sCr7
credScrLo: .byte <(scrn+5*40+14),  <(scrn+7*40+11),  <(scrn+9*40+9)
           .byte <(scrn+11*40+13), <(scrn+12*40+5),  <(scrn+15*40+5)
           .byte <(scrn+18*40+8)
credScrHi: .byte >(scrn+5*40+14),  >(scrn+7*40+11),  >(scrn+9*40+9)
           .byte >(scrn+11*40+13), >(scrn+12*40+5),  >(scrn+15*40+5)
           .byte >(scrn+18*40+8)
credClr:   .byte $01, $0F, $0F, $03, $03, $0E, $07

sCr1:   .asciiz "1978 MERLIN"
sCr2:   .asciiz "BY MILTON BRADLEY"
sCr3:   .asciiz "DESIGNED BY BOB DOYLE"
sCr4:   .asciiz "ROM DECODE BY"
sCr5:   .asciiz "DOMINIC THIBODEAU (HOTKEYSOFT)"
sCr6:   .asciiz "MORE INFO: THECARLEDWARDS.COM"
sCr7:   .asciiz "PRESS ANY KEY TO RETURN"

; MERLIN title sprite bitmaps (6 x 64 bytes), generated by `go run ./gen`.
; Copied to $3000 at init (see the title routine).
spriteSrc: .incbin "sprites.bin"

; Half-period -> SID frequency word, indexed by the toggle half-period in
; instructions (512 bytes: 256 low bytes then 256 high bytes). Generated
; by `go run ./gen`; lets hTDO set the pitch with two table reads.
freqLo: .incbin "sidfreq.bin"
freqHi = freqLo + 256

; Transcribed sound table, generated by `go run ./gen` (see songgen): a
; count, then per-song (caller PB, caller SR, data-offset) headers keyed by
; the tone routine's caller, then (half-period, frames) note data. findSong
; matches tPB:tSR here; the player reads the notes. Built from the accurate
; Go core, so pitch and tempo track real Merlin.
songBlob: .incbin "songs.bin"

; The unscrambled MP3404 ROM (2048 bytes), generated by `go run ./gen`.
romdat: .incbin "rom.bin"

; --- mutable state -----------------------------------------------------------

mram:   .res 128, $00           ; 8 pages x 16 nibbles (init refills with $0A)
rlines: .res 11, $00            ; R0-R10 latches
fresh:  .res 11, $00            ; per-pad LED freshness counters
