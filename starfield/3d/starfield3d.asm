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
// Press any key to exit.

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

// Number of concurrently animated stars.
.const NUM_STARS = 64

// Charset index 64 is an all-zero blank character used for clearing.
.const BLANK     = 64

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

  // Create all stars with random X/Y/Z world coordinates.
  ldx #0
InitStars:
  stx ZP_IDX
  jsr RespawnStar
  ldx ZP_IDX
  inx
  cpx #NUM_STARS
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
  jsr WaitFrame

  // Erase previous frame stars.
  // OldOfsLo/Hi already contain the exact address of the previously drawn
  // screen cell, so we can blank it with a single indirect write.
  ldx #0
EraseLoop:
  // Zero OldOfsHi means "this star has nothing valid to erase".
  lda OldOfsHi,x
  beq EraseNext
  sta $fc
  lda OldOfsLo,x
  sta $fb
  ldy #0
  lda #BLANK
  sta ($fb),y
  // Invalidate saved address after erase so we never erase the same stale
  // cell twice if the star is skipped later.
  lda #0
  sta OldOfsLo,x
  sta OldOfsHi,x
EraseNext:
  inx
  cpx #NUM_STARS
  bne EraseLoop

  // Move + project + draw each star.
  ldx #0
StarLoop:
  stx ZP_IDX

  // Move one unit toward the viewer every frame.
  dec ZPos,x
  lda ZPos,x
  // If it reached/passed the near plane, respawn it at a fresh far depth.
  cmp #Z_MIN
  bcs ZOk
  jsr RespawnStar
  ldx ZP_IDX
ZOk:
  // Try projecting the star. Carry clear means it landed on-screen.
  jsr ProjectStar
  bcc DrawNow

  // If the star projected off-screen, respawn and try once more.
  jsr RespawnStar
  ldx ZP_IDX
  jsr ProjectStar
  // Still off-screen? Skip drawing this star this frame.
  bcs SkipDraw

DrawNow:
  jsr DrawProjected
  jmp NextStar
SkipDraw:
  ldx ZP_IDX
  // Ensure skipped stars do not leave any old cell registered for erase.
  lda #0
  sta OldOfsLo,x
  sta OldOfsHi,x
NextStar:
  ldx ZP_IDX
  inx
  cpx #NUM_STARS
  bne StarLoop

  // Key check. Any detected key exits back to BASIC.
  lda #$ff
  sta $dc00
  lda $dc01
  sta ZP_TMP
  lda #$00
  sta $dc00
  lda $dc01
  cmp ZP_TMP
  bne ExitNow
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
  ldx ZP_IDX

  // Convert depth Z into a zero-based LUT depth index.
  lda ZPos,x
  sec
  sbc #Z_MIN
  tay
  sty ZP_TMP

  // Convert signed X world coordinate [-31..31] to a LUT index [0..62].
  ldx ZP_IDX
  lda XPos,x
  clc
  adc #31
  tay

  // Read projected character column from the depth-specific X LUT.
  ldx ZP_TMP
  lda XCharPtrLo,x
  sta $fb
  lda XCharPtrHi,x
  sta $fc
  lda ($fb),y
  // $FF marks "this depth/X combination is off-screen".
  cmp #$ff
  beq ProjOut
  sta ZP_PX

  // Read projected pixel-within-cell X from companion LUT.
  ldx ZP_TMP
  lda XSubPtrLo,x
  sta $fb
  lda XSubPtrHi,x
  sta $fc
  lda ($fb),y
  sta ZP_SUBX

  // Convert signed Y world coordinate [-23..23] to a LUT index [0..46].
  ldx ZP_IDX
  lda YPos,x
  clc
  adc #23
  tay

  // Read projected character row from the depth-specific Y LUT.
  ldx ZP_TMP
  lda YCharPtrLo,x
  sta $fb
  lda YCharPtrHi,x
  sta $fc
  lda ($fb),y
  cmp #$ff
  beq ProjOut
  sta ZP_PY

  // Read projected pixel-within-cell Y from companion LUT.
  ldx ZP_TMP
  lda YSubPtrLo,x
  sta $fb
  lda YSubPtrHi,x
  sta $fc
  lda ($fb),y
  sta ZP_SUBY

  // Visible.
  clc
  rts

ProjOut:
  // Off-screen.
  sec
  rts

// ------------------------------------------------------------
// Draw projected star for index in ZP_IDX.
// This routine writes both screen RAM (character index) and color RAM.
// ------------------------------------------------------------
DrawProjected:
  // Build screen pointer for row ZP_PY.
  lda ZP_PY
  tay
  lda RowTableLo,y
  sta $fb
  lda RowTableHi,y
  clc
  adc #>SCRN
  sta $fc

  // Select the target screen column.
  ldy ZP_PX

  // Combine sub-Y (row 0..7) and sub-X (bit 0..7) into a character index
  // 0..63. The custom charset maps each of these 64 chars to a single pixel
  // inside the 8x8 cell.
  lda ZP_SUBY
  asl
  asl
  asl
  sta ZP_TMP
  lda ZP_SUBX
  ora ZP_TMP
DrawChar:
  // Write the chosen custom character into screen RAM.
  sta ($fb),y

  // Save exact previous cell pointer for next-frame erase
  ldx ZP_IDX
  // Old cell address = row base pointer + X column.
  tya
  clc
  adc $fb
  sta OldOfsLo,x
  lda $fc
  adc #0
  sta OldOfsHi,x

  // Build matching color RAM pointer for the same row.
  lda ZP_PY
  tay
  lda RowTableLo,y
  sta $fd
  lda RowTableHi,y
  clc
  adc #>COL
  sta $fe

  // Pick color by depth so near stars look brighter.
  ldx ZP_IDX
  lda ZPos,x
  cmp #14
  bcc NearCol
  cmp #30
  bcc MidCol
  lda #$0b
  bne ColOut
MidCol:
  lda #$0f
  bne ColOut
NearCol:
  lda #$01
ColOut:
  // Write color into the same column in color RAM.
  ldy ZP_PX
  sta ($fd),y
  rts

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
  jsr Rng
  and #$3f
  cmp #47
  bcs RandY
  sec
  sbc #23
  sta YPos,x

RandZ:
  // Generate 0..63, reject 56..63, then add Z_MIN => 8..63.
  jsr Rng
  and #$3f
  cmp #56
  bcs RandZ
  clc
  adc #Z_MIN
  sta ZPos,x

  // No valid old screen address yet for this newly respawned star.
  lda #0
  sta OldOfsLo,x
  sta OldOfsHi,x
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

// 40-byte row offset tables for the 25 text rows.
RowTableLo:
  .fill 25, <(i * 40)
RowTableHi:
  .fill 25, >(i * 40)

// Per-star world state and saved previous screen cell pointer.
XPos: .fill NUM_STARS, 0
YPos: .fill NUM_STARS, 0
ZPos: .fill NUM_STARS, 0
OldOfsLo: .fill NUM_STARS, 0
OldOfsHi: .fill NUM_STARS, 0

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

// Depth -> pointer to projected character-column table for X.
XCharPtrLo:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte <(XCharLut + (z - Z_MIN) * 63)
  }
XCharPtrHi:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte >(XCharLut + (z - Z_MIN) * 63)
  }
XSubPtrLo:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte <(XSubLut + (z - Z_MIN) * 63)
  }
XSubPtrHi:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte >(XSubLut + (z - Z_MIN) * 63)
  }

// Depth -> pointer to projected character-row table for Y.
YCharPtrLo:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte <(YCharLut + (z - Z_MIN) * 47)
  }
YCharPtrHi:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte >(YCharLut + (z - Z_MIN) * 47)
  }
YSubPtrLo:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte <(YSubLut + (z - Z_MIN) * 47)
  }
YSubPtrHi:
  .for (var z = Z_MIN; z <= Z_MAX; z++) {
    .byte >(YSubLut + (z - Z_MIN) * 47)
  }

// X projection LUT:
// For each depth and signed X, precompute final pixel X around screen center.
// Store character column or $FF if off-screen.
XCharLut:
.for (var z = Z_MIN; z <= Z_MAX; z++) {
  .for (var xi = 0; xi < 63; xi++) {
    .var xs = xi - 31
    .var px = 160 + round(xs * (128.0 / z))
    .if (px < 0 || px > 319) {
      .byte $ff
    } else {
      .byte floor(px / 8)
    }
  }
}

// Same X projection, but store sub-pixel position within the 8-pixel cell.
XSubLut:
.for (var z = Z_MIN; z <= Z_MAX; z++) {
  .for (var xi = 0; xi < 63; xi++) {
    .var xs = xi - 31
    .var px = 160 + round(xs * (128.0 / z))
    .if (px < 0 || px > 319) {
      .byte 0
    } else {
      .byte mod(px, 8)
    }
  }
}

// Y projection LUT:
// Same idea as X, but centered on screen line 100.
YCharLut:
.for (var z = Z_MIN; z <= Z_MAX; z++) {
  .for (var yi = 0; yi < 47; yi++) {
    .var ys = yi - 23
    .var py = 100 + round(ys * (104.0 / z))
    .if (py < 0 || py > 199) {
      .byte $ff
    } else {
      .byte floor(py / 8)
    }
  }
}

// Y sub-pixel lookup within each 8-line text cell.
YSubLut:
.for (var z = Z_MIN; z <= Z_MAX; z++) {
  .for (var yi = 0; yi < 47; yi++) {
    .var ys = yi - 23
    .var py = 100 + round(ys * (104.0 / z))
    .if (py < 0 || py > 199) {
      .byte 0
    } else {
      .byte mod(py, 8)
    }
  }
}