RAM_ROM_SWITCH     = $01

SAVE_A             = $02
SAVE_X             = $03
SAVE_Y             = $04

MULTI_MAX_Y_IN_STRIP = $05

PTR_HIRES           = $06;-$07
PTR_COLOR           = $08;-$09
PTR_SCREEN          = $0a;-$0b

FRAME_COUNTER       = $06
STRIP0_IN_FRAME     = $07
STRIP1_IN_FRAME     = $08
STRIP2_IN_FRAME     = $09
STRIP3_IN_FRAME     = $0a
COLLISION_0_1       = $0b
COLLISION_1_2       = $0c
COLLISION_2_3       = $0d
SPRITE_STRIP_X_MSB  = $0e
SPRITE_STRIP_MULTI  = $0f
SPRITE_STRIP_X      = $10
SPRITE_STRIP_Y      = $18
SPRITE_STRIP_COLOR  = $20
SPRITE_STRIP_FRAME  = $28
MULTI_INDEX_TABLE   = $30

; is indexed by 
; lda FRAME_COUNTER_TABLE, x
; where x = {1, 3}
FRAME_COUNTER_TABLE = $50-1
