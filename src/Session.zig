const std = @import("std");

const BTree = @import("BTree.zig");

const Io = std.Io;

/// A `Session` is a connection to an open database file.
const Self = @This();

io: Io,
gpa: std.mem.Allocator,
db_file: Io.File,
tree: BTree,

/// Open the database at `path`.
/// A new database is initialized If `path` doesn't exist.
pub fn open(
    io: Io,
    gpa: std.mem.Allocator,
    cwd: Io.Dir,
    path: []const u8,
) !Self {
    var initialize = false;
    const file = cwd.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            initialize = true;
            break :blk try cwd.createFile(io, path, .{ .read = true });
        },
        else => return err,
    };
    errdefer file.close(io);

    const tree = if (initialize)
        try BTree.empty(gpa, io, file)
    else
        BTree.load(gpa, io, file);

    return .{
        .io = io,
        .gpa = gpa,
        .db_file = file,
        .tree = tree,
    };
}

pub fn deinit(self: *Self) void {
    self.tree.deinit();
    self.db_file.close(self.io);
}

pub fn insert(self: *Self, key: []const u8, value: []const u8) !void {
    try self.tree.insert(key, value);
}

/// Look up `key` and return a copy of its value, or `null` when it's not found.
///
/// The caller owns the returned slice.
pub fn find(self: *Self, key: []const u8) !?[]u8 {
    const result = try self.tree.find(key);
    defer self.tree.page_cache.put(result.page);

    var cell = result.cell orelse return null;
    return try self.gpa.dupe(u8, cell.val());
}

const testing = std.testing;

test "insert then find a key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try Self.open(testing.io, testing.allocator, tmp.dir, "db");
    defer session.deinit();

    try session.insert("abc", "123");

    const value = try session.find("abc") orelse return error.KeyMissing;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("123", value);

    try testing.expect((try session.find("missing")) == null);
}

test "keys survive reopening the database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var session = try Self.open(testing.io, testing.allocator, tmp.dir, "db");
        defer session.deinit();
        try session.insert("abc", "123");
        try session.insert("hello", "world");
    }

    var session = try Self.open(testing.io, testing.allocator, tmp.dir, "db");
    defer session.deinit();

    const value = try session.find("hello") orelse return error.KeyMissing;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("world", value);
}
