const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const Io = std.Io;
const mem = std.mem;
const fmt = std.fmt;
const assert = std.debug.assert;

// hex for 'DATA'
pub const page_magic: u32 = 0x44415441;
pub const page_size: u32 = 1024 * 4; // 4kb for now
pub const max_record_size: u32 = page_size / 3;
// a pointer in the pointers directory in a slotted page
const CellOffset = u64;
const PageId = u64;

/// In-memory representation of a slotted page.
/// ------------------------------
/// |p| |p| |p| <- lower
///
///
///       free space
///
///                  upper->  | cell
///    | |      cell      | | cell |
/// -------------------------------
pub const PageHeader = extern struct {
    const Self = @This();
    pub const Type = enum(u32) { internal, leaf };

    magic: u32 align(@alignOf(CellOffset)),
    /// offset to first free slot in pointers
    lower: u64,
    /// offset to last slot in cells
    upper: u64,
    number_of_cells: u64,
    /// Available space in the page (total, including fragmented)
    free_bytes: usize,
    type: Type,
    right_pointer: PageId,

    pub fn empty(of_type: Type) Self {
        return .{ .magic = page_magic, .lower = @sizeOf(Self), .upper = page_size, .number_of_cells = 0, .free_bytes = 0, .type = of_type, .right_pointer = 0 };
    }

    /// free space in the page for pointers and cells
    pub fn freeSpace(self: *Self) usize {
        return self.upper - self.lower;
    }
};

/// A hashmap based page cache.
///
/// Just like the rest of the code, this is not thread-safe, yet.
pub const PageCache = struct {
    pub const Self = @This();
    cache: std.AutoHashMap(PageId, *PageBuffer),
    // TODO: use a different allocator for the hashmap and the page buffer?
    allocator: mem.Allocator,
    file: Io.File,
    io: Io,
    // TODO: this is temporary. we should track free blocks some other way.
    free_page_id: PageId = 0,

    pub fn new(allocator: mem.Allocator, file: Io.File, io: Io) Self {
        return .{
            .allocator = allocator,
            .cache = .init(allocator),
            .file = file,
            .io = io,
        };
    }

    fn load_page(self: *Self, id: PageId) !*PageBuffer {
        // TODO: should page buf be a fixed array inside PageBuffer?
        //       it would allow us to do a single allocation.
        const page_buf = try self.allocator.alloc(u8, page_size);
        const page = try self.allocator.create(PageBuffer);
        errdefer {
            self.allocator.free(page_buf);
            self.allocator.destroy(page);
        }

        const read_len = try self.file.readPositionalAll(self.io, page_buf, id * page_size);
        if (read_len != page_buf.len) {
            return error.IncompletePage;
        }

        page.* = .new(page_buf, id);
        return page;
    }

    pub fn mark_page_dirty(self: *Self, id: PageId) !void {
        var page: *PageBuffer = self.cache.get(id) orelse return error.PageNotFound;
        page.is_dirty = true;
    }

    inline fn writeback_page(self: *Self, page: *PageBuffer) void {
        self.file.writePositionalAll(self.io, page.inner, page.page_id * page_size) catch {
            @panic("writeback failed");
        };
        page.is_dirty = false;
    }

    /// TODO: i'm not sure if this is the right API and if it belongs in PageCache
    /// TODO: why even accept a page id? shouldn't we track the next free page id and return it?
    pub fn allocate(self: *Self) !PageId {
        const id = self.free_page_id;
        self.free_page_id += 1;
        errdefer self.free_page_id -= 1;

        const page_buf: [page_size]u8 = undefined;
        _ = try self.file.writePositionalAll(self.io, &page_buf, id * page_size);
        // TOOD: should allocating also cache the page?
        return id;
    }

    /// Get a page buffer.
    ///
    /// # Example
    ///
    /// ```zig
    /// const result = try page_cache.get(page_id);
    /// const page = result orelse return null;
    /// defer page_cache.put(page);
    /// // modify the page
    /// ```
    pub fn get(self: *Self, id: PageId) !?*PageBuffer {
        const result = try self.cache.getOrPut(id);
        if (!result.found_existing) {
            errdefer _ = self.cache.remove(id);
            result.value_ptr.* = try self.load_page(id);
        }
        _ = result.value_ptr.*.refcnt.fetchAdd(1, .monotonic);

        return result.value_ptr.*;
    }

    pub fn put(self: *Self, page: *PageBuffer) void {
        const old_refcnt = page.refcnt.fetchSub(1, .monotonic);
        if (old_refcnt == 1) {
            self.writeback_page(page);
            self.allocator.free(page.inner);
            self.allocator.destroy(page);
        }
    }

    /// This will writeback all dirty pages, and free *all* page buffers.
    pub fn deinit(self: *Self) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.put(entry.value_ptr.*);
        }
        self.cache.deinit();
    }
};

test PageCache {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "file", .{ .read = true });

    var cache: PageCache = .new(allocator, file, io);
    defer cache.deinit();
    assert(cache.get(0) == error.IncompletePage);
}

/// A wrapper around the page bytes
pub const PageBuffer = struct {
    const Self = @This();
    inner: []u8,
    // This should not be accessed directly, only by the page cache.
    // Initial value is *1* because it's referenced by the page cache.
    refcnt: std.atomic.Value(usize) = .init(1),
    // Whether the page has been modified and is out of sync with disk.
    is_dirty: bool = false,
    page_id: PageId,

    pub fn new(buffer: []u8, id: PageId) Self {
        assert(buffer.len == page_size);

        return .{
            .inner = buffer,
            .page_id = id,
        };
    }

    pub fn header(self: *Self) *PageHeader {
        return @ptrCast(@alignCast(self.inner.ptr));
    }

    pub fn pointers(self: *Self) []CellOffset {
        const end = @sizeOf(CellOffset) * self.header().number_of_cells;
        //std.debug.print("end {d}; cells {d} \n", .{ end, self.header().number_of_cells });
        const raw: []u8 = self
            .inner[@sizeOf(PageHeader)..][0..end];
        const __ptrs: [*]CellOffset = @ptrCast(@alignCast(raw.ptr));
        return __ptrs[0..self.header().number_of_cells];
    }

    /// Get the nth offset (0-based).
    pub fn offset(self: *Self, n: usize) CellOffset {
        if (n > self.header().number_of_cells - 1) {
            @panic("no cell");
        }
        return self.pointers()[n];
    }

    pub fn cell(self: *Self, off: CellOffset) Cell {
        return .load(self.inner[off..].ptr);
    }

    /// Append a cell to the page.
    /// This will take care of updating the page metadata.
    pub fn append_cell(self: *Self, record: []u8) void {
        comptime if (!builtin.is_test) {
            @compileError("test-only function");
        };
        var head = self.header();
        const ptr_idx = head.number_of_cells;
        head.number_of_cells += 1;
        head.upper -= record.len;
        head.lower += @sizeOf(CellOffset);
        self.pointers()[ptr_idx] = head.upper;
        @memcpy(self.inner[head.upper .. head.upper + record.len], record);
    }
};

/// -----------------------------------
/// | key_size | val_size | key | val |
/// -----------------------------------
pub const Cell = struct {
    const Self = @This();
    inner: [*]u8,

    /// Load an existing initialized cell.
    ///
    /// Use this when reading a cell that's already written, while traversing
    /// the tree for example.
    pub fn load(buf: [*]u8) Self {
        return .{
            .inner = buf,
        };
    }

    /// Wrap an uninitialized buffer (that will be populated as a new cell).
    ///
    /// Use this when inserting a new cell after allocating space for it.
    pub fn raw(buf: [*]u8) Self {
        return .{
            .inner = buf,
        };
    }

    pub fn key_size(self: *Self) u64 {
        return mem.readInt(u64, self.inner[0..@sizeOf(u64)], .little);
    }

    pub fn val_size(self: *Self) u64 {
        return mem.readInt(u64, self.inner[@sizeOf(u64)..][0..@sizeOf(u64)], .little);
    }

    pub fn key(self: *Self) []u8 {
        return self.inner[@sizeOf(u64) * 2 ..][0..self.key_size()];
    }

    pub fn val(self: *Self) []u8 {
        return self.inner[@sizeOf(u64) * 2 + self.key_size() ..][0..self.val_size()];
    }

    /// The *entire* cell length.
    pub fn len(self: *Self) usize {
        std.debug.print("key size = {d}\n", .{self.key_size()});
        return self.key_size() + self.val_size() + @sizeOf(u64) * 2;
    }

    pub fn as_slice(self: *Self) []u8 {
        return self.inner[0..self.len()];
    }

    pub fn write_key_size(self: *Self, size: u64) void {
        mem.writeInt(u64, self.inner[0..@sizeOf(u64)], size, .little);
    }

    pub fn write_val_size(self: *Self, size: u64) void {
        mem.writeInt(u64, self.inner[@sizeOf(u64)..][0..@sizeOf(u64)], size, .little);
    }

    pub fn from_keyval(self: *Self, _key: []const u8, value: []const u8) void {
        self.write_key_size(_key.len);
        self.write_val_size(value.len);
        @memcpy(self.key(), _key);
        @memcpy(self.val(), value);
    }
};

/// The result returned by a btree lookup.
/// Lookup will stop when a leaf node is found and optionally the key is found.
pub const FindResult = struct {
    cell: ?Cell,
    page: *PageBuffer,
    /// Index of the pointer that points to key upper bound in page.
    /// If null, then the key is the greatest in the page.
    upper_bound_idx: ?usize,
};

pub const Tree = struct {
    const Self = @This();
    io: Io,
    file: Io.File,
    root_page_id: u64 = 0,
    page_cache: PageCache,

    /// initialize a new tree, `file` is expected to be empty.
    pub fn empty(allocator: mem.Allocator, io: Io, file: Io.File) !Self {
        var tree: Self = .load(allocator, io, file);
        const root_id = try tree.page_cache.allocate();
        tree.root_page_id = root_id;

        var root_page = (try tree.page_cache.get(root_id)).?;
        defer tree.page_cache.put(root_page);

        root_page.header().* = .empty(.leaf);
        try tree.page_cache.mark_page_dirty(root_id);

        return tree;
    }

    pub fn load(allocator: mem.Allocator, io: Io, file: Io.File) Self {
        return .{
            .io = io,
            .file = file,
            .page_cache = .new(allocator, file, io),
        };
    }

    pub fn find(self: *Self, key: []const u8) !FindResult {
        var page_id: u64 = self.root_page_id;

        var page: *PageBuffer = undefined;
        var header: *PageHeader = undefined;
        var upper_bound_idx: ?usize = null;
        nodes_loop: while (true) {
            page = (try self.page_cache.get(page_id)).?;
            defer self.page_cache.put(page);

            header = page.header();
            upper_bound_idx = null;

            var low: usize = 0;
            var high: usize = page.pointers().len;
            if (high == 0) {
                // reached empty node.
                std.debug.print("empty node!!\n", .{});
                break :nodes_loop;
            }
            while (low < high) {
                const mid = low + (high - low) / 2;
                const midOffset: CellOffset = page.pointers()[mid];
                var cell: Cell = page.cell(midOffset);
                std.debug.print("mid = {d}\n", .{mid});
                std.debug.print("offset = 0x{x}\n", .{midOffset});
                std.debug.print("cell val = {s}\n", .{cell.val()});
                switch (mem.order(u8, key, cell.key())) {
                    .eq => {
                        switch (header.type) {
                            .internal => {
                                if (mid + 1 >= page.pointers().len) {
                                    page_id = page.header().right_pointer;
                                    std.debug.print("going rigt! {s}\n", .{key});
                                    continue :nodes_loop;
                                }
                                const offset = page.pointers()[mid + 1];
                                cell = page.cell(offset);
                                page_id = mem.readInt(u64, @ptrCast(cell.val()), .little);
                                // exact match found at internal node
                                // next pointer is the upper bound.
                                continue :nodes_loop;
                            },
                            .leaf => {
                                std.debug.print("equal! {s}\n", .{key});
                                return .{
                                    .cell = cell,
                                    .page = page,
                                    .upper_bound_idx = upper_bound_idx,
                                };
                            },
                        }
                    },
                    .lt => {
                        high = mid;
                        upper_bound_idx = mid;
                    },
                    .gt => low = mid + 1,
                }
            }

            // loop ended, either:
            // 1. key is greater than all keys -> use right pointer
            // 2. upper bound found
            // 3. we reached a leaf -> key doesn't exist
            if (header.type == .leaf) {
                break :nodes_loop;
            }
            if (upper_bound_idx) |idx| {
                const offset = page.pointers()[idx];
                var cell = page.cell(offset);
                page_id = mem.readInt(u64, @ptrCast(cell.val()), .little);
            } else {
                page_id = page.header().right_pointer;
            }
        }

        return .{
            .cell = null,
            .page = page,
            .upper_bound_idx = upper_bound_idx,
        };
    }

    pub fn insert(
        self: *Self,
        key: []const u8,
        value: []const u8,
    ) !void {
        var find_result = try self.find(key);
        var page: *PageBuffer = find_result.page;
        if (find_result.cell != null)
            return error.KeyAlreadyExists;

        // now, figure out where to insert
        const expected_size = key.len + value.len + @sizeOf(u64) * 2;
        if (find_result.page.header().freeSpace() < expected_size + @sizeOf(CellOffset)) {
            @panic("split unimplemented");
        }
        const insert_idx = find_result.upper_bound_idx orelse page.pointers().len;
        if (find_result.upper_bound_idx) |idx| {
            // shift pointers to right (starting from upper bound)
            @memmove(page.pointers().ptr[0 .. page.pointers().len + 1][idx + 1 ..], page.pointers()[idx..]);
        }
        page.header().number_of_cells += 1;
        page.header().upper -= expected_size;
        page.header().lower += @sizeOf(CellOffset);
        page.pointers()[insert_idx] = page.header().upper;
        var cell: Cell = .raw(page.inner[page.header().upper..].ptr);
        cell.from_keyval(key, value);
        try self.page_cache.mark_page_dirty(page.page_id);
    }

    pub fn deinit(self: *Self) void {
        self.page_cache.deinit();
    }
};

const validPageResult = struct {
    max_key: []u8,
};

/// Validate a b+tree and check its invariants.
pub fn expectValidTree(tree: *Tree) !void {
    if (!builtin.is_test) @compileError("expectValidTree is only allowed in testing");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
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
                        prev_cell.key(),
                        current_cell.key(),
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
    const allocator = std.testing.allocator;
    const gpa = std.testing.allocator;
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
    result = try tree.find("KB");
    try std.testing.expectEqualStrings("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", result.cell.?.val());
    result = try tree.find("KC");
    try std.testing.expectEqualStrings("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", result.cell.?.val());
    result = try tree.find("blah");
    try std.testing.expect(result.cell == null);
}

test {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
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
    result = try tree.find("2");
    try std.testing.expectEqualStrings("two", result.cell.?.val());
    result = try tree.find("3");
    try std.testing.expectEqualStrings("three", result.cell.?.val());

    try expectValidTree(&tree);
}

test "insert random keys" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "b.tree", .{ .read = true });

    var tree: Tree = try .empty(allocator, io, file);
    defer tree.deinit();

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    for (0..100) |_| {
        var key: [10]u8 = undefined;
        random.bytes(&key);
        try tree.insert(&key, "one");
    }

    try expectValidTree(&tree);
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
    const allocator = std.testing.allocator;
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
    result = try tree.find("2");
    try std.testing.expectEqualStrings("two", result.cell.?.val());
    result = try tree.find("3");
    try std.testing.expectEqualStrings("three", result.cell.?.val());
    result = try tree.find("4");
    try std.testing.expectEqualStrings("four", result.cell.?.val());
    result = try tree.find("5");
    try std.testing.expectEqualStrings("five", result.cell.?.val());
    result = try tree.find("6");
    try std.testing.expectEqualStrings("six", result.cell.?.val());
    result = try tree.find("7");
    try std.testing.expectEqualStrings("seven", result.cell.?.val());
    result = try tree.find("8");
    try std.testing.expectEqualStrings("eight", result.cell.?.val());
    // fails because 10 is less than 9 lexically, i should use alphabet or stop at 9
    //try std.testing.expectEqualStrings("nine", (try tree.find("9", &storage)).?);
}
