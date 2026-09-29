const std = @import("std");
const Io = std.Io;

const Self = @This();

const LSN = u64;

dir: Io.Dir,
io: Io,
file: Io.File,
pos: usize,
lock: std.Io.Mutex,
lsn: LSN,

pub const Entry = extern struct {
    len: u64,
    checksum: u64,
};

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
        // TODO: persist
        .lsn = 0,
    };
}

pub fn append(self: *Self, bytes: []const u8) !LSN {
    try self.lock.lock(self.io);
    defer self.lock.unlock(self.io);

    const reserve = bytes.len + @sizeOf(Entry);
    const pos = self.pos;

    self.pos += reserve;
    errdefer self.pos -= reserve;

    const lsn = self.lsn;
    self.lsn += 1;
    errdefer self.lsn -= 1;

    var checksum = std.hash.Crc32.init();

    const len: u64 = bytes.len;
    checksum.update(@ptrCast(&len));
    checksum.update(bytes);

    const entry: Entry = .{
        .checksum = checksum.final(),
        .len = bytes.len,
    };
    const written = try self.file.writePositional(self.io, &.{ @ptrCast(&entry), bytes }, pos);
    if (written != reserve)
        return error.Incomplete; // TODO: retry the write

    self.file.sync(self.io) catch {
        @panic("fatal: fsync failure");
    };

    return lsn;
}

test {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Self.open(io, tmp.dir);
    var lsn = try wal.append("inc 5");
    try std.testing.expectEqual(0, lsn);

    lsn = try wal.append("inc 5");
    try std.testing.expectEqual(1, lsn);
}
