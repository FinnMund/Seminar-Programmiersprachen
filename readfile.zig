const std = @import("std");
const Regex = @import("zig-regex/src/regex.zig").Regex;

fn readFile(
    path: []const u8,
    pattern: *Regex,
    color: bool,
    after: usize,
    before: usize,
    no_heading: bool,
    ignore_case: bool,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const cwd = std.fs.cwd();

    // Read the whole file into memory
    // This part is implemented inefficiently because I still don't fully understand the new I/O system that was introduced in Zig 0.15.
    const fileContents = try cwd.readFileAlloc(alloc, path, 256_000_000);
    defer alloc.free(fileContents);

    const RED = "\x1b[31m";
    const Reset = "\x1b[0m";

    // Buffer for storing "before" context lines
    var before_buffer = try alloc.alloc([]const u8, before);
    defer alloc.free(before_buffer);

    var printed_header = false;

    var i: usize = 0;
    var line_start: usize = 0;
    var line_num: u32 = 1;
    var print_after: usize = 0;
    var before_count: usize = 0;

    // Lowercased line (only when ignore-case is enabled)
    var line_lower: ?[]u8 = null;
    defer {
        if (line_lower) |l| alloc.free(l);
    }

    while (i < fileContents.len) : (i += 1) {
        const b = fileContents[i];
        if (b == '\n') {
            const line = fileContents[line_start..i];

            // Store lines for before-context
            if (before > 0) {
                if (before_count < before) {
                    before_buffer[before_count] = line;
                    before_count += 1;
                } else {
                    // Shift left to keep last 'before' lines
                    for (0..(before - 1)) |idx| {
                        before_buffer[idx] = before_buffer[idx + 1];
                    }
                    before_buffer[before - 1] = line;
                }
            }

            var line_to_match: []const u8 = line;

            // Convert line to lowercase if ignore-case is active
            if (ignore_case) {
                if (line_lower) |l| alloc.free(l);
                line_lower = try alloc.dupe(u8, line);

                for (line_lower.?) |*c| c.* = std.ascii.toLower(c.*);
                line_to_match = line_lower.?;
            }

            // Check if the pattern matches
            if (try pattern.partialMatch(line_to_match)) {
                // Print filename header once
                if (!no_heading and !printed_header) {
                    std.debug.print("{s}\n", .{path});
                    printed_header = true;
                }

                // Print before-context lines
                var bi: usize = 0;
                while (bi < before_count) : (bi += 1) {
                    const before_line_num = line_num - before_count + bi;

                    if (no_heading)
                        std.debug.print("{s}:{}- {s}\n", .{ path, before_line_num, before_buffer[bi] })
                    else
                        std.debug.print("{}- {s}\n", .{ before_line_num, before_buffer[bi] });
                }
                before_count = 0;

                // Print matching line
                if (color) {
                    if (no_heading)
                        std.debug.print("{s}:{}: {s}{s}{s}\n", .{ path, line_num, RED, line, Reset })
                    else
                        std.debug.print("{}: {s}{s}{s}\n", .{ line_num, RED, line, Reset });
                } else {
                    if (no_heading)
                        std.debug.print("{s}:{}: {s}\n", .{ path, line_num, line })
                    else
                        std.debug.print("{}: {s}\n", .{ line_num, line });
                }

                print_after = after;
            }
            // Print after-context lines
            else if (print_after > 0) {
                if (no_heading)
                    std.debug.print("{s}:{}: {s}\n", .{ path, line_num, line })
                else
                    std.debug.print("{}: {s}\n", .{ line_num, line });

                print_after -= 1;
            }

            line_start = i + 1;
            line_num += 1;
        }
    }

    // Handle last line (no trailing newline)
    if (line_start < fileContents.len) {
        const line = fileContents[line_start..];

        var line_to_match: []const u8 = line;

        if (ignore_case) {
            if (line_lower) |l| alloc.free(l);
            line_lower = try alloc.dupe(u8, line);

            for (line_lower.?) |*c| c.* = std.ascii.toLower(c.*);
            line_to_match = line_lower.?;
        }

        if (try pattern.partialMatch(line_to_match)) {
            if (!no_heading and !printed_header) {
                std.debug.print("{s}\n", .{path});
            }

            var bi: usize = 0;
            while (bi < before_count) : (bi += 1) {
                const before_line_num = line_num - before_count + bi;

                if (no_heading)
                    std.debug.print("{s}:{}- {s}\n", .{ path, before_line_num, before_buffer[bi] })
                else
                    std.debug.print("{}- {s}\n", .{ before_line_num, before_buffer[bi] });
            }

            if (no_heading)
                std.debug.print("{s}:{}: {s}\n", .{ path, line_num, line })
            else
                std.debug.print("{}: {s}\n", .{ line_num, line });
        }
    }
}

fn searchRe(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    dir: std.fs.Dir,
    pattern: *Regex,
    color: bool,
    after: usize,
    before: usize,
    no_heading: bool,
    is_hidden: bool,
    ignore_case: bool,
) !void {
    // Iterate through directory entries
    var it = dir.iterate();
    while (try it.next()) |entry| {
        // Build full path of file/directory
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                // Skip hidden files unless enabled
                if (!is_hidden and entry.name[0] == '.') continue;
                try readFile(full_path, pattern, color, after, before, no_heading, ignore_case);
            },
            .directory => {
                // Skip "." and ".."
                if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
                if (!is_hidden and entry.name[0] == '.') continue;

                // Open subdirectory
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();

                // Recurse into directory
                try searchRe(allocator, full_path, sub, pattern, color, after, before, no_heading, is_hidden, ignore_case);
            },
            else => {},
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Help option
    if (args.len >= 2) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "-H") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
            // Print usage help
            std.debug.print(
                \\Usage: mygrep [OPTIONS] PATTERN [PATH ...]
                \\Options:
                \\  -A <n>, --after-context <n>    print n lines after match
                \\  -B <n>, --before-context <n>   print n lines before match
                \\  -C <n>, --context <n>          print n lines before AND after
                \\  -c, --color                    print with colors, highlighting the matched phrase in the output
                \\  -h, --hidden                   search hidden files and folders
                \\  -i,--ignore-case               search case insensitive
                \\  --no-heading                   prints a single line including the filename for each match
                \\  -h, --help                     show this help message
            , .{});
            return;
        }
    }

    if (args.len < 2) {
        std.debug.print("Error: missing arguments. Use --help.\n", .{});
        return;
    }

    var color: bool = false;
    var i: usize = 1;
    var after: usize = 0;
    var before: usize = 0;
    var context: usize = 0;
    var pattern: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var no_heading: bool = false;
    var ignore_case: bool = false;
    var is_hidden: bool = false;

    // Parse CLI options
    while (i < args.len) {
        const arg = args[i];

        // After-context
        if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--after-context")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: missing value after -A / --after-context\n", .{});
                return;
            }
            i += 1;
            after = std.fmt.parseInt(usize, args[i], 10) catch {
                std.debug.print("Error: invalid number for -A / --after-context: {s}\n", .{args[i]});
                return;
            };
            std.debug.print("Parsed after-context: {d}\n", .{after});
            i += 1;
            continue;
        }

        // Before-context
        if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--before-context")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: missing value after -B / --before-context\n", .{});
                return;
            }
            i += 1;
            before = std.fmt.parseInt(usize, args[i], 10) catch {
                std.debug.print("Error: invalid number for -B / --before-context: {s}\n", .{args[i]});
                return;
            };
            std.debug.print("Parsed before-context: {d}\n", .{before});
            i += 1;
            continue;
        }

        // Combined context
        if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--context")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: missing value after -C / --context\n", .{});
                return;
            }
            i += 1;
            context = std.fmt.parseInt(usize, args[i], 10) catch {
                std.debug.print("Error: invalid number for -C / --context: {s}\n", .{args[i]});
                return;
            };
            std.debug.print("Parsed context: {d}\n", .{context});
            before = context;
            after = context;
            i += 1;
            continue;
        }

        // Color output
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--color")) {
            color = true;
            i += 1;
            continue;
        }

        // Disable heading
        if (std.mem.eql(u8, arg, "--no-heading")) {
            no_heading = true;
            i += 1;
            continue;
        }

        // Ignore case
        if (std.mem.eql(u8, arg, "--ignore-case") or std.mem.eql(u8, arg, "-i")) {
            ignore_case = true;
            i += 1;
            continue;
        }

        // Show hidden files
        if (std.mem.eql(u8, arg, "--hidden") or std.mem.eql(u8, arg, "-h")) {
            is_hidden = true;
            i += 1;
            continue;
        }

        // First non-option = pattern
        if (pattern == null) {
            pattern = arg;
            std.debug.print("pattern: {s}\n", .{pattern.?});
        }
        // Second non-option = path
        else if (path == null) {
            path = arg;
            std.debug.print("path: {s}\n", .{path.?});
        }

        i += 1;
    }

    // Validate required arguments
    if (pattern == null) {
        std.debug.print("Error: missing PATTERN. Use --help.\n", .{});
        return;
    }
    if (path == null) {
        std.debug.print("Error: missing PATH. Use --help.\n", .{});
        return;
    }

    var regex_pattern: []const u8 = pattern.?;
    var lower_pattern: ?[]u8 = null;

    // Convert the regex pattern to lowercase when ignore-case
    if (ignore_case) {
        lower_pattern = try allocator.dupe(u8, pattern.?);
        for (lower_pattern.?) |*c| c.* = std.ascii.toLower(c.*);
        regex_pattern = lower_pattern.?;
    }

    // Compile the regex
    var regex = try Regex.compile(allocator, regex_pattern);
    defer regex.deinit();

    // Free lowercase pattern buffer
    if (lower_pattern) |l| allocator.free(l);

    var cwd = std.fs.cwd();
    // Open the path (directory)
    var dir = try cwd.openDir(path.?, .{ .iterate = true });
    defer dir.close();

    // Begin searching recursively
    try searchRe(allocator, path.?, dir, &regex, color, after, before, no_heading, is_hidden, ignore_case);
}
