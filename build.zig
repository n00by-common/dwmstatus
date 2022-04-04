const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const exe = b.addExecutable("dwmstatus", "dwmstatus.zig");
    exe.linkSystemLibrary("X11");
    exe.addLibPath("/usr/lib");
    exe.addCSourceFile("dwmstatus.c", &.{});
    exe.linkLibC();
    exe.install();
}
