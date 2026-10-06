const std = @import("std");

const mem = std.mem;
const Io = std.Io;

/// A write-ahead-log.
///
///
/// # Example
/// ```zig
/// var wal = try Wal.open(io, dir);
/// defer wal.deinit();
///
/// const lsn = try wal.append("set a 1");
/// _ = try wal.append("set b 2");
///
/// // Replay records
/// var it = wal.iter(allocator, 0);
/// while (try it.next()) |record| {
///     defer record.deinit(allocator);
///     // apply
/// }
/// ```
const Self = @This();

/// Log Sequence Number (LSN).
/// Internally, it represents a byte-offset in the WAL.
const LSN = u64;

dir: Io.Dir,
io: Io,
file: Io.File,
pos: LSN,
lock: std.Io.Mutex,

pub const Header = extern struct {
    len: u64,
    checksum: u64,
};

pub const WalRecoveryError = error{
    /// CRC check failed
    ChecksumMismatch,
    /// Invalid length or truncated record
    InvalidRecord,
} || Io.File.ReadPositionalError || mem.Allocator.Error;

pub const max_segment_size: u64 = 16 * 1024 * 1024;
const segment_name_prefix = "wal-";
const segment_name_digits = 20;
const segment_name_len = segment_name_prefix.len + segment_name_digits;
pub const max_segment_name_len = segment_name_len;

/// Open an existing WAL or create a new one.
pub fn open(io: Io, dir: Io.Dir) !Self {
    const file = dir.openFile(io, "wal", .{
        .allow_directory = false,
        .follow_symlinks = false,
        .mode = .read_write,
    }) catch |e| switch (e) {
        error.FileNotFound => blk: {
            break :blk try dir.createFile(io, "wal", .{ .read = true });
        },
        else => return e,
    };

    const stat = try file.stat(io);
    return .{
        .dir = dir,
        .io = io,
        .file = file,
        .pos = stat.size,
        .lock = .init,
    };
}

pub fn deinit(self: *Self) void {
    self.file.close(self.io);
}

/// Append a WAL entry and return its LSN
pub fn append(self: *Self, bytes: []const u8) !LSN {
    try self.lock.lock(self.io);
    defer self.lock.unlock(self.io);

    const reserve = bytes.len + @sizeOf(Header);
    const pos = self.pos;

    self.pos += reserve;
    errdefer self.pos -= reserve;

    var checksum = std.hash.Crc32.init();

    const len: u64 = bytes.len;
    checksum.update(@ptrCast(&len));
    checksum.update(bytes);

    const entry: Header = .{
        .checksum = checksum.final(),
        .len = bytes.len,
    };
    const written = try self.file.writePositional(self.io, &.{ @ptrCast(&entry), bytes }, pos);
    if (written != reserve)
        return error.Incomplete; // TODO: retry the write

    self.file.sync(self.io) catch {
        @panic("fatal: fsync failure");
    };

    return pos;
}

const Record = struct {
    buffer: []u8,

    pub fn deinit(self: @This(), allocator: mem.Allocator) void {
        allocator.free(self.buffer);
    }
};

/// Return an iterator over the WAL records starting from `pos`
///
/// # Example
/// ```zig
/// var it = wal.iter(allocator, pos);
/// const record = try it.next();
/// assert(record != null);
/// ```
pub fn iter(self: *Self, allocator: mem.Allocator, pos: LSN) WalIter {
    return .{
        .start = pos,
        .wal = self,
        .allocator = allocator,
        .io = self.io,
    };
}

const WalIter = struct {
    allocator: mem.Allocator,
    io: Io,
    wal: *const Self,
    start: LSN = 0,

    pub fn next(self: *@This()) WalRecoveryError!?Record {
        if (self.start == self.wal.pos)
            return null;

        var header: Header = undefined;
        var nread = try self.wal.file.readPositionalAll(self.io, @ptrCast(&header), self.start);

        if (nread != @sizeOf(Header))
            return WalRecoveryError.InvalidRecord;

        const remaining = self.wal.pos - self.start - @sizeOf(Header);
        if (header.len > remaining)
            return WalRecoveryError.InvalidRecord;

        const buf = try self.allocator.alloc(u8, header.len);
        errdefer self.allocator.free(buf);

        nread = try self.wal.file.readPositionalAll(self.io, buf, self.start + @sizeOf(Header));

        if (nread != header.len)
            return WalRecoveryError.InvalidRecord;

        var checksum = std.hash.Crc32.init();

        const len: u64 = header.len;
        checksum.update(@ptrCast(&len));
        checksum.update(buf);

        if (checksum.final() != header.checksum)
            return WalRecoveryError.ChecksumMismatch;

        self.start += header.len + @sizeOf(Header);

        return .{
            .buffer = buf,
        };
    }
};

inline fn lsnToSegmentIdx(lsn: LSN) LSN {
    return lsn / max_segment_size;
}

fn idxToSegmentName(buf: *[segment_name_len]u8, index: LSN) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d:0>20}", .{ segment_name_prefix, index }) catch unreachable;
}

fn nameToSegmentIdx(name: []const u8) !LSN {
    if (!mem.startsWith(u8, name, segment_name_prefix))
        return error.InvalidName;
    const digits = name[segment_name_prefix.len..];
    if (digits.len != segment_name_digits)
        return error.InvalidName;
    return std.fmt.parseInt(LSN, digits, 10) catch return error.InvalidName;
}

test {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.open(io, tmp.dir);
    const first_lsn = try wal.append("inc 5");
    const second_lsn = try wal.append("inc 3");

    try std.testing.expectEqual(0, first_lsn);
    try std.testing.expect(second_lsn > first_lsn);

    var it = wal.iter(allocator, 0);

    const e1 = try it.next();
    defer e1.?.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "inc 5", e1.?.buffer);

    const e2 = try it.next();
    defer e2.?.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "inc 3", e2.?.buffer);

    try std.testing.expectEqual(null, try it.next());
}

test "iter detects corruption of an entry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.open(io, tmp.dir);
    _ = try wal.append("inc 5");

    // change one byte of the entry.
    const payload_offset = @sizeOf(Header);
    try wal.file.writePositionalAll(io, "X", payload_offset);

    var it = wal.iter(allocator, 0);
    try std.testing.expectError(WalRecoveryError.ChecksumMismatch, it.next());
}

test "iter rejects a length that overflows the log" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.open(io, tmp.dir);
    defer wal.deinit();
    _ = try wal.append("inc 5");

    const corrupted_len: u64 = 1 << 40;
    try wal.file.writePositionalAll(io, @ptrCast(&corrupted_len), 0);

    var it = wal.iter(allocator, 0);
    try std.testing.expectError(WalRecoveryError.InvalidRecord, it.next());
}
