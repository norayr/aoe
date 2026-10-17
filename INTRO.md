# A gentle introduction to aoe

## Contents

- Background
- Introduction
- Basic compilation units
- Using multiple modules
- Module initialization
- What is Commands.Context?
- Command arguments
- Standard input and standard output
- Connecting commands
- Reading a file
- Data and control structures
- Active objects
- Shell command files and aliases
- A few useful habits

## Background

This note is written for someone who is learning aoe for the first time and has
done some programming in Pascal, Modula-2, C or C++. It is not intended to be a
complete Active Oberon language manual. Our aim is to write a small program,
understand how it is called, and then connect it to other programs.

The organization follows the gradual, example-based approach of
*A Gentle Introduction to Modula-2* by M. Cheng: begin with modules and their
interfaces, introduce the necessary runtime facilities, and explain what each
example actually does. The examples here are for aoe, not for the Modula-2
compiler described in that note.

For installation details, see [BUILD.md](BUILD.md). For the complete shell
reference, see [README.md](README.md). The separate
[Active Oberon introduction](ACTIVE_OBERON_INTRO.md), if present in your working
copy, discusses monitors and concurrency in more detail.

## Introduction

aoe means *Active Oberon environment*. It combines a compiler, a linker, a module
loader, a runtime and a small command shell. The current distribution runs on
Linux x86-64 and uses glibc and native threads. It does not start the A2 desktop.

An aoe command is usually an exported procedure in an Oberon module. For example,
`System.Time` means "call the procedure Time in the module System". It is not the
name of a separate Linux executable.

Start the shell from the repository directory:

```sh
$ ./bin/amd64/aoe
```

Here `$` represents your Linux shell's prompt; do not type it. aoe displays its
own prompt, shown below as `>`:

```text
> System.Time
> System.ListModules
> help
```

Tab completes module names, callable procedures and filenames. The arrow keys
edit the line or recall previous commands. Type `exit`, or press Ctrl+D on an
empty command line, to leave the shell. Ctrl+C cancels a line being edited; it
does not interrupt a running command.

Question: Is aoe another Bash?

Not quite. It has familiar pipes and redirection, but its normal commands are
Oberon procedures sharing one runtime. Typing `ls` does not automatically run
Linux's `/bin/ls`. Nor should we assume that Bash's expansion or scripting syntax
is available.

You may also execute one command directly from Linux:

```sh
$ ./bin/amd64/aoe System.Time
```

That invocation starts its own runtime and exits after the command. Commands
entered at one ongoing aoe prompt share that prompt's runtime instead.

## Basic compilation units

An Active Oberon program is organized into modules. A module contains declarations
of constants, types, variables and procedures. Unlike the Modula-2 examples in
the reference note, our examples do not use separate `DEFINITION MODULE` and
`IMPLEMENTATION MODULE` source files. An asterisk marks an exported declaration.

Save this complete module as `First.Mod`:

```oberon
MODULE First;

IMPORT Commands;

PROCEDURE Run*(context: Commands.Context);
BEGIN
  context.out.String("Hello from aoe!");
  context.out.Ln
END Run;

END First.
```

Compile and call it inside aoe:

```text
> Compiler.Compile First.Mod
> First.Run
Hello from aoe!
```

`MODULE First` names the module. `IMPORT Commands` makes another module's
interface available. `Run*` exports the procedure so that other modules and the
command runner can find it. The final `END First.` ends the module; the dot is
part of the syntax.

Comments use `(* ... *)`, and assignment uses `:=`. A semicolon separates
statements. We use uppercase keywords and preserve the spelling of identifiers.

Compilation normally creates:

```text
obj/amd64/First.Obj
obj/amd64/First.Sym
```

The `.Obj` file contains the compiled A2 module. It is not an ordinary ELF object
to pass to the Linux linker. The `.Sym` file is the compiler's textual interface
information. The compiler reads symbol files when checking imports; the runtime
loads object files when executing modules.

There is no separate link step for this command. aoe's module loader loads
`First.Obj` when `First.Run` needs it.

Note: These paths belong to the directory from which you started aoe. You can
keep your programs in a separate project directory and invoke the installed
runner by its absolute path. The compiler creates that project's `obj/amd64/`.
The installation's own modules remain available through its search path.

## Using multiple modules

A module interface is a contract between its implementation and its users.
Suppose one module provides a small calculation. Save this as `Arithmetic.Mod`:

```oberon
MODULE Arithmetic;

PROCEDURE Add*(left, right: SIGNED32): SIGNED32;
BEGIN
  RETURN left + right
END Add;

END Arithmetic.
```

Save its user as `UseArithmetic.Mod`:

```oberon
MODULE UseArithmetic;

IMPORT Commands, Arithmetic;

PROCEDURE Run*(context: Commands.Context);
BEGIN
  context.out.Int(Arithmetic.Add(20, 22), 0);
  context.out.Ln
END Run;

END UseArithmetic.
```

Compile the provider first, then its user:

```text
> Compiler.Compile Arithmetic.Mod
> Compiler.Compile UseArithmetic.Mod
> UseArithmetic.Run
42
```

`IMPORT Arithmetic` declares a dependency; it is not textual inclusion like
C's `#include`. The compiler checks calls against `Arithmetic.Sym`. The loader
uses the dependency information to load the required compiled modules.

Question: Why can we call `UseArithmetic.Run` from the shell, but not
`Arithmetic.Add 20 22`?

Because being exported and being a shell command are different properties.
The command runner accepts procedures with no return value and either no
parameters or one `Commands.Context` parameter. `Add` is an ordinary programming
interface with two integer parameters and a result. We call it from Oberon code.

You can examine the interface information without opening an editor:

```text
> System.ShowFile Arithmetic.Sym
> System.ShowFile Commands.Sym | grep.Word PROCEDURE
```

Symbol files can include compiler-required private declarations and layout
information as well as public declarations. They are not polished API manuals.
Typing a module name alone, such as `System`, lists only its callable commands.

## Module initialization

A module may have a final `BEGIN ... END` body. Its purpose is normally
initialization, not a command to repeat each time the user types something.
Save this example as `Visits.Mod`:

```oberon
MODULE Visits;

IMPORT Commands;

VAR count: SIGNED32;

PROCEDURE Next*(context: Commands.Context);
VAR current: SIGNED32;
BEGIN
  BEGIN {EXCLUSIVE}
    INC(count); current := count
  END;
  context.out.Int(current, 0);
  context.out.Ln
END Next;

BEGIN
  count := 0
END Visits.
```

After compilation, try this in one shell:

```text
> Visits.Next
1
> Visits.Next
2
```

The initialization runs when the module is initialized during loading, normally
once per loaded lifetime. The module variable `count` survives between commands.
The local variable `current` belongs to each procedure invocation.

The exclusive region protects the increment if different command threads call
`Next` concurrently. Printing is outside the region. The numbers are unique for
those participating calls, but concurrent output need not appear in number order.

Two separate Linux invocations of `aoe Visits.Next` each start a new runtime,
so they each print `1`. Recompiling `Visits.Mod` does not automatically replace
the version already loaded in an ongoing shell. Starting a fresh aoe process is
the simplest way to test a newly compiled version.

## What is Commands.Context?

The exact name is **`Commands.Context`**, not `Command.Context`. `Commands` is the
module; `Context` is an object type exported by that module.

The context describes one command invocation. The runner creates it and passes
it to your procedure. You normally do not need to construct one yourself.

Its most useful members are:

| Member | Meaning |
| --- | --- |
| `context.arg` | Reader containing the command's textual arguments |
| `context.in` | Reader for standard input |
| `context.out` | Writer for standard output |
| `context.error` | Writer for diagnostic output |
| `context.result` | Command result: `Commands.Ok` means success |
| `context.caller` | Reference supplied by the caller, for caller-specific information |

The context is an object reference, not a C `argc`/`argv` array and not a saved
CPU register context. It carries access to the command's input and output
channels. A stream may be backed by the terminal, a file or an in-memory pipe.

Question: Why not always write to a global console object?

Because a command should write to the destination chosen by its caller. If it
writes through `context.out`, it works on the screen, in a file and in a
pipeline without changing its source code. A hardwired console writer bypasses
that arrangement.

The context's stream references cannot simply be reassigned by the command,
but the referenced readers and writers provide their normal reading and writing
operations. Setting `context.result` is how a command reports failure. It is
initially `Commands.Ok`.

## Command arguments

Save this as `Greeting.Mod`:

```oberon
MODULE Greeting;

IMPORT Commands;

PROCEDURE Say*(context: Commands.Context);
VAR name: ARRAY 128 OF CHAR;
BEGIN
  IF ~context.arg.GetString(name) THEN
    context.error.String("Usage: Greeting.Say name");
    context.error.Ln;
    context.result := Commands.CommandParseError;
    RETURN
  END;
  context.out.String("Hello, ");
  context.out.String(name);
  context.out.Char("!");
  context.out.Ln
END Say;

END Greeting.
```

Compile it, then try:

```text
> Greeting.Say Ada
Hello, Ada!
> Greeting.Say "Ada Lovelace"
Hello, Ada Lovelace!
```

`GetString` skips whitespace and reads an optionally quoted argument. It returns
`FALSE` if there is no next argument. `~` means logical negation, like C's `!`.
`ARRAY 128 OF CHAR` has room for 127 characters followed by a zero terminator.
This convenience reader truncates oversized strings; a production command
which must reject them needs checked argument parsing, as `grep` uses.

Diagnostics go to `context.error`, not `context.out`. This keeps an error message
from being mistaken for normal data by the next pipeline stage. Returning from
the procedure is not itself an error; setting `context.result` makes it one.

When calling from the Linux shell, arguments are currently joined into an
Oberon command string. To preserve a single argument containing spaces, include
literal Oberon quotes:

```sh
$ /path/to/aoe/bin/amd64/aoe Greeting.Say '"Ada Lovelace"'
```

Note: There is no automatic connection between `context.arg` and `context.in`.
`Greeting.Say Ada` supplies an argument. Piping the word `Ada` into a command
supplies standard input instead. The command must read the appropriate channel.

## Standard input and standard output

The `Streams` module provides buffered readers and writers. Some common writer
operations are:

```oberon
context.out.String("answer: ");
context.out.Int(42, 0);
context.out.Ln;
context.out.Update;
```

The second argument of `Int` is the output field width; zero requests no padding.
`Ln` writes A2's CRLF newline. For a Unix-text filter that deliberately emits LF,
use `context.out.Char(0AX)`. `Update` flushes buffered output. The command runner
also flushes on return, but a prompt or long-running service may need to flush
before waiting for input.

### A complete input filter

Save this module as `Filters.Mod`:

```oberon
MODULE Filters;

IMPORT Commands, Streams;

PROCEDURE Upper*(context: Commands.Context);
VAR ch: CHAR;
BEGIN
  LOOP
    context.in.Char(ch);
    IF context.in.res # Streams.Ok THEN EXIT END;
    IF (ch >= "a") & (ch <= "z") THEN ch := CAP(ch) END;
    context.out.Char(ch);
    IF context.out.res # Streams.Ok THEN EXIT END
  END;
  context.out.Update;
  IF ((context.in.res # Streams.Ok) & (context.in.res # Streams.EOF)) OR
     (context.out.res # Streams.Ok) THEN
    context.error.String("Filters.Upper: input/output failed");
    context.error.Ln;
    context.result := Commands.CommandError
  END
END Upper;

PROCEDURE Copy*(context: Commands.Context);
VAR buffer: ARRAY 4096 OF CHAR; count: SIZE;
BEGIN
  WHILE (context.in.res = Streams.Ok) & (context.out.res = Streams.Ok) DO
    context.in.Bytes(buffer, 0, LEN(buffer), count);
    IF count > 0 THEN context.out.Bytes(buffer, 0, count) END
  END;
  context.out.Update;
  IF (context.in.res # Streams.EOF) OR (context.out.res # Streams.Ok) THEN
    context.error.String("Filters.Copy: input/output failed");
    context.error.Ln;
    context.result := Commands.CommandError
  END
END Copy;

END Filters.
```

Compile it and use a file as standard input:

```text
> Compiler.Compile Filters.Mod
> Filters.Upper < First.Mod
> Filters.Copy < First.Mod > first-copy.txt
```

`Char` reads one byte into `ch`. The reader's `res` field reports the result of
that operation: `Streams.Ok` means that a byte was read, while `Streams.EOF`
means end of input. Notice that we check the result **after** reading and before
using the byte. Otherwise we could print a spurious byte after EOF.

Question: Can we use `ch = 0X` as the end-of-file test?

Not for arbitrary data. A zero byte can be real input. The status field tells
us whether the read succeeded. The copy procedure therefore works for binary
data too, while `Upper` is an ASCII transformation, not Unicode case conversion.

For block reads, process the returned `count` even if the read also reports EOF:
the final block may be shorter than the requested size. `Bytes` writes exactly
the requested byte count; `String` instead stops at a zero terminator.

For simple bounded text, `context.in.Ln(line)` reads a line into a character
array and consumes its line ending. It silently truncates lines longer than
the array. Use a growing buffer when complete lines matter; the included
`grep` module demonstrates that approach.

Do not use `Available() = 0` to decide that a pipe has finished. It can mean that
no bytes are available *yet*. A normal read waits for input or EOF.

## Connecting commands

A filter becomes useful when we can reuse it without knowing its source or
destination. Try:

```text
> System.Show hello | Filters.Upper
> System.ShowFile First.Mod | Filters.Upper | grep.Word PROCEDURE
> Filters.Copy < First.Mod | grep.Word context > context-lines.txt
```

The shell connects the first command's `context.out` to the second command's
`context.in`. Additional pipes connect additional stages. Each stage still has
its own argument reader. Thus `PROCEDURE` above is an argument to `grep.Word`,
not part of the text sent by `Filters.Upper`.

Pipeline stages execute concurrently. Their buffers are bounded, so a producer
may wait while the consumer catches up. They are not separate Linux processes;
they share the aoe runtime. Our filter's local variables are local to each call,
so two calls to `Filters.Upper` do not share a single character variable.

Question: Must our filter create an active object to participate in a pipe?

No. The shell supplies concurrent command execution. An ordinary procedure
which reads `context.in` and writes `context.out` is enough.

`>` replaces an output file, `>>` appends, and `<` supplies an input file.
Diagnostics remain on standard error; the current shell does not implement
Bash's full redirection syntax such as `2>`.

The new search commands are:

```text
> grep.Word -i oberon < README.md
> grep.Regex -n "^[A-Z]" First.Mod
> grep.Help
```

`Word` means a literal substring search, not whole-word matching. `Regex` supports
a small byte-oriented syntax, including character classes, anchors and
repetition, but not groups or alternation. Both support `-i`, `-v`, `-l` and `-n`.

No matches gives `Commands.NoMatch`: a nonzero result without an error message.
Errors also fail. Any failed stage makes a pipeline fail, and a failed command
stops a line-based batch script. The Linux launcher currently maps command
failures to exit status 1.

## Reading a file

Standard input is appropriate when the caller chooses the source. Sometimes a
command's own argument names the file it must open. Save this as `FileExample.Mod`:

```oberon
MODULE FileExample;

IMPORT Commands, Streams, Files;

PROCEDURE Show*(context: Commands.Context);
VAR name: Files.FileName; file: Files.File; reader: Files.Reader; ch: CHAR;
BEGIN
  IF ~context.arg.GetString(name) THEN
    context.error.String("Usage: FileExample.Show filename");
    context.error.Ln;
    context.result := Commands.CommandParseError;
    RETURN
  END;
  file := Files.Old(name);
  IF file = NIL THEN
    context.error.String("Cannot open "); context.error.String(name);
    context.error.Ln;
    context.result := Commands.CommandError;
    RETURN
  END;
  Files.OpenReader(reader, file, 0);
  LOOP
    reader.Char(ch);
    IF reader.res # Streams.Ok THEN EXIT END;
    context.out.Char(ch);
    IF context.out.res # Streams.Ok THEN EXIT END
  END;
  context.out.Update;
  IF (reader.res # Streams.EOF) OR (context.out.res # Streams.Ok) THEN
    context.result := Commands.CommandError
  END
END Show;

END FileExample.
```

`Files.Old` opens an existing file, or returns `NIL` if it cannot. `OpenReader`
starts at byte position zero. A `Files.Reader` extends `Streams.Reader`, so its
reading operations are the same ones we used for standard input.

```text
> Compiler.Compile FileExample.Mod
> FileExample.Show First.Mod | grep.Word context
```

Note: `Files.Old` uses the configured file search paths. This is convenient for
finding `Commands.Sym`, but a tool that must inspect only the caller's exact
filename should resolve that path explicitly. The included grep does so.

## Data and control structures

Active Oberon retains familiar Pascal-style variables, arrays, records,
procedures and control structures. A few details prevent unnecessary surprises:

- `=` compares, `#` means not equal, `:=` assigns.
- `&`, `OR` and `~` are Boolean and, or and not.
- Arrays begin at index zero. `ARRAY 10 OF SIGNED32` has indices 0 through 9.
- `LEN(a)` gives an array's length. `VAR` parameters refer to the caller's
  variable; `CONST` parameters provide read-only access.
- Both result-returning functions and procedures use the keyword `PROCEDURE`.
  A result type follows the parameter list, as in `Add(...): SIGNED32`.
- `NIL` is a nil reference. `NEW` allocates an object or a pointer-referenced
  structure. Ordinary heap memory is garbage-collected; resource shutdown still
  needs an explicit design.

For this compiler, prefer explicit numeric widths when they matter:

| Type | Size in the Linux x86-64 build |
| --- | --- |
| `SIGNED8`, `SIGNED16`, `SIGNED32`, `SIGNED64` | 1, 2, 4, 8 bytes respectively |
| `UNSIGNED8`, `UNSIGNED16`, `UNSIGNED32`, `UNSIGNED64` | The corresponding unsigned widths |
| `INTEGER` | 4 bytes |
| `LONGINTEGER`, `SIZE`, `ADDRESS` | 8 bytes |
| `FLOAT32` | 4 bytes |
| `FLOAT64`, `REAL` | 8 bytes |
| `CHAR`, `BOOLEAN` | 1 byte |

Older Oberon material may use `HUGEINT` for a 64-bit integer. Our examples use
`SIGNED64`. Do not apply another compiler's `INTEGER` or `REAL` sizes to this
one. `SIZEOF(type)` reports storage size in bytes.

## Active objects

An ordinary object contains state and methods. An *active* object additionally
has an independently executing body. Save this as `ActiveExample.Mod`:

```oberon
MODULE ActiveExample;

IMPORT Commands;

TYPE Worker = OBJECT
VAR done: BOOLEAN; value: SIGNED32;

  PROCEDURE &Init;
  BEGIN done := FALSE END Init;

  PROCEDURE Result(): SIGNED32;
  BEGIN {EXCLUSIVE}
    AWAIT(done);
    RETURN value
  END Result;

BEGIN {ACTIVE, EXCLUSIVE}
  value := 6 * 7;
  done := TRUE
END Worker;

PROCEDURE Run*(context: Commands.Context);
VAR worker: Worker;
BEGIN
  NEW(worker);
  context.out.Int(worker.Result(), 0);
  context.out.Ln
END Run;

END ActiveExample.
```

The procedure marked `&` is an initializer. `NEW(worker)` constructs the object
and starts its active body after initialization. `Result` is still an ordinary
method call executed by its caller. `{ACTIVE}` does not turn all calls into
messages sent to the object's activity.

The active body and `Result` use the same object's monitor through `{EXCLUSIVE}`.
If `Result` enters first, `AWAIT(done)` releases that monitor while waiting.
The active body can enter, compute the result and finish. The waiting caller
then continues with the monitor held. If the body finishes first, `Result`
finds `done` already true.

```text
> Compiler.Compile ActiveExample.Mod
> ActiveExample.Run
42
```

Question: Does an exclusive call interrupt the code already in the object?

No. A caller waits for an occupied monitor; it does not push its current owner
aside. Non-exclusive code does not acquire that monitor and can overlap with
exclusive code on another thread. Protect all competing accesses to shared
state with a consistent discipline, not just the assignments.

Also distinguish an *active object* from a *background shell command*:

```text
> ActiveExample.Run > answer.txt &
> wait
```

`&` tells the shell not to wait immediately. `wait` waits for its background
commands and reports their failures. Such work shares the runtime and may be
stopped when the runtime shuts down; a background command is not a detached
Linux service. Its default standard input is empty unless redirected or piped.

## Shell command files and aliases

For a short command file, save plain text such as this as `lesson.Tool`:

```text
# Build and run our first example.
Compiler.Compile First.Mod
First.Run
System.Time
```

Execute it from Linux:

```sh
$ /path/to/aoe/bin/amd64/aoe < lesson.Tool
```

Or execute it inside aoe and return to the current shell:

```text
> Shell.Source lesson.Tool
```

Each line is one complete shell command. Blank lines and lines beginning with
`#` are ignored. A failure stops the file. There are no implied multiline Bash
constructs. `System.DoFile` is a different, older facility for A2's
tilde-delimited command files; do not confuse the two formats.

An alias can shorten a command without changing the module interface:

```text
> alias upper=Filters.Upper
> alias grep=grep.Word
> System.Show hello | upper | grep HELLO
> savealias aliases.Tool
```

Load saved definitions later with `loadalias aliases.Tool`. Saving is explicit;
the shell does not automatically overwrite a startup file. At startup it loads
the caller's `Shell.Alias` if present. Alternatively, put
`loadalias aliases.Tool` in a startup script and launch with
`--config=startup.Tool`.

## A few useful habits

1. Keep ordinary library operations separate from their command wrappers.
   `Arithmetic.Add` performs a calculation; `UseArithmetic.Run` connects it to
   the shell. Not every useful procedure needs a command context.
2. Use `context.arg` for arguments, `context.in` for data, `context.out` for
   results and `context.error` for diagnostics. This is the foundation of a
   reusable filter.
3. Check a read's result before using its character. With block reads, preserve
   the final partial block. Flush buffered output when the next operation
   depends on it being visible.
4. Keep temporary command state local. Module globals live across commands and
   can be shared by concurrent pipeline or background calls.
5. Test new compilations in a fresh process when an older module may already
   be loaded. Completion discovering new metadata is not hot code replacement.
6. Use Tab, module command listings and textual symbol files to explore. Classic
   Oberon's `System.ShowModules` is called `System.ListModules` in this A2 runtime.

Finally, aoe can rebuild itself. From the repository directory, in your **Linux**
shell, run:

```sh
$ bin/amd64/aoe < build.Tool
$ sh test.sh .
```

The first command recompiles the included sources and links the runner. The
second checks the shell and tools and compares two freshly self-hosted
generations. Our small commands are using the same compiler, module system and
runtime that build the environment itself.
