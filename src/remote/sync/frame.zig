//! Types for workspace transfer frames.

const std = @import("std");
const protocol = @import("../protocol.zig");

/// One file entry of the workspace manifest.
pub const ManifestEntry = protocol.ManifestEntry;

/// A view over manifest entries.
pub const ManifestEntries = protocol.ListView(ManifestEntry);

/// A view over workspace-relative glob patterns.
pub const PatternList = protocol.ListView([]const u8);

/// One page of the workspace manifest.
pub const Page = struct {
    /// Entry count across all pages of this manifest.
    total_entries: u32,
    /// This page's entries.
    entries: ManifestEntries,
};

/// One chunk of file data.
pub const Chunk = struct {
    /// Workspace-relative path the chunk belongs to.
    path: []const u8,
    /// Offset of `data` within the file.
    offset: u64,
    /// Chunk payload.
    data: []const u8,
};

/// All chunks of a file were sent.
pub const Done = struct {
    /// Workspace-relative path of the completed file.
    path: []const u8,
    /// POSIX permission bits for the file.
    permissions: u32,
    /// Lowercase hex SHA-256 of the file content. The receiver
    /// verifies the bytes it accepted against it. Absent skips
    /// verification.
    hash: ?[]const u8 = null,
};

/// The receiving role wants the content of one file.
pub const Request = struct {
    /// Workspace-relative path of the requested file.
    path: []const u8,
};

/// One frame of a workspace transfer.
pub const Frame = union(enum) {
    /// One page of the workspace manifest.
    page: Page,
    /// Next slice of one file.
    chunk: Chunk,
    /// One file completed.
    done: Done,
    /// Receiver to sender: serve this file next.
    request: Request,
    /// Sender to receiver: the transfer is complete.
    end,
};
