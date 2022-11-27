const std = @import("std");

const build_options = @import("build_options");

extern fn setup() void;
extern fn set_title([*]const u8) void;

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

var bat_now: std.fs.File = undefined;
var bat_full: std.fs.File = undefined;
var bat_status: std.fs.File = undefined;

fn addBattery(writer: anytype) !void {
    if(comptime(build_options.battery_path == null))
        return;

    var buffer: [128]u8 = undefined;
    const charge_now = try readFileUnsigned(usize, bat_now, &buffer);
    const charge_full = try readFileUnsigned(usize, bat_full, &buffer);

    const battery_status_chr: u8 = blk: {
        const battery_status = try readFileString(bat_status, &buffer);

        if(std.mem.eql(u8, battery_status, "Discharging"))
            break :blk '-';

        if(std.mem.eql(u8, battery_status, "Charging"))
            break :blk '+';

        if(std.mem.eql(u8, battery_status, "Full"))
            break :blk '^';

        std.log.debug("Unknown battery status: {s}", .{battery_status});
        break :blk '?';
    };

    const charge_percentage = (charge_now * 100) / charge_full;

    try writer.print("Bat: {d:0>3}%{c} ", .{charge_percentage, battery_status_chr});
}

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

pub fn main() !void {
    if(build_options.time_zone) |tz| {
        _ = stdlib.setenv("TZ", tz.ptr, 1);
    }

    procstat_file = try std.fs.openFileAbsolute("/proc/stat", .{});

    setup();

    if(comptime(build_options.battery_path)) |bpath| {
        var battery_dir = try std.fs.openDirAbsolute(bpath, .{});
        defer battery_dir.close();

        bat_now = try battery_dir.openFileZ("charge_now", .{});
        bat_full = try battery_dir.openFileZ("charge_full", .{});
        bat_status = try battery_dir.openFileZ("status", .{});
    }

    while(true) {
        var buffer: [128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try addCPUUsage(&writer);
        try addMemoryUsage(&writer);
        try addBattery(&writer);
        try addTime(&writer);
        try writer.writeByte(spin());

        std.log.info("Result: '{s}'", .{stream.getWritten()});

        buffer[stream.getWritten().len] = 0;

        set_title(&buffer);

        std.time.sleep(1_000_000_000);
    }
}
