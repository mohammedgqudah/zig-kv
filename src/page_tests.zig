const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const pagemod = @import("page.zig");
const PageCache = pagemod.PageCache;
const PageId = pagemod.PageId;
const CellOffset = pagemod.CellOffset;
const PageHeader = pagemod.PageHeader;
const PageBuffer = pagemod.PageBuffer;
const Cell = pagemod.Cell;
const Tree = pagemod.Tree;
const page_size = pagemod.page_size;
const page_magic = pagemod.page_magic;

const Io = std.Io;
const mem = std.mem;
const fmt = std.fmt;
const assert = std.debug.assert;

const test_allocator = std.testing.allocator;

test PageCache {
    const io = std.testing.io;
    const allocator = test_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "file", .{ .read = true });

    var cache: PageCache = .new(allocator, file, io);
    defer cache.deinit();
    assert(cache.get(0) == error.IncompletePage);
}

const validPageResult = struct {
    max_key: []u8,
};

/// Validate a b+tree and check its invariants.
pub fn expectValidTree(tree: *Tree) !void {
    if (!builtin.is_test) @compileError("expectValidTree is only allowed in testing");

    var arena = std.heap.ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try expectValidTreeNode(allocator, tree, tree.root_page_id);
}

pub fn expectValidTreeNode(
    allocator: mem.Allocator,
    tree: *Tree,
    page_id: PageId,
) !validPageResult {
    var page: *PageBuffer = (try tree.page_cache.get(page_id)).?;
    defer tree.page_cache.put(page);

    // 1. root.pointers() is sorted
    // 2. max_key(child[N]) < key[N]
    assert(page.header().magic == page_magic);
    var prev_off = page.pointers()[0];
    for (page.pointers(), 0..) |offset, idx| {
        assert(offset < page_size);
        var prev_cell = page.cell(prev_off);
        var current_cell = page.cell(offset);
        switch (mem.order(u8, current_cell.key(), prev_cell.key())) {
            .lt => {
                std.debug.print(
                    "invalid node: page {d}, pointer {d}: keys are out of order\n" ++
                        "  previous key: {s}\n" ++
                        "  current key:  {s}\n",
                    .{
                        page_id,
                        idx,
                        prev_cell.key()[0..10],
                        current_cell.key()[0..10],
                    },
                );
                return error.InvalidPointers;
            },
            else => {},
        }
        prev_off = offset;
    }

    var greatest_cell = page.cell(page.pointers()[page.pointers().len - 1]);

    if (page.header().type == .internal) {
        for (page.pointers(), 0..) |offset, idx| {
            var cell = page.cell(offset);
            const next_page_id = mem.readInt(PageId, cell.val()[0..8], .little);
            const child_result = try expectValidTreeNode(allocator, tree, next_page_id);
            const cmp = mem.order(u8, child_result.max_key, cell.key());
            if (cmp == .gt or cmp == .eq) {
                std.debug.print(
                    "invalid internal node: page {d}, pointer {d}: " ++
                        "child maximum key exceeds separator key\n" ++
                        "  child page:    {d}\n" ++
                        "  child max key: {s}\n" ++
                        "  separator key: {s}\n",
                    .{
                        page_id,
                        idx,
                        next_page_id,
                        child_result.max_key,
                        cell.key(),
                    },
                );
                return error.InvalidChild;
            }
        }
        if (page.header().right_pointer != 0) {
            const next_page_id = page.header().right_pointer;
            const child_result = try expectValidTreeNode(allocator, tree, next_page_id);
            const cmp = mem.order(u8, child_result.max_key, greatest_cell.key());
            if (cmp == .lt) {
                std.debug.print(
                    "invalid internal node: page {d}, rightmost pointer: " ++
                        "child maximum key exceeds separator key\n" ++
                        "  child page:    {d}\n" ++
                        "  child max key: {s}\n" ++
                        "  separator key: {s}\n",
                    .{
                        page_id,
                        next_page_id,
                        child_result.max_key,
                        greatest_cell.key(),
                    },
                );
                return error.InvalidChild;
            }
        }
    }

    return .{
        .max_key = try allocator.dupe(u8, greatest_cell.key()),
    };
}

test "it finds keys in a leaf root node" {
    const io = std.testing.io;
    const allocator = test_allocator;
    const gpa = test_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "b.tree", .{ .read = true });

    var buf: [page_size]u8 align(@alignOf(PageHeader)) = undefined;
    var test_cell: [48]u8 = undefined;

    var root: PageBuffer = .new(&buf, 0);
    root.header().* = .empty(.leaf);
    for ("ABC") |fill| {
        @memset(&test_cell, fill);
        var cell: Cell = .raw(&test_cell);
        const key = try fmt.allocPrint(gpa, "K{c}", .{fill});
        defer gpa.free(key);
        cell.write_key_size(key.len);
        cell.write_val_size(test_cell.len - (@sizeOf(u64) * 2 + key.len));
        @memcpy(cell.key(), key);
        root.append_cell(&test_cell);
    }
    try file.writePositionalAll(io, &buf, 0);

    var tree: Tree = .load(allocator, io, file);
    defer tree.deinit();

    var result = try tree.find("KA");
    try std.testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("KB");
    try std.testing.expectEqualStrings("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("KC");
    try std.testing.expectEqualStrings("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("blah");
    tree.page_cache.put(result.page);
    try std.testing.expect(result.cell == null);
}

test {
    const io = std.testing.io;
    const allocator = test_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "b.tree", .{ .read = true });

    var storage: [page_size]u8 align(@alignOf(PageHeader)) = undefined;

    var root: PageBuffer = .new(&storage, 0);
    root.header().* = .empty(.leaf);
    try file.writePositionalAll(io, &storage, 0);

    var tree: Tree = .load(allocator, io, file);
    defer tree.deinit();

    try tree.insert("1", "one");
    try tree.insert("3", "three");
    try tree.insert("2", "two");

    var result = try tree.find("1");
    try std.testing.expectEqualStrings("one", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("2");
    try std.testing.expectEqualStrings("two", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("3");
    try std.testing.expectEqualStrings("three", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("5");
    try testing.expect(result.cell == null);
    tree.page_cache.put(result.page);

    try expectValidTree(&tree);
}

pub fn fillAlphanumericAndUnderscore(random: std.Random, slice: []u8) void {
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
    for (slice) |*b| b.* = charset[random.uintLessThan(usize, charset.len)];
}

test "insert random keys" {
    const io = std.testing.io;
    const allocator = test_allocator;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "b.tree", .{ .read = true });

    var tree: Tree = try .empty(allocator, io, file);
    defer tree.deinit();

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    var values: std.StringHashMap([]const u8) = .init(allocator);
    defer values.deinit();

    for (0..300) |_| {
        var key: [10]u8 = undefined;
        random.bytes(&key);
        //fillAlphanumericAndUnderscore(random, &key);
        try tree.insert(&key, "one");
        try values.put(try arena_allocator.dupe(u8, &key), try arena_allocator.dupe(u8, "one"));
        try expectValidTree(&tree);
    }

    // ensure keys were inserted in the tree
    var it = values.iterator();
    while (it.next()) |entry| {
        const res = try tree.find(entry.key_ptr.*);
        defer tree.page_cache.put(res.page);

        var cell = res.cell orelse return error.KeyMissing;
        try std.testing.expectEqualSlices(u8, entry.key_ptr.*, cell.key());
        try std.testing.expectEqualSlices(u8, entry.value_ptr.*, cell.val());
    }
}

//  fanout = 4
//                  [7]                         page = 0
//           ____/      \___
//          /               \
//      [3,     5]             [9]              page = 1 & 2
//     /    |    \          /       \
// [1, 2] [3, 4]  [5, 6]  [7, 8]    [9, 10]     page = 3, 4, 5, 6, 7
test "some tree" {
    const io = std.testing.io;
    const allocator = test_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "b.tree", .{ .read = true });

    var buf: [page_size]u8 align(@alignOf(PageHeader)) = undefined;
    var test_cell: [48]u8 = undefined;

    // root
    var temp_page_id: PageId = 1;
    var cell: Cell = .raw(&test_cell);
    cell.from_keyval("7", @ptrCast(&temp_page_id));
    var page: PageBuffer = .new(&buf, 0);
    page.header().* = .empty(.internal);
    page.header().right_pointer = 2;
    page.append_cell(&test_cell);
    try file.writePositionalAll(io, &buf, 0);

    // [3, 5]
    buf = undefined;
    page = .new(&buf, 1);
    page.header().* = .empty(.internal);
    page.header().right_pointer = 5;

    temp_page_id = 3;
    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("3", @ptrCast(&temp_page_id));
    page.append_cell(&test_cell);

    temp_page_id = 4;
    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("5", @ptrCast(&temp_page_id));
    page.append_cell(&test_cell);

    try file.writePositionalAll(io, &buf, 1 * page_size);

    // [9]
    buf = undefined;
    page = .new(&buf, 2);
    page.header().* = .empty(.internal);
    page.header().right_pointer = 7;

    temp_page_id = 6;
    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("9", @ptrCast(&temp_page_id));
    page.append_cell(&test_cell);
    try file.writePositionalAll(io, &buf, 2 * page_size);

    // [1, 2]
    buf = undefined;
    page = .new(&buf, 3);
    page.header().* = .empty(.leaf);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("1", "one");
    page.append_cell(&test_cell);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("2", "two");
    page.append_cell(&test_cell);

    try file.writePositionalAll(io, &buf, 3 * page_size);

    // [3, 4]
    buf = undefined;
    page = .new(&buf, 4);
    page.header().* = .empty(.leaf);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("3", "three");
    page.append_cell(&test_cell);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("4", "four");
    page.append_cell(&test_cell);

    try file.writePositionalAll(io, &buf, 4 * page_size);

    // [5, 6]
    buf = undefined;
    page = .new(&buf, 5);
    page.header().* = .empty(.leaf);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("5", "five");
    page.append_cell(&test_cell);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("6", "six");
    page.append_cell(&test_cell);

    try file.writePositionalAll(io, &buf, 5 * page_size);

    // [7, 8]
    buf = undefined;
    page = .new(&buf, 6);
    page.header().* = .empty(.leaf);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("7", "seven");
    page.append_cell(&test_cell);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("8", "eight");
    page.append_cell(&test_cell);

    try file.writePositionalAll(io, &buf, 6 * page_size);

    // [9, 10]
    buf = undefined;
    page = .new(&buf, 7);
    page.header().* = .empty(.leaf);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("9", "nine");
    page.append_cell(&test_cell);

    test_cell = undefined;
    cell = .raw(&test_cell);
    //cell.from_keyval("10", "ten");
    //page.append_cell(&test_cell);

    try file.writePositionalAll(io, &buf, 7 * page_size);

    var tree: Tree = .load(allocator, io, file);
    defer tree.deinit();

    try expectValidTree(&tree);

    var result = try tree.find("1");
    try std.testing.expectEqualStrings("one", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("2");
    try std.testing.expectEqualStrings("two", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("3");
    try std.testing.expectEqualStrings("three", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("4");
    try std.testing.expectEqualStrings("four", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("5");
    try std.testing.expectEqualStrings("five", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("6");
    try std.testing.expectEqualStrings("six", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("7");
    try std.testing.expectEqualStrings("seven", result.cell.?.val());
    tree.page_cache.put(result.page);

    result = try tree.find("8");
    try std.testing.expectEqualStrings("eight", result.cell.?.val());
    tree.page_cache.put(result.page);
    // fails because 10 is less than 9 lexically, i should use alphabet or stop at 9
    //try std.testing.expectEqualStrings("nine", (try tree.find("9", &storage)).?);
}
