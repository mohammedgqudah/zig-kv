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

/// Index of the first pointer whose key is greater than `key`.
///
/// If `key` is greater than all keys, then pointers.len is returned.
fn upperBound(page: *PageBuffer, key: []const u8) usize {
    var low: usize = 0;
    var high: usize = page.pointers().len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        var cell = page.cell(page.pointers()[mid]);
        if (mem.order(u8, key, cell.key()) == .lt) {
            high = mid;
        } else {
            low = mid + 1;
        }
    }
    return low;
}

const Path = std.ArrayList(PageId);

/// Return the child (page_id) a cell is pointing to.
fn childAt(page: *PageBuffer, index: usize) PageId {
    std.debug.assert(page.header().type == .internal);
    if (index == page.pointers().len) return page.header().right_pointer;
    var cell = page.cell(page.pointers()[index]);
    return mem.readInt(PageId, @ptrCast(cell.val()), .little);
}

/// Descend the tree until a leaf that might hold `key` is found.
fn descend(self: *Self, key: []const u8, path: ?*Path) Error!*PageBuffer {
    var page_id = self.root_page_id;
    while (true) {
        const page = (try self.page_cache.get(page_id)).?;

        if (path) |p| try p.append(self.allocator, page_id);
        if (page.header().type == .leaf) return page;
        page_id = childAt(page, upperBound(page, key));
        self.page_cache.put(page);
    }
}

fn lookupCell(leaf: *PageBuffer, key: []const u8, upper_bound_idx: usize) ?Cell {
    if (upper_bound_idx == 0) return null;
    var cell = leaf.cell(leaf.pointers()[upper_bound_idx - 1]);
    return if (mem.eql(u8, key, cell.key())) cell else null;
}

pub fn find(self: *Self, key: []const u8) !FindResult {
    const leaf = try self.descend(key, null);
    const upper_bound = upperBound(leaf, key);
    const cell = lookupCell(leaf, key, upper_bound);

    return .{
        .cell = cell,
        .page = leaf,
    };
}

fn insert_separator(
    self: *Self,
    parent_page_id: PageId,
    old_page_id: PageId,
    new_page_id: PageId,
    key: []const u8,
    path: *std.ArrayList(PageId),
) Error!void {
    const _value = old_page_id;
    const value: []const u8 = @ptrCast(&_value);
    const page = (try self.page_cache.get(parent_page_id)).?;
    var target = page;
    defer {
        if (target.page_id != page.page_id)
            self.page_cache.put(target);
        self.page_cache.put(page);
    }

    var insert_idx = upperBound(page, key);

    if (hasRoom(page, key, value)) {
        writeCell(target, insert_idx, key, value);
    } else {
        const result = try self.split_page(page, path, insert_idx, key);
        target = result.target_page;
        insert_idx = result.insert_idx;
        writeCell(target, insert_idx, key, value);
    }

    if (insert_idx + 1 == target.pointers().len) {
        target.header().right_pointer = new_page_id;
    } else {
        var after_cell = target.cell(target.offset(insert_idx + 1));
        mem.writeInt(PageId, @ptrCast(after_cell.val()), new_page_id, .little);
    }
    self.page_cache.mark_page_dirty(target);
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
    page: *PageBuffer,
    path: *Path,
    upper_bound: usize,
    key: []const u8,
) !SplitPageResult {
    var insert_idx = upper_bound;
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
        path,
    );
    // release the new_page buffer because "key" will be inserted
    // in the left half (old page).
    if (target_page.page_id != new_page.page_id) {
        self.page_cache.put(new_page);
    }

    return .{
        .target_page = target_page,
        .insert_idx = insert_idx,
    };
}

inline fn cellSize(key: []const u8, value: []const u8) usize {
    return key.len + value.len + @sizeOf(u64) * 2;
}

/// Shift pointers to the right, and then write a cell at `idx`.
fn writeCell(page: *PageBuffer, idx: usize, key: []const u8, value: []const u8) void {
    const pointers = page.pointers();
    if (idx < pointers.len)
        @memmove(pointers.ptr[idx + 1 .. pointers.len + 1], pointers[idx..]);

    page.header().number_of_cells += 1;
    page.header().lower += @sizeOf(CellOffset);
    page.header().upper -= cellSize(key, value);
    page.pointers()[idx] = page.header().upper;

    var cell = page.cell(page.header().upper);
    cell.from_keyval(key, value);
}

/// Check if the page has room to insert a cell and its pointer (offset)
fn hasRoom(page: *PageBuffer, key: []const u8, value: []const u8) bool {
    const needed_size = cellSize(key, value) + @sizeOf(CellOffset);
    return page.header().freeSpace() >= needed_size;
}

pub fn insert(
    self: *Self,
    key: []const u8,
    value: []const u8,
) !void {
    var path: Path = .empty;
    const page = try self.descend(key, &path);
    var target = page;
    defer {
        if (target.page_id != page.page_id) self.page_cache.put(target);
        self.page_cache.put(page);
        path.deinit(self.allocator);
    }

    var insert_idx = upperBound(page, key);
    if (lookupCell(page, key, insert_idx) != null) return error.KeyAlreadyExists;

    if (hasRoom(page, key, value)) {
        writeCell(target, insert_idx, key, value);
    } else {
        const result = try self.split_page(page, &path, insert_idx, key);
        target = result.target_page;
        insert_idx = result.insert_idx;
        writeCell(target, insert_idx, key, value);
    }

    self.page_cache.mark_page_dirty(target);
}

pub fn deinit(self: *Self) void {
    self.page_cache.deinit();
}
