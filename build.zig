const std = @import("std");

pub fn build(b: *std.Build) !void {
    const exe = b.addExecutable(.{
        .name = "dwmstatus",
        .root_source_file = .{.path = "dwmstatus.zig"},
        .target = b.standardTargetOptions(.{}),
        .optimize = .ReleaseSmall,
    });
    exe.linkSystemLibrary("X11");
    exe.addLibraryPath(.{.path = "/usr/lib"});

    const time_format: [:0]const u8 = blk: {
        const user_input = b.option([]const u8, "time_format", "Format for time, same format as strftime");
        if(user_input) |ui| {
            if(ui.len > 0)
                break :blk try b.allocator.dupeZ(u8, ui);
        }
        break :blk "Week %V, %a %d %b %H:%M:%S %Y";
    };

    const time_zone: ?[:0]const u8 = blk: {
        const user_input = b.option([]const u8, "time_zone", "Timezone for local time");
        if(user_input) |ui| {
            if(ui.len > 0)
                break :blk try b.allocator.dupeZ(u8, ui);
        }
        break :blk null;
    };

    const opts = b.addOptions();
    opts.addOption([:0]const u8, "time_format", time_format);
    opts.addOption(?[:0]const u8, "time_zone", time_zone);

    exe.root_module.addOptions("build_options", opts);

    exe.linkLibC();
    b.installArtifact(exe);
}
