!cpu 6510               ; for illegal opcodes
!convtab scr            ; for conversion to c64 screen codes

;-------------------------------------------------------------------------------
; far branches
;-------------------------------------------------------------------------------

!macro bcc .t {
    bcs * + 5
    jmp .t
}

!macro bcs .t {
    bcc * + 5
    jmp .t
}

!macro beq .t {
    bne * + 5
    jmp .t
}

!macro bne .t {
    beq * + 5
    jmp .t
}

!macro bmi .t {
    bpl * + 5
	jmp .t
}

!macro bpl .t {
    bmi * + 5
	jmp .t
}

!macro bvc .t {
    bvs * + 5
	jmp .t
}

!macro bvs .t {
    bvc * + 5
	jmp .t
}

;-------------------------------------------------------------------------------
; skip jumps
;-------------------------------------------------------------------------------

!macro bcc {
.checkmark
    bcc +                               
+
    !if >.checkmark != >* {
        !warn "page boundary crossed"
    }
}

!macro bcs {
.checkmark
    bcs +                               
+
    !if >.checkmark != >* {
        !warn "page boundary crossed"
    }
}

!macro beq {
.checkmark
    beq +                               
+
    !if >.checkmark != >* {
        !warn "page boundary crossed"
    }
}

!macro bne {
.checkmark
    bne +                               
+
    !if >.checkmark != >* {
        !warn "page boundary crossed"
    }
}

!macro bpl {
.checkmark
    bpl +                               
+
    !if >.checkmark != >* {
        !warn "page boundary crossed"
    }
}

!macro bmi {
.checkmark
    bmi +                               
+
    !if >.checkmark != >* {
        !warn "page boundary crossed"
    }
}

!macro bvc {
.checkmark
    bvc +                               
+
    !if >.checkmark != >* {
        !warn "page boundary crossed"
    }
}

!macro bvs {
.checkmark
    bvs +                               
+
    !if >.checkmark != >* {
        !warn "page boundary crossed"
    }
}

;-------------------------------------------------------------------------------

!macro create_basic_starter .line, .start {
    ; here begins basic
    *=$0801

    ; end address of basic programm
    !word .end - 1

    ; line number of the basic line
    !word .line

    ; sys
    !by $9e

    ; find leading decimal digit of .start
    !set .i = 10000
    !set .digit = 0
    !do while .digit = 0 {
        !set .digit = .start / .i
        !set .start = .start % .i
        !set .i = .i / 10
    }

    !by '0' + .digit

    ; now output the rest
    !do while .i != 0 {
        !by '0' + .start / .i
        !set .start = .start % .i
        !set .i = .i / 10
    }
.end
}

!macro create_basic_starter .start {
    +create_basic_starter 42, .start
}

;-------------------------------------------------------------------------------

VECTOR_NMI   = $fffa
VECTOR_RESET = $fffc
VECTOR_IRQ   = $fffe

!macro save_regs {
    inc VIC_BORDER
    sta SAVE_A
    stx SAVE_X
    sty SAVE_Y
}

!macro restore_regs {
    lda SAVE_A
    ldx SAVE_X
    ldy SAVE_Y
}

!macro stack_save_regs {
    pha
    txa
    pha
    tya
    pha
}

!macro stack_restore_regs {
    pla
    tay
    pla
    tax
    pla   
}

!macro ack_restore_rti {
    dec VIC_BORDER
    inc VIC_IRQ_STATUS
    +restore_regs
    rti
}

!macro stack_save_regs_and_ack_interrupt {
    inc VIC_IRQ_STATUS
    +stack_save_regs
}

!macro stack_restore_regs_and_rti {
    +stack_restore_regs
    rti
}

!macro sprite_line .v {
    !by .v>>16, (.v>>8)&255, .v&255
}

!macro flip_byte .v {
    !by ((.v & 1) << 7) | ((.v & 2) << 5) | ((.v & 4) << 3) | ((.v & 8) << 1) | ((.v & 16) >> 1) | ((.v & 32) >> 3) | ((.v & 64) >> 5) | ((.v & 128) >> 7)
}

!macro address .v {
    !by <.v, >.v
}

!macro clear_screen .v, .addr {
    ldx #0
    lda #.v
-
    sta .addr + $0000, x
    sta .addr + $0100, x
    sta .addr + $0200, x
    sta .addr + $0300, x
    dex
    bne -
}

!macro wait .w {
    !if .w = 1 {
        !error "does not work for an input value of 1"
    } else {
        !if .w % 2 = 0 {
            !for .i, .w / 2 {
                nop
            }
        } else {
            !for .i, (.w-3) / 2 {
                nop
            }
            bit $ea
        }
    }
}

RAM_ROM_SELECTION            = $01
RAM_ROM_DEFAULT	             = %00110111
RAM_ROM_ALL_RAM_WITHIO       = %00100101
RAM_ROM_ALL_RAM_WITHCHARROM  = %00100001
RAM_ROM_ALL_RAM              = %00100000
RAM_ROM_BASIC_CHAR_KERNAL    = %00100011

!macro set .value, .addr {
    lda #.value
    sta .addr
}

!macro set16 .value, .addr {
    lda #<.value
    sta .addr
    lda #>.value
    sta .addr+1
}

!macro set16 .current, .value, .addr {
    lda #<.value
    sta .addr

    !if >.current != >.value {
        lda #>.value
        sta .addr+1
    } else {
        !warn "yeah"
    }
}

BPL_OPCODE = $10
BMI_OPCODE = $30
