// commands benchmark in Rust: N new commands, then the same N as duplicates, each in one BEGIN IMMEDIATE transaction.
// std has no SQLite, so this calls libsqlite3's C API directly (no crates), like bench.c.
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::ptr::null_mut;
use std::time::Instant;

type Db = c_void;
type Stmt = c_void;
const OK: c_int = 0;
const ROW: c_int = 100;
const DONE: c_int = 101;
const TRANSIENT: isize = -1;

#[link(name = "sqlite3")]
extern "C" {
    fn sqlite3_libversion() -> *const c_char;
    fn sqlite3_open(path: *const c_char, db: *mut *mut Db) -> c_int;
    fn sqlite3_close(db: *mut Db) -> c_int;
    fn sqlite3_errmsg(db: *mut Db) -> *const c_char;
    fn sqlite3_exec(db: *mut Db, sql: *const c_char, cb: *mut c_void, arg: *mut c_void, err: *mut *mut c_char) -> c_int;
    fn sqlite3_prepare_v2(db: *mut Db, sql: *const c_char, n: c_int, st: *mut *mut Stmt, tail: *mut *const c_char) -> c_int;
    fn sqlite3_bind_int64(st: *mut Stmt, i: c_int, v: i64) -> c_int;
    fn sqlite3_bind_text(st: *mut Stmt, i: c_int, s: *const c_char, n: c_int, d: isize) -> c_int;
    fn sqlite3_step(st: *mut Stmt) -> c_int;
    fn sqlite3_reset(st: *mut Stmt) -> c_int;
    fn sqlite3_column_text(st: *mut Stmt, i: c_int) -> *const c_char;
    fn sqlite3_finalize(st: *mut Stmt) -> c_int;
}

struct Conn {
    db: *mut Db,
    begin: *mut Stmt,
    commit: *mut Stmt,
    find: *mut Stmt,
    read: *mut Stmt,
    save: *mut Stmt,
    keep: *mut Stmt,
    emit: *mut Stmt,
}

fn ok(db: *mut Db, rc: c_int, want: c_int) {
    if rc != want {
        eprintln!("sqlite: {}", unsafe { CStr::from_ptr(sqlite3_errmsg(db)) }.to_string_lossy());
        std::process::exit(1);
    }
}

fn prepare(db: *mut Db, sql: &CStr) -> *mut Stmt {
    let mut st = null_mut();
    ok(db, unsafe { sqlite3_prepare_v2(db, sql.as_ptr(), -1, &mut st, null_mut()) }, OK);
    st
}

fn exec(db: *mut Db, sql: &CStr) {
    ok(db, unsafe { sqlite3_exec(db, sql.as_ptr(), null_mut(), null_mut(), null_mut()) }, OK);
}

fn col(st: *mut Stmt, i: c_int) -> String {
    unsafe { CStr::from_ptr(sqlite3_column_text(st, i)) }.to_string_lossy().into_owned()
}

impl Conn {
    fn run(&self, st: *mut Stmt) {
        ok(self.db, unsafe { sqlite3_step(st) }, DONE);
        ok(self.db, unsafe { sqlite3_reset(st) }, OK);
    }

    fn text(&self, st: *mut Stmt, i: c_int, s: &str) {
        let c = CString::new(s).unwrap();
        ok(self.db, unsafe { sqlite3_bind_text(st, i, c.as_ptr(), -1, TRANSIENT) }, OK);
    }

    // 1 for a new command, 2 for a duplicate, 0 for a conflict, with the recorded or new total.
    fn handle(&self, id: &str, payload: &str) -> (u32, u32) {
        self.run(self.begin);
        self.text(self.find, 1, id);
        let rc = unsafe { sqlite3_step(self.find) };
        if rc == ROW {
            let same = col(self.find, 0) == payload;
            let r: u32 = col(self.find, 2).parse().unwrap();
            ok(self.db, unsafe { sqlite3_reset(self.find) }, OK);
            self.run(self.commit);
            return (if same { 2 } else { 0 }, r);
        }
        ok(self.db, rc, DONE);
        ok(self.db, unsafe { sqlite3_reset(self.find) }, OK);
        ok(self.db, unsafe { sqlite3_step(self.read) }, ROW);
        let total: u32 = col(self.read, 0).parse::<u32>().unwrap().wrapping_add(payload.parse().unwrap());
        ok(self.db, unsafe { sqlite3_reset(self.read) }, OK);
        let t = total.to_string();
        self.text(self.save, 1, &t);
        self.run(self.save);
        self.text(self.keep, 1, id);
        self.text(self.keep, 2, payload);
        ok(self.db, unsafe { sqlite3_bind_int64(self.keep, 3, 1) }, OK);
        self.text(self.keep, 4, &t);
        ok(self.db, unsafe { sqlite3_bind_int64(self.keep, 5, 200) }, OK);
        self.run(self.keep);
        self.text(self.emit, 1, id);
        self.text(self.emit, 2, &format!("total={total}"));
        self.run(self.emit);
        self.run(self.commit);
        (1, total)
    }

    // Command i has id cmd_i and amount (x_i >> 1) % 1000. h = h*31 + result.
    fn pass(&self, n: u32, want: u32) -> u32 {
        let (mut x, mut h) = (1u32, 0u32);
        for i in 0..n {
            let (kind, r) = self.handle(&format!("cmd_{i}"), &((x >> 1) % 1000).to_string());
            if kind != want {
                eprintln!("unexpected reply");
                std::process::exit(1);
            }
            h = h.wrapping_mul(31).wrapping_add(r);
            x = x.wrapping_mul(1664525).wrapping_add(1013904223);
        }
        h
    }
}

fn main() {
    let path = CString::new(std::env::args().nth(1).unwrap_or("out/rs.db".into())).unwrap();
    let n: u32 = std::env::args().nth(2).map_or(10000, |s| s.parse().expect("command count"));
    let mut db = null_mut();
    if unsafe { sqlite3_open(path.as_ptr(), &mut db) } != OK {
        std::process::exit(1);
    }
    println!("sqlite\t{}", unsafe { CStr::from_ptr(sqlite3_libversion()) }.to_string_lossy());
    exec(db, c"PRAGMA busy_timeout = 10000");
    exec(db, c"CREATE TABLE IF NOT EXISTS commands_state (k INTEGER PRIMARY KEY CHECK (k = 0), state TEXT NOT NULL)");
    exec(db, c"CREATE TABLE IF NOT EXISTS commands_seen (id TEXT PRIMARY KEY, payload TEXT NOT NULL, kind INTEGER NOT NULL, result TEXT NOT NULL, at INTEGER NOT NULL)");
    exec(db, c"CREATE INDEX IF NOT EXISTS commands_seen_at ON commands_seen (at)");
    exec(db, c"CREATE TABLE IF NOT EXISTS commands_outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, effect TEXT NOT NULL)");
    exec(db, c"INSERT OR IGNORE INTO commands_state (k, state) VALUES (0, '0')");
    let c = Conn {
        db,
        begin: prepare(db, c"BEGIN IMMEDIATE"),
        commit: prepare(db, c"COMMIT"),
        find: prepare(db, c"SELECT payload, kind, result, at FROM commands_seen WHERE id = ?"),
        read: prepare(db, c"SELECT state FROM commands_state WHERE k = 0"),
        save: prepare(db, c"UPDATE commands_state SET state = ? WHERE k = 0"),
        keep: prepare(db, c"INSERT INTO commands_seen (id, payload, kind, result, at) VALUES (?, ?, ?, ?, ?)"),
        emit: prepare(db, c"INSERT INTO commands_outbox (id, effect) VALUES (?, ?)"),
    };

    let t0 = Instant::now();
    c.pass(n, 1);
    let fresh = t0.elapsed();
    ok(db, unsafe { sqlite3_step(c.read) }, ROW);
    println!("fresh\t{:.3}\t{}", fresh.as_secs_f64() * 1e3, col(c.read, 0));
    ok(db, unsafe { sqlite3_reset(c.read) }, OK);

    let t0 = Instant::now();
    let h = c.pass(n, 2);
    println!("replay\t{:.3}\t{}", t0.elapsed().as_secs_f64() * 1e3, h);

    for st in [c.begin, c.commit, c.find, c.read, c.save, c.keep, c.emit] {
        unsafe { sqlite3_finalize(st) };
    }
    unsafe { sqlite3_close(db) };
}
