const std = @import("std");
const stdx = @import("stdx.zig");

const Io = std.Io;

const zig_simple_kv = @import("zig_simple_kv");

pub fn main(init: std.process.Init) !void {
    const cwd = std.Io.Dir.cwd();
    const db = try blk: {
        if (cwd.openFile(init.io, "db.z", .{ .mode = .read_write })) |f| {
            break :blk f;
        } else |err| {
            if (err == std.Io.Dir.OpenError.FileNotFound) {
                break :blk createDatabase(init.io, cwd);
            } else {
                break :blk err;
            }
        }
    };

    _ = try setKey(db, "abc", "123");
}

pub fn createDatabase(io: std.Io, cwd: std.Io.Dir) !std.Io.File {
    const file = try cwd.createFile(io, "db.z", .{
        .truncate = false,
        .read = true,
    });

    var super = SuperBlock{
        .free_offset = @sizeOf(SuperBlock),
    };
    super.nativeToEndian();

    try file.writePositionalAll(io, std.mem.asBytes(&super), 0);

    return file;
}

const SuperBlock = extern struct {
    const Magic = 0xdeadbeefcafebabe;

    magic: u64 = Magic,
    count: u64 = 0, // total number of keys
    free_offset: u64 = 0, // offset for next free spot

    pub fn endianToNative(self: *SuperBlock) void {
        const info = @typeInfo(SuperBlock);
        inline for (info.@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .int => {
                    @field(self, field.name) = std.mem.littleToNative(field.type, @field(self, field.name));
                },
                .float => @compileError("floats are not supported in SuperBlock"),
                else => {},
            }
        }
    }

    pub fn nativeToEndian(self: *SuperBlock) void {
        const info = @typeInfo(SuperBlock);
        inline for (info.@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .int => {
                    @field(self, field.name) = std.mem.nativeToLittle(field.type, @field(self, field.name));
                },
                .float => @compileError("floats are not supported in SuperBlock"),
                else => {},
            }
        }
    }
};

pub fn loadSuperBlock(db: std.Io.File) !SuperBlock {
    var super: SuperBlock = undefined;
    _ = try stdx.pread(db.handle, std.mem.asBytes(&super), 0);
    super.endianToNative();

    if (super.magic != SuperBlock.Magic) {
        return error.InvalidMagicNumber;
    }

    return super;
}

pub fn writeSuperBlock(db: std.Io.File, super: *const SuperBlock) !void {
    if (super.magic != SuperBlock.Magic) {
        return error.InvalidMagicNumber;
    }

    var copy: SuperBlock = super.*;
    copy.nativeToEndian();

    const iovec: []const std.posix.iovec_const = &.{
        .{ .base = @ptrCast(&copy), .len = @sizeOf(SuperBlock) },
    };
    _ = try stdx.pwritev(db.handle, &iovec, 0);
}

pub fn setKey(db: std.Io.File, key: []const u8, value: []const u8) !void {
    var super = try loadSuperBlock(db);

    const key_len: usize = key.len;
    const val_len: usize = value.len;
    // write key and value in Pascal format
    const iovec: []const std.posix.iovec_const = &.{
        .{ .base = @ptrCast(&key_len), .len = @sizeOf(usize) },
        .{ .base = key.ptr, .len = key_len },

        .{ .base = @ptrCast(&val_len), .len = @sizeOf(usize) },
        .{ .base = value.ptr, .len = val_len },
    };
    _ = try stdx.pwritev(db.handle, &iovec, super.free_offset);

    super.free_offset += key_len + val_len + (@sizeOf(usize) * 2);
    try writeSuperBlock(db, &super);
}
