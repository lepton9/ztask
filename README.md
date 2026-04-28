# ztask

Task automation and workflow runner written in Zig.

## Features
- Event-driven task triggering (e.g. file changes)
- Dependency graph with cycle detection and parallel execution
- CLI and TUI dashboard
- Remote runners (agents connect to a manager over TCP)

## Quickstart

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/ztask
```

CLI help: `ztask --help`.

## Task Files

Tasks are YAML files stored under `<data-dir>/tasks/` 
(e.g. `.ztask/tasks/example.yml`).

Data directory selection:
- Project-local `.ztask/` (auto-detected by walking up from the current 
  directory; create with `ztask init`)
- `ZTASK_DATA_DIR` environment variable
- OS app data directory (use `ztask data` to print the active path)

Example:

```yaml
name: example
on:
  watch: "src/main.zig"

jobs:
  build:
    steps:
      - command: "zig build"
  test:
    deps: [build]
    steps:
      - command: "zig build test"
```

## Remote Runners

When running the TUI or `ztask run`, a manager listens on `127.0.0.1:5555` by 
default.

```bash
./zig-out/bin/ztask runner --name runner1 --address 127.0.0.1 --port 5555
```

Target a remote runner from a job:

```yaml
jobs:
  build:
    run_on: remote:runner1
    steps:
      - command: "zig build"
```

## Development

### Requirements

- Zig (see `build.zig.zon`)

### Build

Omit `-Doptimize` for a debug build.
```bash
zig build -Doptimize=ReleaseFast
```

### Running
```bash
zig build run
```
Or run the compiled binary:
```bash
./zig-out/bin/ztask
```

### Test
```bash
zig build test
```
