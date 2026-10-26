## kv
An on-disk [B+Tree](https://en.wikipedia.org/wiki/B%2B_tree) in zig.

## Why
I’ve always wanted to write a B+ tree from scratch to test my understanding of them.

This is still a work in progress, and I plan to support concurrent operations
once I finished reading some books.

# Disk Layout
```
db
├── CHECKPOINT
├── index
└── wal
    └── wal-00000000000000000000
    └── wal-00000000000000000001
```

### Plan
- [ ] WAL
- [ ] Durability
- [ ] Fault injection tests with dm
