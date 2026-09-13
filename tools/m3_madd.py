"""MADD (Data-Driven Material) decoder for Heroes of the Storm .m3 models.

MADD's `valuePath` field is not a path. It is a Ref<CHAR> pointing at a binary
blob that holds a **two-level, CRC32-keyed property dictionary**:

    layerHash -> { propertyHash -> typed value }

Keys are plain `zlib.crc32` of an unprefixed name:

    level 1   crc32("Diffuse"), crc32("AlphaTest"), crc32("FOW"), ...
    level 2   crc32("DiffuseUVTransform"), crc32("EmissiveControl"), ...

See docs/HOTS_M3_MADD.md for the derivation and for what is still unknown.

Usage:
    python tools/m3_madd.py <file.m3> [...]
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# minimal MD34 reader
# ---------------------------------------------------------------------------

class M3:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        self.magic = self.d[:4][::-1]
        if self.magic not in (b'MD34', b'MD33'):
            raise ValueError('not an m3: %r' % self.magic)
        ofs, n = struct.unpack_from('<II', self.d, 4)
        self.idx = []
        for i in range(n):
            tag, off, cnt, ver = struct.unpack_from('<4sIII', self.d, ofs + 16 * i)
            self.idx.append(dict(tag=tag[::-1], off=off, cnt=cnt, ver=ver))

    def entry(self, i):
        return self.idx[i] if 0 <= i < len(self.idx) else None

    def string(self, count, index):
        e = self.entry(index)
        if not e or e['tag'] != b'CHAR':
            return None
        return self.d[e['off']:e['off'] + count].split(b'\0')[0].decode('utf8', 'replace')

    def u32s(self, count, index):
        e = self.entry(index)
        if not e or not count:
            return []
        return list(struct.unpack_from('<%dI' % count, self.d, e['off']))


# MADD record = SDataDrivenMaterialData (the engine's own name for the chunk).
#
# The v3 loader fixup (Heroes.decrypted, sub_1027987E0) resolves exactly FIVE
# References -- at bytes 0, 12, 24, 36, 48 -- and never touches bytes 60..107,
# which are zero in all 2,132 v3 records. WhiteoutLib declares 9 refs; both
# readings sum to 160, but the engine only treats five as references.
MADD_ELEM_SIZE = {0: 140, 1: 140, 2: 152, 3: 160}
MADD_NREF = {0: 4, 1: 4, 2: 5, 3: 5}
MADD_FIELDS_V2 = ['keyName', 'keyHash', 'extraHash', 'blob', 'texturePaths']
MADD_FIELDS_V1 = ['keyName', 'keyHash', 'blob', 'texturePaths']

# Material type, record byte 150. Prefixes the shader permutation name.
MATERIAL_TYPE = {0: 'Material', 1: 'MaterialMedium', 2: 'MaterialSimple',
                 3: 'MaterialParticle', 4: 'MaterialSplat'}


# ---------------------------------------------------------------------------
# the blob container
# ---------------------------------------------------------------------------

class BadBlob(Exception):
    pass


# A property slot is live only when its type byte is 1. Over the whole corpus
# that holds for 32,554 slots; every other slot is uninitialised padding.
LIVE_TYPE = 1


def _u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def _u64(b, o):
    return struct.unpack_from('<Q', b, o)[0]


def _need(cond, msg):
    if not cond:
        raise BadBlob(msg)


def parse_group(blob, off, n_bytes):
    """Level 2: u32 count; u64 ofsHash, ofsSize, ofsType, ofsValueOffset (36-byte header)."""
    _need(off + 36 <= n_bytes, 'group header out of range')
    count = _u32(blob, off)
    _need(count <= 4096, 'implausible group count %d' % count)
    o_hash, o_size, o_type, o_val = (_u64(blob, off + 4 + 8 * i) for i in range(4))
    if count == 0:
        _need(o_hash == o_size == o_type == o_val == 0, 'empty group with offsets')
        return []
    _need(o_hash == off + 36, 'hash array must follow the header')
    _need(o_size == o_hash + 4 * count, 'size array misplaced')
    _need(o_type == o_size + 2 * count, 'type array misplaced')
    _need(o_val == o_type + count, 'value-offset array misplaced')
    _need(o_val + 8 * count <= n_bytes, 'value-offset array out of range')
    props = []
    for i in range(count):
        typ = blob[o_type + i]
        if typ != LIVE_TYPE:
            # Unused slot. `count` is the array's capacity, not its population,
            # and the writer does not clear the tail -- hash/size/offset are all
            # stale heap bytes. Reading them yields plausible-looking "hashes"
            # (they are really u16 index pairs) and offsets far outside the blob.
            continue
        h = _u32(blob, o_hash + 4 * i)
        size = struct.unpack_from('<H', blob, o_size + 2 * i)[0]
        voff = _u64(blob, o_val + 8 * i)
        if voff + size > n_bytes:
            # Same stale-slot case, but this one kept a type byte of 1. The
            # offset is wild (often ~2**63), so range is the only tell. Drop the
            # slot, not the record: the framing of every other slot is intact.
            continue
        props.append(dict(hash=h, size=size, type=typ, off=voff,
                          data=blob[voff:voff + size]))
    return props


def parse_blob(blob):
    """Level 1: u32 count; u64 ofsKeys(=20); u64 ofsGroupOffsets(=20+4*count)."""
    n = len(blob)
    _need(n >= 20, 'blob too small')
    count = _u32(blob, 0)
    o_keys = _u64(blob, 4)
    o_groups = _u64(blob, 12)
    _need(count <= 4096, 'implausible group count %d' % count)
    _need(o_keys == 20, 'key array must start at 20 (got %d)' % o_keys)
    _need(o_groups == 20 + 4 * count, 'group-offset array misplaced')
    _need(o_groups + 8 * count <= n, 'group-offset array out of range')
    out = []
    for i in range(count):
        h = _u32(blob, o_keys + 4 * i)
        goff = _u64(blob, o_groups + 8 * i)
        out.append(dict(hash=h, off=goff, props=parse_group(blob, goff, n)))
    return out


# ---------------------------------------------------------------------------
# name recovery
# ---------------------------------------------------------------------------

def crc(name):
    return zlib.crc32(name.encode()) & 0xFFFFFFFF


# Level-1 names confirmed by crc32 round-trip against the corpus.
LAYER_NAMES = [
    'Diffuse', 'Specular', 'Normal', 'Decal', 'Emissive', 'Emissive2',
    'AlphaMask', 'AlphaMask2', 'Envio', 'EnvioMask', 'HeightMap',
    'Displacement', 'DisplacementStrength', 'Fog', 'FOW', 'AlphaTest',
    'TwoSided', 'DiffuseTeamColor', 'Cloaking', 'Reflection',
]

# Level-2 names are crc32(<prefix><property>) with NO b_/p_ prefix.
_PROP_SUFFIXES = ['UVTransform', 'Control', 'Constant', 'Alpha', 'Threshold',
                  'Multiplier']
_PROP_PREFIXES = LAYER_NAMES + ['Alpha', 'Strength', 'Heightmap',
                                'ReflectionStrength']

# The two levels are SEPARATE namespaces: a level-1 key is a bare layer name,
# a level-2 key is a composed <prefix><property>. Never look one up in the other
# or composed names leak in as bogus layer identifications.
LAYER_BY_HASH = {crc(_n): _n for _n in LAYER_NAMES}
PROP_BY_HASH = {}
for _p in _PROP_PREFIXES:
    for _s in _PROP_SUFFIXES:
        PROP_BY_HASH.setdefault(crc(_p + _s), _p + _s)

# Names recovered by tools/crc_collide (see its README). The file is generated,
# and every entry in it is crc32-verified, but it is a superset of the two
# namespaces -- so a name only resolves at the level it was actually seen at.
_RECOVERED = os.path.join(HERE, 'crc_collide', 'recovered_names.txt')
ALL_NAMES = {}
if os.path.exists(_RECOVERED):
    for _line in open(_RECOVERED, encoding='utf8'):
        _line = _line.split('#')[0].strip()
        if not _line:
            continue
        _h, _n = _line.split()
        if crc(_n) == int(_h, 16):
            ALL_NAMES[int(_h, 16)] = _n


def layer_of(h):
    return LAYER_BY_HASH.get(h) or ALL_NAMES.get(h)


def property_of(h):
    return PROP_BY_HASH.get(h) or ALL_NAMES.get(h)


# Value shapes. `type` is 1 for every populated value in the corpus.
#
# Each size corresponds to one rollout of the Art Tools `SC2 Bitmap` map, which
# is what a material layer actually is (see docs/HOTS_M3_MADD_STRATEGIES.md).
VALUE_SHAPES = {
    4:  'scalar: f32, u32 enum, or BGRA colour -- depends on the property',
    8:  'Tex<X>: u32 index into texturePaths, u32 texture/RTT source',
    12: 'f32 x3 (triplanar offset / scale)',
    16: 'f32 x4',
    20: '<X>ChannelSelection: u32 selector, f32 multiply, f32 add, f32 (1.0), u16 flags + 2 STALE bytes',
    32: '<X>UVTransform: offset UV, tiling UV, angle UVW (f32 x7) + packed tile flags',
    48: 'FresnelParams<X>: u32 mode, f32 exponent, min, max, rotation, mask x3',
}

# 4-byte values are not one type. These are the ones confirmed against the corpus.
FOUR_BYTE_KIND = {
    'AlphaTestThreshold': 'f32 (normalised 0..1; SMaterialData stores 0..255)',
    'DepthBlendThreshhold': 'f32',
    'Specularity': 'f32',
    'HeightMapScale': 'f32',
    'EmissiveControl': 'u32 LayerBlendOp',
    'Emissive2Control': 'u32 LayerBlendOp',
    'EnvioControl': 'u32 LayerBlendOp',
}


def four_byte_kind(name):
    """f32 / u32-enum / BGRA colour, by property name."""
    if name in FOUR_BYTE_KIND:
        return FOUR_BYTE_KIND[name]
    if name and name.endswith('Constant'):
        return 'BGRA colour'
    if name and name.endswith('UVSelection'):
        return 'u32 UV-set index (0..3)'
    return None


def madd_records(m):
    """Yield (version, {field: Reference}, tail_scalars) for every MADD element."""
    for e in m.idx:
        if e['tag'] != b'MADD':
            continue
        v = e['ver']
        esz, nref = MADD_ELEM_SIZE[v], MADD_NREF[v]
        fields = MADD_FIELDS_V2 if v >= 2 else MADD_FIELDS_V1
        for k in range(e['cnt']):
            base = e['off'] + esz * k
            refs = {fields[j]: struct.unpack_from('<III', m.d, base + 12 * j)
                    for j in range(nref)}
            ntail = (esz - 12 * nref) // 4
            tail = struct.unpack_from('<%dI' % ntail, m.d, base + 12 * nref)
            yield v, refs, tail


def dump(path):
    m = M3(path)
    for v, refs, tail in madd_records(m):
        name = m.string(*refs['keyName'][:2]) or ''
        print(f"\n=== {os.path.basename(path)}  MADD v{v}  material {name!r}")
        cnt, idx, _ = refs['blob']
        if not cnt:
            print("    (no property blob)")
            continue
        e = m.entry(idx)
        blob = m.d[e['off']:e['off'] + cnt]
        try:
            groups = parse_blob(blob)
        except BadBlob as ex:
            print(f"    blob {cnt} bytes -- unparsed ({ex})")
            continue
        for g in groups:
            gname = layer_of(g['hash']) or '?'
            print(f"  [{g['hash']:08x}] {gname:24s} {len(g['props'])} properties")
            for p in g['props']:
                if not p['size']:
                    continue
                pname = property_of(p['hash']) or '?'
                shape = VALUE_SHAPES.get(p['size'], '')
                vals = ''
                if p['size'] % 4 == 0 and p['size'] <= 48:
                    f = struct.unpack('<%df' % (p['size'] // 4), p['data'])
                    u = struct.unpack('<%dI' % (p['size'] // 4), p['data'])
                    vals = ' '.join(('%g' % a) if 1e-6 < abs(a) < 1e9 else ('%#x' % b)
                                    for a, b in zip(f, u))
                print(f"      {p['hash']:08x} {pname:28s} sz={p['size']:<3d} "
                      f"ty={p['type']}  {vals}   [{shape}]")


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)
    for a in sys.argv[1:]:
        dump(a)
