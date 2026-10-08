const std = @import("std");
const stdx = @import("stdx.zig");

const mem = std.mem;
const Io = std.Io;
const assert = std.debug.assert;

/// A write-ahead-log.
///
/// This WAL is physically segmented but the API provides a logically contiguous stream of logs.
///
/// # Example
/// ```zig
/// var wal = try Wal.open(allocator, io, dir, null);
/// defer wal.deinit();
///
/// const lsn = try wal.append("set a 1");
/// _ = try wal.append("set b 2");
///
/// // Replay records
/// while (try wal.next()) |record| {
///     defer record.deinit(allocator);
///     // apply
/// }
/// ```
const Self = @This();

dir: Io.Dir,
io: Io,
file: Io.File,
/// position witin the current segment
pos: LSN,
/// log sequence number. The logical position across all segments
lsn: LSN,
lock: std.Io.Mutex,
segment_size: u64,
mode: Mode,
allocator: mem.Allocator,

/// Log Sequence Number (LSN).
/// Internally, it represents a byte-offset in the WAL.
const LSN = u64;
const SegmentIdx = u64;

const Mode = enum { recovery, append };

pub const Header = extern struct {
    len: u64,
    checksum: u64,
};

pub const WalRecoveryError = error{
    /// CRC check failed
    ChecksumMismatch,
    /// Invalid length or truncated record
    InvalidRecord,
} || Io.File.ReadPositionalError || mem.Allocator.Error || Io.File.OpenError;

pub const default_segment_size: u64 = 16 * 1024 * 1024;
const segment_name_prefix = "wal-";
const segment_name_digits = 20;
const segment_name_len = segment_name_prefix.len + segment_name_digits;

/// 1 GB
const max_record_size = 1 * 1024 * 1024 * 1024;

comptime {
    assert(default_segment_size % 8 == 0);
}

/// Align `len` to multiple of 8
inline fn alignRecord(len: usize) usize {
    return mem.alignForward(usize, len, 8);
}

/// Open an existing WAL or create a new one.
pub fn open(allocator: mem.Allocator, io: Io, dir: Io.Dir, checkpoint: ?LSN) !Self {
    return openWithSegmentSize(allocator, io, dir, default_segment_size, checkpoint);
}

pub fn openWithSegmentSize(allocator: mem.Allocator, io: Io, dir: Io.Dir, segment_size: u64, checkpoint: ?LSN) !Self {
    // start in recovery mode, unless we create a fresh WAL.
    var mode: Mode = .recovery;

    const check_segment_name = idxToSegmentName(0);
    const check_file = dir.openFile(io, &check_segment_name, .{ .path_only = true }) catch |e| switch (e) {
        error.FileNotFound => brk: {
            // if segment zero does not exist, then this is a new WAL
            if (checkpoint != null) {
                @panic("new WAL cannot have a checkpoint");
            }
            mode = .append;
            break :brk try dir.createFile(io, &check_segment_name, .{ .exclusive = true });
        },
        else => return e,
    };
    check_file.close(io);

    const lsn = checkpoint orelse 0;
    const pos = lsn % segment_size;

    const segment = openSegment(io, dir, lsn, segment_size) catch |e| switch (e) {
        error.FileNotFound => blk: {
            // The checkpoint segment is missing. This is only valid when the
            // checkpoint lands exactly at the end of the WAL: on a segment
            // boundary, with the previous segment full.
            if (pos != 0) @panic("checkpoint is beyond WAL");
            const prev = try openSegment(io, dir, lsn - segment_size, segment_size);
            const prev_stat = try prev.stat(io);
            prev.close(io);
            if (prev_stat.size != segment_size) @panic("checkpoint is beyond WAL");
            mode = .append;
            break :blk try dir.createFile(io, &idxToSegmentName(lsn / segment_size), .{ .read = true });
        },
        else => return e,
    };

    const stat = try segment.stat(io);
    if (pos > stat.size)
        @panic("checkpoint is beyond WAL");

    return .{
        .dir = dir,
        .io = io,
        .file = segment,
        .lock = .init,
        .segment_size = segment_size,
        .mode = mode,
        // recovery will take care of setting `pos` and `len`
        // to their latest value, starting from `checkpoint`.
        .pos = pos,
        .lsn = lsn,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.file.close(self.io);
}

/// Return the index of the last segment in
/// the WAL directory.
fn lastSegmentIdx(io: Io, dir: Io.Dir) !?SegmentIdx {
    const it = dir.iterate();

    var highest: ?SegmentIdx = null;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) @panic("unexpected entry in WAL directory");
        const idx = nameToSegmentIdx(entry.name) catch @panic("unexpected file in WAL directory");
        if (highest) |max| {
            highest = @max(max, idx);
        } else {
            highest = idx;
        }
    }

    return highest;
}

/// Append a WAL entry and return its LSN
pub fn append(self: *Self, bytes: []const u8) !LSN {
    assert(self.mode == .append);

    if (bytes.len > max_record_size)
        return error.RecordTooLarge;

    try self.lock.lock(self.io);
    defer self.lock.unlock(self.io);

    const original_pos = self.pos;
    errdefer self.pos = original_pos;

    const reserve = alignRecord(bytes.len + @sizeOf(Header));

    const len: u64 = bytes.len;
    var checksum = std.hash.Crc32.init();
    checksum.update(@ptrCast(&len));
    checksum.update(bytes);

    const header = Header{
        .len = bytes.len,
        .checksum = checksum.final(),
    };

    const pad_len = reserve - (@sizeOf(Header) + bytes.len);
    var pad: [7]u8 = @splat(0);
    const record: [3][]const u8 = .{
        @ptrCast(&header),
        bytes,
        pad[0..pad_len],
    };

    var cursor: stdx.IoVecCursor(record.len, false) = .init(&record);
    // track global offset to use when rotating
    var offset = self.lsn;
    while (!cursor.isDone()) {
        const available = self.segment_size - self.pos;
        if (available == 0) {
            try self.rotate(offset / self.segment_size);
            continue;
        }

        const written = try self.file.writePositional(self.io, cursor.peek(available), self.pos);
        cursor.advance(written);
        self.pos += written;
        offset += written;
        self.file.sync(self.io) catch {
            @panic("fatal: fsync failure");
        };
    }

    const lsn = self.lsn;
    self.lsn += reserve;
    return lsn;
}

/// Create the next segment if we reached the end of the current segment
fn rotate(self: *Self, idx: SegmentIdx) !void {
    assert(self.pos == self.segment_size);
    const file_name = idxToSegmentName(idx);
    self.file.close(self.io);
    self.file = try self.dir.createFile(self.io, &file_name, .{ .read = true });
    self.pos = 0;
}

const Record = struct {
    buffer: []u8,

    pub fn deinit(self: @This(), allocator: mem.Allocator) void {
        allocator.free(self.buffer);
    }
};

/// Open the segment containing `lsn`
fn openSegment(io: Io, dir: Io.Dir, lsn: LSN, segment_size: u64) Io.File.OpenError!Io.File {
    const idx = lsn / segment_size;
    return dir.openFile(io, &idxToSegmentName(idx), .{
        .allow_directory = false,
        .follow_symlinks = false,
        .mode = .read_write,
    });
}

/// Roll to the next segment. Returns false if the current segment is the last one.
fn nextSegment(self: *Self) !bool {
    assert(self.pos == self.segment_size);
    const file = openSegment(self.io, self.dir, self.lsn, self.segment_size) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    self.file.close(self.io);
    self.file = file;
    self.pos = 0;
    return true;
}

pub fn next(self: *@This()) WalRecoveryError!?Record {
    var header: Header = undefined;

    // A record may end exactly at a segment boundary, leaving the next
    // record's length field at the start of the next segment.
    if (self.pos == self.segment_size and !try self.nextSegment()) {
        self.mode = .append;
        return null;
    }

    var record_len: u64 = undefined;
    var nread = try self.file.readPositionalAll(self.io, @ptrCast(&record_len), self.pos);

    // we have reached the end of the WAL
    if (nread == 0) {
        self.mode = .append;
        return null;
    }

    // there is always space for `length` (8 bytes) in a segment,
    // because records are padded to be aligned to 8 bytes. if not,
    // then something is wrong.
    if (nread != @sizeOf(u64))
        return WalRecoveryError.InvalidRecord;

    header.len = record_len;
    self.pos += @sizeOf(u64);
    self.lsn += @sizeOf(u64);

    // protect against corrupted lengths to avoid OOM
    if (header.len > max_record_size)
        return WalRecoveryError.InvalidRecord;

    const buf = try self.allocator.alloc(u8, record_len);
    errdefer self.allocator.free(buf);

    const header_bytes: []u8 = std.mem.asBytes(&header);
    const iovec: [2][]u8 = .{
        header_bytes[@offsetOf(Header, "checksum")..],
        buf,
    };
    var cursor: stdx.IoVecCursor(2, true) = .init(&iovec);

    while (!cursor.isDone()) {
        const remaining = self.segment_size - self.pos;
        if (remaining == 0) {
            if (!try self.nextSegment()) @panic("next segment does not exist");
        }

        nread = try self.file.readPositional(self.io, cursor.peek(remaining), self.pos);

        cursor.advance(nread);
        self.pos += nread;
        self.lsn += nread;
    }

    var checksum = std.hash.Crc32.init();

    const len: u64 = header.len;
    checksum.update(@ptrCast(&len));
    checksum.update(buf);

    if (checksum.final() != header.checksum)
        return WalRecoveryError.ChecksumMismatch;

    self.pos = alignRecord(self.pos);
    self.lsn = alignRecord(self.lsn);

    return .{
        .buffer = buf,
    };
}

inline fn idxToSegmentName(index: LSN) [segment_name_len]u8 {
    var buf: [segment_name_len]u8 = undefined;
    const ret = mem.print(&buf, "{s}{d:0>20}", .{ segment_name_prefix, index }) catch unreachable;
    assert(ret.len == segment_name_len);

    return buf;
}

fn nameToSegmentIdx(name: []const u8) !LSN {
    if (!mem.startsWith(u8, name, segment_name_prefix))
        return error.InvalidName;
    const digits = name[segment_name_prefix.len..];
    if (digits.len != segment_name_digits)
        return error.InvalidName;
    return std.fmt.parseInt(LSN, digits, 10) catch return error.InvalidName;
}

test "append and iterate" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.open(allocator, io, tmp.dir, null);
    const first_lsn = try wal.append("inc 5");
    const second_lsn = try wal.append("inc 3");

    try std.testing.expectEqual(0, first_lsn);
    try std.testing.expect(second_lsn > first_lsn);

    wal.deinit();
    wal = try Self.open(allocator, io, tmp.dir, null);

    const e1 = try wal.next();
    defer e1.?.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "inc 5", e1.?.buffer);

    const e2 = try wal.next();
    defer e2.?.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "inc 3", e2.?.buffer);

    try std.testing.expectEqual(null, try wal.next());
}

test "iter detects corruption of an entry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.open(allocator, io, tmp.dir, null);
    _ = try wal.append("inc 5");

    // change one byte of the entry.
    const payload_offset = @sizeOf(Header);
    try wal.file.writePositionalAll(io, "X", payload_offset);

    wal.deinit();
    wal = try Self.open(allocator, io, tmp.dir, null);

    try std.testing.expectError(WalRecoveryError.ChecksumMismatch, wal.next());
}

test "iter rejects a length that overflows the log" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.open(allocator, io, tmp.dir, null);
    defer wal.deinit();
    _ = try wal.append("inc 5");

    const corrupted_len: u64 = 1 << 40;
    try wal.file.writePositionalAll(io, @ptrCast(&corrupted_len), 0);

    wal.deinit();
    wal = try Self.open(allocator, io, tmp.dir, null);

    try std.testing.expectError(WalRecoveryError.InvalidRecord, wal.next());
}

test "append a record that crosses a segment boundary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.openWithSegmentSize(allocator, io, tmp.dir, 64, null);
    defer wal.deinit();

    const filler: [40]u8 = @splat(0);
    _ = try wal.append(&filler);

    // only 8 bytes are available in the segment now
    _ = try wal.append("test");
    _ = try wal.append("foobar");

    wal = try Self.openWithSegmentSize(allocator, io, tmp.dir, 64, null);

    const entry = try wal.next();
    defer entry.?.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &filler, entry.?.buffer);

    const entry2 = try wal.next();
    defer entry2.?.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "test", entry2.?.buffer);

    const entry3 = try wal.next();
    defer entry3.?.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "foobar", entry3.?.buffer);

    try std.testing.expectEqual(.recovery, wal.mode);
    try std.testing.expectEqual(null, try wal.next());
    try std.testing.expectEqual(.append, wal.mode);
}

test "recovery continues past a record ending exactly at a segment boundary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.openWithSegmentSize(allocator, io, tmp.dir, 64, null);

    // header (16) + 48 bytes = 64, so the record ends exactly at the segment boundary.
    const filler: [48]u8 = @splat(42);
    _ = try wal.append(&filler);
    _ = try wal.append("after-boundary");

    wal.deinit();
    wal = try Self.openWithSegmentSize(allocator, io, tmp.dir, 64, null);
    defer wal.deinit();

    const entry = try wal.next();
    defer entry.?.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &filler, entry.?.buffer);

    // This should be the record in the next segment, but recovery stops at the boundary.
    const entry2 = try wal.next();
    try std.testing.expect(entry2 != null);
    defer if (entry2) |e| e.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "after-boundary", entry2.?.buffer);
}

test "append across three segments recovers all records" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.openWithSegmentSize(allocator, io, tmp.dir, 64, null);

    // Each 48-byte payload plus the 16-byte header fills a 64-byte segment exactly,
    // forcing a rotate into a new segment before each record.
    const one: [48]u8 = @splat(1);
    const two: [48]u8 = @splat(2);
    const three: [48]u8 = @splat(3);
    _ = try wal.append(&one);
    _ = try wal.append(&two);
    _ = try wal.append(&three);

    wal.deinit();
    wal = try Self.openWithSegmentSize(allocator, io, tmp.dir, 64, null);
    defer wal.deinit();

    const e1 = try wal.next();
    defer e1.?.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &one, e1.?.buffer);

    const e2 = try wal.next();
    defer e2.?.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &two, e2.?.buffer);

    const e3 = try wal.next();
    defer e3.?.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &three, e3.?.buffer);

    try std.testing.expectEqual(null, try wal.next());
}
