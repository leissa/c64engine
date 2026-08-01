#!/usr/bin/env python3
"""Build an EasyFlash .crt from the assembled engine image and boot stub.

Layout follows the EasyFlash Programmer's Guide (skoe, 2012-05-22);
section numbers in the comments refer to it.

    bank 0, ROMH  $1800-$1aff  EAPI (768 bytes, 5.1)
                  $1b00-$1b07  magic "EF-Name:" (6)
                  $1b08-$1b17  cartridge name, 16 bytes, 0-padded (6)
                  $1c00-$1fff  boot stub, appears at $fc00 in Ultimax (4.1)
    bank 1..n     $0000-$00ff  chunk table
                  $0100-       chunk data, each chunk padded to a page

Each chunk is "copy <len> bytes to <dest>"; a zero length ends the table.
The boot copier walks this stream with the cartridge in 16k mode, so bank n covers a contiguous $8000-$bfff window.
Keeping every chunk's data page aligned means a bank boundary can only be crossed on a page boundary, which is all the
copier's bank-wrap check has to handle.

The .crt is written directly rather than via `cartconv -t easy` so that the per-bank placement above is explicit;
`cartconv -c` validates the result.
"""

import argparse
import sys

BANK_SIZE = 0x2000          # one chip, one bank
BANKS = 64                  # 512 KiB per chip (2.1)
PAGE = 0x100
TABLE_SIZE = PAGE           # chunk table occupies the first page of bank 1
EAPI_SIZE = 0x300           # 5.1: reserve 768 bytes
EAPI_OFF = 0x1800
NAME_MAGIC_OFF = 0x1b00
NAME_OFF = 0x1b08
NAME_LEN = 16
BOOT_OFF = 0x1c00
BOOT_SIZE = BANK_SIZE - BOOT_OFF
PAYLOAD_BANK = 1
FILL = 0xff                 # 3.5: unused areas should be $ff

CRT_MAGIC = b"C64 CARTRIDGE   "
CRT_HARDWARE_EASYFLASH = 32
CRT_CHIP_FLASH = 2
# EasyFlash powers up in Ultimax: /GAME asserted, /EXROM not (table 2.1).
# The header records line status, where 0 means active.
CRT_EXROM, CRT_GAME = 1, 0


def die(msg):
    sys.exit(f"mkcart: {msg}")


def petscii(s):
    """ASCII to PETSCII: swap the case of letters, pass everything else.

    This reproduces the magic given as a byte sequence in section 6 -- "EF-Name:" is spelled 65 66 2d 6e 41 4d 45 3a.
    """
    out = bytearray()
    for ch in s:
        c = ord(ch)
        if 0x41 <= c <= 0x5a or 0x61 <= c <= 0x7a:
            c ^= 0x20
        if c > 0xff:
            die(f"cannot encode {ch!r} in the cartridge name")
        out.append(c)
    return bytes(out)


def parse_range(text):
    try:
        lo, hi = text.split(":")
        lo, hi = int(lo, 0), int(hi, 0)
    except ValueError:
        die(f"bad range {text!r}, expected start:end (e.g. 0xc000:0xe400)")
    if lo >= hi:
        die(f"bad range {text!r}, start must be below end")
    return lo, hi


def read_cbm(path):
    """Read a prg/obj: two byte little-endian load address, then the image."""
    data = open(path, "rb").read()
    if len(data) < 3:
        die(f"{path}: too short to be a cbm image")
    return data[0] | data[1] << 8, data[2:]


def split_chunks(load, body, skips):
    """Split the image into chunks, dropping the skipped address ranges."""
    end = load + len(body)
    cuts = []
    for lo, hi in sorted(skips):
        lo, hi = max(lo, load), min(hi, end)
        if lo < hi:
            cuts.append((lo, hi))

    chunks, pos = [], load
    for lo, hi in cuts:
        if pos < lo:
            chunks.append((pos, body[pos - load:lo - load]))
        pos = max(pos, hi)
    if pos < end:
        chunks.append((pos, body[pos - load:]))

    for dest, data in chunks:
        if dest + len(data) > 0x10000:
            die(f"chunk at ${dest:04x} runs past the top of memory")
    return chunks


def build_stream(chunks):
    """Chunk table in the first page, then page-aligned chunk data."""
    if len(chunks) * 4 + 4 > TABLE_SIZE:
        die(f"{len(chunks)} chunks do not fit in a {TABLE_SIZE} byte table")

    table, data = bytearray(), bytearray()
    for dest, payload in chunks:
        n = len(payload)
        table += bytes([dest & 0xff, dest >> 8, n & 0xff, n >> 8])
        data += payload
        if len(data) % PAGE:                    # pad up to the next page
            data += bytes(FILL for _ in range(PAGE - len(data) % PAGE))
    table += bytes(4)                           # zero length terminates

    return bytes(table).ljust(TABLE_SIZE, b"\xff") + bytes(data)


def build_banks(stream, boot, eapi, name):
    banks = [[bytearray([FILL] * BANK_SIZE) for _ in range(2)]
             for _ in range(BANKS)]

    romh0 = banks[0][1]
    romh0[EAPI_OFF:EAPI_OFF + EAPI_SIZE] = eapi
    romh0[NAME_MAGIC_OFF:NAME_MAGIC_OFF + 8] = petscii("EF-Name:")
    romh0[NAME_OFF:NAME_OFF + NAME_LEN] = petscii(name).ljust(NAME_LEN, b"\0")
    romh0[BOOT_OFF:BOOT_OFF + BOOT_SIZE] = boot

    # The 16k window is ROML then ROMH of the same bank, so the stream simply runs through chip 0 and chip 1 of each
    # bank in turn.
    avail = (BANKS - PAYLOAD_BANK) * 2 * BANK_SIZE
    if len(stream) > avail:
        die(f"payload of {len(stream)} bytes exceeds {avail} bytes of flash")

    for i in range(0, len(stream), BANK_SIZE):
        piece = stream[i:i + BANK_SIZE]
        slot = i // BANK_SIZE
        banks[PAYLOAD_BANK + slot // 2][slot % 2][:len(piece)] = piece

    return banks


def write_crt(path, banks, title):
    with open(path, "wb") as f:
        f.write(CRT_MAGIC)
        f.write((0x40).to_bytes(4, "big"))
        f.write((0x0100).to_bytes(2, "big"))
        f.write(CRT_HARDWARE_EASYFLASH.to_bytes(2, "big"))
        f.write(bytes([CRT_EXROM, CRT_GAME]))
        f.write(bytes(6))
        f.write(title.encode("ascii", "replace")[:32].ljust(32, b"\0"))

        for bank, chips in enumerate(banks):
            for chip, image in enumerate(chips):
                f.write(b"CHIP")
                f.write((0x10 + BANK_SIZE).to_bytes(4, "big"))
                f.write(CRT_CHIP_FLASH.to_bytes(2, "big"))
                f.write(bank.to_bytes(2, "big"))
                f.write((0x8000 if chip == 0 else 0xa000).to_bytes(2, "big"))
                f.write(BANK_SIZE.to_bytes(2, "big"))
                f.write(image)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--engine", required=True, help="assembled engine (cbm image)")
    p.add_argument("--boot", required=True, help="boot stub (flat $fc00-$ffff)")
    p.add_argument("--eapi", required=True, help="EAPI binary (cbm image)")
    p.add_argument("--name", required=True, help=f"menu name, max {NAME_LEN} chars")
    p.add_argument("--skip", action="append", default=[], metavar="LO:HI",
                   help="address range to leave out of the payload, e.g. "
                        "0xc000:0xe400 for memory the engine fills at runtime")
    p.add_argument("-o", "--output", required=True)
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()

    if len(args.name) > NAME_LEN:
        die(f"name {args.name!r} is longer than {NAME_LEN} characters")

    boot = open(args.boot, "rb").read()
    if len(boot) != BOOT_SIZE:
        die(f"{args.boot}: expected {BOOT_SIZE} bytes, got {len(boot)}")

    # EAPI is assembled with a load address;
    # strip it and check the signature so a wrong file is caught here rather than on real hardware (5.5).
    _, eapi = read_cbm(args.eapi)
    if len(eapi) != EAPI_SIZE:
        die(f"{args.eapi}: expected {EAPI_SIZE} bytes of EAPI, got {len(eapi)}")
    if eapi[:4] != b"eapi":
        die(f"{args.eapi}: missing the 'eapi' signature")

    load, body = read_cbm(args.engine)
    chunks = split_chunks(load, body, [parse_range(s) for s in args.skip])
    stream = build_stream(chunks)
    banks = build_banks(stream, boot, eapi, args.name)
    write_crt(args.output, banks, args.name)

    if args.verbose:
        print(f"engine  ${load:04x}-${load + len(body) - 1:04x}"
              f"  {len(body)} bytes")
        for dest, data in chunks:
            print(f"chunk   ${dest:04x}-${dest + len(data) - 1:04x}"
                  f"  {len(data)} bytes")
        used = -(-len(stream) // BANK_SIZE)
        print(f"payload {len(stream)} bytes -> banks {PAYLOAD_BANK}"
              f"..{PAYLOAD_BANK + (used - 1) // 2}")
        print(f"{args.output}: {BANKS} banks")


if __name__ == "__main__":
    main()
