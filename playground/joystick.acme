!macro inc_soft_x {
    inc SOFT_X
    ldx #8
    cpx SOFT_X
    bne +
    ldx #0
    stx SOFT_X
    jsr INC_HARD_X
+
}

!macro inc_soft_y {
    inc SOFT_Y
    ldy #8
    cpy SOFT_Y
    bne +
    ldy #0
    sty SOFT_Y
    jsr INC_HARD_Y
+
}

!macro dec_soft_x {
    dec SOFT_X
    bpl +
    ldx #7
    stx SOFT_X
    jsr DEC_HARD_X
+
}

!macro dec_soft_y {
    dec SOFT_Y
    bpl +
    ldx #7
    stx SOFT_Y
    jsr DEC_HARD_Y
+
}

INC_HARD_X !zone {
    inc HARD_X
    ldx #40
    cpx HARD_X
    bne .return

    ldx #0
    stx HARD_X
    jsr DEC_HARD_Y

.return
    rts
}

INC_HARD_Y !zone {
    inc HARD_Y
    ldx #25
    cpx HARD_Y
    bne .return

    ldx #0
    stx HARD_Y

    pha
    lda HARD_X
    sec
    sbc #16
    sta HARD_X
    clc
    adc #40
    bpl +
    sta HARD_X
    jmp ++
+
    dec SCREEN_Y
++
    pla
.return
    rts
}

DEC_HARD_X !zone {
    dec HARD_X
    bpl .return

    ldx #39
    stx HARD_X
    jsr INC_HARD_Y

.return
    rts
}

DEC_HARD_Y !zone {
    dec HARD_Y
    bpl .return

    ldx #24
    stx HARD_Y

    pha
    lda HARD_X
    clc
    adc #16
    sta HARD_X
    sec
    sbc #40
    bmi +
    sta HARD_X
    jmp ++
+
    inc SCREEN_Y
++
    pla
.return
    rts
}

JOY !zone {
    lda CIA1_PORT_2
.up
    lsr 
    bcs .down
    +dec_soft_y
.down
    lsr
    bcs .left
    +inc_soft_y
.left
    lsr
    bcs .right
    +inc_soft_x
.right
    lsr
    bcs .fire
    +dec_soft_x
.fire
    lsr
    bcs +
    inc SCREEN
+
    lda SCREEN_Y
    clc
    adc HARD_Y
    sta TOTAL_Y
    rts
}


