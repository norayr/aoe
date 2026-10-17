MODULE ShellCommands; (** Command execution, streams, aliases and scripts for the console shell. *)
(* SPDX-License-Identifier: GPL-3.0-only *)

IMPORT Commands, Modules, Streams, Strings, Files, Pipes, StdIO;

CONST
	MaxLine = 4096; MaxExpansion = 32;
	End = 0; Word = 1; Bar = 2; Input = 3; Output = 4; Append = 5; Background = 6; Bad = 7;

TYPE
	Line = ARRAY MaxLine OF CHAR;
	Session* = OBJECT
	VAR quit*: BOOLEAN; depth*: INTEGER; background: BOOLEAN;
	END Session;
	AliasEntry = POINTER TO RECORD next: AliasEntry; name: Modules.Name; value: Line END;
	(* Commands own their writer buffers. Sinks serialize writes to shared
	   streams so background output cannot mutate the editor's buffer. *)
	Sink = OBJECT
	VAR target: Streams.Writer;
		PROCEDURE Send(CONST data: ARRAY OF CHAR; ofs, len: SIZE; propagate: BOOLEAN; VAR res: INTEGER);
		BEGIN {EXCLUSIVE}
			target.Bytes(data, ofs, len); target.Update; res := target.res;
		END Send;
	END Sink;
	SharedWriter = OBJECT (Streams.Writer)
	VAR sink: Sink;
		PROCEDURE &Init(sink: Sink);
		BEGIN SELF.sink := sink; InitWriter(sink.Send, 1024) END Init;
	END SharedWriter;
	Stage = POINTER TO RECORD
		next: Stage; name, args: Line;
		input, output: Files.FileName; append: BOOLEAN;
		context: Commands.Context; source, destination: Pipes.Pipe;
	END;

TYPE
	Worker = OBJECT
	VAR next: Worker; stage: Stage; done, entered, flushed: BOOLEAN;
		PROCEDURE &Init(stage: Stage);
		BEGIN SELF.stage := stage END Init;
		PROCEDURE Join(): INTEGER;
		BEGIN {EXCLUSIVE} AWAIT(done); RETURN stage.context.result END Join;
	BEGIN {ACTIVE, SAFE}
		IF ~entered THEN entered := TRUE; Dispatch(stage.context, stage.name)
		ELSE stage.context.result := Commands.CommandTrapped END;
	FINALLY
		IF ~flushed THEN
			flushed := TRUE; stage.context.out.Update; stage.context.error.Update;
		END;
		IF (stage.context.out.res # Streams.Ok) & (stage.context.result = Commands.Ok) THEN
			stage.context.result := Commands.CommandError;
		END;
		IF stage.destination # NIL THEN stage.destination.Close END;
		IF stage.source # NIL THEN stage.source.Close END;
		BEGIN {EXCLUSIVE} done := TRUE END;
	END Worker;
	Pipeline = OBJECT
	VAR head: Stage; workers: Worker; done, entered, background: BOOLEAN; result: INTEGER;
		context: Commands.Context;
		stage: Stage; worker: Worker; res: INTEGER;
		PROCEDURE &Init(context: Commands.Context; head: Stage; background: BOOLEAN);
		BEGIN SELF.context := context; SELF.head := head; SELF.background := background END Init;
		PROCEDURE Join(): INTEGER;
		BEGIN {EXCLUSIVE} AWAIT(done); RETURN result END Join;
	BEGIN {ACTIVE, SAFE}
		IF ~entered THEN
			entered := TRUE;
			IF Prepare(context, head, background) THEN
				stage := head;
				WHILE stage # NIL DO
					NEW(worker, stage); worker.next := workers; workers := worker; stage := stage.next;
				END;
				worker := workers;
				WHILE worker # NIL DO
					res := worker.Join(); IF res # Commands.Ok THEN result := res END;
					worker := worker.next;
				END;
			ELSE result := context.result;
			END;
		ELSE result := Commands.CommandTrapped;
		END;
	FINALLY
		BEGIN {EXCLUSIVE} done := TRUE END;
	END Pipeline;
	Job = POINTER TO RECORD next: Job; pipeline: Pipeline END;

VAR aliases: AliasEntry; stdout, stderr: Sink; jobs: Job;
	aliasFile: Files.FileName; initialized: BOOLEAN;

PROCEDURE Error(context: Commands.Context; CONST message: ARRAY OF CHAR);
BEGIN
	context.error.String("Shell: "); context.error.String(message); context.error.Ln;
	context.error.Update;
	context.result := Commands.CommandParseError;
END Error;

PROCEDURE NewSession*(caller: OBJECT): Session;
VAR session: Session;
BEGIN
	NEW(session); session.depth := 1;
	IF (caller # NIL) & (caller IS Session) THEN
		session.depth := caller(Session).depth+1; session.background := caller(Session).background;
	END;
	RETURN session;
END NewSession;

PROCEDURE GetSink(target: Streams.Writer): Sink;
VAR sink: Sink;
BEGIN {EXCLUSIVE}
	IF target IS SharedWriter THEN RETURN target(SharedWriter).sink END;
	IF target = StdIO.env.out THEN
		IF stdout = NIL THEN NEW(stdout); stdout.target := target END; RETURN stdout;
	ELSIF target = StdIO.env.error THEN
		IF stderr = NIL THEN NEW(stderr); stderr.target := target END; RETURN stderr;
	END;
	NEW(sink); sink.target := target; RETURN sink;
END GetSink;

PROCEDURE Writer(target: Streams.Writer): Streams.Writer;
VAR writer: SharedWriter;
BEGIN NEW(writer, GetSink(target)); RETURN writer END Writer;

PROCEDURE Context*(outer: Commands.Context; arg: Streams.Reader; caller: OBJECT): Commands.Context;
VAR context: Commands.Context;
BEGIN
	NEW(context, outer.in, arg, Writer(outer.out), Writer(outer.error), caller);
	RETURN context;
END Context;

PROCEDURE Tail(reader: Streams.Reader; VAR text: ARRAY OF CHAR): BOOLEAN;
VAR ch: CHAR; i: SIZE;
BEGIN
	i := 0;
	LOOP
		reader.Char(ch); IF (reader.res # Streams.Ok) OR (ch = 0X) THEN EXIT END;
		IF i >= LEN(text)-1 THEN text[0] := 0X; RETURN FALSE END;
		text[i] := ch; INC(i);
	END;
	text[i] := 0X; RETURN TRUE;
END Tail;

(* Keep original quoting for command argument readers. Operators are recognized
   only outside matching single or double quotes. No implicit host-shell expansion. *)
PROCEDURE Token(CONST line: ARRAY OF CHAR; VAR pos, start, end: SIZE): INTEGER;
VAR ch, quote: CHAR; kind: INTEGER;
BEGIN
	WHILE (line[pos] = ' ') OR (line[pos] = 9X) DO INC(pos) END;
	start := pos; ch := line[pos]; kind := Word;
	CASE ch OF
	| 0X: kind := End;
	| '|': INC(pos); kind := Bar;
	| '<': INC(pos); kind := Input;
	| '>': INC(pos); kind := Output; IF line[pos] = '>' THEN INC(pos); kind := Append END;
	| '&': INC(pos); kind := Background;
	ELSE
		quote := 0X;
		LOOP
			ch := line[pos];
			IF ch = 0X THEN EXIT END;
			IF quote # 0X THEN
				IF ch = quote THEN quote := 0X END;
			ELSIF (ch = '"') OR (ch = "'") THEN quote := ch
			ELSIF (ch = ' ') OR (ch = 9X) OR (ch = '|') OR (ch = '<') OR (ch = '>') OR (ch = '&') THEN EXIT;
			END;
			INC(pos);
		END;
		IF quote # 0X THEN kind := Bad END;
	END;
	end := pos; RETURN kind;
END Token;

PROCEDURE Value(CONST line: ARRAY OF CHAR; start, end: SIZE; VAR value: ARRAY OF CHAR): BOOLEAN;
VAR raw: Line; reader: Streams.StringReader;
BEGIN
	IF end-start >= LEN(value) THEN RETURN FALSE END;
	Strings.Copy(line, start, end-start, raw); Streams.OpenStringReader(reader, raw);
	RETURN reader.GetString(value);
END Value;

PROCEDURE Argument(VAR args: Line; CONST line: ARRAY OF CHAR; start, end: SIZE): BOOLEAN;
VAR n, i: SIZE;
BEGIN
	n := Strings.Length(args);
	IF n+1+end-start >= LEN(args) THEN RETURN FALSE END;
	args[n] := ' '; INC(n);
	FOR i := start TO end-1 DO args[n] := line[i]; INC(n) END;
	args[n] := 0X; RETURN TRUE;
END Argument;

PROCEDURE FindAlias(CONST name: ARRAY OF CHAR; VAR value: Line): BOOLEAN;
VAR entry: AliasEntry;
BEGIN {EXCLUSIVE}
	entry := aliases;
	WHILE (entry # NIL) & (entry.name # name) DO entry := entry.next END;
	IF entry = NIL THEN RETURN FALSE END;
	value := entry.value; RETURN TRUE;
END FindAlias;

PROCEDURE Snapshot(): AliasEntry;
VAR source, head, last, entry: AliasEntry;
BEGIN {EXCLUSIVE}
	source := aliases;
	WHILE source # NIL DO
		NEW(entry); entry.name := source.name; entry.value := source.value;
		IF head = NIL THEN head := entry ELSE last.next := entry END;
		last := entry; source := source.next;
	END;
	RETURN head;
END Snapshot;

PROCEDURE AliasNames*(VAR reader: Streams.StringReader);
VAR entry: AliasEntry; buffer: Streams.Buffer; writer: Streams.Writer;
BEGIN
	NEW(buffer, 256); writer := buffer.GetWriter(); entry := Snapshot();
	WHILE entry # NIL DO writer.String(entry.name); writer.Ln; entry := entry.next END;
	reader := buffer.GetReader();
END AliasNames;

PROCEDURE SetAlias(CONST name, value: ARRAY OF CHAR);
VAR entry, previous: AliasEntry;
BEGIN {EXCLUSIVE}
	entry := aliases;
	WHILE (entry # NIL) & (entry.name < name) DO previous := entry; entry := entry.next END;
	IF (entry # NIL) & (entry.name = name) THEN
		IF value # "" THEN COPY(value, entry.value)
		ELSIF previous = NIL THEN aliases := entry.next ELSE previous.next := entry.next END;
	ELSIF value # "" THEN
		NEW(entry); COPY(name, entry.name); COPY(value, entry.value);
		IF previous = NIL THEN entry.next := aliases; aliases := entry
		ELSE entry.next := previous.next; previous.next := entry END;
	END;
END SetAlias;

PROCEDURE Alias*(context: Commands.Context);
VAR text, value: Line; name: Modules.Name; i, j, pos, start, end: SIZE; kind: INTEGER; entry: AliasEntry;
BEGIN
	IF ~Tail(context.arg, text) THEN Error(context, "alias definition too long"); RETURN END;
	Strings.TrimWS(text);
	IF text = "" THEN
		entry := Snapshot();
		WHILE entry # NIL DO
			context.out.String("alias "); context.out.String(entry.name); context.out.Char('=');
			context.out.String(entry.value); context.out.Ln; entry := entry.next;
		END;
		RETURN;
	END;
	i := 0;
	WHILE (text[i] # 0X) & (text[i] # '=') & (text[i] # ' ') & (text[i] # 9X) DO INC(i) END;
	IF (i = 0) OR (i >= LEN(name)) THEN Error(context, "invalid alias name"); RETURN END;
	Strings.Copy(text, 0, i, name);
	IF text[i] = 0X THEN SetAlias(name, ""); RETURN END;
	IF text[i] # '=' THEN Error(context, "use alias name=Module.Procedure [arguments]"); RETURN END;
	INC(i); Strings.Copy(text, i, Strings.Length(text)-i, value); Strings.TrimWS(value);
	(* Accept Bash-style quoting of the whole replacement, as well as the old
	   unquoted definition. Quotes around individual arguments stay intact. *)
	IF (value[0] = '"') OR (value[0] = "'") THEN
		pos := 0; kind := Token(value, pos, start, end);
		IF (kind = Word) & (value[pos] = 0X) THEN
			text := value;
			IF ~Value(text, start, end, value) THEN Error(context, "invalid alias replacement"); RETURN END;
		END;
	END;
	pos := 0;
	LOOP
		kind := Token(value, pos, start, end);
		IF kind = End THEN EXIT END;
		IF kind # Word THEN Error(context, "aliases expand to a command and arguments, not operators"); RETURN END;
	END;
	FOR j := 0 TO Strings.Length(name)-1 DO
		IF (name[j] = '|') OR (name[j] = '<') OR (name[j] = '>') OR (name[j] = '&') OR
			(name[j] = '"') OR (name[j] = "'") THEN Error(context, "invalid alias name"); RETURN END;
	END;
	SetAlias(name, value);
END Alias;

PROCEDURE Unalias*(context: Commands.Context);
VAR name: Modules.Name;
BEGIN
	IF ~context.arg.GetString(name) THEN Error(context, "expected an alias name"); RETURN END;
	LOOP
		SetAlias(name, ""); context.arg.SkipWhitespace;
		IF context.arg.Peek() = 0X THEN EXIT END;
		IF ~context.arg.GetString(name) THEN Error(context, "invalid alias name"); RETURN END;
	END;
END Unalias;

PROCEDURE LocalPath(context: Commands.Context; CONST name: ARRAY OF CHAR; VAR path: Files.FileName): BOOLEAN;
BEGIN
	path := "";
	IF (name = "") OR (Strings.Length(name)+2 >= LEN(path)) THEN Error(context, "invalid or overlong filename"); RETURN FALSE END;
	IF name[0] # '/' THEN path := "./" END;
	Strings.Append(path, name); RETURN TRUE;
END LocalPath;

PROCEDURE ScriptLine(context: Commands.Context; reader: Streams.Reader; VAR line: Line): BOOLEAN;
VAR ch: CHAR; i: SIZE; overflow: BOOLEAN;
BEGIN
	i := 0; overflow := FALSE;
	LOOP
		reader.Char(ch);
		IF (reader.res # Streams.Ok) OR (ch = 0AX) THEN EXIT END;
		IF ch = 0DX THEN
			IF reader.Peek() = 0AX THEN reader.Char(ch) END;
			EXIT;
		END;
		IF i < LEN(line)-1 THEN line[i] := ch; INC(i) ELSE overflow := TRUE END;
	END;
	line[i] := 0X;
	IF overflow THEN Error(context, "input line too long") END;
	RETURN ~overflow;
END ScriptLine;

PROCEDURE CurrentAliasFile(VAR filename: Files.FileName);
BEGIN {EXCLUSIVE} filename := aliasFile END CurrentAliasFile;

PROCEDURE RememberAliasFile(CONST filename: Files.FileName);
BEGIN {EXCLUSIVE} aliasFile := filename END RememberAliasFile;

PROCEDURE AliasFilename(context: Commands.Context; VAR filename: Files.FileName): BOOLEAN;
BEGIN
	context.arg.SkipWhitespace;
	IF context.arg.Peek() = 0X THEN CurrentAliasFile(filename); RETURN TRUE END;
	IF context.arg.GetString(filename) THEN RETURN TRUE END;
	Error(context, "invalid alias filename"); RETURN FALSE;
END AliasFilename;

PROCEDURE LoadAliases*(context: Commands.Context);
VAR filename, path: Files.FileName; file: Files.File; reader: Files.Reader;
	line: Line; arg: Streams.StringReader; command: Commands.Context;
BEGIN
	IF ~AliasFilename(context, filename) THEN RETURN END;
	IF ~LocalPath(context, filename, path) THEN RETURN END;
	file := Files.Old(path);
	IF file = NIL THEN Error(context, "cannot open alias file"); RETURN END;
	Files.OpenReader(reader, file, 0);
	WHILE reader.res = Streams.Ok DO
		IF ~ScriptLine(context, reader, line) THEN RETURN END;
		Strings.TrimWS(line);
		IF (line # "") & (line[0] # '#') THEN
			IF (Strings.Length(line) >= 6) & (line[0] = 'a') & (line[1] = 'l') &
				(line[2] = 'i') & (line[3] = 'a') & (line[4] = 's') & (line[5] = ' ') THEN
				Strings.Delete(line, 0, 6);
			END;
			Streams.OpenStringReader(arg, line); command := Context(context, arg, context.caller);
			Alias(command);
			IF command.result # Commands.Ok THEN context.result := command.result; RETURN END;
		END;
	END;
	RememberAliasFile(filename);
END LoadAliases;

PROCEDURE SaveAliases*(context: Commands.Context);
VAR filename, path: Files.FileName; file: Files.File; writer: Files.Writer; entry: AliasEntry;
BEGIN
	IF ~AliasFilename(context, filename) THEN RETURN END;
	IF ~LocalPath(context, filename, path) THEN RETURN END;
	file := Files.New(path);
	IF file = NIL THEN Error(context, "cannot create alias file"); RETURN END;
	Files.OpenWriter(writer, file, 0); entry := Snapshot();
	WHILE entry # NIL DO
		writer.String("alias "); writer.String(entry.name); writer.Char('='); writer.String(entry.value); writer.Ln;
		entry := entry.next;
	END;
	writer.Update;
	IF writer.res # Streams.Ok THEN Error(context, "cannot write alias file"); RETURN END;
	Files.Register(file); RememberAliasFile(filename);
END SaveAliases;

PROCEDURE Initialize*(context: Commands.Context);
VAR arg: Streams.StringReader; command: Commands.Context;
BEGIN
	IF initialized THEN RETURN END;
	initialized := TRUE;
	IF Files.Old("./Shell.Alias") # NIL THEN
		Streams.OpenStringReader(arg, ""); command := Context(context, arg, context.caller);
		LoadAliases(command); context.result := command.result;
	END;
END Initialize;

PROCEDURE Expand(context: Commands.Context; stage: Stage): BOOLEAN;
VAR replacement, name, args: Line; n: INTEGER; pos, start, end: SIZE; kind: INTEGER;
BEGIN
	n := 0;
	WHILE FindAlias(stage.name, replacement) DO
		INC(n); IF n > MaxExpansion THEN Error(context, "alias expansion cycle or excessive nesting"); RETURN FALSE END;
		pos := 0; kind := Token(replacement, pos, start, end);
		IF (kind # Word) OR ~Value(replacement, start, end, name) THEN Error(context, "invalid alias command"); RETURN FALSE END;
		Strings.Copy(replacement, pos, Strings.Length(replacement)-pos, args);
		IF Strings.Length(args)+Strings.Length(stage.args) >= LEN(args) THEN Error(context, "expanded arguments too long"); RETURN FALSE END;
		Strings.Append(args, stage.args); stage.name := name; stage.args := args;
	END;
	RETURN TRUE;
END Expand;

PROCEDURE Parse(context: Commands.Context; CONST line: Line; VAR head: Stage; VAR background: BOOLEAN): BOOLEAN;
VAR stage: Stage; kind, direction: INTEGER; pos, start, end: SIZE; filename: Files.FileName;
BEGIN
	pos := 0; kind := Token(line, pos, start, end);
	IF kind = End THEN RETURN TRUE END;
	IF line[start] = '#' THEN RETURN TRUE END;
	LOOP
		IF kind # Word THEN Error(context, "expected a command"); RETURN FALSE END;
		IF head = NIL THEN NEW(head); stage := head ELSE NEW(stage.next); stage := stage.next END;
		IF ~Value(line, start, end, stage.name) THEN Error(context, "invalid command name"); RETURN FALSE END;
		LOOP
			kind := Token(line, pos, start, end);
			IF kind = Word THEN
				IF ~Argument(stage.args, line, start, end) THEN Error(context, "arguments too long"); RETURN FALSE END;
			ELSIF (kind = Input) OR (kind = Output) OR (kind = Append) THEN
				direction := kind; kind := Token(line, pos, start, end);
				IF (kind # Word) OR ~Value(line, start, end, filename) THEN Error(context, "expected a redirection filename"); RETURN FALSE END;
				IF filename = "" THEN Error(context, "empty redirection filename"); RETURN FALSE END;
				IF direction = Input THEN
					IF stage.input # "" THEN Error(context, "duplicate input redirection"); RETURN FALSE END;
					stage.input := filename;
				ELSE
					IF stage.output # "" THEN Error(context, "duplicate output redirection"); RETURN FALSE END;
					stage.output := filename; stage.append := direction = Append;
				END;
			ELSE EXIT;
			END;
		END;
		IF ~Expand(context, stage) THEN RETURN FALSE END;
		IF kind = Bar THEN kind := Token(line, pos, start, end)
		ELSE EXIT;
		END;
	END;
	IF kind = Background THEN background := TRUE; kind := Token(line, pos, start, end) END;
	IF kind # End THEN Error(context, "unexpected operator or unterminated quote"); RETURN FALSE END;
	stage := head;
	WHILE stage # NIL DO
		IF background & ((stage.name = "wait") OR (stage.name = "Shell.Wait")) THEN
			Error(context, "wait cannot run in the background"); RETURN FALSE;
		END;
		IF ((head.next # NIL) OR background) & ((stage.name = "exit") OR (stage.name = "quit")) THEN
			Error(context, "exit cannot be piped or backgrounded"); RETURN FALSE;
		END;
		stage := stage.next;
	END;
	RETURN TRUE;
END Parse;

PROCEDURE Prepare(context: Commands.Context; head: Stage; background: BOOLEAN): BOOLEAN;
VAR stage, previous: Stage; input: Streams.Reader; output: Streams.Writer;
	reader: Files.Reader; writer: Files.Writer; arg: Streams.StringReader; file: Files.File; path: Files.FileName;
	caller: OBJECT; session: Session;
BEGIN
	caller := context.caller;
	IF background THEN session := NewSession(caller); session.background := TRUE; caller := session END;
	stage := head;
	WHILE stage # NIL DO
		IF previous # NIL THEN
			IF (previous.output # "") OR (stage.input # "") THEN Error(context, "pipeline conflicts with redirection"); RETURN FALSE END;
			NEW(stage.source, 4096); previous.destination := stage.source;
		END;
		previous := stage; stage := stage.next;
	END;
	stage := head;
	WHILE stage # NIL DO
		input := context.in; output := context.out;
		IF background THEN NEW(arg, 1); arg.Set(""); input := arg END;
		IF stage.source # NIL THEN Streams.OpenReader(input, stage.source.Receive) END;
		IF stage.destination # NIL THEN Streams.OpenWriter(output, stage.destination.Send) END;
		IF stage.input # "" THEN
			(* Redirection refers to the caller's directory, never an installed library. *)
			IF ~LocalPath(context, stage.input, path) THEN RETURN FALSE END;
			file := Files.Old(path);
			IF file = NIL THEN Error(context, "cannot open input file"); RETURN FALSE END;
			Files.OpenReader(reader, file, 0); input := reader;
		END;
		IF stage.output # "" THEN
			IF ~LocalPath(context, stage.output, path) THEN RETURN FALSE END;
			file := NIL;
			IF stage.append THEN file := Files.Old(path) END;
			IF file = NIL THEN file := Files.New(path); IF file # NIL THEN Files.Register(file) END END;
			IF file = NIL THEN Error(context, "cannot open output file"); RETURN FALSE END;
			IF stage.append THEN Files.OpenWriter(writer, file, file.Length()) ELSE Files.OpenWriter(writer, file, 0) END;
			output := writer;
		END;
		Streams.OpenStringReader(arg, stage.args);
		NEW(stage.context, input, arg, Writer(output), Writer(context.error), caller);
		stage := stage.next;
	END;
	RETURN TRUE;
END Prepare;

PROCEDURE RememberJob(pipeline: Pipeline);
VAR job: Job;
BEGIN {EXCLUSIVE}
	NEW(job); job.pipeline := pipeline; job.next := jobs; jobs := job;
END RememberJob;

PROCEDURE TakeJobs(): Job;
VAR result: Job;
BEGIN {EXCLUSIVE} result := jobs; jobs := NIL; RETURN result END TakeJobs;

PROCEDURE Wait*(context: Commands.Context);
VAR job: Job; result: INTEGER;
BEGIN
	IF (context.caller # NIL) & (context.caller IS Session) & context.caller(Session).background THEN
		Error(context, "wait cannot run inside a background command"); RETURN;
	END;
	job := TakeJobs();
	WHILE job # NIL DO
		result := job.pipeline.Join(); IF result # Commands.Ok THEN context.result := result END;
		job := job.next;
	END;
END Wait;

PROCEDURE Execute*(context: Commands.Context);
VAR line: Line; head: Stage; background: BOOLEAN; pipeline: Pipeline;
BEGIN
	background := FALSE; head := NIL;
	IF ~Tail(context.arg, line) THEN Error(context, "command line too long"); RETURN END;
	IF ~Parse(context, line, head, background) OR (head = NIL) THEN RETURN END;
	NEW(pipeline, context, head, background);
	IF background THEN RememberJob(pipeline) ELSE context.result := pipeline.Join() END;
END Execute;

PROCEDURE SourceFile*(context: Commands.Context; CONST filename: ARRAY OF CHAR);
VAR path: Files.FileName; file: Files.File; reader: Files.Reader; line: Line;
	arg: Streams.StringReader; command: Commands.Context; session: Session;
BEGIN
	IF ~LocalPath(context, filename, path) THEN RETURN END;
	file := Files.Old(path);
	IF file = NIL THEN Error(context, "cannot open script"); RETURN END;
	session := NewSession(context.caller);
	IF session.depth > MaxExpansion THEN Error(context, "script nesting limit exceeded"); RETURN END;
	Files.OpenReader(reader, file, 0);
	WHILE (reader.res = Streams.Ok) & ~session.quit DO
		IF ~ScriptLine(context, reader, line) THEN RETURN END;
		Streams.OpenStringReader(arg, line); command := Context(context, arg, session);
		Execute(command);
		IF command.result # Commands.Ok THEN context.result := command.result; RETURN END;
	END;
END SourceFile;

PROCEDURE Source*(context: Commands.Context);
VAR filename: Files.FileName;
BEGIN
	IF ~context.arg.GetString(filename) THEN Error(context, "expected a script filename"); RETURN END;
	SourceFile(context, filename);
END Source;

PROCEDURE Dispatch(context: Commands.Context; CONST name: ARRAY OF CHAR);
VAR res: INTEGER; msg: ARRAY 256 OF CHAR; i: SIZE;
	arg: Streams.StringReader; info: Commands.Context;
BEGIN
	IF (name = "alias") THEN Alias(context)
	ELSIF (name = "unalias") THEN Unalias(context)
	ELSIF (name = "loadalias") THEN LoadAliases(context)
	ELSIF (name = "savealias") THEN SaveAliases(context)
	ELSIF (name = "wait") THEN Wait(context)
	ELSIF (name = "exit") OR (name = "quit") THEN
		IF (context.caller # NIL) & (context.caller IS Session) THEN context.caller(Session).quit := TRUE END;
	ELSE
		IF (name = "help") OR (name = "--help") OR (name = "-h") THEN
			Commands.Activate("Shell.Help", context, {Commands.Wait}, res, msg);
		ELSIF name = "batch" THEN Commands.Activate("Shell.Start", context, {Commands.Wait}, res, msg)
		ELSIF name = "clear" THEN Commands.Activate("Shell.Clear", context, {Commands.Wait}, res, msg)
		ELSIF name = "version" THEN Commands.Activate("Shell.Version", context, {Commands.Wait}, res, msg)
		ELSE
			i := 0; WHILE (name[i] # 0X) & (name[i] # '.') DO INC(i) END;
			IF name[i] = 0X THEN
				Streams.OpenStringReader(arg, name); info := Context(context, arg, context.caller);
				Commands.Activate("Shell.Describe", info, {Commands.Wait}, res, msg);
			ELSE Commands.Activate(name, context, {Commands.Wait}, res, msg);
			END;
		END;
		context.result := res;
		IF (res # Commands.Ok) & (msg # "") THEN context.error.String(msg); context.error.Ln END;
	END;
END Dispatch;

(* argv already has a command/argument boundary. Do not interpret metacharacters
   in its arguments as shell operators; Linux's calling shell handled those. *)
PROCEDURE Command*(context: Commands.Context);
VAR stage: Stage; arg: Streams.StringReader; command: Commands.Context;
BEGIN
	NEW(stage);
	IF ~context.arg.GetString(stage.name) THEN RETURN END;
	IF ~Tail(context.arg, stage.args) THEN Error(context, "arguments too long"); RETURN END;
	IF ~Expand(context, stage) THEN RETURN END;
	Streams.OpenStringReader(arg, stage.args); command := Context(context, arg, context.caller);
	Dispatch(command, stage.name); command.out.Update; command.error.Update; context.result := command.result;
END Command;

BEGIN aliasFile := "Shell.Alias";
END ShellCommands.
