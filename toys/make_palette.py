#!/usr/bin/python

import math

colors = [
    ([0x00, 0x00, 0x00], "Black"       ),
    ([0xFF, 0xFF, 0xFF], "White"       ),
    ([0x68, 0x37, 0x2B], "Red"         ),
    ([0x70, 0xA4, 0xB2], "Cyan"        ),
    ([0x6F, 0x3D, 0x86], "Purple"      ),
    ([0x58, 0x8D, 0x43], "Green"       ),
    ([0x35, 0x28, 0x79], "Blue"        ),
    ([0xB8, 0xC7, 0x6F], "Yellow"      ),
    ([0x6F, 0x4F, 0x25], "Orange"      ),
    ([0x43, 0x39, 0x00], "Brown"       ),
    ([0x9A, 0x67, 0x59], "Light Red"   ),
    ([0x44, 0x44, 0x44], "Dark Grey"   ),
    ([0x6C, 0x6C, 0x6C], "Grey"        ),
    ([0x9A, 0xD2, 0x84], "Light Green" ),
    ([0x6C, 0x5E, 0xB5], "Light Blue"  ),
    ([0x95, 0x95, 0x95], "Light Grey"  ),
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
print("Columns: 16")

for col in colors:
    dump_col(col)

for m in mix:
    dump_mix(m)
