#!/usr/bin/python

import math

colors = [
    ([  0,   0,   0], "Black"       ),
    ([255, 255, 255], "White"       ),
    ([136,   0,   0], "Red"         ),
    ([170, 255, 238], "Cyan"        ),
    ([204,  68, 204], "Purple"      ),
    ([  0, 204,  85], "Green"       ),
    ([  0,   0, 170], "Blue"        ),
    ([238, 238, 119], "Yellow"      ),
    ([221, 136,  85], "Orange"      ),
    ([102,  68,   0], "Brown"       ),
    ([255, 119, 119], "Light Red"   ),
    ([ 51,  51,  51], "Dark Grey"   ),
    ([119, 119, 119], "Grey"        ),
    ([170, 255, 102], "Light Green" ),
    ([  0, 136, 255], "Light Blue"  ),
    ([187, 187, 187], "Light Grey"  ),
]

BLACK       = 0x0
WHITE       = 0x1
RED         = 0x2
CYAN        = 0x3
PURPLE      = 0x4
GREEN       = 0x5
BLUE        = 0x6
YELLOW      = 0x7
ORANGE      = 0x8
BROWN       = 0x9
LIGHT_RED   = 0xa
DARK_GREY   = 0xb
GREY        = 0xc
LIGHT_GREEN = 0xd
LIGHT_BLUE  = 0xe
LIGHT_GREY  = 0xf

def distance(x, y):
    (xr, xg, xb), x_name = x
    (yr, yg, yb), y_name = y
    dist = math.sqrt((xr-yr)**2 + (xg-yg)**2 + (xb-yb)**2)
    f = lambda x, y: int((x + y)/2 + 0.5)
    return (dist, [f(xr, yr), f(xg, yg), f(xb, yb)], "{} - {}: {}".format(x_name, y_name, int(dist + 0.5)))

def dump_col(col):
    (r, g, b), name = col
    print("{} {} {} {}".format(r, g, b, name))

def dump_mix(mix):
    dist, (r, g, b), name = mix
    print("{} {} {} {}".format(r, g, b, name))

# calculate all possible color mixes
mix = []

for i in range(0, 15):
    for j in range(i + 1, 16):
        mix.append(distance(colors[i], colors[j]))

mix.sort(key=lambda dist: dist[0])

print("GIMP Palette")
print("Name: C64 Palette")
print("Columns: 0")

for col in colors:
    dump_col(col)

for m in mix:
    dump_mix(m)
