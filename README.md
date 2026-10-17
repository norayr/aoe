# aoe


# active oberon environment

The original A2 system is a graphical operating system. Later more about it.

This is a self-hosting Active Oberon compiler, linker and module runner
that works in Linux console.

The checked-in `bin/amd64/aoe` executable and `obj/amd64/` modules run directly after cloning.
The root `aoe` is a convenience symlink, so `./aoe Hello.Run` works too.
Some selected sources, build recipe and tests are included.

## What A2 already provided

The upstream distribution already contained:

- `StdIOShell` and `Shell`: a console entry point and interactive command shell,
  with commands such as `compile`, `link`, `execute`, and `do`.
- `Modules`, `Loader`, `ObjectFile` and `GenericLinker`: dynamic module loading.
- Fox Active Oberon compiler, its Oberon frontend,  amd64 code generator,
  and a static linker capable of producing Linux ELF executables.
- The Unix runtime: files, streams, active objects, synchronization, garbage
  collection, reflection and trap reporting.

In order to start the desktop in original distribution, the user would
run a script `a2.sh`, which would run `./oberon run a2.txt`.
That script installed the display, window manager and other desktop components.

It was already possible to run the console only shell by just running `./oberon`. Without cli arguments it would start the shell.

Other console-only uses that were already available:
```
./oberon --config=oberon.ini compile YourModule.Mod
./oberon --config=oberon.ini YourModule.YourCommand
./oberon do 'System.Show Hello~ System.Ln~'
```
In order to start the desktop it was necessary to call:
```
./oberon run a2.txt
```

### A bit of history

In April 20, 2007 I received answer from Guenter Feldman
from University of Bremen, who back then prepared and was
maintaining UnixAos. Later the project was merged into ETH
tree.

I asked if it's possible to write AOS programs in console,
compile, and run them in Linux console.

The answer was that it is already possible. Back then to
create a console mode application you'd have to do the
following:

1) Create an application Module which only imports the core modules
(Unix, Kernel, Threads, AosOut, FileDir, Files, AosActive, AosModules).
It had to not import module Input.
2) Remove the line
```
Execute( "XDisplay", "Install" )
```
from AosStarter.Mod and recompile it.
3) Start your application with
```
aos  -x YourModule.YourCommand
```
(The default is  aos  -x System.Init)

Sorry for bothering you with historical details. (:

## What we changed now

Fast forward to 2026.

1. We imported 66 unchanged upstream modules, then
   added CLI environment, command metadata, shell command and grep modules. The 71-module build recipe
   is `build.Tool`.
   It includes the runtime, shell, compiler and linker.
2. `CLIEnvironment.Mod` installs search paths for the caller's
   current directory, the project's `obj/amd64/`, and the installation's
   `obj/amd64/` directory. It locates the
   executable through `/proc/self/exe`, so the installation can be moved or
   invoked through a symbolic link. It also corrects the runtime's cached
   working directory when the inherited `$PWD` is stale.
3. `Compiler.Compile` now returns immediately after an options-parsing failure,
   instead of overwriting the error result with success.
   Invalid targets and options therefore produce a failing exit status for build tools.
4. Replaced the simple shell with a [polpo](https://github.com/polpo-system/polpo)'s loksh-style console shell: direct
   `Module.Procedure` calls, Tab completion of modules/commands/files,
   cursor editing, history, Ctrl+D, and line-by-line batch input. Removed the
   `compile`, `link`, `do`, `execute` and `run` aliases. Module completion reads
   metadata without running module initializers.
5. Quoted the executable name in `Unix.StdIO`. This keeps an installation
   path containing spaces from being misread as extra command arguments.
6. Self-rebuild and tests. The repository includes a native
   runner, matching object/symbol files, an active-object example, and a recipe
   that recompiles all included sources and links another runner using only
   the included Oberon tools.
7. The runner lives in `bin/amd64/`; objects and symbols live in `obj/amd64/`.
   `Compiler.Compile` creates the caller's `obj/amd64/` by default. Symbol imports
   fall back from the output directory to the project/installation search paths.
8. Standard input no longer has an eager background reader. EOF terminates the
   shell, commands can consume their own input, and terminal settings are restored
   before commands run. `System.ShowFile` no longer appends a spurious EOF byte.
9. `Linker.Link --executable` sets executable permissions on its output, so
   `build.Tool` can rebuild the runner without a separate permission-setting step.

The compiler backend, module format, threading model and libc interface are
otherwise unchanged. Right now Linux x86-64 is the only supported build recipe.

## Try it

From this repository:

```sh
./bin/amd64/aoe                            # interactive shell; Ctrl+D to leave
./bin/amd64/aoe Compiler.Compile examples/Hello.Mod
./bin/amd64/aoe Hello.Run
./bin/amd64/aoe System.ShowFile examples/Hello.Mod
```

`Hello.Run` creates an active object and waits for it with `AWAIT`. Compilation
writes `Hello.Obj` and `Hello.Sym` into the project's `obj/amd64/`. The runner can
also be invoked by absolute path from another directory; its search paths are
the caller's working directory, its `obj/amd64/`, and the installation's
`obj/amd64/`. Modules in the current directory remain usable too.

### Inside the shell

The interaction model follows [polpo's loksh](https://github.com/polpo-system/polpo) (`src/cli/shell.Mod`).
In polpo only Linux syscalls are used and now connection to C userspace exists.
aoe is implemented with A2 streams and glibc terminal functions.

```text
> Compiler.Compile Hello.Mod
> Compiler.Compile source/Hello.Mod
> System.ShowFile Hello.Mod
> System.ShowFile source/Hello.Mod
> Hello.Run
> System.ListModules
> System.Time
```

File paths are relative to the directory where you start `aoe`; `Hello.Run`
loads `obj/amd64/Hello.Obj`. `System` lists its callable commands.
`System.Show` prints text, while `System.ShowFile` displays file contents.

Useful commands include `System.ListModules` (loaded modules),
`System.ShowProcesses` (runtime processes), and `System.Time` (current time).
There is no `System.ShowModules` command.

Tab completes module names, callable commands (for example
`System.Sh`), and filename/directory arguments. Ambiguous matches are listed;
unique filenames containing spaces are quoted. Completion sees freshly compiled
modules without restarting the shell. `CommandInfo` reads compiler-generated
command tables from `.Obj` files without linking or initializing the target
module; symbol files are not needed for completion. Already loaded command
tables are a fallback when object files are unavailable.
The signature rule matches command invocation: no return value, and either no
parameters or one `Commands.Context` parameter (including type aliases).
Other public procedures, functions, methods and private procedures are not
offered. This is signature-based, with no procedure-name exceptions.

Up/Down browse the last 64 commands; Left/Right, Home/End, Backspace and Delete
edit the line. Ctrl+C cancels an input line; Ctrl+D on an empty line, `exit`, or
`quit` exits. Terminal settings are restored while commands run and on exit.
Unlike polpo's stack-reset recovery, A2's existing signal handling is unchanged:
Ctrl+C does **not** stop a running command. History is in memory for this session.

### Pipes, redirection and background commands

These operators are available inside the shell and in its line-based scripts:

| Syntax | Intended behaviour |
| --- | --- |
| `Producer.Run \| Consumer.Run` | Connect one command's standard output to another's standard input. |
| `Consumer.Run < input.txt` | Read standard input from a file. |
| `System.ListModules > modules.txt` | Write standard output to a file, replacing its contents. |
| `System.ListModules >> modules.txt` | Append standard output to a file. |
| `SomeModule.Run &` | Start a command without waiting for completion. |

`Producer`, `Consumer` and `SomeModule` are illustrative module names. A working
example uses `Shell.Copy`, which copies standard input to standard output:

```text
> System.Show hello | Shell.Copy > greeting.txt
> Shell.Copy < greeting.txt | Shell.Copy >> greetings.txt
> Hello.Run > hello.txt &
> wait
```

Pipeline stages run concurrently; the shell waits for all stages of a foreground
pipeline. Any failed stage makes the pipeline fail. Standard error is not redirected.
Use matching single or double quotes around filenames or arguments containing
spaces or operator characters. Input redirection on a piped input, or output
redirection on a piped output, is rejected rather than silently overriding the pipe.

Pipes carry `Commands.Context.in` and `.out`, not command arguments (`.arg`).
Commands must use those streams to participate: `System.Show` prints arguments,
and `System.ShowFile` opens named files; neither reads piped input.

Background commands share the Oberon runtime and loaded modules; they are not
separate Linux processes. Their input is empty unless redirected or piped, so
they cannot steal shell input. `wait` (also `Shell.Wait`) waits for shell-started
background commands and reports failures. Wait before exiting if their work
must finish: runtime shutdown stops remaining activities.
`System.ShowProcesses` lists runtime threads, and `System.Kill id` terminates
one; these are low-level runtime operations, not Bash job control. Killing a
thread can leave shared state or a waiting command incomplete. There are no
`fg`/`bg` commands.

### Filtering text with grep

`grep.Word` searches for literal substrings; `grep.Regex` uses polpo's small
regular-expression engine. Both consume standard input when no files are given:

```text
> System.ShowFile Commands.Sym | grep.Word PROCEDURE
> System.ShowFile Clock.Sym | grep.Regex "Get.*" | grep.Word SIGNED32
> grep.Word -i oberon < README.md
> grep.Regex -n "^[A-Z]" source/Commands.Mod
> grep.Word -l AWAIT "source/*.Mod"
```

Options can be combined: `-i` ignores ASCII case, `-v` selects nonmatching lines,
`-l` prints only matching filenames, and `-n` adds line numbers. `--` ends option
parsing so a pattern can begin with `-`. A file operand of `-` reads standard
input. File searches prefix lines with the filename; piped input has no prefix
unless `-n` is requested. `-l` calls standard input `(standard input)`.
File masks support `*` and `?` in the basename, not recursive directory patterns.

Regex syntax includes `.`, `^`, `$`, character classes and ranges (`[a-z]`,
`[^0-9]`), repetition (`*`, `+`, `?`), and backslash escapes. There are no groups,
alternation or backreferences. Matching is byte-oriented, not Unicode-aware.
Patterns have a 255-byte compiled limit; literal metacharacters consume an extra
escape byte. Input lines grow as needed rather than being silently truncated.
LF, CRLF and CR input is accepted; matching lines are written with LF endings,
including an unterminated final line. NUL-containing input is rejected as non-text.
This command reads plain text, not encoded Oberon document files; convert those
to plain text first.

No matching lines produces a nonzero command result without a diagnostic; errors
also fail and print to standard error. As with any failed command, no match stops
a batch script or fails a pipeline. The launcher currently maps all command
failures to Linux exit status 1 rather than distinguishing grep's usual 1 and 2.
`grep.Help` summarizes usage. The adaptations and their GPLv3 license are
described in [UPSTREAM.md](UPSTREAM.md).

### Aliases and startup configuration

```text
> alias cat=System.ShowFile
> alias hello='System.Show hello'
> cat examples/Hello.Mod
> alias
> alias cat
> savealias aliases.Tool
> loadalias aliases.Tool
```

`alias` lists definitions; `alias cat` removes `cat` (`unalias cat` also works).
Aliases replace a command name with another command and initial
arguments; invocation arguments are appended. They do not expand to operators.
Alias expansion detects cycles. Tab completion includes alias names.

At startup the shell loads `Shell.Alias` from the caller's directory if present.
`loadalias` accepts both old `name=Module.Procedure` definitions and saved
`alias name=Module.Procedure` lines. `savealias` explicitly writes the current
definitions, replacing its target file. With no filename, these commands use
`Shell.Alias`, or the last successfully loaded/saved alias file.
Their direct forms are `Shell.Alias`, `Shell.Unalias`, `Shell.LoadAliases` and `Shell.SaveAliases`.

`--config` runs a line-based shell script before the requested command or shell:

```sh
./bin/amd64/aoe --config=startup.Tool
./bin/amd64/aoe --config=startup.Tool Hello.Run
```

For persistent runtime aliases, put `loadalias aliases.Tool` in `startup.Tool`,
then use `savealias` after changing aliases interactively. The startup script
itself is never automatically overwritten; it may contain other commands.
A failed startup command prevents launching the requested command or shell.
Unlike A2's old `--config`, this reads shell lines, not tilde-delimited commands;
legacy command files remain runnable with `System.DoFile`.

### Launcher names and command files

The removed launcher names mapped to these existing procedures:

| Old name | Direct call |
| --- | --- |
| `compile` | `Compiler.Compile` |
| `link` | `Linker.Link` |
| `do` | `System.DoCommands` (execute command text) |
| `execute` | `System.DoFile` (execute a command file and return) |
| `run` | `System.DoFile`, then enter the interactive shell |

`do` took command text; `execute` took a file and exited; `run` took a file and
then entered the shell. Direct `Module.Procedure` invocation replaces the command
shortcuts, but does not by itself provide `run`'s second step.
For the new line-based format, use `Shell.Source file.Tool` to execute a script
and return, or `Shell.RunFile file.Tool` to execute it and enter the shell.
Inside an existing shell, `Shell.Source` returns to that shell.
The old launcher names are not predefined, but can be defined as aliases.

`batch` enters a nested shell (`batch < commands.Tool` reads commands from a
file); `exit` or EOF returns to the outer shell. `clear` and `version` are also
available, with direct forms `Shell.Clear` and `Shell.Version`.
Host-shell redirection and pipes still work when invoking `aoe` from Linux;
argv arguments are not reparsed as shell operators. Existing Oberon command
procedures retain their interfaces.

### Scripts

With redirected input, the shell runs one command per line, without prompts:

```sh
./bin/amd64/aoe < commands.txt
./bin/amd64/aoe < build.Tool
./bin/amd64/aoe System.DoCommands 'System.Show hello~ System.Ln~'
```

Blank lines and lines starting with `#` are ignored. Batch errors stop execution
and produce a nonzero exit status. `System.DoFile` retains A2's tilde-delimited recipe format;
stdin scripts use one complete command per line.

Application imports need matching `.Sym` files to compile and `.Obj` files
to run. Additional libraries can be added, but desktop-dependent modules are
not included. Compiler options with values use `=`, e.g. `--destPath=objects/`;
create the output directory first. The upstream argument channel still joins
arguments into a command string: for a source filename containing spaces,
preserve literal Oberon quotes, e.g. `'"my source.Mod"'`.

## Rebuild itself

```sh
bin/amd64/aoe < build.Tool
```

The recipe compiles all included sources into `obj/amd64/` and replaces
`bin/amd64/aoe` with an executable runner. It stops on the first error. To keep
the previous installation, copy the distribution to another directory and run
the same command there. See [BUILD.md](BUILD.md) for details.

## Tests

```sh
sh test.sh .
```

Tests check compilation, dynamic loading, active objects,
batch input and EOF, pipes, redirection, background execution and waiting,
alias persistence, startup configuration, nested shells, failing exit codes, relocation,
paths containing spaces, and the absence of loaded GUI
modules. They also rebuild every included module and
the runner twice, checking that the two fresh generations
have byte-identical executables, object files
and symbol files.

A2 embeds a build date in `Machine`, so rebuilding a checked-in
binary on another date is not expected to reproduce that old
binary exactly.

The original A2 binary bootstrap omits `OVERRIDE` annotations that the current
source compiler emits in textual symbol files. This difference settles after
the first self-hosted generation; the checked-in binaries come from a
self-hosted build. The tests do not modify the installed distribution.

## License

aoe's original code, examples, build scripts and tests, and our modifications
to upstream code, are licensed under the GNU General Public License version 3
only (`GPL-3.0-only`). The complete license is in [LICENSE](LICENSE).

Existing third-party code retains its original copyright notices and license
terms. In particular, the imported A2 sources retain the notices and terms in
[license.txt](license.txt) and their source headers; the polpo grep adaptations
are GPLv3, with their upstream license also preserved in
[license-polpo.txt](license-polpo.txt). See [UPSTREAM.md](UPSTREAM.md) for provenance.
The combined aoe distribution is distributed under GPLv3, with the applicable
upstream notices retained.

## Dependencies and provenance

The executable shell needs Linux ELF startup, glibc/libdl,
pthreads and active-object runtime.
It needs Linux `/proc`, `/lib64/ld-linux-x86-64.so.2`,
and the libraries expected by `Linux.Unix.Mod`.
