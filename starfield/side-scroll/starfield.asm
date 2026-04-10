.pc = $0801
.byte $0c, $08
.word 10
.byte $9E
.text "2064"
.byte 0
.byte 0, 0

.pc = $0810

.const NUM_STARS = 60
.const PER_LYR   = 20
.const BLANK     = 64
.const ZP_IDX    = $02
.const ZP_TMP    = $03
.const ZP_CHAR   = $04
.const SCRN      = $0400
.const COL       = $D800

Main:
  sei
  lda $DD00
  and #$FC
  ora #$03
  sta $DD00
  lda #$1B
  sta $D011
  lda #$08
  sta $D016
  lda #$18
  sta $D018
  lda #0
  sta $D020
  sta $D021

  lda #0
  ldx #0
SeedLoop:
  eor $D012
  adc #$31
  inx
  bne SeedLoop
  ora #$01
  sta RngLo
  eor #$C7
  ora #$80
  sta RngHi

  lda #BLANK
  ldx #0
CS:
  sta SCRN,x
  sta SCRN+$100,x
  sta SCRN+$200,x
  sta SCRN+$300,x
  inx
  bne CS

  lda #0
  ldx #0
CC:
  sta COL,x
  sta COL+$100,x
  sta COL+$200,x
  sta COL+$300,x
  inx
  bne CC

  ldx #0
InitL0:
  jsr RandStar
  lda #$0B
  sta StarCol,x
  lda #1
  sta StarSpd,x
  inx
  cpx #PER_LYR
  bne InitL0

InitL1:
  jsr RandStar
  lda #$0F
  sta StarCol,x
  lda #2
  sta StarSpd,x
  inx
  cpx #(PER_LYR*2)
  bne InitL1

InitL2:
  jsr RandStar
  lda #$01
  sta StarCol,x
  lda #4
  sta StarSpd,x
  inx
  cpx #NUM_STARS
  bne InitL2

  ldx #0
InitDraw:
  stx ZP_IDX
  jsr DrawStar
  ldx ZP_IDX
  inx
  cpx #NUM_STARS
  bne InitDraw

WaitRel:
  jsr WaitFrame
  lda #$FF
  sta $DC00
  lda $DC01
  sta ZP_TMP
  lda #$00
  sta $DC00
  lda $DC01
  cmp ZP_TMP
  bne WaitRel

FrameLoop:
  jsr WaitFrame
  ldx #0
  lda #BLANK
EraseLoop:
  ldy OldOfsHi,x
  sty $fc
  ldy OldOfsLo,x
  sty $fb
  ldy #0
  sta ($fb),y
  inx
  cpx #NUM_STARS
  bne EraseLoop

  ldx #0
MoveLoop:
  lda StarXLo,x
  sec
  sbc StarSpd,x
  sta StarXLo,x
  lda StarXHi,x
  sbc #0
  sta StarXHi,x
  bpl MOk
  jsr Rng
  and #$1F
  sta ZP_TMP
  lda #<319
  sec
  sbc ZP_TMP
  sta StarXLo,x
  lda #>319
  sbc #0
  sta StarXHi,x
WrapY:
  jsr Rng
  cmp #200
  bcs WrapY
  sta StarY,x
MOk:
  inx
  cpx #NUM_STARS
  bne MoveLoop

  ldx #0
DLoop:
  stx ZP_IDX
  jsr DrawStar
  ldx ZP_IDX
  inx
  cpx #NUM_STARS
  bne DLoop

  lda #$FF
  sta $DC00
  lda $DC01
  sta ZP_TMP
  lda #$00
  sta $DC00
  lda $DC01
  cmp ZP_TMP
  bne ExitNow
  jmp FrameLoop

ExitNow:
  lda #$FF
  sta $DC00
  cli
  jsr $FF81
  rts

WaitFrame:
WFP1:
  lda $D012
  cmp #251
  bcs WFP1
WFP2:
  lda $D012
  cmp #251
  bcc WFP2
  rts

RandStar:
  jsr Rng
  jsr Rng
  jsr Rng
  jsr Rng
  jsr Rng
  jsr Rng
  sta StarXLo,x
  txa
  asl
  eor StarXLo,x
  sta StarXLo,x
  jsr Rng
  and #$01
  sta StarXHi,x
  cmp #1
  bne RSY
  lda StarXLo,x
  cmp #64
  bcc RSY
  lda #63
  sta StarXLo,x
RSY:
  jsr Rng
  cmp #200
  bcs RSY
  sta StarY,x
  rts

Rng:
  lsr RngHi
  ror RngLo
  bcc RngNT
  lda RngHi
  eor #$D0
  sta RngHi
  lda RngLo
  eor #$08
  sta RngLo
RngNT:
  lda RngLo
  eor RngHi
  rts

RngLo: .byte $01
RngHi: .byte $01

CalcScreenPos:
  ldx ZP_IDX
  lda StarXLo,x
  sta ZP_TMP
  lda StarXHi,x
  lsr
  ror ZP_TMP
  lsr
  ror ZP_TMP
  lsr
  ror ZP_TMP

  lda StarY,x
  lsr
  lsr
  lsr
  tay

  lda RowTableLo,y
  clc
  adc ZP_TMP
  sta $fb
  lda RowTableHi,y
  adc #0
  sta $fc

  lda $fb
  sta $fd
  lda $fc
  clc
  adc #$04
  sta $fc

  clc
  adc #$D4
  sta $fe

  ldx ZP_IDX
  lda StarY,x
  and #$07
  asl
  asl
  asl
  sta ZP_TMP
  lda StarXLo,x
  and #$07
  ora ZP_TMP
  rts

DrawStar:
  jsr CalcScreenPos
  sta ZP_CHAR
  ldx ZP_IDX
  lda $fb
  sta OldOfsLo,x
  lda $fc
  sta OldOfsHi,x
  ldy #0
  lda StarCol,x
  sta ($fd),y
  lda ZP_CHAR
  sta ($fb),y
  rts

RowTableLo:
  .fill 25, <(i * 40)
RowTableHi:
  .fill 25, >(i * 40)

StarXLo:  .fill NUM_STARS, 0
StarXHi:  .fill NUM_STARS, 0
StarY:    .fill NUM_STARS, 0
StarCol:  .fill NUM_STARS, 0
StarSpd:  .fill NUM_STARS, 0
OldOfsLo: .fill NUM_STARS, 0
OldOfsHi: .fill NUM_STARS, 0

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
  } else {
    .fill 8, 0
  }
}