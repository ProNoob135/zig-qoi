const std = @import("std");
const png = @cImport({
    @cInclude("png.h");
});

const QoiHeader = extern struct {
    magic: [4]u8 = .{'q', 'o', 'i', 'f'},
    width: u32 align(1),
    height: u32 align(1),
    channels: u8 = 3,
    colorspace: u8 = 0,
};

pub fn loadPng(path: [:0]const u8) !struct {png.png_image, []u8} {
    var input_png: png.png_image = .{.version = png.PNG_IMAGE_VERSION};

    if (png.png_image_begin_read_from_file(&input_png, @ptrCast(path)) == 0) {
        std.debug.print("LibPNG error: \"{s}\"\n", .{input_png.message});
        return error.FailedImageLoad;
    }

    input_png.format = png.PNG_FORMAT_RGBA;
    
    const buffer = try std.heap.c_allocator.alloc(u8, 4 * input_png.width * input_png.height);

    if (png.png_image_finish_read(&input_png, null, @ptrCast(buffer), 0, null) != 1) {
        std.debug.print("LibPNG error: \"¯\\_(ツ)_/¯\"\n", .{});
        return error.FailedImageRead;
    }

    return .{input_png, buffer};
}

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.c_allocator);
    _ = args.skip();
    const input_path = args.next();
    const output_path = args.next();
    if (input_path == null or output_path == null or args.next() != null) {
        std.debug.print("Usage: qoi <input path> <output path>\n", .{});
        return;
    }

    const input_png, const input_data = loadPng(input_path.?) catch return;

    const header: QoiHeader = .{.width = input_png.width, .height = input_png.height};

    const output_image = try std.fs.createFileAbsolute(output_path.?, .{});
    defer output_image.close();
    const output_writer = output_image.writer();
    var buffered_output_image = std.io.bufferedWriter(output_writer);
    const buffered_output_writer = buffered_output_image.writer();

    try buffered_output_writer.writeStructEndian(header, std.builtin.Endian.big);

    var prev_rgba = @Vector(4, u8){0, 0, 0, 255};
    var hash_table = [_]@Vector(4, u8){@as(@Vector(4, u8), @splat(0))} ** 64;

    var has_alpha = false;
    var input_index: u32 = 0;
    var run: u8 = 0;
    for (0..header.width) |_| {
        for (0..header.height) |_| {
            const current_rgba: @Vector(4, u8) = input_data[input_index..][0..4].*;
            input_index += 4;
            defer prev_rgba = current_rgba;

            if (@as(u32, @bitCast(current_rgba)) == @as(u32, @bitCast(prev_rgba))) {
                run += 1;
                if (run == 62) {
                    try buffered_output_writer.writeByte(192 + (run - 1));
                    run = 0;
                }
                continue;
            } else if (run != 0) {
                try buffered_output_writer.writeByte(192 + (run - 1));
                run = 0;
            }

            const hash_index: u8 = @mod(current_rgba[0] *% 3 +% current_rgba[1] *% 5 +% current_rgba[2] *% 7 +% current_rgba[3] *% 11, 64);
            if (@as(u32, @bitCast(current_rgba)) == @as(u32, @bitCast(hash_table[hash_index]))) {
                try buffered_output_writer.writeByte(hash_index);    
                continue;
            } else {
                hash_table[hash_index] = current_rgba;
            }

            if (current_rgba[3] == prev_rgba[3]) {
                const current_rgb = @Vector(3, u8){current_rgba[0], current_rgba[1], current_rgba[2]};
                const prev_rgb = @Vector(3, u8){prev_rgba[0], prev_rgba[1], prev_rgba[2]};

                const difference = (current_rgb -% prev_rgb);// +% @as(@Vector(3, u8), @splat(2));

                const difference_u2 = difference +% @as(@Vector(3, u8), @splat(2));
                if (@reduce(.Max, difference_u2) < 4) {
                    try buffered_output_writer.writeByte(64 + (difference_u2[0] << 4) + (difference_u2[1] << 2) + difference_u2[2]);
                    continue;
                }

                const difference_luma: @Vector(3, u8) = .{
                    difference[0] -% difference[1] +% 8,
                    difference[1] +% 32,
                    difference[2] -% difference[1] +% 8,
                };
                if (difference_luma[0] < 16 and difference_luma[1] < 64 and difference_luma[2] < 16) {
                    try buffered_output_writer.writeByte(128 + difference_luma[1]);
                    try buffered_output_writer.writeByte((difference_luma[0] << 4) + difference_luma[2]);
                    continue;
                }
                
                _ = try buffered_output_writer.write( &(.{254} ++ @as([3]u8, current_rgb)) );
                continue;
            }

            if (!has_alpha) {
                has_alpha = true;
                try buffered_output_image.flush();
                std.debug.print("{any}\n", .{try output_image.getPos()});
                const value = try output_image.pwrite(&.{4}, 12);
                std.debug.print("{any}\n", .{value});
                std.debug.print("{any}\n", .{try output_image.getPos()});
            }

            _ = try buffered_output_writer.write( &(.{255} ++ @as([4]u8, current_rgba)) );
        }
    }
    if (run != 0) {
        try buffered_output_writer.writeByte(192 + (run - 1));
        run = 0;
    }

    _ = try buffered_output_writer.writeInt(u64, 1, std.builtin.Endian.big);
    try buffered_output_image.flush();
}
