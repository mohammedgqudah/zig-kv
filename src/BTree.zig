const std = @import("std");

const pagemod = @import("page.zig");
const PageCache = @import("PageCache.zig");
const Cell = pagemod.Cell;
const CellOffset = pagemod.CellOffset;
const PageBuffer = pagemod.PageBuffer;
const PageHeader = pagemod.PageHeader;
const PageId = pagemod.PageId;
const page_size = pagemod.page_size;
const Io = std.Io;
const mem = std.mem;

/// A B+tree
const Self = @This();

/// The result returned by a btree lookup.
/// Lookup will stop when a leaf node is found and optionally the key is found.
pub const FindResult = struct {
    /// The lifetime of the cell is tied to the page buffer
    cell: ?Cell,
    page: *PageBuffer,
    /// Index of the pointer that points to key upper bound in page.
    /// If null, then the key is the greatest in the page.
    upper_bound_idx: ?usize,
    /// If "track_path" was set. The caller owns this allocation
    path: ?std.ArrayList(PageId) = null,
};

pub const FindOptions = struct {
    /// Track pages while traversing the tree
    track_path: bool,
};

io: Io,
file: Io.File,
root_page_id: u64 = 0,
page_cache: PageCache,
allocator: mem.Allocator,

/// initialize a new tree, `file` is expected to be empty.
pub fn empty(allocator: mem.Allocator, io: Io, file: Io.File) !Self {
    var tree: Self = .load(allocator, io, file);
    const root_id = try tree.page_cache.allocate();
    tree.root_page_id = root_id;

    var root_page = (try tree.page_cache.get(root_id)).?;
    defer tree.page_cache.put(root_page);

    root_page.header().* = .empty(.leaf);
    tree.page_cache.mark_page_dirty(root_page);

    return tree;
}

pub fn load(allocator: mem.Allocator, io: Io, file: Io.File) Self {
    return .{
        .io = io,
        .file = file,
        .page_cache = .new(allocator, file, io),
        .allocator = allocator,
    };
}

fn _find(self: *Self, key: []const u8, options: FindOptions) !FindResult {
    var path: ?std.ArrayList(PageId) = if (options.track_path)
        .empty
    else
        null;

    var page_id: u64 = self.root_page_id;

    while (true) {
        if (options.track_path)
            try path.?.append(self.allocator, page_id);

        var next_page_id: ?PageId = null;
        const page = (try self.page_cache.get(page_id)).?;
        const header = page.header();
        var upper_bound_idx: ?usize = null;
        var low: usize = 0;
        var high: usize = page.pointers().len;

        if (high == 0)
            return .{ .cell = null, .page = page, .upper_bound_idx = null, .path = path };

        while (low < high) {
            const mid = low + (high - low) / 2;
            const midOffset: CellOffset = page.pointers()[mid];
            var cell: Cell = page.cell(midOffset);
            switch (mem.order(u8, key, cell.key())) {
                .eq => {
                    switch (header.type) {
                        .internal => {
                            if (mid + 1 >= page.pointers().len) {
                                next_page_id = page.header().right_pointer;
                            } else {
                                const offset = page.pointers()[mid + 1];
                                cell = page.cell(offset);
                                next_page_id = mem.readInt(u64, @ptrCast(cell.val()), .little);
                            }
                            break;
                        },
                        .leaf => {
                            return .{ .cell = cell, .page = page, .upper_bound_idx = upper_bound_idx, .path = path };
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

        // we reached the bottom of the tree and there are no more pointers to follow
        if (page.header().type == .leaf) {
            return .{
                .cell = null,
                .page = page,
                .upper_bound_idx = upper_bound_idx,
                .path = path,
            };
        }

        if (next_page_id) |id| {
            page_id = id;
        } else if (upper_bound_idx) |idx| {
            const offset = page.pointers()[idx];
            var cell = page.cell(offset);
            page_id = mem.readInt(u64, @ptrCast(cell.val()), .little);
        } else {
            page_id = page.header().right_pointer;
        }
        self.page_cache.put(page);
    }
    @panic("unreachable");
}

pub fn find(self: *Self, key: []const u8) !FindResult {
    return self._find(key, .{
        .track_path = false,
    });
}

fn insert_separator(
    self: *Self,
    parent_page_id: PageId,
    old_page_id: PageId,
    new_page_id: PageId,
    key: []const u8,
    path: *std.ArrayList(PageId),
) !void {
    _ = path;

    const _value = old_page_id;
    const value: []const u8 = @ptrCast(&_value);
    const page = (try self.page_cache.get(parent_page_id)).?;
    defer self.page_cache.put(page);

    std.debug.print("available space in parent: {d}\n", .{page.header().freeSpace()});
    // now, figure out where to insert
    const expected_size = key.len + value.len + @sizeOf(u64) * 2;
    if (page.header().freeSpace() < expected_size + @sizeOf(CellOffset)) {
        @panic("propagting split not supported");
    }

    var upper_bound_idx: ?usize = null;
    var low: usize = 0;
    var high: usize = page.pointers().len;
    if (high == 0)
        upper_bound_idx = 0;

    while (low < high) {
        const mid = low + (high - low) / 2;
        const midOffset: CellOffset = page.pointers()[mid];
        var cell: Cell = page.cell(midOffset);
        switch (mem.order(u8, key, cell.key())) {
            .eq => {
                @panic("unreachable - parent already has the key");
            },
            .lt => {
                high = mid;
                upper_bound_idx = mid;
            },
            .gt => low = mid + 1,
        }
    }

    const insert_idx = upper_bound_idx orelse page.pointers().len;
    std.debug.print("separator insert index: {d} @ page {d} @ {*}\n", .{ insert_idx, parent_page_id, page });
    // shift pointers to right to inesrt new separator
    const old_len = page.header().number_of_cells;
    if (insert_idx < old_len) {
        @memmove(
            page.pointers().ptr[insert_idx + 1 .. old_len + 1],
            page.pointers()[insert_idx..old_len],
        );
    }
    page.header().number_of_cells += 1;
    page.header().upper -= expected_size;
    page.header().lower += @sizeOf(CellOffset);
    page.pointers()[insert_idx] = page.header().upper;
    //var cell: Cell = .raw(page.inner[page.header().upper..].ptr);
    var cell = page.cell(page.offset(insert_idx));
    cell.from_keyval(key, value);
    if (insert_idx + 1 == page.pointers().len) {
        std.debug.print("assigning right pointer\n", .{});
        page.header().right_pointer = new_page_id;
    } else {
        std.debug.print("updating pointer to the right\n", .{});
        const p: []const u8 = @ptrCast(&new_page_id);
        var after_cell = page.cell(page.offset(insert_idx + 1));
        @memcpy(after_cell.val(), p);
    }
    self.page_cache.mark_page_dirty(page);
}

/// Split `page` into two pages.
/// The existing `page` is the left half, and the returned page
/// is the right half.
///
/// The caller is responsible for updating the parent pointers.
///
/// left: [0..split_idx)
/// right: [split_idx..]
///
/// [1, 3, 4, 5, 6, 7]
///
/// left: [1, 3, 4]
/// right: [5, 6, 7]
pub fn split_page(self: *Self, page: *PageBuffer) !*PageBuffer {
    std.debug.print("splitting page {d}\n", .{page.page_id});
    const new_page_id = try self.page_cache.allocate();
    const new_page = try self.page_cache.get(new_page_id) orelse @panic("unreachable");
    new_page.header().* = .empty(page.header().type);
    const split_index = page.pointers().len / 2;
    // fill new page
    for (page.pointers()[split_index..], 0..) |offset, idx| {
        var old_cell = page.cell(offset);

        new_page.header().number_of_cells += 1;
        new_page.header().lower += @sizeOf(CellOffset);
        new_page.header().upper -= old_cell.len();
        new_page.pointers()[idx] = new_page.header().upper;

        var new_cell = new_page.cell(new_page.header().upper);
        new_cell.from_keyval(old_cell.key(), old_cell.val());
    }

    // rewrite the old page (left half) and shrink it.
    var scratch: [page_size]u8 = undefined;
    var new_upper: usize = page_size;
    for (page.pointers()[0..split_index], 0..) |offset, idx| {
        var cell = page.cell(offset);
        new_upper -= cell.len();
        @memcpy(scratch[new_upper..][0..cell.len()], cell.as_slice());
        page.pointers()[idx] = new_upper;
    }
    @memcpy(page.inner[new_upper..page_size], scratch[new_upper..page_size]);
    page.header().number_of_cells = split_index;
    page.header().lower = @sizeOf(PageHeader) + split_index * @sizeOf(CellOffset);
    page.header().upper = new_upper;

    return new_page;
}

pub fn insert(
    self: *Self,
    key: []const u8,
    value: []const u8,
) !void {
    var find_result = try self._find(key, .{ .track_path = true });
    var page: *PageBuffer = find_result.page;
    var target_page: *PageBuffer = page;
    defer {
        if (target_page.page_id != page.page_id) {
            self.page_cache.put(target_page);
        }
        self.page_cache.put(page);
        find_result.path.?.deinit(self.allocator);
    }

    if (find_result.cell != null)
        return error.KeyAlreadyExists;

    // TODO: page and index to insert in, could change if we split
    var insert_idx = find_result.upper_bound_idx orelse page.pointers().len;

    // now, figure out where to insert
    const expected_size = key.len + value.len + @sizeOf(u64) * 2;
    if (find_result.page.header().freeSpace() < expected_size + @sizeOf(CellOffset)) {
        var path = find_result.path orelse @panic("path is tracked");
        // TODO: same calculation is in split_page, keep in sync
        const split_index = page.pointers().len / 2;
        const new_page = try self.split_page(page);

        // after splitting the page, the smallest key in the right half should be
        // promopted to the parent as a separator. The smallest is either the new key we're inserting, or
        // the first key in the half.
        const separator_key = if (insert_idx == split_index) key else blk: {
            var first_cell = new_page.cell(new_page.pointers()[0]);
            break :blk first_cell.key();
        };
        if (insert_idx >= split_index) {
            target_page = new_page;
            insert_idx -= split_index;
        }
        _ = path.pop(); // old leaf id
        const parent_id = parent_id: {
            if (path.pop()) |id| break :parent_id id;
            const new_root_id = try self.page_cache.allocate();
            var new_root = (try self.page_cache.get(new_root_id)).?;
            defer self.page_cache.put(new_root); // <- why does leaking cause inconsisntecy
            new_root.header().* = .empty(.internal);
            std.debug.print("new root: {d}, space= {d}\n", .{
                new_root.page_id,
                new_root.header().freeSpace(),
            });
            self.root_page_id = new_root.page_id;
            break :parent_id new_root_id;
        };
        std.debug.print("parent _id={d}\n", .{parent_id});
        try self.insert_separator(
            parent_id,
            page.page_id,
            new_page.page_id,
            separator_key,
            &path,
        );
        // release the new page buffer is the new key will be inserted
        // in the left half (old page).
        if (target_page.page_id != new_page.page_id) {
            self.page_cache.put(new_page);
        }
    }

    // shift pointers to right (starting from upper bound)
    const pointers = target_page.pointers();
    @memmove(
        pointers.ptr[insert_idx + 1 .. pointers.len + 1],
        pointers[insert_idx..],
    );

    target_page.header().number_of_cells += 1;
    target_page.header().upper -= expected_size;
    target_page.header().lower += @sizeOf(CellOffset);
    target_page.pointers()[insert_idx] = target_page.header().upper;
    var cell: Cell = .raw(target_page.inner[target_page.header().upper..].ptr);
    cell.from_keyval(key, value);
    self.page_cache.mark_page_dirty(target_page);
}

pub fn deinit(self: *Self) void {
    self.page_cache.deinit();
}
