import struct,sys
d=open(sys.argv[1],'rb').read()
pe=struct.unpack_from('<I',d,0x3c)[0]
nsec=struct.unpack_from('<H',d,pe+6)[0]; optsz=struct.unpack_from('<H',d,pe+20)[0]
base=struct.unpack_from('<I',d,pe+24+28)[0]
secs=[];o=pe+24+optsz
for i in range(nsec):
    vsz,va,rsz,raw=struct.unpack_from('<IIII',d,o+8); secs.append((va,vsz,raw,rsz)); o+=40
def off(vaddr):
    rva=vaddr-base
    for va,vsz,raw,rsz in secs:
        if va<=rva<va+max(vsz,rsz): return raw+rva-va
for ptr in (0x9229d4,0x9229d8):
    target=struct.unpack_from('<I',d,off(ptr))[0]
    o=off(target); raw=d[o:o+40]; raw=raw[:raw.index(0)] if 0 in raw else raw
    print(hex(ptr),'->',hex(target),'raw',raw.hex(),'xor 0xB7 =',bytes(b^0xB7 for b in raw).decode('latin1'))
