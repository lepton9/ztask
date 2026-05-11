# ztask

Task automation and workflow runner written in Zig.

## Features
- Event-driven task triggering (e.g. file changes)
- Dependency graph with cycle detection and parallel execution
- CLI and TUI dashboard
- Remote runners (agents connect to a manager over TCP)

Supported platforms: Linux, Windows

## Quickstart

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/ztask --help
```

CLI help: `ztask --help`.
Help for specific sub-commands: `ztask <cmd> --help`.

## Task Files

Tasks are YAML files stored under `<data-dir>/tasks/` 
(e.g. `.ztask/tasks/example.yml`) by default.

New tasks can be created using `ztask new`, or existing tasks can be added with 
`ztask add`.

Tasks can have multiple jobs, and each job can consist of multiple steps. Jobs 
that do not have dependencies on other jobs can be executed in parallel. Within 
a job, steps are executed in sequence. Each step is a CLI command that is 
executed.

Added tasks can be ran using `ztask run` or from the TUI. Existing tasks can be 
seen using `ztask list` or in the TUI.

### Triggers

If a task has a trigger, it is executed when the specified trigger event 
occurs. Without a trigger, the task executes immediately.

A trigger can be:

- `watch: "src"`
  - Watches for file or directory changes.
- `interval: "hh:mm:ss"`
  - Executes the task at specified intervals.
- `time: "hh:mm:ss"`
  - Executes the task at a certain time of the day (UTC).

Example:

```yaml
name: "example" # Required name of the task
id: "123" # Optional ID for the task
cwd: "." # Current working directory

# Trigger
on:
  watch: "src/main.zig"

jobs:
  build: # Job name
    steps:
      - command: "zig build"
  test:
    deps: [build]
    steps:
      - command: "zig fmt --check . src"
      - command: "zig build test"
```

### Runners

Jobs can be executed either locally or on a remote runner via TCP. By default, 
they are all executed locally.

You can specify the runner using the `run_on` field inside a job.
For example `run_on: local` or `run_on: remote:<runner_name>`.

Target a remote runner from a job:

```yaml
name: "Remote example"
jobs:
  remoteJob1:
    run_on:
      type: remote
      name: remoteRunner1
      addr: 127.0.0.1 # IP address of the remote runner
    steps:
      - command: "zig build"
  remoteJob2:
    run_on: remote:remoteRunner2@127.0.0.1
    steps:
      - command: "zig build"
```

The remote runner must be connected to the manager that runs the task. If the 
desired remote runner can't be found or is not connected, the job fails.
When running the task, the manager listens on `127.0.0.1:5555` by default.

You can change the IP address and port that the remote runner connects to:

```bash
ztask runner --name runner1 --address 127.0.0.1 --port 5555
```

### Data directory

The data directory is where the metadata and logs for tasks and task runs is 
stored, and where new tasks are created by default. You can use `ztask env` to 
print the active path and other information.

Data directory selection:
- Project-local `.ztask/`
  - Auto-detected by walking up from the current directory. Create with `ztask 
init`
- `ZTASK_DATA_DIR` environment variable
- Default OS app data directory


## Development

### Requirements

- Zig 0.15.2 (see `build.zig.zon`)

### Build

```bash
zig build -Doptimize=ReleaseFast
```
> Omit the `-Doptimize=ReleaseFast` flag for a debug build.

### Compile and run
```bash
zig build run
```
Or run the compiled binary:
```bash
./zig-out/bin/ztask
```

### Run tests
```bash
zig build test
```
