/// A library for using devicemapper
///
/// Debugging:
/// * use "sudo dmesg | grep device-mapper" when debugging failures.
/// * sudo dmsetup table --inactive <dev_name>          # show inactive table for device
/// * sudo dmsetup table  <dev_name>                    # show active table for device
/// * sudo dmsetup remove  <dev_name>                   # remove dm device
/// * sudo dmsetup ls                                   # list all dm devices
const std = @import("std");
const c = @import("c");

const OpenMapperError = error{
    ControlFileNotFound,
    VersionCommandFailed,
};

const version = [_]u32{
    c.DM_VERSION_MAJOR,
    c.DM_VERSION_MINOR,
    c.DM_VERSION_PATCHLEVEL,
};

fn ioctl(fd: std.c.fd_t, request: u32, arg: usize) std.os.linux.E {
    const rc = std.os.linux.ioctl(fd, request, arg);
    return std.os.linux.errno(rc);
}

const CreateDeviceError = error{
    /// device busy (e.g. a device with the same name exists)
    Busy,
    InvalidName,
    /// Invalid value in dm_ioctl struct (uuid, name, etc..)
    InvalidValue,
    Unexpected,
};

const LoadTableError = error{
    /// Invalid value (e.g. `next` in dm_target_spec is oob)
    InvalidValue,
    /// Failed to lookup the device for a linear target
    DeviceNotFound,
    Unexpected,
};

pub const Device = struct {
    /// The device id.
    /// Make sure its in the dm_ioctl struct when sending commands.
    ///
    /// The kernel will lookup the device when doing an ioctl using the uuid, or the name, or the dev (in order of presence)
    /// see: `__find_device_hash_cell` in the kernel source.
    dev: u64,
};

pub const CreateDeviceOptions = struct {
    name: []const u8,
    uuid: ?[c.DM_UUID_LEN]u8 = null,
};

pub const RemoveDeviceOptions = struct {
    name: []const u8,
    uuid: ?[c.DM_UUID_LEN]u8 = null,
};

/// A device mapper target
pub const Target = struct {
    pub const Type = enum {
        // dm-linear
        linear,
        // dm-error
        @"error",
    };

    /// The number of blocks that map to this device
    length: u64,
    type: Type,
    params: ?[]const u8 = null,
};

pub const Mapper = struct {
    /// /dev/mapper/control
    ctrl_file: std.Io.File,

    pub fn open(io: std.Io) !Mapper {
        const file = try std.Io.Dir.openFileAbsolute(io, "/dev/mapper/control", .{
            .mode = .read_write,
        });

        // communicate our comptabile version.
        // I imagine this fails if the kernel is not comptabile with our version.
        var dm_ioctl = c.dm_ioctl{
            .version = version,
        };
        const rc = ioctl(file.handle, c.DM_VERSION, @intFromPtr(&dm_ioctl));
        switch (rc) {
            .SUCCESS => {},
            else => return OpenMapperError.VersionCommandFailed,
        }

        return .{
            .ctrl_file = file,
        };
    }

    pub fn create_dev(self: *const Mapper, options: CreateDeviceOptions) CreateDeviceError!Device {
        const invalid_name = blk: {
            if (options.name.len >= c.DM_NAME_LEN) break :blk true;
            if (std.mem.indexOfScalar(u8, options.name, '.') != null) break :blk true;
            if (std.mem.indexOfScalar(u8, options.name, '/') != null) break :blk true;
            if (std.mem.indexOf(u8, options.name, "..") != null) break :blk true;
            if (std.mem.indexOf(u8, options.name, "mapper") != null) break :blk true;

            break :blk false;
        };
        if (invalid_name) {
            return CreateDeviceError.InvalidName;
        }

        if (options.uuid != null) {
            @panic("unhandled");
        }

        var dm_ioctl = c.dm_ioctl{
            .version = version,
            .dev = undefined,
            .name = std.mem.zeroes([c.DM_NAME_LEN]u8),
            .uuid = std.mem.zeroes([c.DM_UUID_LEN]u8),
            .data_size = @sizeOf(c.dm_ioctl),
        };

        // .name is already zero-initilized so this is correctly stored
        // as a null-terminated string in dm_ioctl.
        @memcpy(dm_ioctl.name[0..options.name.len], options.name);

        const rc = ioctl(
            self.ctrl_file.handle,
            c.DM_DEV_CREATE,
            @intFromPtr(&dm_ioctl),
        );
        switch (rc) {
            .SUCCESS => {},
            .BUSY => return CreateDeviceError.Busy,
            .INVAL => return CreateDeviceError.InvalidValue,
            else => {
                std.log.err("failed to create device: {s}", .{@tagName(rc)});
                return std.posix.unexpectedErrno(rc);
            },
        }

        std.debug.print("device: {any}", .{dm_ioctl.dev});
        return .{ .dev = dm_ioctl.dev };
    }

    pub fn remove_dev(self: *const Mapper, options: RemoveDeviceOptions) !void {
        if (options.uuid != null) {
            @panic("unhandled");
        }

        var dm_ioctl = c.dm_ioctl{
            .version = version,
            .dev = 0,
            .name = std.mem.zeroes([c.DM_NAME_LEN]u8),
            .uuid = std.mem.zeroes([c.DM_UUID_LEN]u8),
            .data_size = @sizeOf(c.dm_ioctl),
        };
        @memcpy(dm_ioctl.name[0..options.name.len], options.name);

        const rc = ioctl(
            self.ctrl_file.handle,
            c.DM_DEV_REMOVE,
            @intFromPtr(&dm_ioctl),
        );
        switch (rc) {
            .SUCCESS => {},
            .NXIO => {
                // NXIO could also occur if both name and dev were passed
                // lookup in the kernel is done by `__find_device_hash_cell`
                return error.DeviceNotFound;
            },
            else => {
                std.log.err("failed to remove device: {s}", .{@tagName(rc)});
                return std.posix.unexpectedErrno(rc);
            },
        }
    }

    /// Load a table into the `inactive` slot of the device.
    /// The table can be loaded into the `active` slot by `resuming` this device.
    ///
    /// Note: The device doesn't need to be suspended to call `resume`, a resume in this context
    /// means loading the table into the active slot.
    pub fn load_table(self: *const Mapper, allocator: std.mem.Allocator, device: *const Device, targets: []const Target) !void {
        // `dm_target_spec` is a variable-sized struct, if the target type accepts params, they will be placed at the end of the struct
        // so what we will eventually pass to the kernel is an array that looks like this
        // -------------------------------------------------
        // dm_ioctl|target_spec|params|target_spec|target_spec|params
        //         |1          |      |2          |3
        // -------------------------------------------------
        // dm_target_spec.next is used to form a "linked-list" so that the kernel knows
        // how to skip the variable-sized params.
        //
        // This will calculate the total number of bytes required for this array and the params.
        var buffer_size: usize = @sizeOf(c.dm_ioctl);
        buffer_size += targets.len * @sizeOf(c.dm_target_spec);
        for (targets) |target| {
            if (target.params) |param| {
                // +1 because we will insert a null-terminator
                // and we align to 8 bytes to ensure the next `dm_target_spec` is proprely
                // aligned.
                buffer_size += std.mem.alignForward(usize, param.len + 1, @alignOf(c.dm_target_spec));
            }
        }

        buffer_size += @alignOf(c.dm_target_spec); // sentinel space for kernel bounds check

        var targets_buf = try allocator.alignedAlloc(u8, .of(c.dm_target_spec), buffer_size);
        defer allocator.free(targets_buf);
        @memset(targets_buf, 0);

        const dm_ioctl: *c.dm_ioctl = @ptrCast(@alignCast(targets_buf));
        dm_ioctl.* = .{
            .version = version,
            .dev = device.dev,
            .name = std.mem.zeroes([c.DM_NAME_LEN]u8),
            .uuid = std.mem.zeroes([c.DM_UUID_LEN]u8),
            .data_size = @intCast(buffer_size), // total size of data including this struct
            .target_count = @intCast(targets.len),
            .data_start = @sizeOf(c.dm_ioctl),
        };

        // location of the next dm_target_spec struct within `targets_buf`
        var offset: usize = @sizeOf(c.dm_ioctl);
        // the logical sector the current target should start from
        // this is auto incremented based on the .length of the
        // previous targets.
        var sector_start: u64 = 0;

        for (targets, 0..) |target, idx| {
            var next: u32 = @sizeOf(c.dm_target_spec);

            const dm_target_spec: *c.dm_target_spec = @ptrCast(@alignCast(&targets_buf[offset]));
            offset += @sizeOf(c.dm_target_spec);
            if (target.params) |param| {
                const param_size = std.mem.alignForward(u32, @intCast(param.len + 1), @alignOf(c.dm_target_spec));
                @memcpy(targets_buf[offset..][0..param.len], param); // insert params directly after the dm_target_spec struct
                targets_buf[offset + param.len] = 0; // null-terminate params
                offset += param_size;
                next += param_size;
            }

            dm_target_spec.sector_start = sector_start;
            dm_target_spec.length = target.length;

            const target_type_name = @tagName(target.type);
            if (target_type_name.len >= c.DM_MAX_TYPE_NAME) unreachable;

            @memcpy(dm_target_spec.target_type[0..target_type_name.len], target_type_name);
            dm_target_spec.target_type[target_type_name.len] = 0;

            // `next` is relative to the current target spec struct
            dm_target_spec.next = if (idx == targets.len - 1) 0 else next;

            sector_start += target.length;
        }

        const rc = ioctl(
            self.ctrl_file.handle,
            c.DM_TABLE_LOAD,
            @intFromPtr(targets_buf.ptr),
        );
        switch (rc) {
            .SUCCESS => {},
            .INVAL => return LoadTableError.InvalidValue,
            .NOENT => return LoadTableError.DeviceNotFound,
            else => {
                std.log.err("failed to create device: {s}", .{@tagName(rc)});
                return std.posix.unexpectedErrno(rc);
            },
        }
    }

    pub fn deinit(self: *const Mapper, io: std.Io) void {
        self.ctrl_file.close(io);
    }
};
