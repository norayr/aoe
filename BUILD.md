# A2 compiler and aoe shell (active oberon environment).

Rebuild from the repository root using the checked-in runner and compiler modules:

```sh
bin/amd64/aoe < build.Tool
```

`build.Tool` compiles all included modules into `obj/amd64/` and links
`bin/amd64/aoe` in place. The linked file is made executable. Batch execution
stops on the first error, so a failed compilation does not proceed to linking.
The linker writes `link.log`.

The distribution contains a native `bin/amd64/aoe` ELF runner, a small interactive
shell, the Fox Active Oberon compiler's Oberon frontend and AMD backend, the
linker, and their runtime dependencies. `source/` contains only the selected
sources, listed in compilation order in `build.Tool`.

## Use

From any working directory:

```sh
/path/to/aoe/bin/amd64/aoe                  # shell; Tab completion, Ctrl+D to exit
/path/to/aoe/bin/amd64/aoe Compiler.Compile -p=Unix64 Hello.Mod
/path/to/aoe/bin/amd64/aoe Hello.Run         # loads obj/amd64/Hello.GofUu
/path/to/aoe/bin/amd64/aoe System.ShowFile source/Hello.Mod
/path/to/aoe/bin/amd64/aoe System.DoFile commands.txt
/path/to/aoe/bin/amd64/aoe < lines.txt       # one complete command per line
```

The runner searches the current directory, its `obj/amd64/`, and the installation's
`obj/amd64/`. It discovers its location through Linux `/proc/self/exe`; the distribution can be
moved and does not need the original repository. Compilation writes object and
symbol files into the project's `obj/amd64/` by default, creating it if needed.
Explicit `--destPath=./` preserves current-directory output. Imports need matching
`.SymUu` files; execution needs matching `.GofUu` files. Compiler options with
values use `=`, for example `--destPath=objects/` (create the directory first).
The upstream argument channel joins argv into a command string; for filenames
with spaces, preserve literal Oberon quotes, e.g. `'"my source.Mod"'`.

`examples/Hello.Mod` demonstrates a command using an active object and AWAIT.
Application modules must stay within the included dependencies unless you add
more modules yourself. Commands accept `Commands.Context`, with standard input,
output, error and argument streams. The original desktop's autostart services,
network services and graphical tools are not started or included.

## Self-hosting

From the distribution directory:

```sh
bin/amd64/aoe < build.Tool
bin/amd64/aoe System.Time
```

This recompiles every included source and replaces the runner using the
distribution's own Oberon compiler and linker. To keep a previous installation,
copy the distribution into another directory and run the same command there.

## Tests

```sh
sh test.sh .
```

The test compares two fresh self-hosted generations byte-for-byte, including
the runner and all object and symbol files. A2 embeds the build date in `Machine`,
so a binary built on another day can legitimately differ. The historical bootstrap
omits `OVERRIDE` annotations which the source compiler emits in textual symbol
files; these settle after the first self-hosted generation. Tests use disposable
copies and can be repeated without modifying the installed distribution.
