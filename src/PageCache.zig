const std = @import("std");
const config = @import("config");
const pagemod = @import("page.zig");

const Io = std.Io;
const mem = std.mem;
const PageId = pagemod.PageId;
const PageBuffer = pagemod.PageBuffer;
const PageHeader = pagemod.PageHeader;
const page_size = pagemod.page_size;

/// A hashmap based page cache.
///
/// Just like the rest of the code, this is not thread-safe, yet.
const Self = @This();

cache: std.AutoHashMap(PageId, *PageBuffer),
allocator: mem.Allocator,
file: Io.File,
io: Io,
// TODO: this is temporary. We should track free blocks some other way.
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
    const page_buf = try self.allocator.alignedAlloc(
        u8,
        .of(PageHeader),
        page_size,
    );
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

pub fn mark_page_dirty(self: *Self, page: *PageBuffer) void {
    _ = self;
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
    if (config.disable_page_cache) {
        return self.load_page(id);
    }
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

/// Drop page cace references to page buffers and deinit the hashmap.
pub fn deinit(self: *Self) void {
    var it = self.cache.iterator();
    while (it.next()) |entry| {
        self.put(entry.value_ptr.*);
    }
    self.cache.deinit();
}
