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

/// A wrapper around the page bytes
pub const PageBuffer = struct {
    const Self = @This();
    inner: []u8,

    pub fn new(buffer: []u8) Self {
        assert(buffer.len == page_size);

        return .{
            .inner = buffer,
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

pub const Tree = struct {
    const Self = @This();
    io: Io,
    file: Io.File,
    root_page_id: u64 = 0,

    /// initialize a new tree, `file` is expected to be empty.
    pub fn empty(io: Io, file: Io.File) !Self {
        var root_node: [page_size]u8 align(@alignOf(PageHeader)) = mem.zeroes([page_size]u8);
        const header: *PageHeader = @ptrCast(&root_node);
        header.* = .empty(.internal);
        try file.writePositionalAll(io, &root_node, 0);
        return .{
            .io = io,
            .file = file,
        };
    }

    pub fn load(io: Io, file: Io.File) Self {
        return .{
            .io = io,
            .file = file,
        };
    }

    pub fn find(self: *Self, key: []const u8, page_buf: *[page_size]u8) !?[]u8 {
        var page_id: u64 = self.root_page_id;

        var page: PageBuffer = undefined;
        var header: *PageHeader = undefined;
        nodes_loop: while (true) {
            const page_offset = page_id * page_size;
            //var page_buf: [page_size]u8 align(@alignOf(PageHeader)) = undefined;
            const read_len = try self.file.readPositionalAll(self.io, page_buf, page_offset);
            if (read_len != page_buf.len) {
                @panic("database is corrupted");
            }

            page = .new(page_buf);
            header = page.header();

            var low: usize = 0;
            var high: usize = page.pointers().len;
            var upper_bound_idx: ?usize = null;
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
                                return cell.val();
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

        return null;

        //const raw_record_size = key.len + value.len + (@sizeOf(u64) * 2);
        //const needed_space = @sizeOf(CellOffset) + raw_record_size;
        //if (header.freeSpace() == 0) {
        //    // split page
        //} else {
        //    // there is enough space
        //    if (needed_space > max_record_size or header.freeSpace() < needed_space) {
        //        // extend node size (use an off page)
        //    } else {
        //        // insert
        //        const _pointers: [*]CellOffset = @ptrCast(&page_buf[@sizeOf(PageHeader)]);
        //        const pointers: []CellOffset = _pointers[0..header.number_of_cells];

        //        const new_upper = header.upper - raw_record_size;
        //        header.upper = new_upper;
        //        header.number_of_cells += 1;
        //        if (pointers.len == 0) {
        //            const coffset: *CellOffset = @ptrCast(@alignCast(&page_buf[header.lower]));
        //            coffset.* = new_upper;
        //            header.lower += @sizeOf(CellOffset);
        //            try self.file.writePositionalAll(self.io, &page_buf, page_offset);
        //        } else {
        //            @panic("w0t");
        //        }
        //        // binary search
        //    }
        //}
    }
};

// insert
// delete
// update
// find
//test {
//    const io = std.testing.io;
//    Io.Dir.cwd().deleteFile(io, "./test.tree") catch {};
//    const file = try Io.Dir.cwd().createFile(io, "./test.tree", .{ .read = true });
//
//    var tree: Tree = try .empty(io, file);
//    try tree.find("xyz", "abc");
//    //try tree.insert("hello", "abc2");
//}

test "it finds keys in a leaf root node" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    Io.Dir.cwd().deleteFile(io, "./test2.tree") catch {};
    const file = try Io.Dir.cwd().createFile(io, "./test2.tree", .{ .read = true });

    var buf: [page_size]u8 align(@alignOf(PageHeader)) = undefined;
    var test_cell: [48]u8 = undefined;

    var root: PageBuffer = .new(&buf);
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

    var storage: [page_size]u8 align(@alignOf(PageHeader)) = undefined;
    var tree: Tree = .load(io, file);
    try std.testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", (try tree.find("KA", &storage)).?);
    try std.testing.expectEqualStrings("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", (try tree.find("KB", &storage)).?);
    try std.testing.expectEqualStrings("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", (try tree.find("KC", &storage)).?);
    try std.testing.expect(try tree.find("blah", &storage) == null);
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
    const gpa = std.testing.allocator;
    _ = gpa;
    Io.Dir.cwd().deleteFile(io, "./test3.tree") catch {};
    const file = try Io.Dir.cwd().createFile(io, "./test3.tree", .{ .read = true });

    var buf: [page_size]u8 align(@alignOf(PageHeader)) = undefined;
    var test_cell: [48]u8 = undefined;

    // root
    var temp_page_id: PageId = 1;
    var cell: Cell = .raw(&test_cell);
    cell.from_keyval("7", @ptrCast(&temp_page_id));
    var page: PageBuffer = .new(&buf);
    page.header().* = .empty(.internal);
    page.header().right_pointer = 2;
    page.append_cell(&test_cell);
    try file.writePositionalAll(io, &buf, 0);

    // [3, 5]
    buf = undefined;
    page = .new(&buf);
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
    page = .new(&buf);
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
    page = .new(&buf);
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
    page = .new(&buf);
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
    page = .new(&buf);
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
    page = .new(&buf);
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
    page = .new(&buf);
    page.header().* = .empty(.leaf);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("9", "nine");
    page.append_cell(&test_cell);

    test_cell = undefined;
    cell = .raw(&test_cell);
    cell.from_keyval("10", "ten");
    page.append_cell(&test_cell);

    try file.writePositionalAll(io, &buf, 7 * page_size);

    var storage: [page_size]u8 align(@alignOf(PageHeader)) = undefined;
    var tree: Tree = .load(io, file);

    try std.testing.expectEqualStrings("one", (try tree.find("1", &storage)).?);
    try std.testing.expectEqualStrings("two", (try tree.find("2", &storage)).?);
    try std.testing.expectEqualStrings("three", (try tree.find("3", &storage)).?);
    try std.testing.expectEqualStrings("four", (try tree.find("4", &storage)).?);
    try std.testing.expectEqualStrings("five", (try tree.find("5", &storage)).?);
    try std.testing.expectEqualStrings("six", (try tree.find("6", &storage)).?);
    try std.testing.expectEqualStrings("seven", (try tree.find("7", &storage)).?);
    try std.testing.expectEqualStrings("eight", (try tree.find("8", &storage)).?);
    // fails because 10 is less than 9 lexically, i should use alphabit or stop at 9
    //try std.testing.expectEqualStrings("nine", (try tree.find("9", &storage)).?);
}
