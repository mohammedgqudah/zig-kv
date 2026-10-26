## kv
A key value database, based on a [B+Tree](https://en.wikipedia.org/wiki/B%2B_tree)


# Usage
```zig
pub fn main(init: std.process.Init) !void {
    const db = try Database.open("db", .{
        .io = init.io,
        .gpa = init.gpa,
        .cwd = std.Io.Dir.cwd(),
    });
    defer db.deinit();

    var session = Session.open(db, init.gpa);
    defer session.deinit();

    try session.insert("abc", "123");

    // `find` returns a copy of the value, owned by the caller.
    const value = try session.find("abc") orelse return error.KeyMissing;
    defer init.gpa.free(value);
}
```

# Disk Layout
```
db
├── CHECKPOINT
├── index
└── wal
    └── wal-00000000000000000000
    └── wal-00000000000000000001
```


# Plan
- [ ] Concurrency
- [ ] Finish WAL
