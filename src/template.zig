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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    // Embedded command and arguments (may contain env vars to expand)
    const embedded_cmd_raw = "{{COMMAND}}";
    const embedded_args_raw = [_][]const u8{{{ARGS}}};
    
    // Expand environment variables in command
    const embedded_cmd = try expandEnvVars(allocator, embedded_cmd_raw);
    defer allocator.free(embedded_cmd);
    
    // Expand environment variables in arguments
    var embedded_args = try allocator.alloc([]u8, embedded_args_raw.len);
    defer {
        for (embedded_args) |arg| {
            allocator.free(arg);
        }
        allocator.free(embedded_args);
    }
    
    for (embedded_args_raw, 0..) |arg_raw, i| {
        embedded_args[i] = try expandEnvVars(allocator, arg_raw);
    }
    
    // Build argv with embedded command, embedded args, and user runtime args
    const total_args = 1 + embedded_args.len + (if (args.len > 1) args.len - 1 else 0);
    var argv = try allocator.alloc([]const u8, total_args);
    defer allocator.free(argv);
    
    // Set the command
    argv[0] = embedded_cmd;
    
    // Add embedded arguments
    for (embedded_args, 0..) |arg, i| {
        argv[1 + i] = arg;
    }
    
    // Add runtime arguments from user
    if (args.len > 1) {
        for (args[1..], 0..) |arg, i| {
            argv[1 + embedded_args.len + i] = arg;
        }
    }
    
    // Execute the command with all arguments
    const err = std.process.execv(allocator, argv);
    
    // If we reach here, execv failed
    std.debug.print("Failed to execute {s}: {}\n", .{ embedded_cmd, err });
}