const std = @import("std");

fn expandEnvVars(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "{env.")) {
            if (std.mem.indexOf(u8, input[i..], "}")) |close_pos| {
                const var_name = input[i + 5 .. i + close_pos];
                if (std.process.getEnvVarOwned(allocator, var_name)) |value| {
                    defer allocator.free(value);
                    try result.appendSlice(value);
                } else |_| {
                    // Keep original placeholder if env var not found
                    try result.appendSlice(input[i .. i + close_pos + 1]);
                }
                i += close_pos + 1;
                continue;
            }
        }
        try result.append(input[i]);
        i += 1;
    }
    
    return result.toOwnedSlice();
}

fn findAliasJson(allocator: std.mem.Allocator) ![]u8 {
    // Always look for alias.json in the same directory as the executable
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.AliasJsonNotFound;
    const alias_path = try std.fs.path.join(allocator, &[_][]const u8{ exe_dir, "alias.json" });
    defer allocator.free(alias_path);
    
    const file = std.fs.openFileAbsolute(alias_path, .{}) catch |err| {
        // Try /etc/shelffiles/alias.json as a fallback
        const etc_file = std.fs.openFileAbsolute("/etc/shelffiles/alias.json", .{}) catch return err;
        defer etc_file.close();
        return try etc_file.readToEndAlloc(allocator, 1024 * 1024);
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn parseCommandLine(allocator: std.mem.Allocator, command_line: []const u8) ![][]u8 {
    var args = std.ArrayList([]u8).init(allocator);
    defer args.deinit();
    
    var in_quotes = false;
    var escaped = false;
    var current_arg = std.ArrayList(u8).init(allocator);
    defer current_arg.deinit();
    
    for (command_line) |char| {
        if (escaped) {
            try current_arg.append(char);
            escaped = false;
            continue;
        }
        
        if (char == '\\') {
            escaped = true;
            continue;
        }
        
        if (char == '"') {
            in_quotes = !in_quotes;
            continue;
        }
        
        if (char == ' ' and !in_quotes) {
            if (current_arg.items.len > 0) {
                try args.append(try current_arg.toOwnedSlice());
                current_arg = std.ArrayList(u8).init(allocator);
            }
            continue;
        }
        
        try current_arg.append(char);
    }
    
    if (current_arg.items.len > 0) {
        try args.append(try current_arg.toOwnedSlice());
    }
    
    return args.toOwnedSlice();
}

fn createFilteredPath(allocator: std.mem.Allocator, exe_dir: []const u8) ![]u8 {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return try allocator.dupe(u8, "/usr/bin:/bin");
    defer allocator.free(path_env);
    
    var new_path = std.ArrayList(u8).init(allocator);
    defer new_path.deinit();
    
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    var first = true;
    while (it.next()) |dir| {
        // Skip if this directory matches our executable's directory
        if (std.mem.eql(u8, dir, exe_dir)) {
            continue;
        }
        
        if (!first) {
            try new_path.append(':');
        }
        try new_path.appendSlice(dir);
        first = false;
    }
    
    return new_path.toOwnedSlice();
}

fn createEnviron(allocator: std.mem.Allocator, filtered_path: []const u8) ![:null]?[*:0]u8 {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    
    // Update PATH
    try env_map.put("PATH", filtered_path);
    
    // Create environ array
    var environ = std.ArrayList(?[*:0]u8).init(allocator);
    defer environ.deinit();
    
    var it = env_map.iterator();
    while (it.next()) |entry| {
        const env_string = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        defer allocator.free(env_string);
        
        const env_z = try allocator.allocSentinel(u8, env_string.len, 0);
        @memcpy(env_z, env_string);
        try environ.append(env_z);
    }
    
    return try environ.toOwnedSliceSentinel(null);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    // Get the full path of the executable
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    
    // Get directory of the executable
    // const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
    
    // Get the directory containing the symlink (from argv[0])
    const argv0_dir_owned = blk: {
        if (std.fs.path.isAbsolute(args[0])) {
            const dir = std.fs.path.dirname(args[0]) orelse ".";
            break :blk try allocator.dupe(u8, dir);
        } else {
            const cwd = try std.process.getCwdAlloc(allocator);
            defer allocator.free(cwd);
            const abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, args[0] });
            defer allocator.free(abs_path);
            const dir = std.fs.path.dirname(abs_path) orelse ".";
            break :blk try allocator.dupe(u8, dir);
        }
    };
    defer allocator.free(argv0_dir_owned);
    const argv0_dir = argv0_dir_owned;
    
    // Get the program name (basename of argv[0])
    const program_name = std.fs.path.basename(args[0]);
    
    // Debug output
    // std.debug.print("Debug: exe_path={s}, exe_dir={s}, argv0_dir={s}, program_name={s}\n", .{ exe_path, exe_dir, argv0_dir, program_name });
    
    // Read alias.json
    const json_content = findAliasJson(allocator) catch |err| {
        std.debug.print("Error: Could not find alias.json: {}\n", .{err});
        std.debug.print("Looking for alias: {s}\n", .{program_name});
        std.process.exit(1);
    };
    defer allocator.free(json_content);
    
    // Parse JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch |err| {
        std.debug.print("Error parsing alias.json: {}\n", .{err});
        std.process.exit(1);
    };
    defer parsed.deinit();
    
    // Look for the alias
    const aliases = parsed.value.object;
    const command_raw = aliases.get(program_name) orelse {
        std.debug.print("Error: No alias found for '{s}' in alias.json\n", .{program_name});
        std.process.exit(1);
    };
    
    if (command_raw != .string) {
        std.debug.print("Error: Alias for '{s}' must be a string\n", .{program_name});
        std.process.exit(1);
    }
    
    // Expand environment variables in the command
    const expanded_command = try expandEnvVars(allocator, command_raw.string);
    defer allocator.free(expanded_command);
    
    // Parse the command line into arguments
    const parsed_args = try parseCommandLine(allocator, expanded_command);
    defer {
        for (parsed_args) |arg| {
            allocator.free(arg);
        }
        allocator.free(parsed_args);
    }
    
    if (parsed_args.len == 0) {
        std.debug.print("Error: Empty command for alias '{s}'\n", .{program_name});
        std.process.exit(1);
    }
    
    // Build argv with parsed command and user runtime args
    const total_args = parsed_args.len + (if (args.len > 1) args.len - 1 else 0);
    var argv = try allocator.alloc(?[*:0]u8, total_args + 1);
    defer allocator.free(argv);
    
    // Convert args to null-terminated strings
    for (parsed_args, 0..) |arg, i| {
        const arg_z = try allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(arg_z, arg);
        argv[i] = arg_z;
    }
    
    // Add runtime arguments from user
    if (args.len > 1) {
        for (args[1..], 0..) |arg, i| {
            const arg_z = try allocator.allocSentinel(u8, arg.len, 0);
            @memcpy(arg_z, arg);
            argv[parsed_args.len + i] = arg_z;
        }
    }
    
    argv[total_args] = null;
    
    // Create filtered PATH - remove the directory containing the symlink
    const filtered_path = try createFilteredPath(allocator, argv0_dir);
    defer allocator.free(filtered_path);
    
    // std.debug.print("Debug: Filtered PATH={s}\n", .{filtered_path});
    
    // Create environment with filtered PATH
    const environ = try createEnviron(allocator, filtered_path);
    defer allocator.free(environ);
    
    // Convert argv to []const []const u8 for execve
    var argv_slice = try allocator.alloc([]const u8, total_args);
    defer allocator.free(argv_slice);
    
    for (0..total_args) |i| {
        const len = std.mem.len(argv[i].?);
        argv_slice[i] = argv[i].?[0..len];
    }
    
    // Convert environ to std.process.EnvMap
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    
    // Add all environment variables
    var i: usize = 0;
    while (environ[i]) |env_str| : (i += 1) {
        const env_slice = env_str[0..std.mem.len(env_str)];
        if (std.mem.indexOf(u8, env_slice, "=")) |eq_pos| {
            const key = env_slice[0..eq_pos];
            const value = env_slice[eq_pos + 1..];
            try env_map.put(key, value);
        }
    }
    
    // Execute with custom environment
    const err = std.process.execve(allocator, argv_slice, &env_map);
    
    // If we reach here, execve failed
    std.debug.print("Failed to execute: {}\n", .{err});
}