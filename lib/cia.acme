; CIA1 and CIA2 constants

CIA1 = $DC00
CIA2 = $DD00

CIA1_PORT_2 = $DC00
CIA1_PORT_1 = $DC01
CIA1_TIMER_A_LO = $DC04
CIA1_TIMER_A_HI = $DC05
CIA1_TIMER_B_LO = $DC06
CIA1_TIMER_B_HI = $DC07
CIA1_INTERRUPT_CONTROL = $DC0D

    ;Bit 0..1: Select the position of the VIC-memory
    ;   * %00, 0: Bank 3: $C000-$FFFF, 49152-65535
    ;   * %01, 1: Bank 2: $8000-$BFFF, 32768-49151
    ;   * %10, 2: Bank 1: $4000-$7FFF, 16384-32767
    ;   * %11, 3: Bank 0: $0000-$3FFF, 0-16383 (standard)
    ;Bit 2: RS-232: TXD Output, Userport: Data PA 2 (pin M)
    ;Bit 3..5: serial bus Output (0=High/Inactive, 1=Low/Active)
    ;   * Bit 3: ATN OUT
    ;   * Bit 4: CLOCK OUT
    ;   * Bit 5: DATA OUT
    ;Bit 6..7: serial bus Input (0=Low/Active, 1=High/Inactive)
    ;   * Bit 6: CLOCK IN
    ;   * Bit 7: DATA IN 
CIA2_DATA_PORT_A = $DD00

CIA2_TIMER_A_LO = $DD04
CIA2_TIMER_A_HI = $DD05
CIA2_TIMER_B_LO = $DD06
CIA2_TIMER_B_HI = $DD07
CIA2_INTERRUPT_CONTROL = $DD0D
CIA2_CONTROL_TIMER_A = $DD0E

!macro disable_timer_interrupts {
    lda #%01111111
    sta CIA1_INTERRUPT_CONTROL
    sta CIA2_INTERRUPT_CONTROL
}

!macro clear_timer {
    lda #0
    sta CIA1_TIMER_A_LO
    sta CIA1_TIMER_A_HI
    sta CIA2_TIMER_A_LO
    sta CIA2_TIMER_A_HI
}
