const std = @import("std");
const builtin = @import("builtin");

const QoiHeader = extern struct {
    magic: [4]u8 = .{ 'q', 'o', 'i', 'f' },
    width: u32 align(1),
    height: u32 align(1),
    channels: u8 = 4,
    colorspace: u8 = 0,
};

pub fn qoiWrite(reader: anytype, writer: anytype, header: QoiHeader) !void {
    try writer.writeStructEndian(header, std.builtin.Endian.big);

    // Previous pixel and hash table must be initialized to 0
    var prev_rgba = @Vector(4, u8){ 0, 0, 0, 255 };
    var hash_table = [_]@Vector(4, u8){@as(@Vector(4, u8), @splat(0))} ** 64;

    var run: u8 = 0;
    for (0..header.width * header.height) |_| {
        const current_rgba: @Vector(4, u8) = switch (header.channels) {
            3 => try reader.readBytesNoEof(3) ++ .{255},
            4 => try reader.readBytesNoEof(4),
            else => unreachable,
        };

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

        // Wait until current_rgba changes to update previous pixel, and don't do it until it's done being used
        defer prev_rgba = current_rgba;

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
            try writer.writeAll(&(.{255} ++ @as([4]u8, current_rgba)));
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
        if (@reduce(.And, difference_luma < @Vector(3, u8){ 16, 64, 16 })) {
            //try writer.writeByte(128 + difference_luma[1]);
            //try writer.writeByte((difference_luma[0] << 4) + difference_luma[2]);
            try writer.writeAll(&(.{128 + difference_luma[1], (difference_luma[0] << 4) + difference_luma[2]}));
            continue;
        }

        // QOI_OP_RGB (if all compression attempts have failed)
        try writer.writeAll(&(.{254} ++ @as([3]u8, current_rgb)));
        continue;
    }
    // Finish any incomplete runs
    if (run != 0) {
        try writer.writeByte(192 + (run - 1));
        run = 0;
    }

    // Write terminator
    try writer.writeInt(u64, 1, std.builtin.Endian.big);
}

fn qoiRead(reader: anytype, writer: anytype) !void {
    const header = try reader.readStructEndian(QoiHeader, .big);
    std.debug.print("{any}\n", .{header});

    // Previous pixel and hash table must be initialized to 0
    var prev_rgba = @Vector(4, u8){ 0, 0, 0, 255 };
    var hash_table = [_]@Vector(4, u8){ .{ 0, 0, 0, 255} } ** 64;

    var index: u64 = 0;
    while (index < header.width * header.height) {

        var current_rgba: @Vector(4, u8) = undefined;
        const tag_byte = try reader.readByte();
        switch(tag_byte) {
            // QOI_OP_INDEX
            0...63 => {
                index += 1;
                current_rgba = hash_table[tag_byte];
                switch (header.channels) {
                    3 => try writer.writeAll(@as([4]u8, current_rgba)[0..3]),
                    4 => try writer.writeAll(&@as([4]u8, current_rgba)),
                    else => unreachable,
                }
                prev_rgba = current_rgba;
                // Updating hash table is unecessary as there are no new colors.
                continue;
            },
            // QOI_OP_DIFF
            64...127 => {
                index += 1;
                const mask: @Vector(4, u2) = .{ 3, 3, 3, 0 };
                const bias: @Vector(4, u2) = .{ 2, 2, 2, 0 };
                const difference = (@Vector(4, u8){ (tag_byte >> 4), (tag_byte >> 2), tag_byte, 0} & mask) -% bias;
                current_rgba = prev_rgba +% difference;
            },
            // QOI_OP_LUMA
            128...191 => {
                index += 1;
                const mask: @Vector(4, u6) = .{ 15, 63, 15, 0 };
                // Red and Blue must include green bias.
                const bias: @Vector(4, u6) = .{ 40, 32, 40, 0 };
                const next_byte = try reader.readByte();
                const biased_green_difference = tag_byte & 63;
                const difference = (@Vector(4, u8){ (next_byte >> 4), biased_green_difference, next_byte, 0 } & mask) +% @Vector(4, u8){ biased_green_difference, 0, biased_green_difference, 0 } -% bias;
                current_rgba = prev_rgba +% difference;
            },
            // QOI_OP_RUN
            192...253 => {
                const run = (tag_byte & 63) + 1;
                index += run;
                switch (header.channels) {
                    3 => try writer.writeBytesNTimes(@as([4]u8, prev_rgba)[0..3], run),
                    4 => try writer.writeBytesNTimes(&@as([4]u8, prev_rgba), run),
                    else => unreachable,
                }
                // Updating hash table and previous color is unecessary as there are no new colors.
                continue;
            },
            // QOI_OP_RGB
            254 => {
                index += 1;
                current_rgba = try reader.readBytesNoEof(3) ++ .{prev_rgba[3]};
            },
            // QOI_OP_RGBA
            255 => {
                index += 1;
                current_rgba = try reader.readBytesNoEof(4);
            },
            //else => {
            //    index += 1;
            //    current_rgba = .{ 128, 128, 128, 255};
            //},
        }
        switch (header.channels) {
            3 => try writer.writeAll(@as([4]u8, current_rgba)[0..3]),
            4 => try writer.writeAll(&@as([4]u8, current_rgba)),
            else => unreachable,
        }
        prev_rgba = current_rgba;

        const hash_index: u8 = @mod(current_rgba[0] *% 3 +% current_rgba[1] *% 5 +% current_rgba[2] *% 7 +% current_rgba[3] *% 11, 64);
        hash_table[hash_index] = current_rgba;
    }
}

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
    
    var write = false;
    var qoi_header: QoiHeader = undefined;
    if (std.mem.eql(u8, input_path[input_path.len-4..][0..4], ".raw")) {
        write = true;
        qoi_header = .{
             .width = std.fmt.parseInt(u32, args.next() orelse printHelp(), 10) catch printHelp(),
             .height = std.fmt.parseInt(u32, args.next() orelse printHelp(), 10) catch printHelp(),
             .channels = std.fmt.parseInt(u3, args.next() orelse printHelp(), 10) catch printHelp(),
             .colorspace = std.fmt.parseInt(u1, args.next() orelse printHelp(), 10) catch printHelp(),
        };
        if (qoi_header.channels < 3 or qoi_header.channels > 4 or qoi_header.colorspace < 0 or qoi_header.colorspace > 1) printHelp();
    }

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

    switch(write) {
        true => try qoiWrite(&buffered_input_image.reader(), &buffered_output_image.writer(), qoi_header),
        false => try qoiRead(&buffered_input_image.reader(), &buffered_output_image.writer()),
    }

    try buffered_output_image.flush();
}
