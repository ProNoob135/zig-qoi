const std = @import("std");
const builtin = @import("builtin");

const QoiHeader = extern struct {
    magic: [4]u8 = .{'q', 'o', 'i', 'f'},
    width: u32 align(1),
    height: u32 align(1),
    channels: u8 = 4,
    colorspace: u8 = 0,
};

pub fn qoiWrite(reader: anytype, writer: anytype, header: QoiHeader) !void {
    try writer.writeStructEndian(header, std.builtin.Endian.big);

    // Previous pixel and hash table must be initialized to 0
    var prev_rgba = @Vector(4, u8){0, 0, 0, 255};
    var hash_table = [_]@Vector(4, u8){@as(@Vector(4, u8), @splat(0))} ** 64;

    var run: u8 = 0;
    for (0..header.width * header.height) |_| {
        const current_rgba: @Vector(4, u8) = switch(header.channels) {
            3 => ((try reader.readBoundedBytes(3)).slice()[0..3] ++ .{255}).*,
            4 => (try reader.readBoundedBytes(4)).slice()[0..4].*,
            else => unreachable,
        };
        defer prev_rgba = current_rgba;

        // QOI_OP_RUN
        if (@as(u32, @bitCast(current_rgba)) == @as(u32, @bitCast(prev_rgba))) {
            run += 1;
            if (run == 62) {
                try writer.writeByte(192 + (run - 1));
                run = 0;
            }
            continue;
        } else if (run != 0) {
            try writer.writeByte(192 + (run - 1));
            run = 0;
        }

        // If pixel has changed, the hash must always be calculated, so may as well do it now
        const hash_index: u8 = @mod(current_rgba[0] *% 3 +% current_rgba[1] *% 5 +% current_rgba[2] *% 7 +% current_rgba[3] *% 11, 64);
        // QOI_OP_INDEX
        if (@as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(current_rgba))), @bitCast(current_rgba)) == @as(u32, @bitCast(hash_table[hash_index]))) {
            try writer.writeByte(hash_index);    
            continue;
        } else {
            hash_table[hash_index] = current_rgba;
        }

        // QOI_OP_RGBA (must be used if alpha has changed)
        if (current_rgba[3] != prev_rgba[3]) {
            _ = try writer.write( &(.{255} ++ @as([4]u8, current_rgba)) );
            continue;
        }

        // Remove alpha channel going forward as it's irrelevant
        const current_rgb: @Vector(3, u8) = @as([4]u8, current_rgba)[0..3].*;
        const prev_rgb: @Vector(3, u8) = @as([4]u8, prev_rgba)[0..3].*;

        // calculate difference once
        const difference = (current_rgb -% prev_rgb);

        // QOI_OP_DIFF
        const difference_u2 = difference +% @as(@Vector(3, u8), @splat(2));
        if (@reduce(.Max, difference_u2) < 4) {
            try writer.writeByte(64 + (difference_u2[0] << 4) + (difference_u2[1] << 2) + difference_u2[2]);
            continue;
        }

        // QOI_OP_LUMA
        const difference_luma: @Vector(3, u8) = .{
            difference[0] -% difference[1] +% 8,
            difference[1] +% 32,
            difference[2] -% difference[1] +% 8,
        };
        if (@reduce(.And, difference_luma < @Vector(3, u8){16, 64, 16})) {
            try writer.writeByte(128 + difference_luma[1]);
            try writer.writeByte((difference_luma[0] << 4) + difference_luma[2]);
            continue;
        }
        
        // QOI_OP_RGB (if all compression attempts have failed)
        _ = try writer.write( &(.{254} ++ @as([3]u8, current_rgb)) );
        continue;
    }
    // Finish any incomplete runs
    if (run != 0) {
        try writer.writeByte(192 + (run - 1));
        run = 0;
    }

    // Write terminator
    _ = try writer.writeInt(u64, 1, std.builtin.Endian.big);
}

pub fn main() !void {
    var args: std.process.ArgIterator = undefined;
    if (builtin.os.tag == .windows) {
        args = try std.process.argsWithAllocator(std.heap.page_allocator);
    } else {
        args = std.process.args();
    }
    _ = args.skip();
    var argSlices = [_][:0]const u8{undefined} ** 6;
    for (&argSlices) |*arg| {
        if (args.next()) |next_arg| {
            arg.* = next_arg;
        } else {
            std.debug.print("Usage: qoi <input path> <width> <height> <channels (3,4)> <colorspace (0, 1)> <output path>\n", .{});
            return;
        }
    }
    const input_path = argSlices[0];
    const width = try std.fmt.parseInt(u32, argSlices[1], 10);
    const height = try std.fmt.parseInt(u32, argSlices[2], 10);
    const channels = try std.fmt.parseInt(u3, argSlices[3], 10);
    const colorspace = try std.fmt.parseInt(u1, argSlices[4], 10);
    const output_path = argSlices[5];

    const input_image = try std.fs.cwd().openFile(input_path, .{.mode = .read_only});
    const input_image_reader = input_image.reader();
    var buffered_input_image = std.io.bufferedReader(input_image_reader);

    const output_image = try std.fs.cwd().createFile(output_path, .{});
    defer output_image.close();
    const output_image_writer = output_image.writer();
    var buffered_output_image = std.io.bufferedWriter(output_image_writer);

    try qoiWrite(&buffered_input_image.reader(), &buffered_output_image.writer(), .{ .width = width, .height = height, .channels = channels, .colorspace = colorspace});
    
    try buffered_output_image.flush();
}
