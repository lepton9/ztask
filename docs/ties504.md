
# Description

The program, named ztask, is designed to automate tasks defined by the user. The 
program is primarily tested on Linux, but most of the core functionality
is also compatible with Windows.

# Why is the program useful

I first got the idea for the program from combining GitHub actions and Zig's 
feature `zig build --watch`, which detects file changes and recompiles the 
program automatically. This would serve as a language-agnostic automatic 
compiling tool. The program has many other use cases in addition to 
auto-compiling. It can be used to automate almost any tasks that the user has in 
mind.

# Architecture

The architecture can be seen from [README](./architecture/README.md).

# Requirements

The MVP requirements I had for this project:
## Functional
- Running multiple tasks at the same time
- Have local and remote runners
- Having at least a file watcher that can trigger tasks
- CLI for the main usage and a minimal TUI for viewing

## Non-functional
- No memory leaks at any point
- Ensure the code is maintainable and scalable for future development
- Easy to use and clear errors

# Features

## CLI
- Running and stopping tasks
- Creating, deleting, moving and editing tasks
- Syncing manually modified or moved tasks
- Spawning remote runners

## TUI
- Running and stopping tasks
- Viewing task runs, jobs, and job logs
- Deleting tasks

Help for using the program can be found in the README.md file at the root of the 
repository. [README](../README.md)

# Self-evaluation

## What was hard

Creating the TUI was one of the hardest parts of the project. The library I used 
to create the TUI (libvaxis), does not have a lot of documentation. The only 
sources of information are the small examples and the source code 
itself. Additionally, the error messages from the library were pretty, bad and 
most of the time, they didn't explain the main reason for the error at all. I 
have previously used a couple of TUI libraries and even made my own, and their 
usage differs significantly from this one. But after understanding where the 
errors originated from, the development became easier.

Hard parts in addition to the TUI, was making the non-blocking TCP server work 
for Windows. I spent a lot of time trying to figure out why the code would work 
for Linux but not for Windows. There were also a few additional challenges, such 
as executing the jobs in a truly attached mode and running the child process in 
the foreground.

## What was easy

Writing Zig was quite easy and enjoyable since I had used it a fair amount prior 
to this project. From the program itself, it was easy to manage all the 
different tasks and file parsing. Adding more subcommands and options was also 
easy since I used a CLI library that I created myself.

## What I should have done differently

If I were to start over or refactor some of the code, I would probably use a 
library for the TCP communication or move the TCP server into its own 
thread. Zig has a TCP socket implementation in the standard library, but it is 
exclusively blocking, at least in Zig 0.15.0. I wanted to have a non-blocking 
server and poll the sockets from the main loop. This saves an additional thread 
but requires a lot of work. I had to use the underlying POSIX sockets and handle 
Linux and Windows implementations separately in some cases.

I would also prioritize making the CLI more complete and adding more 
features. After completing the CLI part of the program, I would only then start 
creating the TUI if I had time. It took a big portion of the time I used, and is 
not as essential as the CLI.

## Credits and grade

Since the credits are calculated from the amount of used hours, and if the 
maximum amount of credits for this course is 8op, I would give myself 
8op. Because one credit is 27 hours and 27 * 8 == 216, and I have used roughly 
410 hours, which exceeds the required amount.

For the grade, I would give myself either a 4 or 5. The project is in a 
relatively good state, although there may still be minor bugs present. On 
Windows, there are a couple of features that don't work as of now, but Linux has 
been the main focus. I completed most of the planned features, but there are 
still many additional features I plan to implement in the future. The project is 
fairly large for a course of this size, and I have significantly exceeded the 
maximum credit amount. Most of the important functions are documented, and 
complex code blocks include comments for clarity. Additionally, there are unit 
tests to verify some of the core logic used in the program. I have also 
optimized and polished many parts of the program, including the log file 
reading, which reads only the necessary chunks from the file.

The difficulty of the project varies a lot depending on the part of the 
program. Overall, I would classify the difficulty as ranging from medium to 
fairly challenging. The program includes concepts such as a TCP server, thread 
management and communication between them, memory management, file system 
operations and child processes. The OS specific parts, like TCP connection and 
file watcher, are implemented for Linux and Windows. Additionally, Zig is a 
relatively new systems programming language that is still under development and 
not yet widely adopted. The libraries developed in Zig are also relatively new 
due to the language, and the selection is limited. I had to make a few fixes in 
the YAML parsing library to have my own tests pass, since it would either leak 
memory or not handle duplicate keys properly.

#### Time tracking
Time usage can be seen from [Time](./time.md).

