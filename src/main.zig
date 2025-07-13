const std = @import("std");
const builtin = @import("builtin");

const qoi = @import("qoi");

fn printHelp() noreturn {
    std.debug.print("Usage: qoi <input path> <width> <height> <channels (3,4)> <colorspace (0, 1)> <output path>\n", .{});
    std.process.exit(1);
}

pub fn main() !void {
    var args: std.process.ArgIterator = undefined;
    if (builtin.os.tag == .windows) {
        args = try std.process.argsWithAllocator(std.heap.page_allocator);
    } else {
        args = std.process.args();
    }
    _ = args.skip();
    const input_path = args.next() orelse printHelp();
    
    const ToFrom = enum { qoi_to_raw, raw_to_qoi };
    var qoi_header: qoi.Header = undefined;
    var to_from: ToFrom = undefined;
    if (input_path.len >= 4 and @as(u32, @bitCast(input_path[input_path.len-4..][0..4].*)) == @as(u32, @bitCast(@as([4]u8, ".raw".*)))) {
        to_from = .raw_to_qoi;
        qoi_header = .{
             .width = std.fmt.parseInt(u32, args.next() orelse printHelp(), 10) catch printHelp(),
             .height = std.fmt.parseInt(u32, args.next() orelse printHelp(), 10) catch printHelp(),
             .channels = std.fmt.parseInt(u8, args.next() orelse printHelp(), 10) catch printHelp(),
             .colorspace = std.fmt.parseInt(u8, args.next() orelse printHelp(), 10) catch printHelp(),
        };
    } else if (input_path.len >= 4 and @as(u32, @bitCast(input_path[input_path.len-4..][0..4].*)) == @as(u32, @bitCast(@as([4]u8, ".qoi".*)))) {
        to_from = .qoi_to_raw;
    } else printHelp();

    const output_path = args.next() orelse printHelp();
    if (args.skip()) printHelp();

    const input_image = std.fs.cwd().openFile(input_path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("file read error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const input_image_reader = input_image.reader();
    var buffered_input_image = std.io.bufferedReader(input_image_reader);

    const output_image = std.fs.cwd().createFile(output_path, .{}) catch |err| {
        std.debug.print("File write error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer output_image.close();
    const output_image_writer = output_image.writer();
    var buffered_output_image = std.io.bufferedWriter(output_image_writer);

    switch(to_from) {
        .qoi_to_raw => _ = qoi.read(&buffered_input_image.reader(), &buffered_output_image.writer()) catch |err| switch(err) {
                error.InvalidInput => std.debug.print("Not a valid QOI image!\n", .{}),
                else => std.debug.print("File error: {s}\n", .{@errorName(err)}),
            },
        .raw_to_qoi => qoi.write(&buffered_input_image.reader(), &buffered_output_image.writer(), qoi_header) catch |err| switch(err) {
                error.InvalidInput => std.debug.print("Invalid QOI header!\n", .{}),
                else => std.debug.print("File error: {s}\n", .{@errorName(err)}),
            }
    } 

    try buffered_output_image.flush();
}
