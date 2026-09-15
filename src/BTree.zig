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

/// Errors that can occur while mutating the tree.
pub const Error = mem.Allocator.Error ||
    Io.File.ReadPositionalError ||
    Io.File.WritePositionalError ||
    error{IncompletePage};

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
) Error!void {
    const page = (try self.page_cache.get(parent_page_id)).?;
    var target_page = page;
    defer {
        if (target_page.page_id != page.page_id) {
            self.page_cache.put(target_page);
        }
        self.page_cache.put(page);
    }

    // calculate upper bound
    var upper_bound_idx: ?usize = null;
    var low: usize = 0;
    var high: usize = page.pointers().len;
    if (high == 0)
        upper_bound_idx = 0;
    while (low < high) {
        const mid = low + (high - low) / 2;
        var cell = page.cell(page.pointers()[mid]);
        switch (mem.order(u8, key, cell.key())) {
            .eq => @panic("unreachable - the parent cannot already have the key"),
            .lt => {
                high = mid;
                upper_bound_idx = mid;
            },
            .gt => low = mid + 1,
        }
    }

    var insert_idx = upper_bound_idx orelse page.pointers().len;
    std.debug.print("separator insert index: {d} @ page {d} @ {*}\n", .{ insert_idx, parent_page_id, page });

    const _value = old_page_id;
    const value: []const u8 = @ptrCast(&_value);

    const cell_size = key.len + value.len + @sizeOf(u64) * 2;
    const needed_size = cell_size + @sizeOf(CellOffset);
    if (page.header().freeSpace() < needed_size) {
        const split_result = try self.split_page(
            .{
                .page = page,
                .cell = null,
                .upper_bound_idx = upper_bound_idx,
                .path = path.*,
            },
            key,
        );
        target_page = split_result.target_page;
        insert_idx = split_result.insert_idx;
        path.* = split_result.path;
    }

    // shift pointers to right to insert new separator
    const old_len = target_page.header().number_of_cells;
    if (insert_idx < old_len) {
        @memmove(
            target_page.pointers().ptr[insert_idx + 1 .. old_len + 1],
            target_page.pointers()[insert_idx..old_len],
        );
    }
    target_page.header().number_of_cells += 1;
    target_page.header().upper -= cell_size;
    target_page.header().lower += @sizeOf(CellOffset);
    target_page.pointers()[insert_idx] = target_page.header().upper;
    var cell = target_page.cell(target_page.offset(insert_idx));
    cell.from_keyval(key, value);
    if (insert_idx + 1 == target_page.pointers().len) {
        std.debug.print("assigning right pointer\n", .{});
        target_page.header().right_pointer = new_page_id;
    } else {
        std.debug.print("updating pointer to the right\n", .{});
        const p: []const u8 = @ptrCast(&new_page_id);
        var after_cell = target_page.cell(target_page.offset(insert_idx + 1));
        @memcpy(after_cell.val(), p);
    }
    self.page_cache.mark_page_dirty(target_page);
}

/// Only split `page` into two pages, without promoting a key
/// and updating pointers.
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
pub fn __split_page(self: *Self, page: *PageBuffer, out_separator_key: []u8) !*PageBuffer {
    std.debug.print("splitting page {d}\n", .{page.page_id});
    const new_page_id = try self.page_cache.allocate();
    const new_page = try self.page_cache.get(new_page_id) orelse @panic("unreachable");
    new_page.header().* = .empty(page.header().type);
    new_page.header().right_pointer = page.header().right_pointer;
    const split_index = page.pointers().len / 2;
    // Internal: skip the separator; leaf: keep it in the new page.
    const fill_from_idx = if (page.header().type == .internal)
        split_index + 1
    else
        split_index;

    // if this is an internal page, then the separator key will not be kept,
    // and is only promoted. The caller needs a copy of the separator key before we discard it.
    if (page.header().type == .internal) {
        var cell = page.cell(page.pointers()[split_index]);
        @memcpy(out_separator_key[0..cell.key().len], cell.key());
        // the promoted cell's child becomes the left half's right pointer
        page.header().right_pointer = mem.readInt(u64, cell.val()[0..@sizeOf(u64)], .little);
    }

    // fill new page
    for (page.pointers()[fill_from_idx..], 0..) |offset, idx| {
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

const SplitPageResult = struct {
    /// The page to insert the new key after splitting
    target_page: *PageBuffer,
    insert_idx: usize,
    // hack alert, return the same path that was passed,
    // because i had to shallow copy it in insert_separator
    path: std.ArrayList(PageId),
};

/// Split `page` into two pages.
/// The existing `page` is the left half, and the returned page
/// is the right half.
///
/// `key` is what caused the split to occur, it's only needed in case `key` becomes the smallest key
/// in the new right have, and has to be promoted to the parent.
///
pub fn split_page(
    self: *Self,
    find_result: FindResult,
    key: []const u8,
) !SplitPageResult {
    var page: *PageBuffer = find_result.page;
    var path = find_result.path orelse @panic("path is tracked");
    var insert_idx = find_result.upper_bound_idx orelse page.pointers().len;
    var target_page: *PageBuffer = page;

    var separator_key_buf: [page_size]u8 = undefined;

    std.debug.assert(path.items.len != 0);
    std.debug.assert(path.items[path.items.len - 1] == page.page_id);

    const split_index = page.pointers().len / 2;
    const is_internal = page.header().type == .internal;
    // internal pages promote the middle cell, which __split_page copies out
    // before rewriting the page, so remember its length here.
    var separator_len: usize = 0;
    if (is_internal) {
        var mid_cell = page.cell(page.pointers()[split_index]);
        separator_len = mid_cell.key().len;
    }

    const new_page = try self.__split_page(page, &separator_key_buf);
    // after splitting the page, the separator will be promoted to the parent:
    // for internal pages it's the middle key that was removed from the page,
    // for leaves it's the smallest key of the new right half, unless the key
    // we're inserting becomes the smallest key in right half.
    const separator_key: []const u8 = if (is_internal)
        separator_key_buf[0..separator_len]
    else if (insert_idx == split_index)
        key
    else blk: {
        var cell = new_page.cell(new_page.pointers()[0]);
        break :blk cell.key();
    };

    // the right half starts one cell later for internal pages, because their
    // middle cell is promoted to the parent and not kept in new page.
    const right_half_start = if (is_internal) split_index + 1 else split_index;
    if (insert_idx >= right_half_start) {
        target_page = new_page;
        insert_idx -= right_half_start;
    }

    _ = path.pop(); // old leaf id
    const parent_id = parent_id: {
        if (path.items.len != 0) break :parent_id path.items[path.items.len - 1];
        const new_root_id = try self.page_cache.allocate();
        var new_root = (try self.page_cache.get(new_root_id)).?;
        defer self.page_cache.put(new_root);
        new_root.header().* = .empty(.internal);
        self.root_page_id = new_root.page_id;
        break :parent_id new_root_id;
    };
    try self.insert_separator(
        parent_id,
        page.page_id,
        new_page.page_id,
        separator_key,
        &path,
    );
    // release the new_page buffer because "key" will be inserted
    // in the left half (old page).
    if (target_page.page_id != new_page.page_id) {
        self.page_cache.put(new_page);
    }

    return .{
        .target_page = target_page,
        .insert_idx = insert_idx,
        .path = path,
    };
}

pub fn insert(
    self: *Self,
    key: []const u8,
    value: []const u8,
) !void {
    var find_result = try self._find(key, .{ .track_path = true });
    if (find_result.cell != null)
        return error.KeyAlreadyExists;
    var page: *PageBuffer = find_result.page;
    // target page is usually the page we found, unless the page had to be split,
    // in which case the target page might be the new (right half) page.
    var target_page: *PageBuffer = page;
    var insert_idx = find_result.upper_bound_idx orelse page.pointers().len;
    defer {
        if (target_page.page_id != page.page_id) {
            self.page_cache.put(target_page);
        }
        self.page_cache.put(page);
        find_result.path.?.deinit(self.allocator);
    }

    const cell_size = key.len + value.len + @sizeOf(u64) * 2;
    const needed_size = cell_size + @sizeOf(CellOffset);
    // split the page if it doesn't have enough free space. In the future,
    // we should support overflow pages, and decide when to compact a page.
    if (find_result.page.header().freeSpace() < needed_size) {
        const split_result = try self.split_page(find_result, key);
        target_page = split_result.target_page;
        insert_idx = split_result.insert_idx;
    }

    // shift pointers to right (starting from upper bound)
    const pointers = target_page.pointers();
    @memmove(
        pointers.ptr[insert_idx + 1 .. pointers.len + 1],
        pointers[insert_idx..],
    );

    target_page.header().number_of_cells += 1;
    target_page.header().upper -= cell_size;
    target_page.header().lower += @sizeOf(CellOffset);
    target_page.pointers()[insert_idx] = target_page.header().upper;
    var cell: Cell = .raw(target_page.inner[target_page.header().upper..].ptr);
    cell.from_keyval(key, value);
    self.page_cache.mark_page_dirty(target_page);
}

pub fn deinit(self: *Self) void {
    self.page_cache.deinit();
}
