const std = @import("std");

const Wal = @import("Wal.zig");
const pagemod = @import("page.zig");
const BTree = @import("BTree.zig");
const PageCache = @import("PageCache.zig");

const Io = std.Io;
const mem = std.mem;

pub const LSN = Wal.LSN;
const PageFrame = pagemod.PageFrame;
const PageId = pagemod.PageId;
const page_size = pagemod.page_size;

/// Thin wrapper around `Wal`.
///
/// Inserted records will be prefixed with an 8-bytes "tag".
const Log = @This();
wal: Wal,
tree: *BTree,
/// The WAL checkpoint. Borrowed from `Database`.
checkpoint: *const LSN,
page_cache: *PageCache,

pub const Tag = enum(u64) {
    full_page,
    insert,
};

/// Open an existing WAL or create a new one.
pub fn open(io: Io, dir: Io.Dir, checkpoint: *const LSN, page_cache: *PageCache) !Log {
    return .{
        .wal = try Wal.open(io, dir, if (checkpoint.* == 0) null else checkpoint.*),
        .checkpoint = checkpoint,
        // trust caller to set `tree`
        .tree = undefined,
        .page_cache = page_cache,
    };
}

pub fn deinit(self: *Log) void {
    self.wal.deinit();
}

pub fn recover(self: *Log, allocator: mem.Allocator) !void {
    while (try self.wal.next(allocator)) |raw_record| {
        defer raw_record.deinit(allocator);
        const raw_buf = raw_record.buffer;

        @setRuntimeSafety(true);
        const tag: Tag = @fromBackingInt(std.mem.readInt(u64, raw_buf[0..8], .little));
        switch (tag) {
            .insert => try self.recover_insert(raw_buf[8..], raw_record.lsn),
            .full_page => try self.recover_full_page(raw_buf[8..]),
        }
    }
}

/// See `log_insert` to learn how raw_buf is constructed. raw_buf starts after `tag`
pub fn recover_insert(self: *Log, raw_buf: []u8, lsn: LSN) !void {
    var offset: usize = 0;
    const key_len = std.mem.readInt(usize, raw_buf[offset..][0..@sizeOf(usize)], .little);
    offset += @sizeOf(usize);
    const value_len = std.mem.readInt(usize, raw_buf[offset..][0..@sizeOf(usize)], .little);
    offset += @sizeOf(usize);
    const key: []u8 = raw_buf[offset..][0..key_len];
    offset += key_len;
    const value: []u8 = raw_buf[offset..][0..value_len];

    try self.tree.insert(key, value, .{ .recovery_lsn = lsn });
}

pub fn recover_full_page(self: *Log, raw_buf: []u8) !void {
    const page_id = std.mem.readInt(PageId, raw_buf[0..8], .little);
    const logged_page = raw_buf[8..];
    // TODO: if it fails with IncompletePage then we should still write the page and not fail
    // because it's the job of the WAL to recover it.
    const page_frame = try self.page_cache.get(page_id);
    defer self.page_cache.put(page_frame);

    @memcpy(page_frame.inner, logged_page);
}

/// log an `insert` operation.
///
/// if the affected page has not been touched since the last WAL checkpoint then a full image of
/// the page will be recorded.
///
/// format: [tag][key_len][value_len][key][value]
pub fn log_insert(self: *Log, allocator: mem.Allocator, key: []const u8, value: []const u8, page: *PageFrame) !LSN {
    // no-op during recover inserts, see `recover_insert`
    // TODO: not sure if the caller (the tree) is responsible for that
    if (self.wal.mode == .recovery) return 0;

    // always log the full page if this is the first change since the
    // last checkpoint. This is to recover torn writes and changes
    // that did not persist.
    if (page.header().lsn < self.checkpoint.* or page.header().lsn == 0) {
        _ = try self.log_page(allocator, page);
    }

    const total_len = @sizeOf(Tag) + @sizeOf(usize) + @sizeOf(usize) + key.len + value.len;
    const buf = try allocator.alloc(u8, total_len);
    defer allocator.free(buf);

    var offset: usize = 0;
    std.mem.writeInt(u64, buf[offset..][0..@sizeOf(Tag)], @backingInt(Tag.insert), .little);
    offset += @sizeOf(Tag);
    std.mem.writeInt(u64, buf[offset..][0..@sizeOf(usize)], key.len, .little);
    offset += @sizeOf(u64);
    std.mem.writeInt(u64, buf[offset..][0..@sizeOf(usize)], value.len, .little);
    offset += @sizeOf(u64);
    @memcpy(buf[offset..][0..key.len], key);
    offset += key.len;
    @memcpy(buf[offset..][0..value.len], value);

    return try self.wal.append(buf);
}

/// log a copy of the page
///
/// format: [tag][page_id][page]
pub fn log_page(self: *Log, allocator: mem.Allocator, page: *const PageFrame) !LSN {
    const buf = try allocator.alloc(u8, @sizeOf(Tag) + @sizeOf(PageId) + page_size);
    defer allocator.free(buf);

    var offset: usize = 0;
    std.mem.writeInt(u64, buf[offset..][0..@sizeOf(Tag)], @backingInt(Tag.full_page), .little);
    offset += @sizeOf(Tag);
    std.mem.writeInt(PageId, buf[offset..][0..@sizeOf(PageId)], page.page_id, .little);
    offset += @sizeOf(PageId);
    @memcpy(buf[offset..][0..page_size], page.inner);

    return try self.wal.append(buf);
}
