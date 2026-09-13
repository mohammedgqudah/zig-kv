const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const config = @import("config");
const PageCache = @import("PageCache.zig");

const Io = std.Io;
const mem = std.mem;
const fmt = std.fmt;
const assert = std.debug.assert;

// hex for 'DATA'
pub const page_magic: u32 = 0x44415441;
pub const page_size: u32 = 1024 * 4; // 4kb for now
pub const max_record_size: u32 = page_size / 3;
// a pointer in the pointers directory in a slotted page
pub const CellOffset = u64;
pub const PageId = u64;

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

/// Raw bytes for a page.
pub const PageBytes = []align(@alignOf(PageHeader)) u8;

/// A wrapper around the page bytes
pub const PageBuffer = struct {
    const Self = @This();
    inner: PageBytes,
    // This should not be accessed directly, only by the page cache.
    // Initial value is *1* because it's referenced by the page cache.
    refcnt: std.atomic.Value(usize) = .init(1),
    // Whether the page has been modified and is out of sync with disk.
    is_dirty: bool = false,
    page_id: PageId,

    pub fn new(buffer: PageBytes, id: PageId) Self {
        assert(buffer.len == page_size);

        return .{
            .inner = buffer,
            .page_id = id,
        };
    }

    pub inline fn header(self: *Self) *PageHeader {
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

    pub fn format(
        self: *Self,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "PageBuffer{{ page={}, ref_count={}, dirty={} }} @ {*}\n",
            .{
                self.page_id,
                self.refcnt.load(.monotonic),
                self.is_dirty,
                self,
            },
        );
        try writer.print("   inner @ {*}\n", .{self.inner.ptr});
    }
};

