"""SC2 baselineCache.bin miner.

Parses the SC2 `MSER` shader-cache container (reverse-engineered from the macOS
client's parser `sub_1023A05C0`), decodes each permutation's RLE-encoded key into
its `b_*` feature vector (decoder ported byte-exact from `sub_1023C9C40`), and —
for the Metal cache — reads the plaintext `<Family><hash>_<Entry>_<profile>` name
embedded in each MTLB. Emits per-family permutation manifests.

See docs/SC2_BASELINECACHE_ANALYSIS.md §6.5 for the format.

Usage:
    python tools/sc2_cache.py <baselinecache.bin> [--metal] [--out DIR]
"""
import argparse
import json
import os
import re
import struct
from collections import Counter, defaultdict


def parse_cache(path):
    """Return (data, blob_region_start, records) where each record is a dict
    {keysize, blobsize, key, blob_off}. Blobs are sequential from 0x20."""
    data = open(path, "rb").read()
    assert data[0x10:0x14] == b"MSER", "not an MSER cache"
    version = struct.unpack("<I", data[0x14:0x18])[0]
    blob_start = struct.unpack("<I", data[0x20:0x24])[0]
    p2_off = struct.unpack("<I", data[0x28:0x2C])[0]
    p2_size = struct.unpack("<I", data[0x2C:0x30])[0]
    cache_ver = struct.unpack("<I", data[0x34:0x38])[0]
    assert version == 8, f"unexpected format version {version}"

    records = []
    pos, end = p2_off, p2_off + p2_size
    blob_off = blob_start
    while pos < end:
        d0 = struct.unpack("<I", data[pos:pos + 4])[0]
        keysize = d0 & 0xFF
        blobsize = d0 >> 8
        key = data[pos + 12:pos + 12 + keysize]
        records.append(dict(keysize=keysize, blobsize=blobsize, key=key,
                            blob_off=blob_off))
        blob_off += blobsize
        pos += 12 + keysize
    assert blob_off == p2_off, "blob region did not tile to payload2 start"
    return data, cache_ver, records


def decode_key(key):
    """Byte-exact port of sub_1023C9C40's RLE/escape expander.

    Grammar (starting at key[2]; key[0],key[1] are a 2-byte header):
      literal b (b != 0xFF)      -> one field = b
      FF n     (n in 1..254)     -> a run of n zero (default) fields
      FF FF                      -> one field = 0xFF
      FF 00 b2 (b2 != 0xFF)      -> one field = b2   (escape for a literal)
      FF 00 FF ...               -> skip the 00 FF pair, keep scanning
    Trailing default (0) fields are omitted by the encoder, so the decoded
    length varies per permutation within a family.
    """
    res = []
    p, n = 2, len(key)
    while p < n:
        b = key[p]
        if b != 0xFF:
            res.append(b)
            p += 1
            continue
        p += 1  # consume FF
        while p < n:
            c = key[p]
            if c != 0:
                if c == 0xFF:
                    res.append(0xFF)
                else:
                    res.extend([0] * c)
                p += 1
                break
            b2 = key[p + 1] if p + 1 < n else 0
            if b2 == 0xFF:
                p += 2
                continue
            res.append(b2)
            p += 2
            break
    return (key[0], key[1]), res


_NAME_RE = re.compile(rb"NAME(..)([\x20-\x7e]{6,90})\x00", re.S)
_PARSE_RE = re.compile(r"^(?P<family>.*?)(?P<hash>[0-9a-f]{8})_"
                       r"(?P<entry>\w+?)_(?P<profile>(?:vs|ps|cs)_\d_\d)$")


def metal_name(data, off, blobsize):
    m = _NAME_RE.search(data[off:off + blobsize])
    if not m:
        return None
    return m.group(2).decode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cache")
    ap.add_argument("--metal", action="store_true",
                    help="cache is the Metal variant (read MTLB names)")
    ap.add_argument("--out", default=None, help="write per-family JSON manifests here")
    ap.add_argument("--limit", type=int, default=0, help="only process first N records")
    args = ap.parse_args()

    data, cache_ver, records = parse_cache(args.cache)
    if args.limit:
        records = records[:args.limit]
    print(f"cache version {cache_ver}; {len(records)} permutation records")

    clean = 0
    by_family = defaultdict(list)
    lengths = Counter()
    for i, r in enumerate(records):
        (h0, h1), vec = decode_key(r["key"])
        lengths[len(vec)] += 1
        # verify full consumption as an integrity check
        _, vec2 = decode_key(r["key"])
        if vec == vec2:
            clean += 1
        name = None
        family = entry = profile = None
        if args.metal:
            name = metal_name(data, r["blob_off"], r["blobsize"])
            if name:
                m = _PARSE_RE.match(name)
                if m:
                    family, entry, profile = m["family"], m["entry"], m["profile"]
        key_flag = data[r["blob_off"]]  # 0 = unique, !=0 = dedup ref
        rec = dict(index=i, header=[h0, h1], vec_len=len(vec), vec=vec,
                   flag=key_flag)
        if name:
            rec.update(family=family, entry=entry, profile=profile)
        by_family[(family, entry, profile)].append(rec)

    print(f"decoded {clean}/{len(records)} keys")
    print("top families (by instance count):")
    for k, v in sorted(by_family.items(), key=lambda x: -len(x[1]))[:20]:
        fam = "/".join(str(x) for x in k) if k[0] else f"<len {v[0]['vec_len']}>"
        print(f"  {fam:<44} {len(v):6d}")

    if args.out:
        os.makedirs(args.out, exist_ok=True)
        for k, v in by_family.items():
            if k[0]:
                fname = f"{k[0]}_{k[1]}_{k[2]}".replace("/", "_")
            else:
                fname = f"len{v[0]['vec_len']}"
            with open(os.path.join(args.out, fname + ".json"), "w") as f:
                json.dump(v, f)
        print(f"wrote {len(by_family)} manifests to {args.out}")


if __name__ == "__main__":
    main()
