; 
; zero page: $0000 - $00FF
;

RAM_ROM_SWITCH     = $01

SAVE_A             = $02
SAVE_X             = $03
SAVE_Y             = $04

MULTI_MAX_Y_IN_STRIP = $05

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

; 
; CPU stack: $0100 - $01FF
;

CPU_STACK   = $0100; - $01FF

; 
; VIC area: $4000 - $7FFF
; 

HIRES           = $4000; - $5fff
SPR_FR          = $6000; - $6fff ; 32 sprites * 2 buffers * 64 bytes/frame

SCREEN          = $7000; - $73ff
SCREEN_ZERO     = $7400; only sprite ptrs used
SCREEN_STATUS_0 = $7800; only sprite ptrs used
SCREEN_STATUS_1 = $7c00; only sprite ptrs used

SPR_FR_ZERO     = $7400; - $7440
SPR_FR_STATUS_0 = $7800; - $7aff
SPR_FR_STATUS_1 = $7c00; - $7dff

SPR_PTR         = SCREEN + $400 - 8
SPR_PTR_ZERO    = SCREEN_ZERO + $400 - 8
SPR_PTR_STATUS_0= SCREEN_STATUS_0 + $400 - 8
SPR_PTR_STATUS_1= SCREEN_STATUS_1 + $400 - 8

; REMARK: there is still plenty of room within the dummy screen areas

SOFT_SPR_FR     = $8000; - $8fff
TILES           = $9000; - $9fff
SOFTCHARS       = $a000; - $a800

SOFTCHARS_0 = $8000
SOFTCHARS_1 = $8100
SOFTCHARS_2 = $8200
SOFTCHARS_3 = $8300
SOFTCHARS_4 = $8400
SOFTCHARS_5 = $8500
SOFTCHARS_6 = $8600
SOFTCHARS_7 = $8700
SOFTCHARS_C = $8800
SOFTCHARS_S = $8900

; 64 x 64 tiles (6.4 x 10.24 full screens)
LEVEL       = $a000; - $afff
