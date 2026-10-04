const std = @import("std");

/// Match `path` against a single `glob`.
pub fn match(glob: []const u8, path: []const u8) bool {
    // `**` as a whole segment (or trailing) matches zero or more segments
    if (std.mem.startsWith(u8, glob, "**") and (glob.len == 2 or glob[2] == '/')) {
        const rest = if (glob.len == 2) "" else glob[3..];
        // A trailing `**` matches everything that is left.
        if (rest.len == 0) return true;
        if (match(rest, path)) return true;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '/' and match(rest, path[i + 1 ..])) return true;
        }
        return false;
    }

    const g_end = std.mem.indexOfScalar(u8, glob, '/') orelse glob.len;
    const p_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    if (!matchSegment(glob[0..g_end], path[0..p_end])) return false;
    if (g_end == glob.len) return p_end == path.len;
    if (p_end == path.len) return match(glob[g_end + 1 ..], "");
    return match(glob[g_end + 1 ..], path[p_end + 1 ..]);
}

/// Check whether `path` is matched by any of the exclusion globs.
pub fn matchAny(globs: []const []const u8, path: []const u8) bool {
    for (globs) |glob| {
        if (match(glob, path)) return true;
        if (std.mem.indexOfScalar(u8, glob, '/') != null) continue;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (match(glob, seg)) return true;
        }
    }
    return false;
}

/// Match a single path segment (no `/`) against a pattern containing only
/// literals, `?` and `*`.
fn matchSegment(pattern: []const u8, name: []const u8) bool {
    var pattern_i: usize = 0;
    var name_i: usize = 0;
    var next_pattern_i: usize = 0;
    var next_name_i: usize = 0;
    while (pattern_i < pattern.len or name_i < name.len) {
        if (pattern_i < pattern.len) {
            const c = pattern[pattern_i];
            switch (c) {
                '?' => { // single-character wildcard
                    if (name_i < name.len) {
                        pattern_i += 1;
                        name_i += 1;
                        continue;
                    }
                },
                '*' => { // zero-or-more-character wildcard
                    next_pattern_i = pattern_i;
                    next_name_i = name_i + 1;
                    pattern_i += 1;
                    continue;
                },
                else => { // ordinary character
                    if (name_i < name.len and name[name_i] == c) {
                        pattern_i += 1;
                        name_i += 1;
                        continue;
                    }
                },
            }
        }
        // Mismatch
        if (next_name_i > 0 and next_name_i <= name.len) {
            pattern_i = next_pattern_i;
            name_i = next_name_i;
            continue;
        }
        return false;
    }
    return true;
}

const expect = std.testing.expect;

test "literal" {
    try expect(match("main.zig", "main.zig"));
    try expect(!match("main.zig", "main.zigc"));
    try expect(!match("main.zig", "src/main.zig"));
    try expect(match("", ""));
    try expect(!match("", "x"));
}

test "single_star_stays_in_segment" {
    try expect(match("*.zig", "main.zig"));
    try expect(match("*", "anything"));
    try expect(!match("*.zig", "src/main.zig"));
    try expect(!match("src/*", "src/a/main.zig"));
    try expect(match("src/*.zig", "src/main.zig"));
}

test "double_star_crosses_segments" {
    try expect(match("src/**", "src"));
    try expect(match("src/**", "src/a/b.zig"));
    try expect(!match("src/**", "srcx/a"));
    try expect(match("**/*.zig", "main.zig"));
    try expect(match("**/*.zig", "src/a/main.zig"));
    try expect(match("a/**/b", "a/b"));
    try expect(match("a/**/b", "a/x/y/b"));
    try expect(!match("a/**/b", "a/x/b/c"));
    try expect(match("a/**", "a/x"));
    try expect(match("a/**", "a/x/y"));
    try expect(match("**", "a/b/c"));
}

test "question_mark" {
    try expect(match("file?.txt", "file1.txt"));
    try expect(!match("file?.txt", "file10.txt"));
    try expect(!match("file?.txt", "file/.txt"));
    try expect(match("??", "ab"));
}

test "multi_star_backtrack" {
    try expect(match("*a*b", "xayb"));
    try expect(!match("*a*b", "xaybz"));
    try expect(match("a*a*a", "aaa"));
    try expect(match("*ab", "aab"));
    try expect(match("?*?", "abc"));
    try expect(match("?*?", "ab"));
    try expect(match("*", ""));
    try expect(!match("a*", "ba"));
}

test "match_any_segment" {
    const globs = &.{ "node_modules", ".zig-cache" };
    try expect(matchAny(globs, "node_modules"));
    try expect(matchAny(globs, "sub/.zig-cache"));
    try expect(matchAny(globs, "sub/.zig-cache/f.txt"));
    try expect(!matchAny(globs, "sub/node_modules.txt"));
    try expect(matchAny(&.{"src/**/*.zig"}, "src/gen/a.zig"));
    try expect(!matchAny(&.{}, "anything"));
}
