const std = @import("std");

const stdx = @import("stdx.zig");
const Database = @import("Database.zig");
const pagemod = @import("page.zig");

const mem = std.mem;

/// A `Session` is a handle to an open database.
const Self = @This();

db: *Database,
gpa: mem.Allocator,

pub fn open(db: *Database, gpa: mem.Allocator) Self {
    return .{ .db = db, .gpa = gpa };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn insert(self: *Self, key: []const u8, value: []const u8) !void {
    try self.db.tree.insert(key, value, .{});
}

/// Look up `key` and return a copy of its value, or `null` when it's not found.
///
/// The caller owns the returned slice.
pub fn find(self: *Self, key: []const u8) !?[]u8 {
    const result = try self.db.tree.find(key);
    defer self.db.page_cache.put(result.page);

    var cell = result.cell orelse return null;
    return try self.gpa.dupe(u8, cell.val());
}

const testing = std.testing;

test "insert then find a key" {
    var tmp = stdx.tmpMemoryDir(.{});
    defer tmp.cleanup();

    const db = try Database.open(testing.io, testing.allocator, tmp.dir, "db");
    defer db.deinit();

    var session = Self.open(db, testing.allocator);
    defer session.deinit();

    try session.insert("abc", "123");

    const value = try session.find("abc") orelse return error.KeyMissing;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("123", value);

    try testing.expect((try session.find("missing")) == null);
}

test "keys survive reopening the database" {
    var tmp = stdx.tmpMemoryDir(.{});
    defer tmp.cleanup();

    {
        const db = try Database.open(testing.io, testing.allocator, tmp.dir, "db");
        defer db.deinit();

        var session = Self.open(db, testing.allocator);
        defer session.deinit();
        try session.insert("abc", "123");
        try session.insert("hello", "world");
    }

    const db = try Database.open(testing.io, testing.allocator, tmp.dir, "db");
    defer db.deinit();

    var session = Self.open(db, testing.allocator);
    defer session.deinit();

    const value = try session.find("hello") orelse return error.KeyMissing;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("world", value);
}

// TODO: page-oriented logging
//test "WAL recovers inserts" {
//    var tmp = stdx.tmpMemoryDir(.{});
//    defer tmp.cleanup();
//
//    {
//        const db = try Database.open(testing.io, testing.allocator, tmp.dir, "db");
//
//        var session = Self.open(db, testing.allocator);
//        try session.insert("abc", "123");
//
//        session.deinit();
//        db.deinit();
//
//        const data_dir = try tmp.dir.openDir(testing.io, "db", .{});
//        defer data_dir.close(testing.io);
//
//        const index_file = try data_dir.openFile(testing.io, "index", .{ .mode = .read_write });
//        defer index_file.close(testing.io);
//
//        // XXX: simulate the system crashing before persisting the page.
//        const fill: pagemod.PageHeader = .empty(.leaf);
//        try index_file.writePositionalAll(testing.io, @ptrCast(&fill), 0);
//    }
//
//    const db = try Database.open(testing.io, testing.allocator, tmp.dir, "db");
//    defer db.deinit();
//
//    var session = Self.open(db, testing.allocator);
//    defer session.deinit();
//
//    const result = try session.db.tree.find("abc");
//    defer session.db.page_cache.put(result.page);
//
//    var cell = result.cell orelse return error.KeyMissing;
//    try testing.expectEqualStrings("123", cell.val());
//
//    // assert that recovery updates the LSN too
//    try testing.expect(result.page.header().lsn != 0);
//}

test "reopening a database that spans multiple pages" {
    var tmp = stdx.tmpMemoryDir(.{});
    defer tmp.cleanup();

    var value: [1000]u8 = @splat('v');
    var key_buf: [16]u8 = undefined;

    // Enough rows to split the root page and allocate new pages.
    {
        const db = try Database.open(testing.io, testing.allocator, tmp.dir, "db");
        defer db.deinit();

        var session = Self.open(db, testing.allocator);
        defer session.deinit();

        for (0..10) |i| {
            const key = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
            try session.insert(key, &value);
        }
    }

    const db = try Database.open(testing.io, testing.allocator, tmp.dir, "db");
    defer db.deinit();

    var session = Self.open(db, testing.allocator);
    defer session.deinit();

    for (0..10) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        const found = try session.find(key) orelse return error.KeyMissing;
        defer testing.allocator.free(found);
        try testing.expectEqualStrings(&value, found);
    }
}
