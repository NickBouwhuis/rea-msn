import os,re,sys
D=sys.argv[1]
idx=[]
for f in os.listdir(D):
    if not f.endswith('.c'): continue
    with open(os.path.join(D,f)) as fh:
        head=fh.read(600)
    m=re.search(r'// range: (0x[0-9a-f]+)-(0x[0-9a-f]+)',head)
    if m: idx.append((int(m.group(1),16),int(m.group(2),16),f))
for a in sys.argv[2:]:
    t=int(a,16)
    print(a,[f for s,e,f in idx if s<=t<=e])
