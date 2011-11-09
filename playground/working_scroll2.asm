!to "scroll.prg", cbm   ; output program
!sl "labels.l"          ; create label file for vice
!cpu 6510               ; for illegal opcodes
!convtab scr            ; for conversion to c64 screen codes

!source "../lib/mem.asm"
!source "../lib/vic.asm"
!source "../lib/cia.asm"
!source "../lib/std.asm"

SPRITE_FRAME_BASE = 2040

+create_basic_starter $0c00
*=$0c00; = 2304

    ; Bit 7: Bit 8 of $D012        
    ; Bit 6: Extended Color Modus  
    ; Bit 5: Bitmapmode      
    ; Bit 4: Screen output enabled?
    ; Bit 3: 25 rows (24 otherwise)
CONTROL_Y        =%00110000
CONTROL_Y_MASK   =%10111111
CONTROL_Y_INVALID=%01110000

    ; Bit 7..5: unused
    ; Bit 4: Multicolormode
    ; Bit 3: 40 cols (on)/38 cols (off)
    ; Bit 2..0: Offset in Pixels starting from the left screen edge
CONTROL_X        =%00011000

FIRST_BADLINE = $33-3
LINE_0        = FIRST_BADLINE-3
LINE_SPLIT    = FIRST_BADLINE-3

LINES_TO_CRUNCH = 31

START !zone {

    ; select VIC area: $4000 - $7FFF
    lda CIA2_CONTROL_TIMER_A
    and #%11111100
    ora #%00000010
    sta CIA2_DATA_PORT_A

    ; select screen bank 
    lda # ((SCREEN % $4000 / $0400) << 4) | ((HIRES % $4000 / $2000) << 2)
    sta VIC_ADDR_SELECT

    ; init pointers
    +set16 HIRES,     PTR_HIRES
    +set16 COLOR_RAM, PTR_COLOR
    +set16 SCREEN,    PTR_SCREEN

;-------------------------------------------------------------------------------
;   disable all basic, kernal and irq crap
;-------------------------------------------------------------------------------
    ; disable IRQs
    sei

    ; disable ROMs
    +set RAM_ROM_ALL_RAM_WITHIO, RAM_ROM_SELECTION

    ; ack all interrupts which might have happend
    +set $ff, VIC_IRQ_STATUS
    lda CIA1_INTERRUPT_CONTROL
    lda CIA2_INTERRUPT_CONTROL

    ; set empty interrupt routines
    +set16 EMPTY_INTERRUPT, VECTOR_NMI
    +set16 EMPTY_INTERRUPT, VECTOR_RESET
    +set16 EMPTY_INTERRUPT, VECTOR_IRQ

    ; disable_timer_interrupts
    lda #%01111111
    sta CIA1_INTERRUPT_CONTROL
    sta CIA2_INTERRUPT_CONTROL

    ; set timer A to 0
    sta CIA2_TIMER_A_LO
    sta CIA2_TIMER_A_HI

    ; trigger timer A interrupt
    +set %10000001, CIA2_INTERRUPT_CONTROL
    +set %00000001, CIA2_CONTROL_TIMER_A

    ; reset stack
    ldx #$ff
    txs

    ; just clear this flag and never ever touch this again
    cld

    ; enable IRQs
    cli

    ; wait till the timer interrupt has happend
-
    bit LOCK
    bne -

    ; -> NMI is disabled since we will never ever ack it again
    ; -> zero page completely free on this spot except for the special regs $00 and $01

;-------------------------------------------------------------------------------
;   setup raster irq
;-------------------------------------------------------------------------------

    sei
        +set16 IRQ, VECTOR_IRQ
        +set_raster_line_9 LINE_0
        +set 1, VIC_IRQ_CONTROL
    cli

-
    ; some 7 cycle garbage instructions
    lda ($ff), y
    lda ($ff, x)
    lda ($ff), y
    lda ($ff, x)
    lda ($ff), y
    inc HIRES
    inc SCREEN
    sec     ; 2
    +bcs    ; 3
    jmp -
}

!source "joystick.asm"

!macro inc_vic_control_y {
    lda VIC_CONTROL_Y                       ;  4
    clc                                     ;  2
    adc #1                                  ;  2
    and #%00000111                          ;  2
    adc #CONTROL_Y_INVALID                  ;  2
    sta VIC_CONTROL_Y                       ;  4
}                                           ;--> 16

!align 255, 0
IRQ !zone {
;-------------------------------------------------------------------------------
;   LINE_0
;-------------------------------------------------------------------------------

    ; irq event                             ;  7
    ; last instruction                      ;  1 (min)
    +save_regs                              ;  9
    ; ack interrupt
    inc VIC_IRQ_STATUS                      ;  6

    inc VIC_RASTER                          ;  6
    +set16 .irq_line_0_plus_1, VECTOR_IRQ   ; 12

    ; save stack state
    tsx                                     ;  2

    +wait 6                                 ;  6 TODO
    ; begin raster stabilization
    cli                                     ;  2
                                            ;--> 51

    ; somewhere here the next interrupt will hit
    +wait 63 - 51

;-------------------------------------------------------------------------------
;   LINE_0 + 1
;-------------------------------------------------------------------------------
.irq_line_0_plus_1
    ; irq event                             ;  7
    ; last instruction                      ;1-2 (because of the nop field above)
    ; restore stack state
    txs                                     ;  2
                                            ;--> 10-11

    ; calculate the number of nops to skip in VSP
    lda #39                                 ;  2
    sec                                     ;  2
    sbc HARD_X                              ;  4
    lsr                                     ;  2
    sta .self_modifying_branch__nops + 1    ;  4
                                            ;--> 14

    ; introduce an extra cycle in VSP if carry is set
    bcs .set_bcc                            ;2-3
.set_bcs
    ldx #BCS_OPCODE                         ;  2
    bne +   ; always true                   ;  3
.set_bcc
    ldx #BCC_OPCODE                         ;  2
    nop     ; make this path as long        ;  2
+
    stx .self_modifying_branch__lsb         ;  4
                                            ;--> 11

    ; set up soft scroll
    lda #CONTROL_X                          ;  2
    clc                                     ;  2
    adc SOFT_X                              ;  4
    sta VIC_CONTROL_X                       ;  4
                                            ;--> 12

    +wait 63-11-14-11-12-6

    ; wobble check
    lda #LINE_0 + 2                         ;  2
    cmp VIC_RASTER                          ;  4
                                            ;--> 6
    +bne                                    ;3-2
    ; -> the raster interrupt is stable now with 3 cycles off

;-------------------------------------------------------------------------------
;   LINE_0 + 2
;-------------------------------------------------------------------------------

    ; wobble check from above               ;  3
    lda #LINES_TO_CRUNCH-1                  ;  2
    sec                                     ;  2
    sbc TOTAL_Y                             ;  4
    tax                                     ;  2
                                            ;--> 13

    ; make FIRST_BADLINE a bad line
    lda #CONTROL_Y_INVALID                  ;  2
    sta VIC_CONTROL_Y                       ;  4
                                            ;--> 6

    lda #7 + LINES_TO_CRUNCH % 8            ;  2
    sec                                     ;  2
    sbc SOFT_Y                              ;  4
    and #%00000111                          ;  2
    adc #CONTROL_Y_INVALID-1                ;  2
    sta .load_soft_y+1                      ;  4
                                            ;--> 16

    ;wait till just before LINE_O + 3 == FIRST_BADLINE
    +wait_loop 63 - 13 - 6 - 16 - 20 - 4

;-------------------------------------------------------------------------------
;   FLD & line crunch
;-------------------------------------------------------------------------------

.fld_loop
    cpx #0                                  ;  2
    beq +                                   ;  2 (in this loop)
    +inc_vic_control_y                      ; 16
                                            ;--> 20
    +wait_loop 63 - 20 - 2 - 3
    dex                                     ;  2
    jmp .fld_loop                           ;  3
+

    ldx TOTAL_Y

.crunch_loop
    cpx #0                                  ;  2
    beq +                                   ;  2 (in this loop)
    +inc_vic_control_y                      ; 16
                                            ;--> 20

    +wait_loop 63 - 20 - 2 - 3
    dex                                     ;  2
    jmp .crunch_loop                        ;  3
+

    ; ^^^ these are always 25 raster lines ^^^

;-------------------------------------------------------------------------------
;   VSP
;-------------------------------------------------------------------------------
    ; make VSP line not a bad line
    inc VIC_CONTROL_Y
    +wait 5
    ; crunch loop
    sec
    ; introduce an extra cycle if 39 - HARD_X is odd
.self_modifying_branch__lsb
    +bcs                                    ;2-3

.self_modifying_branch__nops
    ; always true and jump into nop field
    +bcs                                    ;  3
    +wait 38                                ;0-38

    ; generate bad line
    dec VIC_CONTROL_Y

;-------------------------------------------------------------------------------
; soft scroll
;-------------------------------------------------------------------------------

.load_soft_y
    lda #0
    sta VIC_CONTROL_Y
    pha

    +wait_loop 63 * 7

    ldx SOFT_Y
    ;bne +
    ;+wait_loop 20
;+
    pla
    and #CONTROL_Y_MASK
    sta VIC_CONTROL_Y

!if (>IRQ) != (>*) {
    !warn "critical irq code in different pages"
}

;-------------------------------------------------------------------------------
; clean up
;-------------------------------------------------------------------------------

    jsr JOY

; test soft char
    inc VIC_BORDER
    ;ldx #3
    ;jsr COPY_SOFTCHARS
    ldy #0
    jsr COPY_TILE_ROW_0
    ldy #1
    jsr COPY_TILE_ROW_0
    ldy #2
    jsr COPY_TILE_ROW_0
    dec VIC_BORDER

    +set_raster_line_8 LINE_0
    +set16 IRQ, VECTOR_IRQ

    +ack_restore_rti
}

INC_SCROLL_PTRS !zone {
    lda PTR_HIRES
    clc
    adc #8
    sta PTR_HIRES
    bcc .out_safely_inc_others  

    inc PTR_HIRES + 1   ; add carry to high byte

    ; PTR_SCREEN and PTR_COLOR _may_ overflow
    inc PTR_SCREEN
    inc PTR_COLOR

    ; do PTR_SCREEN and PTR_COLOR overflow, too?
    bne .out

    inc PTR_SCREEN + 1
    inc PTR_COLOR + 1

    ; is here a wrap-around of the buffers?
    lda PTR_COLOR + 1
    cmp #(>COLOR_RAM) + >($0400)
    bne .out

    ; wrap around
    lda # >COLOR_RAM
    sta PTR_COLOR + 1

    lda # >SCREEN
    sta PTR_SCREEN + 1

    lda # >HIRES
    sta PTR_HIRES + 1
    rts

.out_safely_inc_others

    ; PTR_SCREEN and PTR_COLOR _cannot_ overflow
    inc PTR_SCREEN
    inc PTR_COLOR

.out
    rts
}

COPY_SOFTCHARS !zone {
    ; x -> softchar index
    
    ; copy over soft char line by line
    ; y is used to index the row

    !for .j, 8 {
    !set .i = .j - 1
        
        !if .i = 0 {
            ldy #7
        } else {
            dey
        }

        lda SOFTCHARS + .i * $100, x
        sta (PTR_HIRES), y
    }

    ; y = 0 here

    ; copy over color infos
    lda SOFTCHARS_C, x
    sta (PTR_COLOR), y
    lda SOFTCHARS_S, x
    sta (PTR_SCREEN), y

    rts
}

!macro copy_tile_elem .row, .col {
    ; y -> tile index
    ldx TILES + .col * $40 + .row * $0100, y  ; load softchar index
    jsr COPY_SOFTCHARS
    jsr INC_SCROLL_PTRS
}

    ; y -> tile index
COPY_TILE_ROW_0 !zone {
    sty TMP_TILE_INDEX
    +copy_tile_elem 0, 0
    ldy TMP_TILE_INDEX

COPY_TILE_ROW_1
    sty TMP_TILE_INDEX
    +copy_tile_elem 0, 1
    ldy TMP_TILE_INDEX

COPY_TILE_ROW_2
    sty TMP_TILE_INDEX
    +copy_tile_elem 0, 2
    ldy TMP_TILE_INDEX

COPY_TILE_ROW_3
    sty TMP_TILE_INDEX
    +copy_tile_elem 0, 3
    ldy TMP_TILE_INDEX

    rts
}

SOFT_X   !by 0
SOFT_Y   !by 0
HARD_X   !by 0
HARD_Y   !by 0
SCREEN_Y !by 0
TOTAL_Y  !by 0
NTSC     !by 0

EMPTY_INTERRUPT
    inc LOCK
    rti

LOCK
    !by $ff

!source "data.asm"
