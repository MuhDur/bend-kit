# Runner replay benchmark: zlib.crc32, struct, and heapq (see README.md).
import heapq
import struct
import sys
import time
import zlib

lg = int(sys.argv[1]) if len(sys.argv) > 1 else 16
n = 1 << lg


def frame(p):
    return struct.pack("<III", len(p), (~len(p)) & 0xFFFFFFFF, zlib.crc32(p) & 0xFFFFFFFF) + p


def op(tag, a, b=0):
    return struct.pack("<IQQ", tag, a, b)


# The log: n enqueues, then n rounds of Select{1024} and Complete or Requeue of the selected ticket.
parts = []
deadline = [(i * 37) % 1024 for i in range(n)]
for i in range(n):
    parts.append(frame(struct.pack("<IQ", 1, deadline[i]) + struct.pack("<I", i)))
order = sorted(range(n), key=lambda i: (deadline[i], i))
for k in range(n):
    parts.append(frame(op(2, 1024)))
    parts.append(frame(op(3, order[k]) if k < n // 2 else op(5, order[k], 2048 + k)))
buf = b"".join(parts)

view = memoryview(buf)
t0 = time.perf_counter()
pending = []  # (deadline, id)
running = set()
payload = {}
tries = {}  # id -> [fails, start]
next_id = 0
off = 0
end = len(buf)
while off + 12 <= end:
    plen, nlen, want = struct.unpack_from("<III", view, off)
    if nlen != ((~plen) & 0xFFFFFFFF) or plen > 64 or off + 12 + plen > end:
        raise SystemExit("bad frame")
    p = view[off + 12 : off + 12 + plen]
    if (zlib.crc32(p) & 0xFFFFFFFF) != want:
        raise SystemExit("bad frame")
    off += 12 + plen
    tag, a = struct.unpack_from("<IQ", p, 0)
    if tag == 1:
        heapq.heappush(pending, (a, next_id))
        payload[next_id] = struct.unpack_from("<I", p, 12)[0]
        tries[next_id] = [0, a]
        next_id += 1
    elif tag == 2:
        if pending and pending[0][0] <= a:
            running.add(heapq.heappop(pending)[1])
    elif tag == 3:
        if a in running:
            running.discard(a)
            payload.pop(a, None)
            tries.pop(a, None)
    elif tag == 5:
        if a in running:
            running.discard(a)
            heapq.heappush(pending, (struct.unpack_from("<Q", p, 12)[0], a))
            tries[a][0] += 1
    else:
        raise SystemExit("bad op")
if off != end:
    raise SystemExit("bad frame")
chk = sum(i * 31 + d for d, i in pending) % (1 << 32)
t1 = time.perf_counter()
print(f"replay\t{(t1 - t0) * 1e3:.3f}\t{chk}\t{len(pending)}/{next_id}")
