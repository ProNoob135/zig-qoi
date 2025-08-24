const std = @import("std");

pub const Header = extern struct {
    magic: [4]u8 = .{ 'q', 'o', 'i', 'f' },
    width: u32 align(1),
    height: u32 align(1),
    channels: u8 = 4,
    colorspace: u8 = 0,
};

pub fn write(reader: anytype, writer: anytype, header: Header) !void {
    if (@as(u32, @bitCast(header.magic)) != @as(u32, @bitCast(@as([4]u8, "qoif".*)))) {
        return error.InvalidInput;
    }
    switch(header.channels) {
        3, 4 => {},
        else => return error.InvalidInput,
    }
    switch(header.colorspace) {
        0, 1 => {},
        else => return error.InvalidInput,
    }
    try writer.writeStructEndian(header, std.builtin.Endian.big);

    // Previous pixel and hash table must be initialized to 0
    var prev_rgba = [4]u8{ 0, 0, 0, 255 };
    var hash_table = [_][4]u8{[_]u8{0} ** 4} ** 64;

    var run: u8 = 0;
    var index: u64 = 0;
    while (index < @as(u64, header.width) * @as(u64, header.height)) : (index += 1) {
        const current_rgba: [4]u8 = switch (header.channels) {
            3 => try reader.readBytesNoEof(3) ++ .{255},
            4 => try reader.readBytesNoEof(4),
            else => unreachable,
        };

        // QOI_OP_RUN
        if (@as(u32, @bitCast(current_rgba)) == @as(u32, @bitCast(prev_rgba))) {
            run += 1;
            if (run == 62) {
                try writer.writeByte(192 | (run - 1));
                run = 0;
            }
            continue;
        } else if (run != 0) {
            try writer.writeByte(192 | (run - 1));
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
            try writer.writeAll(&(.{255} ++ current_rgba));
            continue;
        }

        // Remove alpha channel going forward as it's irrelevant
        const current_rgb = current_rgba[0..3].*;
        const prev_rgb = prev_rgba[0..3].*;

        // calculate difference once
        const difference = .{
            current_rgb[0] -% prev_rgb[0],
            current_rgb[1] -% prev_rgb[1],
            current_rgb[2] -% prev_rgb[2],
        };

        // QOI_OP_DIFF
        const difference_u2 = .{
            difference[0] +% 2,
            difference[1] +% 2,
            difference[2] +% 2,
        };
        if (difference_u2[0] < 4 and difference_u2[1] < 4 and difference_u2[2] < 4) {
            try writer.writeByte(64 | (difference_u2[0] << 4) | (difference_u2[1] << 2) | difference_u2[2]);
            continue;
        }

        // QOI_OP_LUMA
        const difference_luma: [3]u8 = .{
            difference[0] -% difference[1] +% 8,
            difference[1] +% 32,
            difference[2] -% difference[1] +% 8,
        };
        if (difference_luma[0] < 16 and difference_luma[1] < 64 and difference_luma[2] < 16 ) {
            try writer.writeAll(&(.{128 | difference_luma[1], (difference_luma[0] << 4) | difference_luma[2]}));
            continue;
        }

        // QOI_OP_RGB (if all compression attempts have failed)
        try writer.writeAll(&(.{254} ++ current_rgb));
        continue;
    }
    // Finish any incomplete runs
    if (run != 0) {
        try writer.writeByte(192 | (run - 1));
        run = 0;
    }

    // Write terminator
    try writer.writeInt(u64, 1, std.builtin.Endian.big);
}

pub fn read(reader: anytype, writer: anytype) !Header {
    const header = try reader.readStructEndian(Header, .big);
    if (@as(u32, @bitCast(header.magic)) != @as(u32, @bitCast(@as([4]u8, "qoif".*)))) {
        return error.InvalidInput;
    }
    switch(header.channels) {
        3, 4 => {},
        else => return error.InvalidInput,
    }
    switch(header.colorspace) {
        0, 1 => {},
        else => return error.InvalidInput,
    }

    // Previous pixel and hash table must be initialized to 0
    var prev_rgba = [4]u8{ 0, 0, 0, 255 };
    var hash_table = [_][4]u8{[_]u8{0} ** 4} ** 64;

    var index: u64 = 0;
    while (index < @as(u64, header.width) * @as(u64, header.height)) {
        var current_rgba: [4]u8 = undefined;
        const tag_byte = try reader.readByte();
        block: {
            switch(tag_byte) {
                // QOI_OP_INDEX
                0...63 => {
                    index += 1;
                    current_rgba = hash_table[tag_byte];
                    // Updating hash table is unecessary as there are no new colors.
                    break :block;
                },
                // QOI_OP_DIFF
                64...127 => {
                    index += 1;
                    const difference = [3]u8{
                        ((tag_byte >> 4) & 3) -% 2,
                        ((tag_byte >> 2) & 3) -% 2,
                        (tag_byte & 3) -% 2,
                    };
                    current_rgba = .{
                        prev_rgba[0] +% difference[0],
                        prev_rgba[1] +% difference[1],
                        prev_rgba[2] +% difference[2],
                        prev_rgba[3],
                    };
                },
                // QOI_OP_LUMA
                128...191 => {
                    index += 1;
                    // Red and Blue must include Green bias.
                    const bias: [3]u8 = .{ 40, 32, 40 };
                    const next_byte = try reader.readByte();
                    const biased_g_difference = tag_byte & 63;
                    const biased_rb_difference = [2]u8{ (next_byte >> 4) & 15, next_byte & 15 };
                    const difference = .{
                        (biased_rb_difference[0] +% biased_g_difference) -% bias[0],
                        biased_g_difference -% bias[1],
                        (biased_rb_difference[1] +% biased_g_difference) -% bias[2],
                    };
                    current_rgba = .{
                        prev_rgba[0] +% difference[0],
                        prev_rgba[1] +% difference[1],
                        prev_rgba[2] +% difference[2],
                        prev_rgba[3],
                    };
                },
                // QOI_OP_RUN
                192...253 => {
                    const run = (tag_byte & 63) + 1;
                    index += run;
                    // Skip default write and write run all at once
                    switch (header.channels) {
                        3 => try writer.writeBytesNTimes(prev_rgba[0..3], run),
                        4 => try writer.writeBytesNTimes(&prev_rgba, run),
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
            }

            const hash_index: u8 = @mod(current_rgba[0] *% 3 +% current_rgba[1] *% 5 +% current_rgba[2] *% 7 +% current_rgba[3] *% 11, 64);
            hash_table[hash_index] = current_rgba;
        }
        prev_rgba = current_rgba;

        switch (header.channels) {
            3 => try writer.writeAll(current_rgba[0..3]),
            4 => try writer.writeAll(&current_rgba),
            else => unreachable,
        }
    }
    return header;
}

