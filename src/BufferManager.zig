const std = @import("std");
const config = @import("config");
const pagemod = @import("page.zig");

const Io = std.Io;
const mem = std.mem;
const PageId = pagemod.PageId;
const PageFrame = pagemod.PageFrame;
const PageHeader = pagemod.PageHeader;
const page_size = pagemod.page_size;

/// A hashmap based buffer manager.
///
/// Just like the rest of the code, this is not thread-safe, yet.
const Self = @This();

cache: std.AutoHashMap(PageId, *PageFrame),
allocator: mem.Allocator,
file: Io.File,
io: Io,
/// Starts at page `1` because the first page `0`
/// is a special page for the tree.
free_page_id: PageId = 1,

pub fn new(allocator: mem.Allocator, file: Io.File, io: Io) Self {
    return .{
        .allocator = allocator,
        .cache = .init(allocator),
        .file = file,
        .io = io,
    };
}

fn load_page(self: *Self, id: PageId) !*PageFrame {
    const page_buf = try self.allocator.alignedAlloc(
        u8,
        .of(PageHeader),
        page_size,
    );
    const page = try self.allocator.create(PageFrame);
    errdefer {
        self.allocator.free(page_buf);
        self.allocator.destroy(page);
    }

    const read_len = try self.file.readPositionalAll(self.io, page_buf, id * page_size);
    if (read_len != page_buf.len) {
        return error.IncompletePage;
    }

    page.* = .new(page_buf, id);
    //if (page.header().magic != pagemod.page_magic)
    //    return error.InvalidPageMagic;
    return page;
}

pub fn mark_page_dirty(self: *Self, page: *PageFrame) void {
    _ = self;
    page.is_dirty = true;
}

inline fn writeback_page(self: *Self, page: *PageFrame) void {
    self.file.writePositionalAll(self.io, page.inner, page.page_id * page_size) catch {
        @panic("writeback failed");
    };
    page.is_dirty = false;
}

/// Allocate a new page and return its ID.
pub fn allocate(self: *Self) !PageId {
    const id = self.free_page_id;

    const page_buf: [page_size]u8 = undefined;
    _ = try self.file.writePositionalAll(self.io, &page_buf, id * page_size);
    self.free_page_id += 1;

    const meta_page = try self.get(0);
    defer self.put(meta_page);
    meta_page.meta().next_free_page_id = self.free_page_id;

    return id;
}

/// Get a page buffer.
///
/// # Example
///
/// ```zig
/// const page = try buffer_manager.get(page_id);
/// defer buffer_manager.put(page);
/// // modify the page
/// ```
pub fn get(self: *Self, id: PageId) !*PageFrame {
    const result = try self.cache.getOrPut(id);

    if (!result.found_existing) {
        errdefer _ = self.cache.remove(id);
        result.value_ptr.* = try self.load_page(id);
    }
    _ = result.value_ptr.*.refcnt.fetchAdd(1, .monotonic);

    return result.value_ptr.*;
}

pub fn put(self: *Self, page: *PageFrame) void {
    const old_refcnt = page.refcnt.fetchSub(1, .monotonic);
    if (old_refcnt == 1) {
        self.writeback_page(page);
        self.allocator.free(page.inner);
        self.allocator.destroy(page);
    }
}

/// Drop page cace references to page buffers and deinit the hashmap.
pub fn deinit(self: *Self) void {
    var it = self.cache.iterator();
    while (it.next()) |entry| {
        self.put(entry.value_ptr.*);
    }
    self.cache.deinit();
}
