MODULE StdIOShell; (** AUTHOR "Felix Friedrich"; PURPOSE "Command shell for standalone Oberon/A2 Applications"; *)

IMPORT StdIO, Commands, Modules, Trace, Shell, ShellCommands, Options, Streams;

CONST Verbose = FALSE;

PROCEDURE Execute(context: Commands.Context): BOOLEAN;
VAR str: ARRAY 1024 OF CHAR; options: Options.Options; args: Streams.StringReader; config: Commands.Context;
BEGIN
	IF ~context.arg.GetString(str) THEN
		context.error.String("Critical error: no arg"); context.error.Update;
		RETURN FALSE;
	END;

	NEW(options); options.Add("c", "config", Options.String); options.Add("h", "help", Options.Flag);
	IF ~options.Parse(context.arg, context.error) THEN RETURN FALSE END;
	IF options.GetFlag("help") THEN Shell.Help(context); context.out.Update; RETURN TRUE END;
	ShellCommands.Initialize(context);
	IF context.result # Commands.Ok THEN RETURN FALSE END;
	IF options.GetString("config", str) THEN
		Streams.OpenStringReader(args, str); config := ShellCommands.Context(context, args, context.caller);
		ShellCommands.SourceFile(config, str);
		IF config.result # Commands.Ok THEN RETURN FALSE END;
	END;
	context.arg.SkipWhitespace;
	IF context.arg.Available() = 0 THEN Shell.Start(context) ELSE ShellCommands.Command(context) END;
	context.out.Update; context.error.Update;
	RETURN context.result = Commands.Ok;
END Execute;

TYPE
	(* excute the shell and termination in separate thread with proper process data structure *)
	Executor=OBJECT
	VAR done := FALSE: BOOLEAN;
	VAR code := Modules.PowerDown: SIGNED32;

		PROCEDURE Wait;
		BEGIN{EXCLUSIVE}
			AWAIT(done);
		END Wait;

	BEGIN {ACTIVE, EXCLUSIVE}
		IF Execute(StdIO.env) THEN code := Modules.Reboot END;
	FINALLY
		done := TRUE;
	END Executor;

VAR execute: Executor;

(* do not add commands here -- the module loader does not finish here and they will not become available *)
BEGIN
	NEW(execute);
	execute.Wait;
	IF Verbose THEN Trace.String("StdIOShell: Exit"); Trace.Ln END;
	Modules.Shutdown(execute.code);
END StdIOShell.

Linking a command line shell:

Command line shell: (Windows):
Linker.Link  --fileFormat=PE32CUI --fileName=oberon.exe --extension=GofW --displacement=401000H Builtins Trace Kernel32 Machine Heaps Modules Objects Kernel KernelLog Streams Commands Files  WinFS Clock Dates Reals Strings Diagnostics BitSets StringPool ObjectFile GenericLinker Reflection Loader WinTrace StdIO  Traps RelativeFileSystem WMDefaultFont System Shell StdIOShell ~

Command line shell including compiler (and linker)
Linker.Link  --fileFormat=PE32CUI --fileName=oberon.exe --extension=GofW --displacement=401000H Builtins Trace Kernel32 Machine Heaps Modules Objects Kernel KernelLog Streams Commands Files  WinFS Clock Dates Reals Strings Diagnostics BitSets StringPool ObjectFile GenericLinker Reflection Loader WinTrace StdIO  Traps RelativeFileSystem System FSTools StdIOShell
Shell Linker Compiler FoxOberonFrontend FoxARMBackend FoxAMDBackend
~


Command line shell: (Linux):
Linker.Link -p=Linux32 Builtins Trace Glue Unix Machine Heaps Modules Objects Kernel KernelLog  Streams Commands Pipes StdIO TrapWriters Reflection Traps Files UnixFiles Clock Dates Reals Strings Diagnostics BitSets StringPool ObjectFile GenericLinker   Loader Shell System StdIOShell ~

Command line shell including compiler (and linker)
Linker.Link -p=Linux32 Builtins Trace Glue Unix Machine Heaps Modules Objects Kernel KernelLog  Streams Commands Pipes StdIO TrapWriters Reflection Traps Files UnixFiles Clock Dates Reals Strings Diagnostics BitSets StringPool ObjectFile GenericLinker   Loader Shell System StdIOShell
Linker Compiler FoxOberonFrontend FoxARMBackend FoxAMDBackend
~
