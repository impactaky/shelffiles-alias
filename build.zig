const std = @import("std");

const ArgSpec = struct {
    value: []const u8,
    env_var: ?[]const u8,
};

fn parseArgSpec(allocator: std.mem.Allocator, input: []const u8) !ArgSpec {
    if (std.mem.startsWith(u8, input, "{env.") and std.mem.endsWith(u8, input, "}")) {
        const env_name = input[5 .. input.len - 1];
        return ArgSpec{
            .value = try allocator.dupe(u8, input),
            .env_var = try allocator.dupe(u8, env_name),
        };
    }
    return ArgSpec{
        .value = try allocator.dupe(u8, input),
        .env_var = null,
    };
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We will also create a module for our entry point, 'embed_path.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("embed_path.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("alia_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "alia",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "alia",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    
    // Add shelffiles-alias command step
    const shelffiles_alias_step = b.step("shelffiles-alias", "Create an executable that embeds a command");
    
    if (b.args) |args| {
        if (args.len >= 2) {
            const output_name = args[0];
            const command_raw = args[1];
            const command_args_raw = if (args.len > 2) args[2..] else &[_][]const u8{};
            
            // Generate the embedded arguments string
            var args_string = std.ArrayList(u8).init(b.allocator);
            defer args_string.deinit();
            
            for (command_args_raw, 0..) |arg, i| {
                if (i > 0) args_string.appendSlice(", ") catch unreachable;
                args_string.appendSlice("\"") catch unreachable;
                args_string.appendSlice(arg) catch unreachable;
                args_string.appendSlice("\"") catch unreachable;
            }
            
            // Read the template from file
            const cwd = std.fs.cwd();
            const template_file = cwd.openFile("src/template.zig", .{}) catch unreachable;
            defer template_file.close();
            const source_template = template_file.readToEndAlloc(b.allocator, 10 * 1024) catch unreachable;
            defer b.allocator.free(source_template);
            
            // Replace placeholders in the template
            var source_content = std.ArrayList(u8).init(b.allocator);
            
            // Simple string replacement
            var start: usize = 0;
            while (std.mem.indexOf(u8, source_template[start..], "{{COMMAND}}")) |pos| {
                const abs_pos = start + pos;
                source_content.appendSlice(source_template[start..abs_pos]) catch unreachable;
                source_content.appendSlice(command_raw) catch unreachable;
                start = abs_pos + "{{COMMAND}}".len;
            }
            source_content.appendSlice(source_template[start..]) catch unreachable;
            
            // Now replace {{ARGS}}
            const temp = source_content.toOwnedSlice() catch unreachable;
            defer b.allocator.free(temp);
            
            source_content = std.ArrayList(u8).init(b.allocator);
            start = 0;
            while (std.mem.indexOf(u8, temp[start..], "{{ARGS}}")) |pos| {
                const abs_pos = start + pos;
                source_content.appendSlice(temp[start..abs_pos]) catch unreachable;
                source_content.appendSlice(args_string.items) catch unreachable;
                start = abs_pos + "{{ARGS}}".len;
            }
            source_content.appendSlice(temp[start..]) catch unreachable;
            
            const final_source = source_content.toOwnedSlice() catch unreachable;
            defer b.allocator.free(final_source);
            
            // Write source to file
            const wf = b.addWriteFiles();
            const source_filename = std.fmt.allocPrint(b.allocator, "{s}.zig", .{output_name}) catch unreachable;
            defer b.allocator.free(source_filename);
            const source_file = wf.add(source_filename, final_source);
            
            // Create executable from the generated source
            const embed_exe = b.addExecutable(.{
                .name = output_name,
                .root_source_file = source_file,
                .target = target,
                .optimize = optimize,
            });
            
            const install = b.addInstallArtifact(embed_exe, .{});
            shelffiles_alias_step.dependOn(&install.step);
            
            std.debug.print("Creating embedded executable: {s}\n", .{output_name});
            std.debug.print("Command: {s}", .{command_raw});
            if (command_args_raw.len > 0) {
                std.debug.print(" with args:", .{});
                for (command_args_raw) |arg| {
                    std.debug.print(" {s}", .{arg});
                }
            }
            std.debug.print("\n", .{});
            std.debug.print("Note: Environment variables like {{env.HOME}} will be expanded at runtime\n", .{});
        } else {
            std.debug.print("Usage: zig build shelffiles-alias -- <output_name> <command> [args...]\n", .{});
            std.debug.print("Example: zig build shelffiles-alias -- my_docker docker run --rm alpine echo hello\n", .{});
        }
    } else {
        std.debug.print("Usage: zig build shelffiles-alias -- <output_name> <command> [args...]\n", .{});
        std.debug.print("Example: zig build shelffiles-alias -- my_docker docker run --rm alpine echo hello\n", .{});
    }
}
