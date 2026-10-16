MODULE CLIEnvironment; (** Linux console distribution search paths; no desktop initialization. *)

IMPORT SYSTEM, Unix, UnixFiles, Files, Streams, Commands, StdIO, Strings;

PROCEDURE AddPath(CONST path: ARRAY OF CHAR);
VAR quoted: ARRAY 1024 OF CHAR; reader: Streams.StringReader; context: Commands.Context;
BEGIN
	quoted := '"'; Strings.Append(quoted, path); Strings.Append(quoted, '"');
	Streams.OpenStringReader(reader, quoted);
	NEW(context, StdIO.env.in, reader, StdIO.env.out, StdIO.env.error, NIL);
	Files.AddSearchPath(context);
END AddPath;

VAR objectPath-: Files.FileName;
    executable, directory, name, cwd: Files.FileName; done: BOOLEAN;
BEGIN
	(* UnixFiles initially trusts $PWD, which can be stale after a host chdir. *)
	ASSERT(Unix.getcwd(ADDRESS OF cwd, LEN(cwd)) # NIL);
	UnixFiles.ChangeDirectory(cwd, done);
	ASSERT(done);
	(* /proc/self/exe also works when invoked through PATH or a symbolic link. *)
	ASSERT(Unix.realpath(ADDRESS OF "/proc/self/exe", ADDRESS OF executable) # NIL);
	Files.SplitPath(executable, directory, name);
	(* bin/amd64/aoe -> obj/amd64, relative to the resolved installation. *)
	Files.JoinPath(directory, "../../obj/amd64", objectPath);
	AddPath(".");
	AddPath("obj/amd64");
	AddPath(objectPath);
END CLIEnvironment.
