const std = @import("std");

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

var battery_dir: ?std.fs.Dir = null;

var last_stat = Procstat{.idle = 1, .sum = 1};

fn addCPUUsage(writer: anytype) !void {
    const current = try readProcstat();

    const time_delta = current.sum - last_stat.sum;
    const idle_delta = current.idle - last_stat.idle;

    const work_delta = time_delta - idle_delta;

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
        info.totalram = 0;
        info.freeram = 1;
    }

    try writer.print("Mem: {d:0>3}% ", .{((info.totalram - info.freeram) * 100)/info.totalram});
}

const time = @cImport({
    @cInclude("time.h");
});

fn addTime(writer: anytype) !void {
    var buf: [128]u8 = undefined;
    var tim: time.time_t = time.time(null);
    var localtime: *time.struct_tm = time.localtime(&tim) orelse return error.localtime;

    if(time.strftime(&buf, @sizeOf(@TypeOf(buf)) - 1, "Week %V, %a %d %b %H:%M:%S %Y", localtime) == 0)
        return error.strftime;

    try writer.print("{s} ", .{buf[0..std.mem.indexOfScalar(u8, &buf, 0) orelse unreachable]});
}

fn readFileString(file: std.fs.File, buffer: []u8) ![]u8 {
    return buffer[0..try file.preadAll(buffer, 0)];
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
    _ = stdlib.setenv("TZ", "Europe/Stockholm", 1);

    procstat_file = try std.fs.openFileAbsolute("/proc/stat", .{});

    setup();

    while(true) {
        var buffer: [128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try addCPUUsage(&writer);
        try addMemoryUsage(&writer);
        try addTime(&writer);
        try writer.writeByte(spin());

        std.log.info("Result: '{s}'", .{stream.getWritten()});

        buffer[stream.getWritten().len] = 0;

        set_title(&buffer);

        std.time.sleep(1_000_000_000);
    }
}

// char *readfile(char *base, char *file){
//   char *path, line[513];
//   FILE *fd;

//   memset(line, 0, sizeof(line));

//   path = smprintf("%s/%s", base, file);
//   fd = fopen(path, "r");
//   free(path);
//   if (fd == NULL)
//     return NULL;

//   if (fgets(line, sizeof(line)-1, fd) == NULL)
//     return NULL;
//   fclose(fd);

//   return smprintf("%s", line);
// }

// char *getbattery() {
//   char *co, *status, *base;
//   int descap, remcap;

//   base = BATPATH;

//   descap = -1;
//   remcap = -1;

//   co = readfile(base, "present");
//   if (co == NULL)
//     return smprintf("");
//   if (co[0] != '1') {
//     free(co);
//     return smprintf("not present");
//   }
//   free(co);
//   co = readfile(base, "charge_full");
//   if (co == NULL) {
//     co = readfile(base, "energy_full");
//     if (co == NULL)
//       return smprintf(" BAT_ERR2");
//   }
//   sscanf(co, "%d", &descap);
//   free(co);

//   co = readfile(base, "charge_now");
//   if (co == NULL) {
//     co = readfile(base, "energy_now");
//     if (co == NULL)
//       return smprintf(" BAT_ERR3");
//   }
//   sscanf(co, "%d", &remcap);
//   free(co);

//   co = readfile(base, "status");
//   if (!strncmp(co, "Discharging", 11)) {
//     status = "-";
//   } else if(!strncmp(co, "Charging", 8)) {
//     status = "+";
//   } else if(!strncmp(co, "Full", 4)) {
//     status = "^";
//   } else {
//     status = "!";
//   }

//   if (remcap < 1 || descap < 1)
//     return smprintf(" Bat: invalid");

//   return smprintf(" Bat: %03d%%%s", ((remcap*100) / descap), status);
// }
