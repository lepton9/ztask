# Timesheet


| Date                                         | H      | Description                              |
|----------------------------------------------|--------|------------------------------------------|
| 2025-11-14 15:00:00Z - 2025-11-14 15:30:00Z  | 0.5    | Starting project
| 2025-11-15 21:00:00Z - 2025-11-15 23:50:00Z  | 2.83   | Basic structs and file reading
| 2025-11-16 02:45:00Z - 2025-11-16 07:10:00Z  | 4.41   | Task parsing and testing
| 2025-11-17 08:15:00Z - 2025-11-17 12:30:00Z  | 4.25   | refactoring parsing, program structure designing
| 2025-11-18 04:30:00Z - 2025-11-18 09:10:00Z  | 4.66   | Scheduler, DAG building and validation
| 2025-11-19 18:00:00Z - 2025-11-19 21:00:00Z  | 3      | Graph cycle detection testing, scheduler starting
| 2025-11-20 18:00:00Z - 2025-11-20 22:30:00Z  | 4.5    | Runner pool, result queue for job completion
| 2025-11-21 12:00:00Z - 2025-11-21 16:00:00Z  | 4      | Refactoring scheduler and runner pool, added runner threads
| 2025-11-21 18:40:00Z - 2025-11-22 00:40:00Z  | 6      | Task manager and runner threads, scheduler force stopping
| 2025-11-22 18:00:00Z - 2025-11-23 01:00:00Z  | 7      | Implementing file watcher for linux
| 2025-11-23 17:00:00Z - 2025-11-23 20:10:00Z  | 3.16   | Refactoring file watcher
| 2025-11-24 14:50:00Z - 2025-11-24 23:15:00Z  | 8.41   | Task id, watcher refactoring, bug fixing
| 2025-11-25 18:30:00Z - 2025-11-26 00:15:00Z  | 5.75   | Task run logger, log metadata to JSON file
| 2025-11-27 16:30:00Z - 2025-11-27 22:50:00Z  | 6.33   | Job log queue, datastore, read and write metadata files
| 2025-11-27 23:40:00Z - 2025-11-28 04:25:00Z  | 4.75   | Task metadata files, load metafiles in datastore
| 2025-11-29 23:30:00Z - 2025-11-30 02:00:00Z  | 2.5    | Add CI, load task runs in datastore
| 2025-11-30 19:45:00Z - 2025-12-01 01:30:00Z  | 5.75   | Job step running and logging
| 2025-12-01 19:15:00Z - 2025-12-02 04:00:00Z  | 8.75   | Fix logging, refactoring task loading, begin creating remote agent
| 2025-12-03 07:15:00Z - 2025-12-03 13:15:00Z  | 6      | Implementing remote agent and protocol for TCP messages
| 2025-12-04 15:00:00Z - 2025-12-04 17:30:00Z  | 2.5    | Remote manager server
| 2025-12-05 18:00:00Z - 2025-12-05 19:15:00Z  | 1.25   | Fix trigger parsing
| 2025-12-06 19:00:00Z - 2025-12-07 04:15:00Z  | 9.25   | Refactoring file watcher, fixing thread joining, remote manager connection handling
| 2025-12-08 08:00:00Z - 2025-12-08 13:15:00Z  | 5.25   | Remote job dispatching, message sending and reading with sockets
| 2025-12-09 13:00:00Z - 2025-12-09 14:00:00Z  | 1      | Frame reader
| 2025-12-10 16:15:00Z - 2025-12-10 22:15:00Z  | 6      | Connection read/write, packet types
| 2025-12-11 15:00:00Z - 2025-12-11 18:10:00Z  | 3.16   | Job message types, run jobs and handle logs in remote agent
| 2025-12-12 17:50:00Z - 2025-12-12 20:05:00Z  | 2.25   | Protocol message testing
| 2025-12-13 20:00:00Z - 2025-12-14 01:45:00Z  | 5.75   | Dispatching jobs to remote agents and running them
| 2025-12-15 18:00:00Z - 2025-12-15 22:30:00Z  | 4.5    | Remote job canceling and small fixes
| 2025-12-16 19:00:00Z - 2025-12-17 00:05:00Z  | 5.08   | Refactoring protocol message serializing and deserializing
| 2025-12-17 16:30:00Z - 2025-12-17 21:15:00Z  | 4.75   | Protocol msg parser and refactoring msg converting
| 2025-12-18 00:30:00Z - 2025-12-18 01:45:00Z  | 1.25   | Length for slices and booleans type in protocol
| 2025-12-19 18:00:00Z - 2025-12-20 02:10:00Z  | 8.16   | Cli commands and options, agent reconnecting
| 2025-12-21 19:00:00Z - 2025-12-21 23:45:00Z  | 4.75   | Task list command, refactoring datastore
| 2025-12-22 00:10:00Z - 2025-12-22 07:10:00Z  | 7      | Queue with doubly linked lists, testing remote job execution
| 2025-12-23 01:50:00Z - 2025-12-23 05:50:00Z  | 4      | Fix TCP non-blocking connection
| 2025-12-24 01:00:00Z - 2025-12-24 03:00:00Z  | 2      | Use polling in remote manager, better idle checking
| 2025-12-25 19:00:00Z - 2025-12-25 20:15:00Z  | 1.25   | Option handling, option for runner amount
| 2025-12-26 02:15:00Z - 2025-12-26 05:00:00Z  | 2.75   | Begin making TUI
| 2025-12-26 16:30:00Z - 2025-12-26 18:45:00Z  | 2.25   | Test TUI library and fix tick
| 2025-12-27 16:30:00Z - 2025-12-27 20:40:00Z  | 4.16   | Building task list in TUI
| 2025-12-28 17:30:00Z - 2025-12-28 21:50:00Z  | 4.33   | TUI snapshot and displaying task names
| 2025-12-29 02:20:00Z - 2025-12-29 05:50:00Z  | 3.5    | TUI data refactoring and display selected task data
| 2025-12-29 16:50:00Z - 2025-12-29 20:30:00Z  | 3.66   | TUI task list and task view borders and switching
| 2025-12-30 01:00:00Z - 2025-12-30 03:50:00Z  | 2.83   | Comptime enum merging, refactor to use the snapshot structs
| 2025-12-31 01:00:00Z - 2025-12-31 01:30:00Z  | 0.5    | Get active task run
| 2026-01-01 20:00:00Z - 2026-01-01 23:20:00Z  | 3.33   | Display active task run and jobs
| 2026-01-02 04:00:00Z - 2026-01-02 07:10:00Z  | 3.16   | Start and stop tasks in TUI, task run loading and adding
| 2026-01-03 18:45:00Z - 2026-01-03 19:20:00Z  | 0.58   | TUI status bar
| 2026-01-04 23:00:00Z - 2026-01-04 23:20:00Z  | 0.33   | Fix unreachable in remote agent
| 2026-01-05 04:45:00Z - 2026-01-05 07:30:00Z  | 2.75   | Refactoring task ID
| 2026-01-06 23:30:00Z - 2026-01-07 01:40:00Z  | 2.16   | Info notification in TUI
| 2026-01-07 20:00:00Z - 2026-01-08 01:30:00Z  | 5.5    | Displaying task runs in TUI
| 2026-01-08 14:00:00Z - 2026-01-08 16:30:00Z  | 2.5    | Refactoring task run displaying and sorting
| 2026-01-10 23:00:00Z - 2026-01-11 05:30:00Z  | 6.5    | Getting selected task run job info to TUI
| 2026-01-12 11:15:00Z - 2026-01-12 15:15:00Z  | 4      | Displaying past runs and jobs in TUI
| 2026-01-13 11:30:00Z - 2026-01-13 17:30:00Z  | 6      | Fix selected task data handling, refactoring
| 2026-01-14 13:00:00Z - 2026-01-14 19:00:00Z  | 6      | TUI improvements for task view, small fixes, job log chunks
| 2026-01-15 18:20:00Z - 2026-01-15 23:30:00Z  | 5.16   | Display job logs in TUI
| 2026-01-16 12:00:00Z - 2026-01-16 14:20:00Z  | 2.33   | Make a job log area in TUI
| 2026-01-17 17:30:00Z - 2026-01-17 23:30:00Z  | 6      | Key press handling for job log, colored status, fixes
| 2026-01-19 15:15:00Z - 2026-01-19 19:05:00Z  | 3.83   | Sort options for list command, handle command errors
| 2026-01-19 23:00:00Z - 2026-01-20 01:00:00Z  | 2      | Ability to attach to a job
| 2026-01-20 17:00:00Z - 2026-01-20 20:00:00Z  | 3      | Interrupting attached jobs, job retriggering
| 2026-01-21 17:00:00Z - 2026-01-22 00:30:00Z  | 7.5    | Fixing attached job interrupting, better job log retreiving, log scroll
| 2026-01-22 13:30:00Z - 2026-01-22 17:00:00Z  | 3.5    | Log scrolling, datetimes, reorganizing
| 2026-01-22 18:45:00Z - 2026-01-23 01:15:00Z  | 6.5    | Job scroll anchor, convert timestamps to datetimes in TUI, reorganizing
| 2026-01-24 23:30:00Z - 2026-01-25 01:00:00Z  | 1.5    | Small fixes, optimize task finding with path
| 2026-01-27 07:00:00Z - 2026-01-27 15:20:00Z  | 8.33   | File watcher for windows
| 2026-01-28 22:00:00Z - 2026-01-29 01:15:00Z  | 3.25   | TUI area scaling fixes
| 2026-02-02 07:00:00Z - 2026-02-02 11:15:00Z  | 4.25   | TCP connection on Windows, handle disconnected and duplicate remote runners
| 2026-02-03 09:45:00Z - 2026-02-03 13:35:00Z  | 3.83   | Input for 'run', and 'runner' commands
| 2026-02-04 16:15:00Z - 2026-02-04 21:00:00Z  | 4.75   | User confirmation for exiting and deleting in TUI
| 2026-02-05 22:15:00Z - 2026-02-05 23:50:00Z  | 1.58   | Refactoring job run metadata loading
| 2026-02-06 20:20:00Z - 2026-02-07 00:40:00Z  | 4.33   | Add and delete commands for CLI
| 2026-02-17 18:00:00Z - 2026-02-18 02:15:00Z  | 8.25   | Error handling, fixes, watcher tests, configurable data dir
| 2026-02-18 19:00:00Z - 2026-02-19 04:30:00Z  | 9.5    | Commands 'init', 'data', "move", refactoring
| 2026-02-19 22:30:00Z - 2026-02-20 00:15:00Z  | 1.75   | Options 'global' and 'data-dir', and env variable for data dir
| 2026-02-22 00:00:00Z - 2026-02-22 01:30:00Z  | 1.5    | Time trigger parsing
| 2026-02-23 22:00:00Z - 2026-02-24 03:10:00Z  | 5.16   | TimeWatcher implementation
| 2026-02-25 04:15:00Z - 2026-02-25 07:30:00Z  | 3.25   | Match optional IP address for remote agents
| 2026-03-03 11:00:00Z - 2026-03-03 15:00:00Z  | 4      | Repair option for move command
| 2026-03-07 14:00:00Z - 2026-03-07 15:45:00Z  | 1.75   | Refactor task moving
| 2026-03-12 15:00:00Z - 2026-03-12 16:45:00Z  | 1.75   | New task creation
| 2026-03-14 16:00:00Z - 2026-03-14 17:40:00Z  | 1.66   | Task to text conversion
| 2026-04-15 10:00:00Z - 2026-04-15 12:30:00Z  | 2.5    | New task creation, repair command
| 2026-04-17 14:15:00Z - 2026-04-17 16:20:00Z  | 2.08   | Task editing
| 2026-04-26 00:05:00Z - 2026-04-26 02:10:00Z  | 2.08   | Task ID refactoring
| 2026-04-26 13:10:00Z - 2026-04-26 18:00:00Z  | 4.83   | Repair command refactoring and handle ID changes
| 2026-04-27 20:05:00Z - 2026-04-28 02:10:00Z  | 6.08   | Default editor, handle edit errors
| 2026-04-28 15:00:00Z - 2026-04-28 20:00:00Z  | 5      | Improving error handling, bug fixes, improving status bar in TUI
| 2026-05-03 16:20:00Z - 2026-05-03 20:55:00Z  | 4.58   | Show more info from scheduler when using verbose option
| 2026-05-04 22:45:00Z - 2026-05-05 02:20:00Z  | 3.58   | Implementing parsing diagnostics for errors
| 2026-05-05 20:10:00Z - 2026-05-06 01:15:00Z  | 5.08   | Displaying error messages from the diagnostics struct
| 2026-05-06 20:00:00Z - 2026-05-07 01:40:00Z  | 5.66   | More diagnostics, bug fixes, task working directory
| 2026-05-09 20:50:00Z - 2026-05-09 23:55:00Z  | 3.08   | Release step, writing better readme
| 2026-05-10 22:10:00Z - 2026-05-11 02:40:00Z  | 4.5    | Making plantuml graphs
| 2026-05-11 15:20:00Z - 2026-05-11 20:15:00Z  | 4.91   | Recursive dir watching, bug fixing
| 2026-05-14 15:05:00Z - 2026-05-14 18:30:00Z  | 3.41   | Attached job process group, memory leak fixes
|                                       Total: | 406.24 |
