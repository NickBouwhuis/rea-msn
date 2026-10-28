import re,sys
data=open(sys.argv[1],'rb').read()
n=int(sys.argv[2]) if len(sys.argv)>2 else 5
for m in re.finditer(rb'(?:[\x20-\x7e]\x00){%d,}'%n, data):
    print(hex(m.start()), m.group().decode('utf-16le'))
for m in re.finditer(rb'[\x20-\x7e\t\r\n]{%d,}'%n, data):
    print(hex(m.start()), m.group().decode('ascii').replace('\r\n','\\r\\n').replace('\n','\\n'))
