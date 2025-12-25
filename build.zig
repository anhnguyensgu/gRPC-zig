const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spice_dep = b.dependency("spice", .{});
    const spice_mod = spice_dep.module("spice");
    const spice_import: std.Build.Module.Import = .{
        .name = "spice",
        .module = spice_mod,
    };

    // Server library module
    const server_lib_module = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{spice_import},
        .link_libc = true,
    });
    server_lib_module.linkSystemLibrary("z", .{});

    // Server module
    const server_root_module = b.createModule(.{
        .root_source_file = b.path("src/server_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "server", .module = server_lib_module },
        },
        .link_libc = true,
    });
    server_root_module.linkSystemLibrary("z", .{});

    // Client module
    const client_module = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{spice_import},
        .link_libc = true,
    });
    client_module.linkSystemLibrary("z", .{});

    // Benchmark executable
    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{spice_import},
        .link_libc = true,
    });
    benchmark_module.linkSystemLibrary("z", .{});
    const benchmark = b.addExecutable(.{
        .name = "grpc-benchmark",
        .root_module = benchmark_module,
    });
    b.installArtifact(benchmark);

    // Benchmark run step
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_benchmark.addArgs(args);
    }
    const benchmark_step = b.step("benchmark", "Run benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    // Example executables
    const server_example_module = b.createModule(.{
        .root_source_file = b.path("examples/basic_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            spice_import,
            .{ .name = "server", .module = server_lib_module },
        },
        .link_libc = true,
    });
    server_example_module.linkSystemLibrary("z", .{});
    const server_example = b.addExecutable(.{
        .name = "grpc-server-example",
        .root_module = server_example_module,
    });
    b.installArtifact(server_example);

    const client_example_module = b.createModule(.{
        .root_source_file = b.path("examples/basic_client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            spice_import,
            .{ .name = "client", .module = client_module },
        },
        .link_libc = true,
    });
    client_example_module.linkSystemLibrary("z", .{});
    const client_example = b.addExecutable(.{
        .name = "grpc-client-example",
        .root_module = client_example_module,
    });
    b.installArtifact(client_example);

    // Tests
    const tests_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{spice_import},
        .link_libc = true,
    });
    tests_module.linkSystemLibrary("z", .{});
    const tests = b.addTest(.{
        .root_module = tests_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
