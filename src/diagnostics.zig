const std = @import("std");
const ParseDiag = @import("parse.zig").ParseDiag;

/// Generic diagnostics struct for reporting error messages.
pub const GenericDiagnostics = struct {
    err: ?anyerror = null,
    message: ?[]u8 = null,

    pub fn deinit(self: *GenericDiagnostics, gpa: std.mem.Allocator) void {
        if (self.message) |msg| gpa.free(msg);
    }

    pub fn failf(
        self: *GenericDiagnostics,
        gpa: std.mem.Allocator,
        err: anyerror,
        comptime fmt: []const u8,
        args: anytype,
    ) anyerror {
        self.deinit(gpa);
        self.err = err;
        self.message = try std.fmt.allocPrint(gpa, fmt, args);
        return err;
    }

    fn extractParseErrorInternal(
        self: *GenericDiagnostics,
        gpa: std.mem.Allocator,
        parse_diag: ?*ParseDiag,
        prefix: ?[]u8,
    ) !void {
        const pd = parse_diag orelse return;
        const err = pd.err orelse return;
        const msg = pd.message orelse @errorName(err);
        const field = pd.field orelse "";
        if (prefix) |pfx| {
            return self.failf(gpa, err, "{s}: ParseError: {s}: '{s}'", .{ pfx, msg, field });
        } else {
            return self.failf(gpa, err, "ParseError: {s}: '{s}'", .{ msg, field });
        }
    }

    /// Convert the parse error to a proper error message.
    pub fn extractParseError(
        self: *GenericDiagnostics,
        gpa: std.mem.Allocator,
        parse_diag: ?*ParseDiag,
    ) !void {
        return self.extractParseErrorInternal(gpa, parse_diag, null);
    }

    /// Convert the parse error to a proper error message.
    /// Add a prefix to the error message.
    pub fn extractParseErrorPrefix(
        self: *GenericDiagnostics,
        gpa: std.mem.Allocator,
        parse_diag: ?*ParseDiag,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const prefix = try std.fmt.allocPrint(gpa, fmt, args);
        defer gpa.free(prefix);
        return self.extractParseErrorInternal(gpa, parse_diag, prefix);
    }
};
