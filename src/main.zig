const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx.zig");
const devmapper = @import("devicemapper.zig");
const page = @import("page.zig");

const Io = std.Io;
const assert = std.debug.assert;
const mem = std.mem;

const zig_simple_kv = @import("zig_simple_kv");

/// a Session represents an open database. This will be used
/// as a context object throughout the code.
const Session = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    db_file: std.Io.File,

    /// TODO: Never directly modify this object
    /// but for now make sure you call writeSuperBlock after modifying it
    super: SuperBlock,

    pub fn open(io: std.Io, gpa: std.mem.Allocator, cwd: std.Io.Dir, path: []const u8) !Session {
        const file = cwd.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try createDatabase(io, cwd, path),
            else => return err,
        };

        return .{
            .gpa = gpa,
            .io = io,
            .db_file = file,
            .super = try loadSuperBlock(file),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    comptime {
        if (builtin.cpu.arch.endian() != .little) {
            @compileError("Big endian architectures are not supported");
        }
    }

    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();

    //const dm = try devmapper.Mapper.open(init.io);
    //defer dm.deinit(init.io);

    //const device = try dm.create_dev(.{ .name = "zerr10" });
    //defer dm.remove_dev(.{ .name = "zerr10" }) catch |err| {
    //    std.log.err("failed to remove device: {}", .{err});
    //};
    //try dm.load_table(gpa, &device, &.{
    //    .{ .length = 50, .type = .linear, .params = "/dev/nvme0n1p3 0" },
    //    .{ .length = 10, .type = .@"error" },
    //});

    var session = try Session.open(init.io, gpa, cwd, "db.z");
    _ = try setKey(&session, "abc", "123");
    //_ = try setKey(db, "abc", "555");
    //_ = try setKey(db, "hello", "AAA");

    const val = try getKey(&session, "abc") orelse unreachable;
    defer gpa.free(val);

    assert(mem.eql(u8, val, "123"));
    //assert(mem.eql(u8, try getKey(gpa, db, "hello") orelse unreachable, "AAA"));
}

/// Creates the database file and initializes the super block.
pub fn createDatabase(io: std.Io, cwd: std.Io.Dir, path: []const u8) !std.Io.File {
    const file = try cwd.createFile(io, path, .{
        .truncate = false,
        .read = true,
    });

    var super = SuperBlock{
        .free_offset = @sizeOf(SuperBlock),
    };

    try file.writePositionalAll(io, std.mem.asBytes(&super), 0);

    return file;
}

const SuperBlock = extern struct {
    const Magic = 0xdeadbeefcafebabe;

    magic: u64 = Magic,
    count: u64 = 0, // total number of keys
    free_offset: u64 = 0, // offset for next free spot
};

pub fn loadSuperBlock(db: std.Io.File) !SuperBlock {
    var super: SuperBlock = undefined;
    _ = try stdx.pread(db.handle, std.mem.asBytes(&super), 0);

    if (super.magic != SuperBlock.Magic) {
        return error.InvalidMagicNumber;
    }

    return super;
}

pub fn writeSuperBlock(db: std.Io.File, super: *const SuperBlock) !void {
    if (super.magic != SuperBlock.Magic) {
        return error.InvalidMagicNumber;
    }

    _ = try stdx.pwritev(db.handle, &stdx.asIoVec(.{super}), 0);
}

pub fn setKey(session: *Session, key: []const u8, value: []const u8) !void {
    var super = session.super;

    const key_len: usize = key.len;
    const val_len: usize = value.len;
    // -----------------------------------
    // key_len | value_len | key | value
    // -----------------------------------
    const iovec = stdx.asIoVec(.{
        &key_len,
        &val_len,
        key,
        value,
    });
    _ = try stdx.pwritev(session.db_file.handle, &iovec, super.free_offset);

    super.free_offset += key_len + val_len + (@sizeOf(usize) * 2);
    try writeSuperBlock(session.db_file, &super);
    try std.posix.fdatasync(session.db_file.handle);
}

pub fn getKey(session: *const Session, key: []const u8) !?[]const u8 {
    var offset: usize = @sizeOf(SuperBlock);
    var buffer: [0x1000]u8 = undefined;

    while (true) {
        if (try stdx.pread(session.db_file.handle, &buffer, offset) == 0) {
            break;
        }

        const key_start = @sizeOf(usize) * 2;
        const key_size = std.mem.readInt(usize, buffer[0..8], .little);
        const value_size = std.mem.readInt(usize, buffer[8..16], .little);
        const value_start = key_start + key_size;
        const cand_key = buffer[key_start .. key_start + key_size];
        if (std.mem.eql(u8, cand_key, key)) {
            const cand_value = buffer[value_start .. value_start + value_size];
            std.log.info("found", .{});
            const ret = try session.gpa.alloc(u8, cand_value.len);
            @memcpy(ret, cand_value);
            return ret;
        }
        offset += key_start + key_size + value_size;
    }
    return null;
}

test {
    std.testing.refAllDecls(devmapper);
    std.testing.refAllDecls(stdx);
    std.testing.refAllDecls(page);
}
