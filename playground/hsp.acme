!to "hsp.prg", cbm   ; output program
!cpu 6510               ; for illegal opcodes
!convtab scr            ; for conversion to c64 screen codes

!source "../lib/zero.asm"
!source "../lib/vic.asm"
!source "../lib/cia.asm"
!source "../lib/std.asm"

LINE_0  = 48 ; first possible bad line bar
LINE_M  = LINE_0 - 1
LINE_MM = LINE_0 - 2

;CRUNCH_LINE_START=56 ; second chance to tweak stuff
CRUNCH_LINE_START=LINE_0+8
WAIT_VALUE=39

SCREEN0 = $4000
SCREEN1 = $4400

; Bit 7: Bit 8 of $D012        
; Bit 6: Extended Color Modus  
; Bit 5: Hires-Bitmapmode      
; Bit 4: Screen output enabled?
; Bit 3: 25 rows (24 otherwise)
CONTROL_Y=%00011000
CONTROL_Y_INVALID=%01111000
;---------------^^^ must be zero

+create_basic_starter $0c00
*=$0c00; = 2304

START !zone {
    ;
    ; setup interrupt stuff
    ;

    ; select $4000 - $7fff VIC BANK
    lda CIA2_DATA_PORT_A
    and #%11111100
    ora #%00000010
    sta CIA2_DATA_PORT_A

    sei
    cld

    ; ack all interrupts
    lda #$ff
    sta VIC_IRQ_STATUS
    lda CIA1_INTERRUPT_CONTROL
    lda CIA2_INTERRUPT_CONTROL

    +set RAM_ROM_ALL_RAM_WITHIO, RAM_ROM_SELECTION

    ; just select raster interrupts
    +disable_timer_interrupts
    +clear_timer
    +set 1, VIC_IRQ_CONTROL
    +set_raster_line_9 LINE_MM

    ; setup interrupt vectors
    +set16 EMPTY_INTERRUPT, VECTOR_NMI
    +set16 EMPTY_INTERRUPT, VECTOR_RESET
    +set16 IRQ_VSP, VECTOR_IRQ

    ; reset stack
    ldx #$ff
    txs

    ; select RAM
    +set RAM_ROM_ALL_RAM_WITHCHARROM, RAM_ROM_SELECTION

    ; copy over standard chars
    ldx #0
-
    lda $d000, x
    sta $4800, x
    lda $d100, x
    sta $4900, x
    lda $d200, x
    sta $4a00, x
    lda $d300, x
    sta $4b00, x
    lda $d400, x
    sta $4c00, x
    lda $d500, x
    sta $4d00, x
    lda $d600, x
    sta $4e00, x
    lda $d700, x
    sta $4f00, x
    dex
    bne -

    +set RAM_ROM_ALL_RAM_WITHIO, RAM_ROM_SELECTION

    ; enable maskable interrupts again
    cli

    ; select SCREEN0 and 2nd char set
    lda #%00000010
    sta VIC_ADDR_SELECT

    ; setup screen
!for .j, 25 {
!set .i = .j - 1
    lda #.i
    ldx #39
-
    sta SCREEN0 + .i*40, x
    sta COLOR_RAM + .i*40, x
    sta SCREEN1 - 24 + .i*40, x
    dex
    bpl -
}

    ;+clear_screen '!', $0800
}

MAIN_LOOP !zone {
    inc $4000
    ; some 7 cycle garbage instructions
    lda ($ff), y
    lda ($ff, x)
    lda ($ff), y
    lda ($ff, x)
    lda ($ff), y

    lda #%00000100
    bit CIA1_PORT_2
    beq .left

    lda #%00001000
    bit CIA1_PORT_2
    beq .right

    lda #%00000001
    bit CIA1_PORT_2
    beq .up

    lda #%00000010
    bit CIA1_PORT_2
    beq .down

    jmp MAIN_LOOP

.left
    ; wait for lock
-
    lda LOCK
    bne -

    ldx VSP_SCROLL
    dex
    bpl +
    ldx #39
+
    stx VSP_SCROLL
-
    lda #%00000100
    bit CIA1_PORT_2
    beq -
    jmp MAIN_LOOP

.right
    ; wait for lock
-
    lda LOCK
    bne -

    ldx VSP_SCROLL
    inx
    cpx #40
    bne +
    ldx #0
+
    stx VSP_SCROLL
-
    lda #%00001000
    bit CIA1_PORT_2
    beq -
    jmp MAIN_LOOP

.up
    ; wait for lock
-
    lda LOCK
    bne -

    ldx LINE_CRUNCH
    dex
    bpl +
    ldx #24
+
    stx LINE_CRUNCH
-
    lda #%00000001
    bit CIA1_PORT_2
    beq -
    jmp MAIN_LOOP

.down
    ; wait for lock
-
    lda LOCK
    bne -

    ldx LINE_CRUNCH
    inx
    cpx #25
    bne +
    ldx #0
+
    stx LINE_CRUNCH
-
    lda #%00000010
    bit CIA1_PORT_2
    beq -
    jmp MAIN_LOOP
}
EMPTY_INTERRUPT
    inc VIC_BORDER
    rti

!macro init_stable_raster .stabilizing_label {
    +save_regs                      ;       9 cycles
    ; ack interrupt
    inc VIC_IRQ_STATUS              ;  +6 = 15 cycles

    inc VIC_RASTER                  ;  +6 = 21 cycles
    +set16 .stabilizing_label, VECTOR_IRQ  ; +12 = 33 cycles

    ; save stack state
    tsx                             ;  +2 = 35 cycles

    inc LOCK

    ; begin raster stabilization
    cli                             ;  +2 = 37 cycles

    ; somewhere here the next interrupt will hit
    +wait 30
}

!macro wobble_check .line {
    lda #.line
    cmp VIC_RASTER
    +bne
}

!macro inc_vic_control_y {
    lda VIC_CONTROL_Y   ; 4
    clc                 ; 2
    adc #1              ; 2
    and #%00000111      ; 2
    clc                 ; 2
    adc # CONTROL_Y_INVALID     ; 2
    sta VIC_CONTROL_Y   ; 4
}                       ; -> 18

!align 255, 0
IRQ_VSP !zone {
    ; LINE_MM
    +init_stable_raster .irq_line_m

.irq_line_m
    ; LINE_M
    ; -> we are off here by 9 to 10 cycles

    ; regs are still saved

    ; restore stack state
    txs                             ;    +2 = 11/12 cycles

    ; calculate the number of nops to skip
    lda #WAIT_VALUE
    sec
    sbc VSP_SCROLL
    lsr
    sta .self_modifying_branch__nops + 1 ; +14 = 25/26 cycles

    ; introduce an extra cycle below if carry is set
    bcs .set_bmi
.set_bpl
    ldx #BPL_OPCODE
    ; always true
    bne +
.set_bmi
    ldx #BMI_OPCODE
    ; make this code path as long as the previous one
    nop
+
    stx .self_modifying_branch__lsb ;   +11 = 36/37 cycles

    lda # (CONTROL_Y_INVALID & %11111000) + (LINE_0 + 1) % 8
    sta VIC_CONTROL_Y ; make LINE_0 one row before a bad line

    lda # (CONTROL_Y_INVALID & %11111000) + (LINE_0) % 8
    tay ; this value causes a badline in LINE_0   +10 = 46/47 cycles

    +wait 11                        ;   +11 = 57/58 cycles
    +wobble_check LINE_0            ;+10/+9 = 66/66 cycles

    ; the N flag is guaranteed to be clear here

    ; LINE_0
    ; -> the raster interrupt is stable now with 3 cycles off

    ; introduce an extra cycle if VSP_SCROLL is odd i.e., 39 - VSP_SCROLL is even
.self_modifying_branch__lsb
    +bpl
    nop                             ; +4/+5 =  7/8  cycles

.self_modifying_branch__nops
    ; always true
    +bpl
.nops_start
    +wait WAIT_VALUE-1              ; +3-41 = 10-49 cycles

    ; now the store happens at the exact timing
    sty VIC_CONTROL_Y               ;    +4 = 14-53 cycles

    +wait_loop 63*7 + 5 - 31
    ; do we have to crunch?
    ldx LINE_CRUNCH
    beq .fld_loop_no_crunch

    +wait_loop 31 - 10

.crunch_loop
    +inc_vic_control_y          ; 18
    ; we are at cycle 8 here

    dex
    beq .fld_lines              ; 4

    +wait_loop 63 - 18 - 4 - 3
    jmp .crunch_loop            ; 3

.fld_loop_no_crunch
    +wait_loop 31 - 5 - 20
    ldx #25
    jmp .fld_loop

.fld_lines
    lda #25             ; 2
    sec                 ; 2
    sbc LINE_CRUNCH     ; 4
    beq .skip_fld       ; 2
    tax                 ; 2
                        ; -> 12
    ;ldx LINE_CRUNCH     ; 4
    ;tax                 ; 2
    ;sbx #25             ; 2
    ;beq .skip_fld       ; 2
                        ;; -> 10

    +wait_loop 63 - 8 - 5 - 12 - 20

.fld_loop
    +inc_vic_control_y  ; -> 18

    ;dex
    ;beq .skip_fld

    ;+wait_loop 63 - 18 - 4 - 3
    ;jmp .fld_loop

    +wait_loop 63 - 18 - 5

    dex
    bne .fld_loop

.skip_fld

    lda VIC_CONTROL_Y
    and #%00000111
    clc
    adc # CONTROL_Y
    sta VIC_CONTROL_Y

    ; clean up
    dec LOCK

    +set_raster_line_8 LINE_MM
    +set16 IRQ_VSP, VECTOR_IRQ

    +ack_restore_rti
}

VSP_SCROLL
    !by 40 - 24
LOCK
    !by 0
LINE_CRUNCH
    !by 0

!if >IRQ_VSP != >* {
    !error "different pages"
}
