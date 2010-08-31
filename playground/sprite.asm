!to "sprite.prg", cbm   ; output program
!cpu 6510               ; for illegal opcodes
!convtab scr            ; for conversion to c64 screen codes

!source "lib/vic.asm"
!source "lib/cia.asm"
!source "lib/std.asm"
!source "lib/zero.asm"

NUM_SPRITES       = 32
SPRITE_FRAME_BASE = 2040
;TOP_RASTER_LINE   = 255
TOP_RASTER_LINE   = $20
SAFETY_LINES      = 3
BREAK_LINES       = 20

SPRITE16 = 1
MULTI_COLOR = 0

!if SPRITE16 = 1 {
    SPRITE_HEIGHT = 16 + 1 - 2
} else {
    SPRITE_HEIGHT = 21 + 1 - 2
}

; generate BASIC program: 10 sys 2304
*=$0801
!byte $0c,$08,$0a,$00,$9e
!tx "2304"
!byte $00,$00,$00,$00
!byte $00,$00,$00,$00

!align 63, 0, 0
MY_SPRITE
!if SPRITE16 = 1 {
    +sprite_line %################........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %#..............#........
    +sprite_line %################........
    +sprite_line %........................
    +sprite_line %........................
    +sprite_line %........................
    +sprite_line %........................
    +sprite_line %........................
} else {
    +sprite_line %########################
    +sprite_line %########################
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %##....................##
    +sprite_line %########################
    +sprite_line %########################
}

*=$0900; = 2304
START
    sei
    cld

    ; reset stack
    ldx #$ff
    txs

    +set RAM_ROM_ALL_RAM_WITHIO, RAM_ROM_SELECTION

    ; just select raster interrupts
    +disable_timer_interrupts
    +clear_timer
    +set 1, VIC_IRQ_CONTROL
    +set_raster_line_9 TOP_RASTER_LINE

    ; ack all interrupts
    lda #0
    sta VIC_IRQ_STATUS
    lda CIA1_INTERRUPT_CONTROL
    lda CIA2_INTERRUPT_CONTROL

    +set16 EMPTY_INTERRUPT, VECTOR_NMI
    +set16 EMPTY_INTERRUPT, VECTOR_RESET
    +set16 INTERRUPT_STRIP_0, VECTOR_IRQ

    ; init index table
    ldx #NUM_SPRITES-1
-
    txa
    sta MULTI_INDEX_TABLE, x
    dex
    bpl -

    ; init FRAME_COUNTER_TABLE
    lda #%00000010
    sta FRAME_COUNTER_TABLE + %00000001
    lda #%00000001
    sta FRAME_COUNTER_TABLE + %00000010

    lda #1
    sta FRAME_COUNTER

    jsr EXAMINE_SPRITE_STRIPS
    ; init first sprite strip
    jsr CACHE_SPRITE_STRIP 

    ; enable all sprites
    +set $ff, VIC_SPR_ENABLE

    ; enable maskable interrupts again
    cli

MAIN_LOOP
    jmp MAIN_LOOP
    nop
EMPTY_INTERRUPT
    rti

;-------------------------------------------------------------------------------

!macro strip_collision .i {
    ldy MULTI_INDEX_TABLE + .i*8 + 7
    ; A <- max y of current strip
    lda MULTI_SPRITE_Y, y
    clc
    adc #21 - 1

    ; if A < min y of next strip goto +
    ldx #0
    ldy MULTI_INDEX_TABLE + .i*8 + 8
    cmp MULTI_SPRITE_Y, y
    bcc +
    ldx #1
+
    stx COLLISION_0_1 + .i
}

EXAMINE_SPRITE_STRIPS !zone {
    +strip_collision 0 
    +strip_collision 1 
    +strip_collision 2 

    ldx #%00000001
    ldy #%00000010
    lda #%00000011

    stx STRIP0_IN_FRAME
    sty STRIP1_IN_FRAME
    stx STRIP2_IN_FRAME
    sty STRIP3_IN_FRAME

    bit COLLISION_0_1
    bne +
        sta STRIP0_IN_FRAME
        bit COLLISION_1_2
        bne +
        sta STRIP1_IN_FRAME
+

    bit COLLISION_2_3
    bne +
        sta STRIP3_IN_FRAME
        bit COLLISION_1_2
        bne +
        sta STRIP2_IN_FRAME
+

    rts
}

;-------------------------------------------------------------------------------
; display a complete strip of 8 sprites
;-------------------------------------------------------------------------------

DISPLAY_SPRITE_STRIP !zone {
    ; set most important first: the y-coords
    !for .j, 8 {
    !set .i = .j - 1
        lda SPRITE_STRIP_Y + .i
        sta VIC_SPR_0_Y + 2*.i
    }

    ; remember max y-coord of this trip
    sta MULTI_MAX_Y_IN_STRIP

    ; now the x-coords
    !for .j, 8 {
    !set .i = .j - 1
        lda SPRITE_STRIP_X + .i
        sta VIC_SPR_0_X + 2*.i
    }

    ; set x MSB
    lda SPRITE_STRIP_X_MSB
    sta VIC_SPR_X_MSB

    ; set sprite frames
    !for .j, 8 {
    !set .i = .j - 1
        lda SPRITE_STRIP_FRAME + .i
        sta SPRITE_FRAME_BASE + .i
    }
    
    ; set colors
    !for .j, 8 {
    !set .i = .j - 1
        lda SPRITE_STRIP_COLOR + .i
        sta VIC_SPR_0_COLOR + .i
    }

!if MULTI_COLOR = 1 {
    ; set single-/multi-color mode
    lda SPRITE_STRIP_MULTI
    sta VIC_SPR_MULTI
}

    rts
}

;-------------------------------------------------------------------------------

CACHE_SPRITE_STRIP !zone {
    !for .j, 8 {
    !set .i = .j - 1
        ldy MULTI_INDEX_TABLE + .i, x

        lda MULTI_SPRITE_Y, y
        sta SPRITE_STRIP_Y + .i

        lda MULTI_SPRITE_X, y
        sta SPRITE_STRIP_X + .i

        lda MULTI_SPRITE_FRAME, y
        sta SPRITE_STRIP_FRAME + .i

!if MULTI_COLOR = 1 {
        lda MULTI_SPRITE_COLOR, y
        sta SPRITE_STRIP_COLOR + .i
        cmp $%01111111
        ror SPRITE_STRIP_MULTI
}
        lda MULTI_SPRITE_X_MSB, y
        cmp #%00000001
        ror SPRITE_STRIP_X_MSB
    }

    lda MULTI_MAX_Y_IN_STRIP
    clc
    adc #SPRITE_HEIGHT
    +set_raster_line_8

    rts
}
 
!macro cache_sprite_strip .i {
    ldx #(.i % 4) * 8
    jsr CACHE_SPRITE_STRIP 
}

;-------------------------------------------------------------------------------

!macro inc_frame_counter {
    ldx FRAME_COUNTER
    lda FRAME_COUNTER_TABLE, x
    sta FRAME_COUNTER
}

;-------------------------------------------------------------------------------

INTERRUPT_STRIP_0 
    +save_regs
    jsr DISPLAY_SPRITE_STRIP

    lda FRAME_COUNTER
    and STRIP1_IN_FRAME
    beq +
    +cache_sprite_strip 1
    +set16 INTERRUPT_STRIP_1, VECTOR_IRQ
    +ack_restore_rti
+
    +cache_sprite_strip 2
    +set16 INTERRUPT_STRIP_2, VECTOR_IRQ
    +ack_restore_rti
INTERRUPT_STRIP_1 
    +save_regs
    jsr DISPLAY_SPRITE_STRIP

    lda FRAME_COUNTER
    and STRIP2_IN_FRAME
    beq +
    +cache_sprite_strip 2
    +set16 INTERRUPT_STRIP_2, VECTOR_IRQ
    +ack_restore_rti
+
    +cache_sprite_strip 3
    +set16 INTERRUPT_STRIP_3, VECTOR_IRQ
    +ack_restore_rti
INTERRUPT_STRIP_2 
    +save_regs
    jsr DISPLAY_SPRITE_STRIP

    lda FRAME_COUNTER
    and STRIP3_IN_FRAME
    beq +
    +cache_sprite_strip 3
    +set16 INTERRUPT_STRIP_3, VECTOR_IRQ
    +ack_restore_rti
+
    +inc_frame_counter
    lda FRAME_COUNTER
    and STRIP0_IN_FRAME
    beq +
    +cache_sprite_strip 0
        +set_raster_line_8 TOP_RASTER_LINE
    +set16 INTERRUPT_STRIP_0, VECTOR_IRQ
    +ack_restore_rti
+
    +cache_sprite_strip 1
        +set_raster_line_8 TOP_RASTER_LINE
    +set16 INTERRUPT_STRIP_1, VECTOR_IRQ
    +ack_restore_rti
INTERRUPT_STRIP_3 
    +save_regs
    jsr DISPLAY_SPRITE_STRIP

    +inc_frame_counter
    lda FRAME_COUNTER
    and STRIP0_IN_FRAME
    beq +
    +cache_sprite_strip 0
        +set_raster_line_8 TOP_RASTER_LINE
    +set16 INTERRUPT_STRIP_0, VECTOR_IRQ
    +ack_restore_rti
+
    +cache_sprite_strip 1
        +set_raster_line_8 TOP_RASTER_LINE
    +set16 INTERRUPT_STRIP_1, VECTOR_IRQ
    +ack_restore_rti

;-------------------------------------------------------------------------------

!align 255, 0
MULTI_SPRITE_X
    !by $20,$38,$50,$68,$80,$98,$b0,$c8
    !by $28,$40,$58,$70,$88,$a0,$b8,$d0
    !by $30,$48,$60,$78,$90,$a8,$c0,$d8
    !by $38,$50,$68,$80,$98,$b0,$c8,$e0

MULTI_SPRITE_Y
    ;!by $32,$32,$32,$32,$32,$32,$32,$32
    ;!by $47,$47,$47,$47,$47,$47,$47,$47
    ;!by $5c,$5c,$5c,$5c,$5c,$5c,$5c,$5c
    ;!by $71,$71,$71,$71,$71,$71,$71,$71

    !by $32,$32,$32,$32,$32,$32,$32,$32
    !by $47,$47,$47,$47,$47,$47,$47,$47
    ;!by $47,$47,$47,$47,$47,$47,$47,$47
    !by $5c,$5c,$5c,$5c,$5c,$5c,$5c,$5c
    !by $71,$71,$71,$71,$71,$71,$71,$71

    ;!by $32,$32,$32,$32,$32,$32,$32,$32
    ;!by $42,$42,$42,$42,$42,$42,$42,$42
    ;!by $39,$39,$39,$39,$39,$39,$39,$39
    ;!by $40,$40,$40,$40,$40,$40,$40,$40
    ;!by $50,$50,$50,$50,$50,$50,$50,$50
    ;!by $50,$50,$50,$50,$50,$50,$50,$50
    ;!by $61,$61,$61,$61,$61,$61,$61,$61
    ;!by $71,$71,$71,$71,$71,$71,$71,$71
    ;!by $71,$71,$71,$71,$71,$71,$71,$71
    ;!by $91,$91,$91,$91,$91,$91,$91,$91

MULTI_SPRITE_COLOR
    !by $01,$02,$03,$04,$05,$00,$07,$f8
    !by $09,$0a,$0b,$0c,$0d,$0e,$ff,$01
    !by $01,$02,$03,$04,$05,$f0,$07,$08
    !by $09,$0a,$0b,$0c,$fd,$0e,$0f,$01

MULTI_SPRITE_X_MSB
    !by $01,$00,$00,$00,$00,$00,$00,$00
    !by $00,$01,$00,$00,$00,$00,$00,$00
    !by $00,$00,$00,$00,$00,$00,$00,$00
    !by $00,$00,$00,$00,$00,$00,$00,$00

MULTI_SPRITE_FRAME
    !fill 32, (MY_SPRITE/64)
