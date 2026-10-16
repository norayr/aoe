#!/bin/sh
# Test the installation and two self-hosted generations.
set -eu

[ "$#" -eq 1 ] || { echo 'usage: test.sh distribution' >&2; exit 1; }
distribution=$(CDPATH= cd "$1" && pwd -P)
runner=$distribution/bin/amd64/aoe
tmp=$(mktemp -d "${TMPDIR:-/tmp}/aoe-test.XXXXXXXX")
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
unset DISPLAY AOSPATH

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {
    if ! timeout 300 "$@" > "$tmp/output" 2>&1; then
        cat "$tmp/output" >&2
        fail "$*"
    fi
}
reject() {
    if timeout 30 "$@" > "$tmp/output" 2>&1; then
        fail "unexpected success: $*"
    else
        status=$?
        [ "$status" -eq 1 ] || { cat "$tmp/output" >&2; fail "exit $status: $*"; }
    fi
}
contains() { grep -Fq "$1" "$tmp/output" || { cat "$tmp/output" >&2; fail "missing output: $1"; }; }

mkdir "$tmp/work"
cp "$distribution/examples/Hello.Mod" "$tmp/work/Hello.Mod"
cd "$tmp/work"
run "$runner" Compiler.Compile -p=Unix64 Hello.Mod
contains 'Hello done.'
[ -f obj/amd64/Hello.GofUu ] && [ -f obj/amd64/Hello.SymUu ] || fail 'missing compiled module'
[ ! -e Hello.GofUu ] || fail 'default compiler output still uses current directory'
run "$runner" Hello.Run
contains 'Hello from an Active Oberon CLI object!'
if [ -L "$distribution/aoe" ]; then
    run "$distribution/aoe" Hello.Run
    contains 'Hello from an Active Oberon CLI object!'
fi
cat > UseHello.Mod <<'MODULE'
MODULE UseHello;
IMPORT Hello, Commands;
PROCEDURE Run*(context: Commands.Context);
BEGIN Hello.Run(context) END Run;
END UseHello.
MODULE
run "$runner" Compiler.Compile UseHello.Mod
run "$runner" UseHello.Run
contains 'Hello from an Active Oberon CLI object!'
run env PWD=/a/stale/working/directory "$runner" Hello.Run
contains 'Hello from an Active Oberon CLI object!'
printf 'Hello.Run\nexit\n' > "$tmp/input"
run "$runner" < "$tmp/input"
contains 'Hello from an Active Oberon CLI object!'
run "$runner" < /dev/null
printf '# a batch comment\nSystem.Show batch\nSystem.Ln\nHello.Run' > "$tmp/input"
run "$runner" < "$tmp/input"
contains batch
contains 'Hello from an Active Oberon CLI object!'
if grep -Fq '> ' "$tmp/output"; then fail 'batch mode prints interactive prompts'; fi
run "$runner" System
contains System.Show
run "$runner" System.ShowFile Hello.Mod
contains 'MODULE Hello;'
mkdir source
cp Hello.Mod source/Hello.Mod
run "$runner" System.ShowFile source/Hello.Mod
contains 'MODULE Hello;'
run "$runner" Compiler.Compile --destPath=./ Hello.Mod
[ -f Hello.GofUu ] && [ -f Hello.SymUu ] || fail 'explicit current-directory output failed'
run "$runner" Hello.Run
contains 'Hello from an Active Oberon CLI object!'
reject "$runner" MissingModule.Run
reject "$runner" --notAnOption
reject "$runner" compile Hello.Mod
reject "$runner" do 'System.Show old-alias'
reject "$runner" Compiler.Compile -p=NotAPlatform Hello.Mod
reject "$runner" Compiler.Compile --notAnOption Hello.Mod
printf 'MODULE Broken; BEGIN notDeclared := 1 END Broken.\n' > Broken.Mod
reject "$runner" Compiler.Compile Broken.Mod
reject "$runner" Compiler.Compile Missing.Mod
printf 'MissingModule.Run\nSystem.Show still-running\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
if grep -Fq still-running "$tmp/output"; then fail 'batch continues after a failed command'; fi
run "$runner" System.DoCommands 'Compiler.Compile -p=Unix64 Hello.Mod~ Hello.Run~ System.ListModules~'
contains 'Hello from an Active Oberon CLI object!'
if grep -Eq 'XDisplay|WindowManager|WMGraphics|KbdMouse|DisplayRefresher' "$tmp/output"; then
    fail 'loaded a desktop module'
fi
echo 'PASS: compile, dynamic loading, active objects, shell, error status and no GUI modules'

cat > CommandProbe.Mod <<'MODULE'
MODULE CommandProbe;
IMPORT C := Commands, Files;
TYPE ContextAlias = C.Context;
  Other = OBJECT
    PROCEDURE Method*;
    END Method;
  END Other;
VAR marker: Files.File;
PROCEDURE NoArguments*;
END NoArguments;
PROCEDURE WithContext*(context: C.Context);
END WithContext;
PROCEDURE WithAlias*(context: ContextAlias);
END WithAlias;
PROCEDURE Get*(context: C.Context);
END Get;
PROCEDURE ScalarArgument*(value: SIGNED32);
END ScalarArgument;
PROCEDURE OtherArgument*(value: Other);
END OtherArgument;
PROCEDURE AnyArgument*(value: ANY);
END AnyArgument;
PROCEDURE MultipleArguments*(a, b: C.Context);
END MultipleArguments;
PROCEDURE ReturnedObject*(): Other;
BEGIN RETURN NIL END ReturnedObject;
PROCEDURE ReturnedContext*(context: C.Context): C.Context;
BEGIN RETURN context END ReturnedContext;
PROCEDURE Private;
END Private;
BEGIN marker := Files.New("command-info-initialized"); Files.Register(marker);
END CommandProbe.
MODULE
run "$runner" Compiler.Compile CommandProbe.Mod
run "$runner" CommandProbe
printf 'CommandProbe.Get\nCommandProbe.NoArguments\nCommandProbe.WithAlias\nCommandProbe.WithContext\n' > expected-commands
tr -d '\r' < "$tmp/output" > actual-commands
cmp expected-commands actual-commands || fail 'command discovery differs from callable signatures'
[ ! -e command-info-initialized ] || fail 'command discovery initialized a module'
# Completion must work from object metadata alone, not depend on symbol files.
mv obj/amd64/CommandProbe.SymUu CommandProbe.symbol-backup
run "$runner" CommandProbe
tr -d '\r' < "$tmp/output" > actual-commands
cmp expected-commands actual-commands || fail 'command discovery needs symbol files'
[ ! -e command-info-initialized ] || fail 'binary-only discovery initialized a module'
run "$runner" CommandProbe.Get
[ -e command-info-initialized ] || fail 'fixture command did not initialize its module'
run "$runner" CommandProbe.WithAlias
run "$runner" CommandProbe.NoArguments
run "$runner" Clock
[ ! -s "$tmp/output" ] || fail 'Clock exports non-command procedures as commands'
run "$runner" System
cp "$tmp/output" expected-static-commands
mkdir -p "$tmp/static-only/bin/amd64"
cp "$runner" "$tmp/static-only/bin/amd64/aoe"
run "$tmp/static-only/bin/amd64/aoe" System
cmp expected-static-commands "$tmp/output" || fail 'loaded command-table fallback differs from object metadata'
reject "$runner" CommandProbe.ScalarArgument
reject "$runner" CommandProbe.ReturnedContext
echo 'PASS: signature-based command discovery, type aliases, binary-only metadata and no initializer side effects'

cat > ShellProbe.Mod <<'MODULE'
MODULE ShellProbe;
IMPORT Commands;
TYPE Gate = OBJECT
VAR released: BOOLEAN;
  PROCEDURE Release;
  BEGIN {EXCLUSIVE} released := TRUE END Release;
  PROCEDURE Wait;
  BEGIN {EXCLUSIVE} AWAIT(released) END Wait;
END Gate;
VAR gate: Gate;
PROCEDURE Block*(context: Commands.Context);
BEGIN gate.Wait; context.out.String("background finished"); context.out.Ln END Block;
PROCEDURE Release*;
BEGIN gate.Release END Release;
PROCEDURE Fail*(context: Commands.Context);
BEGIN context.result := Commands.CommandError END Fail;
PROCEDURE Trap*(context: Commands.Context);
BEGIN ASSERT(context = NIL) END Trap;
BEGIN NEW(gate);
END ShellProbe.
MODULE
run "$runner" Compiler.Compile ShellProbe.Mod
dd if=/dev/zero of=large.bin bs=1024 count=80 2>/dev/null
cat > "$tmp/input" <<'SCRIPT'
System.Show first>"pipe output.txt"
System.Show second >> "pipe output.txt"
Shell.Copy < "pipe output.txt" | Shell.Copy | Shell.Copy > copied.txt
Shell.Copy < large.bin | Shell.Copy | Shell.Copy > binary-copy.bin
Shell.Copy < large.bin | Shell.Copy > background-copy.bin &
ShellProbe.Block > background.txt &
System.Show foreground > foreground.txt
ShellProbe.Release
wait
System.ShowFile background.txt
SCRIPT
run "$runner" < "$tmp/input"
contains 'background finished'
printf ' first second' > expected.txt
cmp expected.txt copied.txt || fail 'pipes, append or quoted redirection failed'
cmp large.bin binary-copy.bin || fail 'large binary pipeline differs'
cmp large.bin background-copy.bin || fail 'background pipeline differs'
[ -s foreground.txt ] || fail 'background command blocked the shell'
printf 'System.Show replacement > copied.txt\n' > "$tmp/input"
run "$runner" < "$tmp/input"
printf ' replacement' > expected.txt
cmp expected.txt copied.txt || fail 'output redirection did not truncate'
printf 'Shell.Copy < missing-input\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
printf 'ShellProbe.Fail | Shell.Copy\nSystem.Show still-running\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
if grep -Fq still-running "$tmp/output"; then fail 'pipeline error did not stop script'; fi
# A consumer that exits, fails or traps must unblock a producer with a full pipe.
printf 'Shell.Copy < large.bin | System.Show done\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
printf 'Shell.Copy < large.bin | MissingModule.Run\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
printf 'Shell.Copy < large.bin | ShellProbe.Trap\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
printf 'ShellProbe.Fail &\nwait\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
printf 'Shell.Copy > background-input.txt &\nwait\nSystem.Show did-not-steal-input\n' > "$tmp/input"
run "$runner" < "$tmp/input"
contains did-not-steal-input
[ ! -s background-input.txt ] || fail 'background command consumed shell input'
for bad in '| System.Time' 'System.Time |' 'System.Time &&' 'System.Time >' \
    'System.Time > a > b' 'System.Time | Shell.Copy < large.bin' \
    'System.Time > a | Shell.Copy' 'System.Time > ""' 'System.Show "unterminated' 'wait &'; do
    printf '%s\n' "$bad" > "$tmp/input"
    reject "$runner" < "$tmp/input"
done
printf '%s\n' 'System.Show "quoted|operator<&>" > quoted.txt' 'System.ShowFile quoted.txt' > "$tmp/input"
run "$runner" < "$tmp/input"
contains 'quoted|operator<&>'
cat > "$tmp/input" <<'SCRIPT'
alias cat=System.ShowFile
alias greet='System.Show alias-persisted'
alias chain=greet initial
chain extra
savealias "saved aliases.Tool"
alias remembered=System.Time
savealias
alias cat
unalias greet
loadalias "saved aliases.Tool"
cat Hello.Mod
alias
SCRIPT
run "$runner" < "$tmp/input"
contains 'alias-persisted initial extra'
contains 'MODULE Hello;'
contains 'alias cat=System.ShowFile'
grep -Fq 'alias remembered=System.Time' 'saved aliases.Tool' || fail 'savealias forgot the last filename'
printf 'loadalias "saved aliases.Tool"\n' > 'startup config.Tool'
run "$runner" '--config="startup config.Tool"' greet later
contains 'alias-persisted later'
printf 'System.Show automatic-alias\n' > automatic.Tool
printf 'auto=System.ShowFile automatic.Tool\n' > Shell.Alias
run "$runner" auto
contains automatic-alias
printf 'MissingModule.Run\n' > bad-config.Tool
reject "$runner" --config=bad-config.Tool System.Show should-not-start
if grep -Fq should-not-start "$tmp/output"; then fail 'failed config still launched command'; fi
printf 'alias a=b\nalias b=a\na\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
contains 'alias expansion cycle'
printf 'System.Show script-file\n' > commands.Tool
run "$runner" Shell.Source commands.Tool
contains script-file
printf 'System.Show after-file\n' > "$tmp/input"
run "$runner" Shell.RunFile commands.Tool < "$tmp/input"
contains script-file
contains after-file
printf 'MissingModule.Run\nSystem.Show should-not-run\n' > bad-script.Tool
reject "$runner" Shell.Source bad-script.Tool
if grep -Fq should-not-run "$tmp/output"; then fail 'source continued after failure'; fi
printf 'wait\n' > nested-wait.Tool
printf 'Shell.Source nested-wait.Tool &\nwait\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
contains 'wait cannot run inside a background command'
printf 'Shell.Copy > absent-directory/output.txt\n' > "$tmp/input"
reject "$runner" < "$tmp/input"
awk 'BEGIN { for (i=0;i<4100;i++) printf "x"; printf "\nSystem.Show should-not-run\n" }' > long.Tool
reject "$runner" Shell.Source long.Tool
contains 'input line too long'
if grep -Fq should-not-run "$tmp/output"; then fail 'source continued after overlong line'; fi
printf 'System.Show nested-shell\nexit\nSystem.Show should-not-run\n' > nested.Tool
printf 'batch < nested.Tool\nSystem.Show outer-shell\n' > "$tmp/input"
run "$runner" < "$tmp/input"
contains nested-shell
contains outer-shell
if grep -Fq should-not-run "$tmp/output"; then fail 'exit did not leave nested shell'; fi
run "$runner" System.Show 'literal|operator'
contains 'literal|operator'
echo 'PASS: pipes, redirection, background/wait, aliases, config, scripts and nested shells'

mkdir -p "$tmp/relocated tools/bin/amd64" "$tmp/relocated tools/obj"
cp "$runner" "$tmp/relocated tools/bin/amd64/aoe"
cp -R "$distribution/obj/amd64" "$tmp/relocated tools/obj/amd64"
cp Hello.Mod 'source with spaces.Mod'
run "$tmp/relocated tools/bin/amd64/aoe" Compiler.Compile '"source with spaces.Mod"'
contains 'Hello done.'
run "$tmp/relocated tools/bin/amd64/aoe" Hello.Run
contains 'Hello from an Active Oberon CLI object!'
ln -s "$tmp/relocated tools/bin/amd64/aoe" "$tmp/aoe-link"
run "$tmp/aoe-link" Hello.Run
contains 'Hello from an Active Oberon CLI object!'
echo 'PASS: relocated bin/amd64 + obj/amd64 installation, symlinks and paths containing spaces'

mkdir "$tmp/selfhost"
cp "$distribution/build.Tool" "$tmp/selfhost/"
cp -R "$distribution/bin" "$distribution/obj" "$distribution/source" "$tmp/selfhost/"
cd "$tmp/selfhost"
run ./bin/amd64/aoe < build.Tool
contains 'Link successful'
[ -x bin/amd64/aoe ] || fail 'rebuilt runner is not executable'
run ./bin/amd64/aoe System.Show rebuilt
contains rebuilt
# Machine embeds the build date: compare two fresh generations, not a binary
# checked in on an earlier day. The source compiler also updates symbol syntax.
mkdir "$tmp/generation1"
cp bin/amd64/aoe "$tmp/generation1/aoe"
cp -R obj/amd64 "$tmp/generation1/modules"
run ./bin/amd64/aoe < build.Tool
contains 'Link successful'
cmp bin/amd64/aoe "$tmp/generation1/aoe" || fail 'self-hosted executables differ'
for file in obj/amd64/*; do
    cmp "$file" "$tmp/generation1/modules/${file##*/}" || fail "self-hosted module differs: ${file##*/}"
done
echo 'PASS: two self-hosted generations have identical runners, object files and symbol files'
printf 'MODULE Trace; BEGIN notDeclared := 1 END Trace.\n' > source/Trace.Mod
reject ./bin/amd64/aoe < build.Tool
cmp bin/amd64/aoe "$tmp/generation1/aoe" || fail 'failed compilation still relinks the runner'
echo 'PASS: failed builds stop before linking'
