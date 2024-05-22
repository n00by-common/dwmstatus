const std = @import("std");

const build_options = @import("build_options");

const Procstat = struct {
    idle: u64,
    sum: u64,
};

var error_log: ?std.fs.File = null;
var procstat_file: std.fs.File = undefined;
var procmeminfo_file: std.fs.File = undefined;
var ps_dir: std.fs.Dir = undefined;

fn log(comptime fmt: []const u8, args: anytype) void {
    if(error_log) |l| {
        l.writer().print(fmt ++ "\n", args) catch {};
    }
}

inline fn log_error(comptime fmt: []const u8, args: anytype) void {
    log(fmt, args);
    const trace = (@errorReturnTrace() orelse return).*;
    log("{}", .{trace});
}

fn readProcstat() !Procstat {
    var buffer: [1024]u8 = undefined;
    const data = buffer[0..try procstat_file.preadAll(&buffer, 0)];

    var result: Procstat = undefined;
    var it = std.mem.tokenize(u8, data, " \n\t");

    _ = it.next().?; // cpuname
    result.sum = 0;
    result.sum += try std.fmt.parseUnsigned(usize, it.next().?, 10); // user
    result.sum += try std.fmt.parseUnsigned(usize, it.next().?, 10); // nice
    result.sum += try std.fmt.parseUnsigned(usize, it.next().?, 10); // system
    result.idle = try std.fmt.parseUnsigned(usize, it.next().?, 10); // idle
    result.sum += try std.fmt.parseUnsigned(usize, it.next().?, 10); // iowait
    result.sum += try std.fmt.parseUnsigned(usize, it.next().?, 10); // irq
    result.sum += try std.fmt.parseUnsigned(usize, it.next().?, 10); // softirq
    result.sum += try std.fmt.parseUnsigned(usize, it.next().?, 10); // steal
    result.sum += try std.fmt.parseUnsigned(usize, it.next().?, 10); // guest
    result.sum += try std.fmt.parseUnsigned(usize, it.next().?, 10); // guest_nice

    result.sum += result.idle;

    return result;
}

var last_stat = Procstat{.idle = 1, .sum = 1};

fn addCPUUsage(writer: anytype) !void {
    const current = try readProcstat();

    const time_delta = current.sum - last_stat.sum;
    const idle_delta = current.idle - last_stat.idle;

    const work_delta = time_delta - idle_delta;

    if(time_delta == 0) {
        try writer.print("CPU: !!!%", .{});
        return;
    }

    const work_percentage = (work_delta * 100) / time_delta;

    last_stat = current;

    try writer.print("CPU: {d:0>3}% ", .{work_percentage});
}

fn addMemoryUsage(writer: anytype) !void {
    var buffer: [1024]u8 = undefined;
    const data = buffer[0..try procmeminfo_file.preadAll(&buffer, 0)];
    var it = std.mem.tokenize(u8, data, " \n\t");

    _ = it.next(); // MemTotal:
    const total = try std.fmt.parseUnsigned(usize, it.next().?, 10);
    _ = it.next(); // kB
    _ = it.next(); // MemFree:
    _ = it.next();
    _ = it.next(); // kB
    _ = it.next(); // MemAvailable:
    const available = try std.fmt.parseUnsigned(usize, it.next().?, 10);
    _ = it.next(); // kB

    try writer.print("Mem: {d:0>3}% ", .{((total - available) * 100)/total});
}

const Battery = struct {
    name: []const u8,
    fds: ?struct {
        now: std.fs.File,
        full: std.fs.File,
        status: std.fs.File,
    },

    fn add_impl(self: @This(), writer: anytype, fds: anytype) !void {
        var buffer: [128]u8 = undefined;
        const now = try readFileUnsigned(usize, fds.now, &buffer);
        const full = try readFileUnsigned(usize, fds.full, &buffer);
        const status_chr: u8 = blk: {
            const status = try readFileString(fds.status, &buffer);
            if(std.mem.eql(u8, status, "Discharging"))
                break :blk '-';

            if(std.mem.eql(u8, status, "Charging"))
                break :blk '+';

            if(std.mem.eql(u8, status, "Not charging"))
                break :blk '~';

            if(std.mem.eql(u8, status, "Full"))
                break :blk '^';

            log("Unknown battery status: {s}", .{status});
            break :blk '?';
        };
        const charge_percentage = (now * 100) / full;
        try writer.print("{s}: {d:0>3}%{c} ", .{self.name, charge_percentage, status_chr});
    }

    fn add(self: *@This(), writer: anytype) !void {
        while(true) {
            if(self.fds) |fds| {
                self.add_impl(writer, fds) catch |err| {
                    log_error("Got error {!} while reading from {s}", .{err, self.name});
                    fds.now.close();
                    fds.full.close();
                    fds.status.close();
                    self.fds = null;
                };
            }
            if(self.fds == null) {
                self.open() catch break;
                continue;
            }
            return;
        }
        try writer.print("{s}: ERR!! ", .{self.name});
    }

    fn open(self: *@This()) !void {
        var battery_dir = try ps_dir.openDir(self.name, .{});
        defer battery_dir.close();

        inline for(.{"charge", "energy"}) |prefix| blk: {
            const now_file = battery_dir.openFileZ(prefix ++ "_now", .{}) catch break :blk;
            errdefer now_file.close();
            const full_file = battery_dir.openFileZ(prefix ++ "_full", .{}) catch break :blk;
            errdefer full_file.close();
            const status_file = try battery_dir.openFileZ("status", .{});
            self.fds = .{
                .now = now_file,
                .full = full_file,
                .status = status_file,
            };
            return;
        } else {
            log("Could not open any files to get battery charge for battery {s}.\n", .{self.name});
        }
    }
};

const time = @cImport({
    @cInclude("time.h");
});

fn addTime(writer: anytype) !void {
    var buf: [128]u8 = undefined;
    var tim: time.time_t = time.time(null);
    const localtime = time.localtime(&tim) orelse return error.localtime;

    if(time.strftime(&buf, @sizeOf(@TypeOf(buf)) - 1, @ptrCast(build_options.time_format), localtime) == 0)
        return error.strftime;

    try writer.print("{s} ", .{buf[0..std.mem.indexOfScalar(u8, &buf, 0).?]});
}

fn readFileString(file: std.fs.File, buffer: []u8) ![]u8 {
    return buffer[0..(try file.preadAll(buffer, 0)) - 1];
}

fn readFileUnsigned(comptime T: type, file: std.fs.File, buffer: []u8) !T {
    return try std.fmt.parseUnsigned(T, try readFileString(file, buffer), 10);
}

const stdlib = @cImport({
    @cInclude("stdlib.h");
});

// These are the chars that spin around at the end
const spin_chars = "|/-\\";
var current_spin_char: usize = 0;

fn spin() u8 {
    current_spin_char += 1;
    if(current_spin_char == spin_chars.len) {
        current_spin_char = 0;
    }
    return spin_chars[current_spin_char];
}

const x_c = @cImport({
    @cInclude("X11/Xlib.h");
});

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, n: ?usize) noreturn {
    _ = st;
    _ = n;
    log("PANIC: {s}", .{msg});
    std.os.linux.exit(1);
}

pub fn main() !void {
    if(std.fs.openFileAbsoluteZ("/root/dwmstatus_log.txt", .{.mode = .write_only})) |file| {
        error_log = file;
    }
    else |_| { }

    if(build_options.time_zone) |tz| {
        _ = stdlib.setenv("TZ", tz.ptr, 1);
    }

    procstat_file = try std.fs.openFileAbsolute("/proc/stat", .{});
    procmeminfo_file = try std.fs.openFileAbsolute("/proc/meminfo", .{});

    const display = x_c.XOpenDisplay(null);
    const root_window = x_c.XDefaultRootWindow(display);

    var batteries = std.ArrayListUnmanaged(Battery){};
    ps_dir = try std.fs.openDirAbsoluteZ("/sys/class/power_supply", .{.iterate = true});
    {
        var it = ps_dir.iterate();
        while(try it.next()) |dent| {
            if(!std.mem.startsWith(u8, dent.name, "BAT")) continue;
            for(dent.name[3..]) |chr| {
                if(!std.ascii.isDigit(chr)) continue;
            }

            var bat = Battery{
                .name = dent.name,
                .fds = null,
            };
            bat.open() catch continue;
            try batteries.append(std.heap.c_allocator, .{
                .name = try std.heap.c_allocator.dupeZ(u8, dent.name),
                .fds = bat.fds,
            });
        }
    }

    while(true) {
        var buffer: [128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try addCPUUsage(&writer);
        try addMemoryUsage(&writer);
        for(batteries.items) |*bat| {
            try bat.add(&writer);
        }
        try addTime(&writer);
        try writer.writeByte(spin());

        buffer[stream.getWritten().len] = 0;

        _ = x_c.XStoreName(display, root_window, &buffer[0]);
        _ = x_c.XSync(display, 0);

        std.time.sleep(1_000_000_000);
    }
}
