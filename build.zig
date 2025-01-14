const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    {
        const server = b.addExecutable(.{
            .name = "echo-server",
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        });

        b.installArtifact(server);

        const run_cmd = b.addRunArtifact(server);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run-server", "Run the server");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const client = b.addExecutable(.{
            .name = "client",
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(client);

        const run_cmd = b.addRunArtifact(client);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run-client", "Run the client");
        run_step.dependOn(&run_cmd.step);
    }

    const server_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const client_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_server_unit_tests = b.addRunArtifact(server_unit_tests);
    const run_client_unit_tests = b.addRunArtifact(client_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_server_unit_tests.step);
    test_step.dependOn(&run_client_unit_tests.step);
}
