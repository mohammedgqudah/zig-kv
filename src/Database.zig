const std = @import("std");

const BTree = @import("BTree.zig");
const BufferManager = @import("BufferManager.zig");
const Log = @import("Log.zig");

const Io = std.Io;
const mem = std.mem;

const LSN = Log.LSN;

/// The global database state
const Self = @This();

io: Io,
gpa: mem.Allocator,
db_file: Io.File,
buffer_manager: BufferManager,
tree: BTree,
checkpoint: Log.LSN,
checkpoint_file: Io.File,
log: Log,

/// Open the database at `path`.
/// A new database is initialized if `path` doesn't exist.
pub fn open(
    io: Io,
    gpa: mem.Allocator,
    cwd: Io.Dir,
    path: []const u8,
) !*Self {
    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);

    var initialize = false;
    const data_dir = cwd.openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            initialize = true;
            break :blk try cwd.createDirPathOpen(io, path, .{});
        },
        else => return err,
    };

    const db_file = if (initialize)
        try data_dir.createFile(io, "index", .{ .exclusive = true, .read = true })
    else
        try data_dir.openFile(io, "index", .{ .mode = .read_write });

    const checkpoint_file = if (initialize)
        try data_dir.createFile(io, "CHECKPOINT", .{ .exclusive = true, .read = true })
    else
        try data_dir.openFile(io, "CHECKPOINT", .{ .mode = .read_write });

    var checkpoint: LSN = 0;

    if (initialize) {
        try checkpoint_file.writePositionalAll(io, @ptrCast(&checkpoint), 0);
    } else {
        var buf: [@sizeOf(LSN)]u8 = undefined;
        const read = try checkpoint_file.readPositionalAll(io, &buf, 0);
        if (read != buf.len)
            return error.CorruptedCheckPointFile;
        checkpoint = std.mem.readInt(LSN, &buf, .little);
    }

    self.* = .{
        .io = io,
        .gpa = gpa,
        .db_file = db_file,
        .buffer_manager = BufferManager.new(gpa, db_file, io),
        .tree = undefined,
        .checkpoint = checkpoint,
        .checkpoint_file = checkpoint_file,
        .log = undefined,
    };
    errdefer self.buffer_manager.deinit();

    const wal_dir = if (initialize)
        try data_dir.createDirPathOpen(io, "wal", .{ .open_options = .{ .iterate = true } })
    else
        try data_dir.openDir(io, "wal", .{ .iterate = true });

    self.log = try .open(io, wal_dir, &self.checkpoint, &self.buffer_manager);
    errdefer self.log.deinit();

    self.tree = if (initialize)
        try BTree.empty(gpa, &self.buffer_manager, &self.log)
    else
        BTree.load(gpa, &self.buffer_manager, &self.log);

    self.log.tree = &self.tree;
    //_ = try self.log.recover(gpa);

    return self;
}

pub fn deinit(self: *Self) void {
    self.log.deinit();
    self.buffer_manager.deinit();
    self.db_file.close(self.io);
    self.gpa.destroy(self);
}
