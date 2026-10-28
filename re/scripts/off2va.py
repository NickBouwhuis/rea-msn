import struct,sys
d=open(sys.argv[1],'rb').read()
pe=struct.unpack_from('<I',d,0x3c)[0]
nsec=struct.unpack_from('<H',d,pe+6)[0]; optsz=struct.unpack_from('<H',d,pe+20)[0]
base=struct.unpack_from('<I',d,pe+24+28)[0]
secs=[]
o=pe+24+optsz
for i in range(nsec):
    name=d[o:o+8].rstrip(b'\0').decode(); vsz,va,rsz,raw=struct.unpack_from('<IIII',d,o+8); secs.append((name,va,vsz,raw,rsz)); o+=40
for a in sys.argv[2:]:
    off=int(a,16)
    for n,va,vsz,raw,rsz in secs:
        if raw<=off<raw+rsz: print(a,'->',n,hex(base+va+off-raw))
