// 3D Starfield (table-driven projection) for C64
//
// Core idea:
// - Each star has a small signed world-space X/Y plus a depth Z.
// - Instead of doing per-frame multiply/divide to project 3D -> 2D,
//   runtime uses lookup tables indexed by depth and X/Y.
// - Each projected star becomes a single custom-charset pixel inside a
//   normal text cell, which is much cheaper than bitmap plotting.
//
// Frame flow:
// 1. Wait for a stable raster point.
// 2. Erase every star at its previously drawn screen cell.
// 3. Decrease depth so the star moves toward the camera.
// 4. Reproject via LUTs.
// 5. Draw the new projected position and remember that exact cell address.
//
// Left/Right adjust star count, Up/Down adjust speed, SPACE exits.

// BASIC stub at $0801: equivalent to a tiny BASIC program containing
// SYS 2064 so the PRG can be loaded and started with RUN.
.pc = $0801
.byte $0c, $08
.word 10
.byte $9e
.text "2064"
.byte 0
.byte 0, 0

// Machine-code entry point.
.pc = $0810

// Screen RAM and color RAM in VIC bank 0.
.const SCRN      = $0400
.const COL       = $D800

// Star slot allocation. All MAX_STARS slots are initialised at startup;
// ActiveStars (runtime variable below) controls how many are animated.
.const MAX_STARS  = 24
.const INIT_STARS = 16   // starting count
.const MIN_STARS  = 4    // floor for down-arrow key

// Runtime speed control as a fixed-point frame step (0..255).
// 0 = stop, 255 ~= almost 1 depth step per frame.
.const MIN_SPEED  = 0
.const MAX_SPEED  = 255
.const INIT_SPEED = 64

// Charset index 64 is an all-zero blank character used for clearing.
.const BLANK     = 64

// Border debug colors for per-phase timing markers.
.const DBG_BDR_ERASE = 2
.const DBG_BDR_DRAW  = 5

// Valid depth range. Smaller Z = closer to camera.
.const Z_MIN     = 8
.const Z_MAX     = 63
.const Z_COUNT   = (Z_MAX - Z_MIN + 1)

// Small zero-page workspace. Using zero page keeps pointer-heavy code fast.
.const ZP_IDX    = $02
.const ZP_TMP    = $03
.const ZP_PX     = $04
.const ZP_PY     = $05
.const ZP_SUBX   = $06
.const ZP_SUBY   = $07

Main:
  // Disable IRQ while our effect runs so timing and draw bookkeeping stay
  // deterministic. We re-enable it on exit before returning to BASIC.
  sei

  // Select VIC bank 0 ($0000-$3fff) via CIA2.
  // Bits 0-1 of $DD00 are inverted bank selects.
  lda $dd00
  and #$fc
  ora #$03
  sta $dd00

  // VIC-II setup:
  // $D011 = normal text mode, screen on, 25 rows.
  // $D016 = normal 40-column mode.
  // $D018 = screen at $0400 and charset at $2000.
  lda #$1b
  sta $d011
  lda #$08
  sta $d016
  lda #$18
  sta $d018

  // Black border and black background.
  lda #0
  sta $d020
  sta $d021

  // Fill all 1000 screen cells with BLANK (custom char 64).
  lda #BLANK
  ldx #0
ClrScr:
  sta SCRN,x
  sta SCRN+$100,x
  sta SCRN+$200,x
  sta SCRN+$300,x
  inx
  bne ClrScr

  // Clear color RAM so no stale colors remain from previous programs.
  lda #0
  ldx #0
ClrCol:
  sta COL,x
  sta COL+$100,x
  sta COL+$200,x
  sta COL+$300,x
  inx
  bne ClrCol

  // Seed RNG from a changing raster register value. The exact seed is not
  // critical; we just want something non-constant at startup.
  lda #0
  ldx #0
SeedLoop:
  // Mix in current raster line.
  eor $d012
  // Add an odd constant to keep values moving.
  adc #$31
  inx
  bne SeedLoop
  // Ensure non-zero LFSR state.
  ora #$01
  sta RngLo
  // Derive a different high byte from the mixed result.
  eor #$c7
  ora #$80
  sta RngHi

  // Initialise all MAX_STARS slots so every slot has valid data.
  // ActiveStars controls how many are actually animated each frame.
  lda #INIT_STARS
  sta ActiveStars
  ldx #0
InitStars:
  stx ZP_IDX
  jsr RespawnStar
  ldx ZP_IDX
  inx
  cpx #MAX_STARS
  bne InitStars

  // Ignore any key still held from RUN/SYS by waiting for a full release.
WaitRelease:
  jsr WaitFrame
  // Keyboard scan trick: compare CIA result with all rows deselected vs.
  // all rows selected. If different, some key is still held.
  lda #$ff
  sta $dc00
  lda $dc01
  sta ZP_TMP
  lda #$00
  sta $dc00
  lda $dc01
  cmp ZP_TMP
  bne WaitRelease

FrameLoop:
  // Sync to one raster point each frame. This is a simple frame limiter.
  jsr WaitFrame          // c6

  // Debug timing marker: erase phase.
  lda #DBG_BDR_ERASE     // c2
  sta $d020              // c4

  // Erase previous frame stars.
  // OldOfsLo/Hi already contain the exact address of the previously drawn
  // screen cell, so we can blank it with a single indirect write.
  ldx #0                 // c2
EraseLoop:
  // Zero OldOfsHi means "this star has nothing valid to erase".
  lda OldOfsHi,x         // c4
  beq EraseNext          // c2/3
  sta $fc                // c3
  lda OldOfsLo,x         // c4
  sta $fb                // c3
  ldy #0                 // c2
  lda #BLANK             // c2
  sta ($fb),y            // c6
  // Invalidate saved address after erase so we never erase the same stale
  // cell twice if the star is skipped later.
  lda #0                 // c2
  sta OldOfsLo,x         // c5
  sta OldOfsHi,x         // c5
EraseNext:
  inx                    // c2
  cpx ActiveStars        // c3
  bne EraseLoop          // c2/3

  // Debug timing marker: project + draw phase.
  lda #DBG_BDR_DRAW      // c2
  sta $d020              // c4

  // Convert fine-grained Speed (0..255) into a per-frame move flag.
  clc                    // c2
  lda MoveAcc            // c3
  adc Speed              // c3
  sta MoveAcc            // c3
  lda #0                 // c2
  adc #0                 // c2
  sta MoveNow            // c3

  // Move + project + draw each star.
  ldx #0                 // c2
StarLoop:
  stx ZP_IDX             // c3

  // Move this star only when the frame accumulator overflowed.
  lda MoveNow            // c3
  beq CheckNearPlane     // c2/3
  dec ZPos,x             // c7
CheckNearPlane:
  lda ZPos,x             // c4
  // If it reached/passed the near plane, respawn it at a fresh far depth.
  cmp #Z_MIN             // c2
  bcs ZOk                // c2/3
  jsr RespawnStar        // c6
  ldx ZP_IDX             // c3
ZOk:
  // Try projecting the star. Carry clear means it landed on-screen.
  jsr ProjectStar        // c6
  bcc DrawNow            // c2/3

  // If the star projected off-screen, respawn and try once more.
  jsr RespawnStar        // c6
  ldx ZP_IDX             // c3
  jsr ProjectStar        // c6
  // Still off-screen? Skip drawing this star this frame.
  bcs SkipDraw           // c2/3

DrawNow:
  jsr DrawProjected      // c6
  jmp NextStar           // c3
SkipDraw:
  ldx ZP_IDX             // c3
  // Ensure skipped stars do not leave any old cell registered for erase.
  lda #0                 // c2
  sta OldOfsLo,x         // c5
  sta OldOfsHi,x         // c5
NextStar:
  ldx ZP_IDX             // c3
  inx                    // c2
  cpx ActiveStars        // c3
  bne StarLoop           // c2/3

  // End debug timing marker.
  lda #0                 // c2
  sta $d020              // c4

  // Update debug star count display at bottom-right.
  jsr ShowStarCount
  // Update debug speed display at bottom-left.
  jsr ShowSpeed

  // Key handling.
  // C64 keyboard matrix (active-low rows via $DC00, columns read from $DC01):
  //   CRSR RIGHT = Row 0 ($DC00=$FE), bit 2
  //   RSHIFT     = Row 6 ($DC00=$BF), bit 4
  //   CRSR DOWN  = Row 0 ($DC00=$FE), bit 7
  //   LSHIFT     = Row 1 ($DC00=$FD), bit 7
  //   SPACE      = Row 7 ($DC00=$7F), bit 4
  //
  // CRSR RIGHT alone        -> increase star count (up to MAX_STARS)
  // RSHIFT + CRSR RIGHT     -> logical cursor-left -> decrease star count
  // CRSR DOWN alone         -> decrease speed (down to 0 / stop)
  // LSHIFT + CRSR DOWN      -> logical cursor-up -> increase speed
  // SPACE                   -> exit to BASIC
  //
  // KeyHeld prevents repeated firing while the key stays held.

  // Read CRSR RIGHT (Row 0, bit 2).
  lda #$fe
  sta $dc00
  lda $dc01
  and #$04
  bne NoHorizKey          // bit2=1 -> not pressed

  // CRSR RIGHT key is pressed. Check RSHIFT (Row 6, bit 4).
  lda #$bf
  sta $dc00
  lda $dc01
  and #$10
  bne TryIncStars         // bit4=1 -> no shift -> logical cursor-right

  // RSHIFT + CRSR RIGHT = logical cursor-left -> decrease stars.
  lda KeyHeld
  bne CrsrKeyDone
  lda ActiveStars
  cmp #MIN_STARS
  beq MarkCrsrHeld
  // Remove the highest active slot, but erase its currently drawn cell
  // first so it cannot leave a static remnant when dropped from the loop.
  sec
  sbc #1
  tax
  lda OldOfsHi,x
  beq ClearDroppedPtr
  sta $fc
  lda OldOfsLo,x
  sta $fb
  ldy #0
  lda #BLANK
  sta ($fb),y
ClearDroppedPtr:
  dec ActiveStars
  // Slot just deactivated: invalidate its saved erase pointer.
  lda #0
  sta OldOfsLo,x
  sta OldOfsHi,x
  jmp MarkCrsrHeld

TryIncStars:
  // CRSR RIGHT without RSHIFT -> increase stars.
  lda KeyHeld
  bne CrsrKeyDone
  lda ActiveStars
  cmp #MAX_STARS
  beq MarkCrsrHeld
  ldx ActiveStars         // current count is the index of the new slot
  stx ZP_IDX
  jsr RespawnStar         // give the new slot fresh random coords
  inc ActiveStars

MarkCrsrHeld:
  lda #1
  sta KeyHeld

CrsrKeyDone:
  jmp FrameLoop

NoHorizKey:
  // Horizontal cursor key not pressed. Check vertical cursor key for speed.
  lda #$fe
  sta $dc00
  lda $dc01
  and #$80
  bne NoSpeedKey          // bit7=1 -> CRSR DOWN not pressed

  // CRSR DOWN key is pressed. Check LSHIFT for logical cursor-up.
  lda #$fd
  sta $dc00
  lda $dc01
  and #$80
  bne TryDecSpeed         // bit7=1 -> no shift -> logical cursor-down

  // LSHIFT + CRSR DOWN = logical cursor-up -> increase speed.
  lda KeyHeld
  bne SpeedKeyDone
  lda Speed
  cmp #MAX_SPEED
  beq MarkSpeedHeld
  inc Speed
  jmp MarkSpeedHeld

TryDecSpeed:
  // CRSR DOWN without LSHIFT -> decrease speed.
  lda KeyHeld
  bne SpeedKeyDone
  lda Speed
  cmp #MIN_SPEED
  beq MarkSpeedHeld
  dec Speed

MarkSpeedHeld:
  lda #1
  sta KeyHeld

SpeedKeyDone:
  jmp FrameLoop

NoSpeedKey:
  // No control key pressed -> clear held flag.
  lda #0
  sta KeyHeld
  // SPACE bar (row 7, bit 4) -> exit to BASIC.
  lda #$7f
  sta $dc00
  lda $dc01
  and #$10
  beq ExitNow     // bit4=0 means space is pressed
  jmp FrameLoop

ExitNow:
  // Restore normal IRQ-driven BASIC environment and return.
  lda #$ff
  sta $dc00
  cli
  jsr $ff81
  rts

// ------------------------------------------------------------
// Project current star using precomputed LUTs.
//
// Input:
// - current star index in ZP_IDX
// - XPos/YPos/ZPos tables hold world-space coordinates
//
// Output on carry clear:
// - ZP_PX   = screen character X (0..39)
// - ZP_PY   = screen character Y (0..24)
// - ZP_SUBX = pixel X within the 8x8 custom char (0..7)
// - ZP_SUBY = pixel Y within the 8x8 custom char (0..7)
//
// Output on carry set:
// - star projects outside the visible 320x200 area
// ------------------------------------------------------------
ProjectStar:
  ldx ZP_IDX             // c3

  // Convert depth Z into a zero-based LUT depth index.
  lda ZPos,x             // c4
  sec                    // c2
  sbc #Z_MIN             // c2
  tay                    // c2
  sty ZP_TMP             // c3

  // Convert signed X world coordinate [-31..31] to a LUT index [0..62].
  ldx ZP_IDX             // c3
  lda XPos,x             // c4
  clc                    // c2
  adc #31                // c2
  tay                    // c2

  // Read projected character column from the depth-specific X LUT.
  ldx ZP_TMP             // c3
  lda XCharPtrLo,x       // c4
  sta $fb                // c3
  lda XCharPtrHi,x       // c4
  sta $fc                // c3
  lda ($fb),y            // c5(+1)
  // $FF marks "this depth/X combination is off-screen".
  cmp #$ff               // c2
  beq ProjOut            // c2/3
  sta ZP_PX              // c3

  // Read projected pixel-within-cell X from companion LUT.
  ldx ZP_TMP             // c3
  lda XSubPtrLo,x        // c4
  sta $fb                // c3
  lda XSubPtrHi,x        // c4
  sta $fc                // c3
  lda ($fb),y            // c5(+1)
  sta ZP_SUBX            // c3

  // Convert signed Y world coordinate [-23..23] to a LUT index [0..46].
  ldx ZP_IDX             // c3
  lda YPos,x             // c4
  clc                    // c2
  adc #23                // c2
  tay                    // c2

  // Read projected character row from the depth-specific Y LUT.
  ldx ZP_TMP             // c3
  lda YCharPtrLo,x       // c4
  sta $fb                // c3
  lda YCharPtrHi,x       // c4
  sta $fc                // c3
  lda ($fb),y            // c5(+1)
  cmp #$ff               // c2
  beq ProjOut            // c2/3
  sta ZP_PY              // c3

  // Read projected pixel-within-cell Y from companion LUT.
  ldx ZP_TMP             // c3
  lda YSubPtrLo,x        // c4
  sta $fb                // c3
  lda YSubPtrHi,x        // c4
  sta $fc                // c3
  lda ($fb),y            // c5(+1)
  sta ZP_SUBY            // c3

  // Visible.
  clc                    // c2
  rts                    // c6

ProjOut:
  // Off-screen.
  sec                    // c2
  rts                    // c6

// ------------------------------------------------------------
// Draw projected star for index in ZP_IDX.
// This routine writes both screen RAM (character index) and color RAM.
// ------------------------------------------------------------
DrawProjected:
  // Build screen pointer for row ZP_PY.
  lda ZP_PY              // c3
  tay                    // c2
  lda RowTableLo,y       // c4
  sta $fb                // c3
  lda RowTableHi,y       // c4
  clc                    // c2
  adc #>SCRN             // c2
  sta $fc                // c3

  // Select the target screen column.
  ldy ZP_PX              // c3

  // Combine sub-Y (row 0..7) and sub-X (bit 0..7) into a character index
  // 0..63. The custom charset maps each of these 64 chars to a single pixel
  // inside the 8x8 cell.
  lda ZP_SUBY            // c3
  asl                    // c2
  asl                    // c2
  asl                    // c2
  sta ZP_TMP             // c3
  lda ZP_SUBX            // c3
  ora ZP_TMP             // c3
DrawChar:
  // Write the chosen custom character into screen RAM.
  sta ($fb),y            // c6

  // Save exact previous cell pointer for next-frame erase
  ldx ZP_IDX             // c3
  // Old cell address = row base pointer + X column.
  tya                    // c2
  clc                    // c2
  adc $fb                // c3
  sta OldOfsLo,x         // c5
  lda $fc                // c3
  adc #0                 // c2
  sta OldOfsHi,x         // c5

  // Build matching color RAM pointer for the same row.
  lda ZP_PY              // c3
  tay                    // c2
  lda RowTableLo,y       // c4
  sta $fd                // c3
  lda RowTableHi,y       // c4
  clc                    // c2
  adc #>COL              // c2
  sta $fe                // c3

  // Pick color by depth so near stars look brighter.
  ldx ZP_IDX             // c3
  lda ZPos,x             // c4
  cmp #14                // c2
  bcc NearCol            // c2/3
  cmp #30                // c2
  bcc MidCol             // c2/3
  lda #$0b               // c2
  bne ColOut             // c3 (always)
MidCol:
  lda #$0f               // c2
  bne ColOut             // c3 (always)
NearCol:
  lda #$01               // c2
ColOut:
  // Write color into the same column in color RAM.
  ldy ZP_PX              // c3
  sta ($fd),y            // c6
  rts                    // c6

// ------------------------------------------------------------
// Respawn star in index ZP_IDX.
// X in [-31..31], Y in [-23..23], Z in [8..63]
// The ranges intentionally match the bounds covered by the LUTs.
// ------------------------------------------------------------
RespawnStar:
  ldx ZP_IDX

RandX:
  // Generate 0..63, reject 63, then bias to signed range -31..31.
  jsr Rng
  and #$3f
  cmp #63
  beq RandX
  sec
  sbc #31
  sta XPos,x

RandY:
  // Generate 0..63, reject 47..63, then bias to signed range -23..23.
  // Get next pseudo-random byte in A.
  jsr Rng
  // Keep only lower 6 bits so A is 0..63.
  and #$3f
  // Accept only 0..46. Values 47..63 would map outside desired Y range.
  cmp #47
  // If A >= 47, reject and try again.
  bcs RandY
  // Prepare for exact subtraction A - 23.
  sec
  // Remap 0..46 -> -23..23.
  sbc #23
  // Store signed Y coordinate for this star slot.
  sta YPos,x

RandZ:
  // Generate 0..63, reject 56..63, then add Z_MIN => 8..63.
  // Get next pseudo-random byte in A.
  jsr Rng
  // Keep only lower 6 bits so A is 0..63.
  and #$3f
  // Accept only 0..55 so adding Z_MIN yields 8..63.
  cmp #56
  // If A >= 56, reject and try again.
  bcs RandZ
  // Prepare for exact addition.
  clc
  // Remap 0..55 -> 8..63 (valid depth range).
  adc #Z_MIN
  // Store depth for this star slot.
  sta ZPos,x

  // No valid old screen address yet for this newly respawned star.
  // Clearing both bytes marks "no previous cell to erase".
  lda #0
  sta OldOfsLo,x
  sta OldOfsHi,x
  // Return to caller with fresh X/Y/Z and cleared old address pointer.
  rts

// Wait for raster line 250 to roll over.
// This gives one rough frame tick without installing an IRQ handler.
WaitFrame:
WF1:
  lda $d012
  cmp #250
  bcs WF1
WF2:
  lda $d012
  cmp #250
  bcc WF2
  rts

// Display ActiveStars as a 2-digit decimal counter at the bottom-right
// corner of the screen (cells SCRN+998 and SCRN+999).
// Digits use charset chars 65-74 (='0'..'9').
ShowStarCount:
  // A = current active star count (range 4..24 in this program).
  lda ActiveStars
  // X accumulates the decimal tens digit while we peel off 10s from A.
  ldx #0
DigTens:
  // If A < 10 we are done: A is units, X is tens.
  cmp #10
  bcc GotTens
  // Subtract one decimal ten from A and count it in X.
  sec
  sbc #10
  inx
  jmp DigTens
GotTens:
  // Save units (currently in A) while we output the tens digit first.
  pha
  // Move tens digit from X -> A.
  txa
  // Convert numeric digit 0..9 to charset digit code 65..74.
  clc
  adc #65
  // Write tens digit to bottom-right tens position (col 38, row 24).
  sta SCRN+998
  // Make the tens digit white.
  lda #1
  sta COL+998

  // Restore units digit and do the same digit-code conversion.
  pla
  clc
  adc #65
  // Write units digit to final bottom-right cell (col 39, row 24).
  sta SCRN+999
  // Make the units digit white.
  lda #1
  sta COL+999
  rts

// Display Speed as a 3-digit decimal counter at the bottom-left
// corner of the screen (cells SCRN+960..SCRN+962).
// Digits use charset chars 65-74 (='0'..'9').
ShowSpeed:
  lda Speed
  ldx #0
SpdHund:
  cmp #100
  bcc SpdGotHund
  sec
  sbc #100
  inx
  jmp SpdHund
SpdGotHund:
  stx ZP_PX            // hundreds
  ldy #0
SpdTens:
  cmp #10
  bcc SpdGotTens
  sec
  sbc #10
  iny
  jmp SpdTens
SpdGotTens:
  sta ZP_PY            // units

  lda ZP_PX
  clc
  adc #65
  sta SCRN+960
  lda #1
  sta COL+960

  tya
  clc
  adc #65
  sta SCRN+961
  lda #1
  sta COL+961

  lda ZP_PY
  clc
  adc #65
  sta SCRN+962
  lda #1
  sta COL+962
  rts

// 16-bit Galois LFSR.
// Cheap pseudo-random generator suitable for star respawn positions.
Rng:
  // Shift 16-bit state right by 1.
  lsr RngHi
  ror RngLo
  // If carry was set, apply the feedback polynomial.
  bcc RngDone
  lda RngHi
  eor #$d0
  sta RngHi
  lda RngLo
  eor #$08
  sta RngLo
RngDone:
  lda RngLo
  eor RngHi
  rts

RngLo: .byte $01
RngHi: .byte $01

// Runtime star count (4..24) adjusted by cursor keys.
ActiveStars: .byte INIT_STARS
// Runtime starfield speed (0..255). 0 = stop.
Speed: .byte INIT_SPEED
// Fine-grained movement accumulator and per-frame move flag.
MoveAcc: .byte 0
MoveNow: .byte 0
// Debounce flag: 1 while a cursor key is held, 0 when released.
KeyHeld: .byte 0

// 40-byte row offset tables for the 25 text rows.
RowTableLo:
  .fill 25, <(i * 40)
RowTableHi:
  .fill 25, >(i * 40)

// Per-star world state and saved previous screen cell pointer.
// Allocated for all MAX_STARS slots; only ActiveStars are used each frame.
XPos: .fill MAX_STARS, 0
YPos: .fill MAX_STARS, 0
ZPos: .fill MAX_STARS, 0
OldOfsLo: .fill MAX_STARS, 0
OldOfsHi: .fill MAX_STARS, 0

// ------------------------------------------------------------
// Custom charset: 0..63 single-pixel subcell, 64 blank.
//
// Character mapping:
// - char = subY * 8 + subX
// - exactly one bit is set in exactly one row
// - this gives us an effective 320x200 plotting grid while still using
//   ordinary text mode and one byte per star draw
// ------------------------------------------------------------
.pc = $2000
.for (var c = 0; c < 256; c++) {
  .if (c < 64) {
    .for (var row = 0; row < 8; row++) {
      .if (row == floor(c / 8)) {
        .byte 1 << (7 - mod(c, 8))
      } else {
        .byte 0
      }
    }
  } else .if (c == 64) {
    .fill 8, 0
  } else .if (c == 65) {  // '0'
    .byte $3c, $66, $6e, $76, $66, $66, $3c, $00
  } else .if (c == 66) {  // '1'
    .byte $18, $38, $18, $18, $18, $18, $3c, $00
  } else .if (c == 67) {  // '2'
    .byte $3c, $66, $06, $0c, $18, $30, $7e, $00
  } else .if (c == 68) {  // '3'
    .byte $3c, $66, $06, $1c, $06, $66, $3c, $00
  } else .if (c == 69) {  // '4'
    .byte $0c, $1c, $3c, $6c, $7e, $0c, $0c, $00
  } else .if (c == 70) {  // '5'
    .byte $7e, $60, $7c, $06, $06, $66, $3c, $00
  } else .if (c == 71) {  // '6'
    .byte $3c, $66, $60, $7c, $66, $66, $3c, $00
  } else .if (c == 72) {  // '7'
    .byte $7e, $66, $0c, $18, $18, $18, $18, $00
  } else .if (c == 73) {  // '8'
    .byte $3c, $66, $66, $3c, $66, $66, $3c, $00
  } else .if (c == 74) {  // '9'
    .byte $3c, $66, $66, $3e, $06, $66, $3c, $00
  } else {
    .fill 8, 0
  }
}

// ------------------------------------------------------------
// Projection LUTs
// X range: -31..31 (63 entries)
// Y range: -23..23 (47 entries)
// Z levels: 8..63 (56 entries)
//
// Layout:
// - pointer tables first, one pointer per depth slice
// - then the actual flattened LUT data blocks
// - runtime picks depth first, then indexes by X or Y
// ------------------------------------------------------------
.pc = $2800

// ============================================================
// PROJECTION LOOKUP TABLES
// ============================================================
// Instead of computing 3D->2D projection per star per frame
// (expensive multiply/divide), we precompute all valid (depth, X/Y)
// combinations at assembly time and store results in indexed tables.
//
// Four pointer tables (XChar/XSub/YChar/YSub) map each depth level
// to the corresponding slice within each LUT data block.
// Two bytes per pointer (6502 requirement) split into _Lo and _Hi.
//
// Runtime chain:
// 1. Extract depth Z, use as index into pointer table
// 2. Load pointer -> fill zero-page pointer register ($fb/$fc)
// 3. Load X or Y world coordinate, use as index into pointed-at table
// 4. Fetch precomputed projection result (character cell or subpixel)
// This avoids expensive math in the per-frame inner loop.
// ============================================================

// Depth -> pointer to projected character-column table for X.
// 56 bytes (one per depth 8..63), each is a two-byte pointer split
// into low byte (below) and high byte (XCharPtrHi).
// At runtime: ldx #(depth-Z_MIN); lda XCharPtrLo,x; sta $fb
// This points into XCharLut at offset (depth-Z_MIN)*63.
XCharPtrLo:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte <(XCharLut + (z - Z_MIN) * 63)  // Low byte of XCharLut slice address
  }
// High byte of X character LUT pointers.
// One byte per depth. See XCharPtrLo above for usage pattern.
XCharPtrHi:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte >(XCharLut + (z - Z_MIN) * 63)  // High byte of XCharLut slice address
  }
// Low byte of X subpixel LUT pointers (pixel X within 8-pixel cell).
// Each depth has a corresponding 63-byte slice in XSubLut.
// Address = base + (depth_index) * 63
XSubPtrLo:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte <(XSubLut + (z - Z_MIN) * 63)   // Low byte of XSubLut slice address
  }
// High byte of X subpixel LUT pointers.
XSubPtrHi:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte >(XSubLut + (z - Z_MIN) * 63)   // High byte of XSubLut slice address
  }

// Low byte of Y character LUT pointers (character row 0..24).
// Each depth has a corresponding 47-byte slice in YCharLut.
// Note: Y range is smaller than X (47 vs 63) so offset formula differs.
// Address = base + (depth_index) * 47
YCharPtrLo:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte <(YCharLut + (z - Z_MIN) * 47)  // Low byte of YCharLut slice address
  }
// High byte of Y character LUT pointers.
YCharPtrHi:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte >(YCharLut + (z - Z_MIN) * 47)  // High byte of YCharLut slice address
  }

// Low byte of Y subpixel LUT pointers (pixel Y within 8-line cell).
// Each depth has a corresponding 47-byte slice in YSubLut.
YSubPtrLo:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte <(YSubLut + (z - Z_MIN) * 47)   // Low byte of YSubLut slice address
  }
// High byte of Y subpixel LUT pointers.
YSubPtrHi:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte >(YSubLut + (z - Z_MIN) * 47)   // High byte of YSubLut slice address
  }

// X character column LUT:
// Precomputed projection results for all valid (depth, X_world) pairs.
// Structure: 56 depths × 63 X entries = 3528 bytes
//
// For each depth z in [8..63] and each X world coordinate index xi in [0..62]:
//   (xi-31) remaps to signed range [-31..31] representing world X coordinate
//   Perspective projection: px = 160 + round(xs * (128.0 / z))
//     160 = screen center (320/2), 128 = 256/2 for 16-bit precision
//     z divides scale factor -> closer objects span more pixel range
//   Result: px ranges 0..319 (valid screen pixels) or off-screen
//   Stored: floor(px / 8) = character cell column 0..39, or $FF if off-screen
//
// Runtime access pattern in ProjectStar:
//   1. Compute X index: adc #31 (bias world coord to 0-based)
//   2. Load pointer: lda XCharPtrLo,x; sta $fb; lda XCharPtrHi,x; sta $fc
//   3. Fetch result: lda ($fb),y (where y = X index)
XCharLut:
.for (var z = Z_MIN; z <= Z_MAX; z++) {
  .for (var xi = 0; xi < 63; xi++) {
    .var xs = xi - 31          // Remap LUT index to signed world coord [-31..31]
    .var px = 160 + round(xs * (128.0 / z))  // Perspective division and centering
    .if (px < 0 || px > 319) {
      .byte $ff                // Off-screen marker
    } else {
      .byte floor(px / 8)      // Character cell column 0..39
    }
  }
}

// X subpixel LUT:
// Same projection math as XCharLut, but store only the sub-pixel offset
// within the 8-pixel character cell.
// Structure: 56 depths × 63 X entries (matches XCharLut)
//
// For same (depth, X) pair:
//   Calculate px identical to XCharLut
//   Stored: mod(px, 8) = pixel position 0..7 within the cell, or 0 if off-screen
//
// Combined with XCharLut at runtime:
//   lda ($fb),y from XCharLut -> column 0..39 (or $FF)
//   lda ($fb),y from XSubLut -> offset 0..7 within that column
//   Together: exact pixel column position = (char_col * 8) + sub_col
XSubLut:
.for (var z = Z_MIN; z <= Z_MAX; z++) {
  .for (var xi = 0; xi < 63; xi++) {
    .var xs = xi - 31          // Same bias as XCharLut
    .var px = 160 + round(xs * (128.0 / z))  // Same projection formula
    .if (px < 0 || px > 319) {
      .byte 0                  // Off-screen: use pixel 0
    } else {
      .byte mod(px, 8)         // Sub-pixel offset within 8-pixel cell
    }
  }
}

// Y character row LUT:
// Precomputed Y projections for all (depth, Y_world) pairs.
// Structure: 56 depths × 47 Y entries = 2632 bytes
//
// For each depth z and each Y world coordinate index yi in [0..46]:
//   (yi-23) remaps to signed range [-23..23] (visible world Y range)
//   Perspective projection: py = 100 + round(ys * (104.0 / z))
//     100 = screen center (200/2), 104 = approximate 208/2 for aspect ratio
//     (Screen is 40x25 chars = 320x200 pixels, slightly wider than tall)
//   Result: py ranges 0..199 (valid screen lines) or off-screen
//   Stored: floor(py / 8) = character row 0..24, or $FF if off-screen
//
// Runtime access pattern (mirrors XCharLut):
//   1. Compute Y index: adc #23 (bias world coord to 0-based)
//   2. Load pointer: lda YCharPtrLo,x; sta $fb; lda YCharPtrHi,x; sta $fc
//   3. Fetch result: lda ($fb),y (where y = Y index)
YCharLut:
.for (var z = Z_MIN; z <= Z_MAX; z++) {
  .for (var yi = 0; yi < 47; yi++) {
    .var ys = yi - 23          // Remap LUT index to signed world coord [-23..23]
    .var py = 100 + round(ys * (104.0 / z))  // Perspective division and centering
    .if (py < 0 || py > 199) {
      .byte $ff                // Off-screen marker
    } else {
      .byte floor(py / 8)      // Character cell row 0..24
    }
  }
}

// Y subpixel LUT:
// Same projection math as YCharLut, but store only the sub-pixel offset
// within the 8-line character cell.
// Structure: 56 depths × 47 Y entries (matches YCharLut)
//
// For same (depth, Y) pair:
//   Calculate py identical to YCharLut
//   Stored: mod(py, 8) = line position 0..7 within the cell, or 0 if off-screen
//
// Combined with YCharLut at runtime:
//   lda ($fb),y from YCharLut -> row 0..24 (or $FF)
//   lda ($fb),y from YSubLut -> offset 0..7 within that row
//   Together: exact pixel row position = (char_row * 8) + sub_row
// 
// Final star glyph selection in DrawProjected:
//   Custom charset char index = (ZP_SUBY * 8) + ZP_SUBX
//   This maps 6 bits (3 for Y + 3 for X) to chars 0..63, each with
//   exactly one pixel set at the corresponding position within an 8x8 cell.
YSubLut:
.for (var z = Z_MIN; z <= Z_MAX; z++) {
  .for (var yi = 0; yi < 47; yi++) {
    .var ys = yi - 23          // Same bias as YCharLut
    .var py = 100 + round(ys * (104.0 / z))  // Same projection formula
    .if (py < 0 || py > 199) {
      .byte 0                  // Off-screen: use line 0
    } else {
      .byte mod(py, 8)         // Sub-pixel offset within 8-line cell
    }
  }
}