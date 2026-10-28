"""Literal Python translation of WLM 8.1's MSNP challenge code (msnmsgr.exe).

FUN_004a0018: builds "%s%s" (challenge + product id), zero-pads with '0' only
when the length is not a multiple of 8, MD5s challenge+key, calls
FUN_0049fcb8, then XORs the *unmasked* MD5 words with (high, low, high, low).
Used as a test oracle for MSNKit's MSNPChallenge.
"""
import hashlib, struct, sys

M = 0x7FFFFFFF

def fun_0049fcb8(chl, md5):  # chl: list of u32, md5: 4 x u32 (unmasked)
    u1, u4, u2, u5 = md5[0] & M, md5[1] & M, md5[2] & M, md5[3] & M
    v7 = ((chl[0] * 0xE79A9C1) % M) * u1
    v7 = (v7 + u4) % M                      # temp
    v8 = (v7 + chl[1]) * u2
    v9 = (v8 + u5) % M                      # high
    v7 = v9 + v7                            # low accumulator
    v8 = v7
    for i in range(1, len(chl) // 2):
        t = ((chl[2 * i] * 0xE79A9C1) % M)
        t = (t + v9) * u1
        v10 = (t + u4) % M                  # temp
        t = (v10 + chl[2 * i + 1]) * u2
        v9 = (t + u5) % M                   # high
        v8 = v9 + v7 + v10
        v7 = v7 + v10 + v9
    return (v9 + u4) % M, (v8 + u5) % M

def fun_004a0018(challenge, prod_id, prod_key):
    s = (challenge + prod_id).encode()
    if len(s) % 8:
        s += b'0' * (8 - len(s) % 8)
    chl = list(struct.unpack('<%dI' % (len(s) // 4), s))
    md5 = list(struct.unpack('<4I', hashlib.md5((challenge + prod_key).encode()).digest()))
    high, low = fun_0049fcb8(chl, md5)
    out = [md5[0] ^ high, md5[1] ^ low, md5[2] ^ high, md5[3] ^ low]
    return struct.pack('<4I', *out).hex()

if __name__ == '__main__':
    print(fun_004a0018(*sys.argv[1:4]))
