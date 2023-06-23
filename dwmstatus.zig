const std = @import("std");

const build_options = @import("build_options");

const Procstat = struct {
    idle: u64,
    sum: u64,
};

var procstat_file: std.fs.File = undefined;

fn readProcstat() !Procstat {
    var buffer: [1024]u8 = undefined;
    const data = buffer[0..try procstat_file.preadAll(&buffer, 0)];

    var result: Procstat = undefined;
    var it = std.mem.tokenize(u8, data, " \n\t");

    _ = it.next() orelse unreachable; // cpuname
    result.sum = 0;
    result.sum += try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // user
    result.sum += try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // nice
    result.sum += try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // system
    result.idle = try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // idle
    result.sum += try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // iowait
    result.sum += try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // irq
    result.sum += try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // softirq
    result.sum += try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // steal
    result.sum += try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // guest
    result.sum += try std.fmt.parseUnsigned(usize, it.next() orelse unreachable, 10); // guest_nice

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

const sysinfo = @cImport({
    @cInclude("sys/sysinfo.h");
});

fn addMemoryUsage(writer: anytype) !void {
    var info: sysinfo.struct_sysinfo = undefined;
    if(sysinfo.sysinfo(&info) < 0) {
        try writer.print("Mem: !!!%", .{});
        return;
    }

    try writer.print("Mem: {d:0>3}% ", .{((info.totalram - info.freeram) * 100)/info.totalram});
}

const Battery = struct {
    name: []const u8,
    now_file: std.fs.File,
    full_file: std.fs.File,
    status_file: std.fs.File,

    fn add(self: @This(), writer: anytype) !void {
        var buffer: [128]u8 = undefined;
        const now = try readFileUnsigned(usize, self.now_file, &buffer);
        const full = try readFileUnsigned(usize, self.full_file, &buffer);
        const status_chr: u8 = blk: {
            const status = try readFileString(self.status_file, &buffer);
            if(std.mem.eql(u8, status, "Discharging"))
                break :blk '-';

            if(std.mem.eql(u8, status, "Charging"))
                break :blk '+';

            if(std.mem.eql(u8, status, "Full"))
                break :blk '^';

            std.log.debug("Unknown battery status: {s}", .{status});
            break :blk '?';
        };
        const charge_percentage = (now * 100) / full;

        try writer.print("{s}: {d:0>3}%{c} ", .{self.name, charge_percentage, status_chr});
    }
};

const time = @cImport({
    @cInclude("time.h");
});

fn addTime(writer: anytype) !void {
    var buf: [128]u8 = undefined;
    var tim: time.time_t = time.time(null);
    var localtime: *time.struct_tm = time.localtime(&tim) orelse return error.localtime;

    if(time.strftime(&buf, @sizeOf(@TypeOf(buf)) - 1, @ptrCast([*c]const u8, build_options.time_format), localtime) == 0)
        return error.strftime;

    try writer.print("{s} ", .{buf[0..std.mem.indexOfScalar(u8, &buf, 0) orelse unreachable]});
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

pub fn main() !void {
    if(build_options.time_zone) |tz| {
        _ = stdlib.setenv("TZ", tz.ptr, 1);
    }

    procstat_file = try std.fs.openFileAbsolute("/proc/stat", .{});

    const display = x_c.XOpenDisplay(null);
    const root_window = x_c.XDefaultRootWindow(display);

    var batteries = std.ArrayListUnmanaged(Battery){};
    var battery_data_buffer: [0x1000]u8 = undefined;
    {
       var battery_allocator = std.heap.FixedBufferAllocator.init(&battery_data_buffer);
       var ps_dir = try std.fs.openIterableDirAbsoluteZ("/sys/class/power_supply", .{});
       defer ps_dir.close();
       var it = ps_dir.iterate();
       while(try it.next()) |dent| {
           if(!std.mem.eql(u8, dent.name[0..3], "BAT")) continue;
           for(dent.name[3..]) |chr| {
               if(!std.ascii.isDigit(chr)) continue;
           }

           var battery_dir = try ps_dir.dir.openDir(dent.name, .{});
           defer battery_dir.close();

           outer: { inline for(.{"charge", "energy"}) |prefix| blk: {
               const now_file = battery_dir.openFileZ(prefix ++ "_now", .{}) catch break :blk;
               const full_file = battery_dir.openFileZ(prefix ++ "_full", .{}) catch break :blk;
               const status_file = try battery_dir.openFileZ("status", .{});
               try batteries.append(battery_allocator.allocator(), .{
                   .name = try battery_allocator.allocator().dupe(u8, dent.name),
                   .now_file = now_file,
                   .full_file = full_file,
                   .status_file = status_file,
               });
               break :outer;
           } else {
               std.log.err("Could not open any files to get battery charge for battery {s}.\n", .{dent.name});
           }}
       }
    }

    while(true) {
        var buffer: [128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try addCPUUsage(&writer);
        try addMemoryUsage(&writer);
        for(batteries.items) |bat| {
            try bat.add(&writer);
        }
        try addTime(&writer);
        try writer.writeByte(spin());

        std.log.info("Result: '{s}'", .{stream.getWritten()});

        buffer[stream.getWritten().len] = 0;

        _ = x_c.XStoreName(display, root_window, &buffer[0]);
        _ = x_c.XSync(display, 0);

        std.time.sleep(1_000_000_000);
    }
}
