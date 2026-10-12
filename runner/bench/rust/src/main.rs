// Runner replay benchmark: crc32fast and std BinaryHeap (see README.md).
use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap, HashSet};
use std::time::Instant;

fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}

fn u64_at(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}

fn frame(out: &mut Vec<u8>, p: &[u8]) {
    let len = p.len() as u32;
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&(!len).to_le_bytes());
    out.extend_from_slice(&crc32fast::hash(p).to_le_bytes());
    out.extend_from_slice(p);
}

fn op(tag: u32, a: u64, b: u64) -> Vec<u8> {
    let mut p = tag.to_le_bytes().to_vec();
    p.extend_from_slice(&a.to_le_bytes());
    p.extend_from_slice(&b.to_le_bytes());
    p
}

fn main() {
    let lg: u32 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(16);
    let n: u64 = 1 << lg;

    // The log: n enqueues, then n rounds of Select{1024} and Complete or Requeue of the selected ticket.
    let deadline: Vec<u64> = (0..n).map(|i| (i * 37) % 1024).collect();
    let mut buf = Vec::new();
    for i in 0..n {
        let mut p = 1u32.to_le_bytes().to_vec();
        p.extend_from_slice(&deadline[i as usize].to_le_bytes());
        p.extend_from_slice(&(i as u32).to_le_bytes());
        frame(&mut buf, &p);
    }
    let mut order: Vec<u64> = (0..n).collect();
    order.sort_by_key(|&i| (deadline[i as usize], i));
    for k in 0..n {
        frame(&mut buf, &op(2, 1024, 0));
        let id = order[k as usize];
        let p = if k < n / 2 { op(3, id, 0) } else { op(5, id, 2048 + k) };
        frame(&mut buf, &p);
    }

    let t0 = Instant::now();
    let mut pending: BinaryHeap<Reverse<(u64, u64)>> = BinaryHeap::new();
    let mut running: HashSet<u64> = HashSet::new();
    let mut payload: HashMap<u64, u32> = HashMap::new();
    let mut tries: HashMap<u64, (u64, u64)> = HashMap::new();
    let mut next_id: u64 = 0;
    let mut off = 0usize;
    let end = buf.len();
    while off + 12 <= end {
        let plen = u32_at(&buf, off);
        if u32_at(&buf, off + 4) != !plen || plen > 64 || off + 12 + plen as usize > end {
            panic!("bad frame");
        }
        let p = &buf[off + 12..off + 12 + plen as usize];
        if crc32fast::hash(p) != u32_at(&buf, off + 8) {
            panic!("bad frame");
        }
        off += 12 + plen as usize;
        let a = u64_at(p, 4);
        match u32_at(p, 0) {
            1 => {
                pending.push(Reverse((a, next_id)));
                payload.insert(next_id, u32_at(p, 12));
                tries.insert(next_id, (0, a));
                next_id += 1;
            }
            2 => {
                if let Some(&Reverse((d, id))) = pending.peek() {
                    if d <= a {
                        pending.pop();
                        running.insert(id);
                    }
                }
            }
            3 => {
                if running.remove(&a) {
                    payload.remove(&a);
                    tries.remove(&a);
                }
            }
            5 => {
                if running.remove(&a) {
                    pending.push(Reverse((u64_at(p, 12), a)));
                    if let Some(t) = tries.get_mut(&a) {
                        t.0 += 1;
                    }
                }
            }
            _ => panic!("bad op"),
        }
    }
    assert_eq!(off, end, "bad frame");
    let chk = pending.iter().fold(0u64, |s, Reverse((d, i))| s + i * 31 + d) % (1u64 << 32);
    let ms = t0.elapsed().as_secs_f64() * 1e3;
    println!("replay\t{:.3}\t{}\t{}/{}", ms, chk, pending.len(), next_id);
}
