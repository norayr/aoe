MODULE Shell; (** Console shell, following polpo's loksh interaction model. *)

IMPORT SYSTEM, Machine, Unix, Modules, Commands, Streams, Strings, Files, CLIEnvironment, StdIO, ShellCommands, CommandInfo;

CONST
	MaxLine = 4096; MaxHist = 64;
	ESC = 1BX; TAB = 9X; LF = 0AX; CR = 0DX;

TYPE
	Line = ARRAY MaxLine OF CHAR;
	Candidate = POINTER TO RECORD next: Candidate; name: Files.FileName END;

VAR
	tcgetattr: PROCEDURE {C} (fd: SIGNED32; VAR term: Unix.Termios): SIGNED32;
	tcsetattr: PROCEDURE {C} (fd, action: SIGNED32; CONST term: Unix.Termios): SIGNED32;
	saved, editing: Unix.Termios;
	terminal: BOOLEAN;
	history: ARRAY MaxHist OF Line;
	historyCount: INTEGER;

PROCEDURE Restore;
VAR ignored: SIGNED32;
BEGIN
	IF terminal THEN ignored := tcsetattr(0, 0, saved) END;
END Restore;

PROCEDURE Prefix(CONST prefix, name: ARRAY OF CHAR): BOOLEAN;
VAR i: SIZE;
BEGIN
	i := 0;
	WHILE (prefix[i] # 0X) & (prefix[i] = name[i]) DO INC(i) END;
	RETURN prefix[i] = 0X;
END Prefix;

PROCEDURE Add(VAR list: Candidate; CONST name: ARRAY OF CHAR);
VAR p, previous, item: Candidate;
BEGIN
	previous := NIL; p := list;
	WHILE (p # NIL) & (p.name < name) DO previous := p; p := p.next END;
	IF (p # NIL) & (p.name = name) THEN RETURN END;
	NEW(item); COPY(name, item.name); item.next := p;
	IF previous = NIL THEN list := item ELSE previous.next := item END;
END Add;

PROCEDURE CommandNames(CONST module: ARRAY OF CHAR; VAR list: Candidate): BOOLEAN;
VAR names: CommandInfo.Name;
BEGIN
	IF ~CommandInfo.List(module, names) THEN RETURN FALSE END;
	WHILE names # NIL DO Add(list, names.name); names := names.next END;
	RETURN TRUE;
END CommandNames;

PROCEDURE ModuleNames(CONST path: ARRAY OF CHAR; VAR list: Candidate);
VAR enum: Files.Enumerator; mask, full, dir, name: Files.FileName;
	flags: SET; time, date: SIGNED32; size: Files.Size; n, extensionLength: SIZE;
BEGIN
	Files.JoinPath(path, "*", mask); Strings.Append(mask, Machine.DefaultObjectFileExtension);
	extensionLength := Strings.Length(Machine.DefaultObjectFileExtension);
	NEW(enum); enum.Open(mask, {});
	WHILE enum.GetEntry(full, flags, time, date, size) DO
		Files.SplitPath(full, dir, name); n := Strings.Length(name);
		IF (n > extensionLength) & ~(Files.Directory IN flags) THEN
			name[n-extensionLength] := 0X; Strings.Append(name, "."); Add(list, name);
		END;
	END;
	enum.Close;
END ModuleNames;

PROCEDURE ListCommands(context: Commands.Context; CONST module: ARRAY OF CHAR);
VAR list: Candidate;
BEGIN
	IF ~CommandNames(module, list) THEN
		context.error.String(module); context.error.String(": module not found"); context.error.Ln;
		context.result := Commands.CommandNotFound;
	ELSE
		WHILE list # NIL DO
			context.out.String(module); context.out.Char('.'); context.out.String(list.name); context.out.Ln;
			list := list.next;
		END;
	END;
END ListCommands;

PROCEDURE Help*(context: Commands.Context);
BEGIN
	context.out.String("aoe - Active Oberon environment"); context.out.Ln;
	context.out.String("Usage: aoe [Module.Procedure [arguments]]"); context.out.Ln;
	context.out.String("No arguments: terminal shell, or one command per line on stdin."); context.out.Ln;
	context.out.String("Compiler.Compile file.Mod    Linker.Link ...    System.DoFile script.txt"); context.out.Ln;
	context.out.String("Module lists its callable commands. No compile/link/do aliases."); context.out.Ln;
	context.out.String("Operators: |  <  >  >>  &; aliases: alias, unalias, loadalias, savealias; wait"); context.out.Ln;
	context.out.String("--config=file runs a shell script before the command or interactive shell."); context.out.Ln;
	context.out.String("Shell.Source file: script; Shell.RunFile file: script then shell; batch < file"); context.out.Ln;
	context.out.String("Tab: modules, commands, files; arrows: history/cursor; Ctrl+C: cancel line"); context.out.Ln;
	context.out.String("Ctrl+D on an empty line, exit or quit: leave shell."); context.out.Ln;
END Help;

PROCEDURE Execute*(context: Commands.Context);
BEGIN
	ShellCommands.Execute(context);
END Execute;

PROCEDURE Describe*(context: Commands.Context);
VAR module: Modules.Name;
BEGIN IF context.arg.GetString(module) THEN ListCommands(context, module) END END Describe;

PROCEDURE Alias*(context: Commands.Context);
BEGIN ShellCommands.Alias(context) END Alias;

PROCEDURE Unalias*(context: Commands.Context);
BEGIN ShellCommands.Unalias(context) END Unalias;

PROCEDURE LoadAliases*(context: Commands.Context);
BEGIN ShellCommands.LoadAliases(context) END LoadAliases;

PROCEDURE SaveAliases*(context: Commands.Context);
BEGIN ShellCommands.SaveAliases(context) END SaveAliases;

PROCEDURE Wait*(context: Commands.Context);
BEGIN ShellCommands.Wait(context) END Wait;

PROCEDURE Source*(context: Commands.Context);
BEGIN ShellCommands.Source(context) END Source;

PROCEDURE Clear*(context: Commands.Context);
BEGIN context.out.Char(ESC); context.out.String("[2J"); context.out.Char(ESC); context.out.String("[H") END Clear;

PROCEDURE Version*(context: Commands.Context);
BEGIN context.out.String("aoe shell"); context.out.Ln END Version;

PROCEDURE Copy*(context: Commands.Context);
VAR buffer: ARRAY 1024 OF CHAR; count: SIZE;
BEGIN
	WHILE (context.in.res = Streams.Ok) & (context.out.res = Streams.Ok) DO
		context.in.Bytes(buffer, 0, LEN(buffer), count);
		IF count > 0 THEN context.out.Bytes(buffer, 0, count) END;
	END;
END Copy;

PROCEDURE Left(w: Streams.Writer; count: SIZE);
VAR i: SIZE;
BEGIN
	FOR i := 1 TO count DO w.Char(ESC); w.String("[D") END;
END Left;

PROCEDURE Redraw(w: Streams.Writer; CONST line: Line; len, cursor: SIZE);
BEGIN
	w.Char(CR); w.String("> "); w.String(line); w.Char(ESC); w.String("[K");
	Left(w, len-cursor); w.Update;
END Redraw;

PROCEDURE Paths(CONST token: ARRAY OF CHAR; VAR list: Candidate);
VAR path, base, prefix, full, name, value: Files.FileName;
	i, split: SIZE; directory: ADDRESS; entry: Unix.Dirent; status: Unix.Status;
	ch: CHAR; result: SIGNED32; usable: BOOLEAN;
BEGIN
	split := 0; i := 0;
	WHILE token[i] # 0X DO IF token[i] = '/' THEN split := i+1 END; INC(i) END;
	i := 0; WHILE i < split DO path[i] := token[i]; INC(i) END; path[i] := 0X;
	Strings.Copy(token, split, Strings.Length(token)-split, prefix);
	IF path = "" THEN base := "." ELSE COPY(path, base) END;
	directory := Unix.opendir(ADDRESS OF base);
	IF directory = NIL THEN RETURN END;
	entry := Unix.readdir(directory);
	WHILE entry # NIL DO
		(* Files.Enumerator canonicalizes names, losing the spelling of symlinks.
		   readdir preserves the name the user actually needs to type. *)
		i := 0; usable := TRUE;
		REPEAT
			SYSTEM.GET(ADDRESS OF entry.name+i, ch); name[i] := ch; INC(i);
			IF (ch = '"') OR (ch = "'") OR (ch = CR) OR (ch = LF) THEN usable := FALSE END;
		UNTIL (ch = 0X) OR (i = LEN(name));
		name[LEN(name)-1] := 0X;
		IF usable & (name # ".") & (name # "..") & Prefix(prefix, name) &
			((prefix[0] = '.') OR (name[0] # '.')) THEN
			COPY(path, value); Strings.Append(value, name);
			Files.JoinPath(base, name, full);
			result := Unix.stat(ADDRESS OF full, status);
			IF (result = 0) & (status.mode DIV 1000H MOD 10H = 4) THEN Strings.Append(value, "/") END;
			Add(list, value);
		END;
		entry := Unix.readdir(directory);
	END;
	Unix.closedir(directory);
END Paths;

PROCEDURE Complete(w: Streams.Writer; VAR line: Line; VAR len, cursor: SIZE);
VAR all, matches, p: Candidate; token, value, module: Files.FileName;
	i, start, dot, count, end, n: SIZE; quote, ch: CHAR;
	command, needFile, inWord, commandToken: BOOLEAN; aliases: Streams.StringReader;
BEGIN
	(* Complete the token at the cursor, preserving the rest of the line. *)
	start := 0; quote := 0X; command := TRUE; needFile := FALSE; inWord := FALSE; commandToken := TRUE;
	FOR i := 0 TO cursor-1 DO
		ch := line[i];
		IF quote # 0X THEN
			IF quote = ch THEN quote := 0X END;
		ELSIF (ch = ' ') OR (ch = TAB) THEN
			IF inWord THEN
				IF commandToken THEN command := FALSE END;
				needFile := FALSE;
			END;
			inWord := FALSE; start := i+1;
		ELSIF (ch = '|') OR (ch = '&') THEN
			command := TRUE; needFile := FALSE; inWord := FALSE; start := i+1;
		ELSIF (ch = '<') OR (ch = '>') THEN
			IF inWord & commandToken THEN command := FALSE END;
			needFile := TRUE; inWord := FALSE; start := i+1;
		ELSE
			IF ~inWord THEN commandToken := command & ~needFile; inWord := TRUE; start := i END;
			IF (ch = '"') OR (ch = "'") THEN quote := ch; start := i+1 END;
		END;
	END;
	IF ~inWord THEN commandToken := command & ~needFile END;
	IF cursor-start >= LEN(token) THEN RETURN END;
	i := 0; WHILE (start+i < cursor) & (i < LEN(token)-1) DO token[i] := line[start+i]; INC(i) END;
	token[i] := 0X;
	IF ~commandToken THEN Paths(token, all)
	ELSE
		dot := -1;
		FOR i := 0 TO Strings.Length(token)-1 DO IF token[i] = '.' THEN dot := i END END;
		IF dot >= 0 THEN
			Strings.Copy(token, 0, dot, module);
			IF ~CommandNames(module, all) THEN RETURN END;
			p := all; all := NIL;
			WHILE p # NIL DO
				COPY(module, value); Strings.Append(value, "."); Strings.Append(value, p.name);
				Add(all, value); p := p.next;
			END;
		ELSE
			ModuleNames(".", all); ModuleNames("obj/amd64", all); ModuleNames(CLIEnvironment.objectPath, all);
		END;
		ShellCommands.AliasNames(aliases);
		WHILE aliases.res = Streams.Ok DO aliases.Ln(value); IF value # "" THEN Add(all, value) END END;
		Add(all, "alias"); Add(all, "unalias"); Add(all, "loadalias"); Add(all, "savealias");
		Add(all, "wait"); Add(all, "batch"); Add(all, "clear"); Add(all, "version");
		Add(all, "exit"); Add(all, "quit"); Add(all, "help");
	END;
	count := 0; p := all;
	WHILE p # NIL DO
		IF Prefix(token, p.name) THEN Add(matches, p.name); INC(count) END;
		p := p.next;
	END;
	IF count = 1 THEN
		COPY(matches.name, value);
		end := cursor;
		WHILE (line[end] # 0X) & (line[end] # ' ') & (line[end] # TAB) &
			(line[end] # '"') & (line[end] # "'") &
			((quote # 0X) OR ((line[end] # '|') & (line[end] # '<') & (line[end] # '>') & (line[end] # '&'))) DO INC(end) END;
		(* Quote unquoted filenames containing whitespace. *)
		IF ~commandToken & (quote = 0X) THEN
			i := 0;
			WHILE (value[i] # 0X) & (value[i] # ' ') & (value[i] # TAB) &
				(value[i] # '|') & (value[i] # '<') & (value[i] # '>') & (value[i] # '&') DO INC(i) END;
			IF value[i] # 0X THEN
				IF Strings.Length(value)+2 >= LEN(value) THEN RETURN END;
				COPY(value, token); value := '"'; Strings.Append(value, token);
				IF token[Strings.Length(token)-1] # '/' THEN Strings.Append(value, '"') END;
			END;
		ELSIF ~commandToken & (quote # 0X) & (line[end] # quote) &
			(value[Strings.Length(value)-1] # '/') THEN
			n := Strings.Length(value);
			IF n+1 >= LEN(value) THEN RETURN END;
			value[n] := quote; value[n+1] := 0X;
		END;
		n := Strings.Length(value);
		IF len-(end-start)+n < MaxLine THEN
			FOR i := len-end TO 0 BY -1 DO line[start+n+i] := line[end+i] END;
			FOR i := 0 TO n-1 DO line[start+i] := value[i] END;
			len := len-(end-start)+n; cursor := start+n;
		END;
	ELSIF count > 1 THEN
		w.Ln; p := matches;
		WHILE p # NIL DO w.String(p.name); w.String("  "); p := p.next END;
		w.Ln;
	END;
	Redraw(w, line, len, cursor);
END Complete;

PROCEDURE Remember(CONST line: Line);
VAR i: INTEGER;
BEGIN
	IF line = "" THEN RETURN END;
	IF (historyCount > 0) & (history[historyCount-1] = line) THEN RETURN END;
	IF historyCount = MaxHist THEN
		FOR i := 0 TO MaxHist-2 DO history[i] := history[i+1] END;
		DEC(historyCount);
	END;
	history[historyCount] := line; INC(historyCount);
END Remember;

PROCEDURE ReadLine(context: Commands.Context; terminal: BOOLEAN; VAR line: Line; VAR quit: BOOLEAN): BOOLEAN;
VAR len, cursor, i: SIZE; ch: CHAR; hist: INTEGER; draft: Line; overflow: BOOLEAN;
BEGIN
	len := 0; cursor := 0; line := ""; hist := historyCount; quit := FALSE; overflow := FALSE;
	LOOP
		context.in.Char(ch);
		IF context.in.res # Streams.Ok THEN quit := len = 0; EXIT END;
		IF (ch = LF) OR (ch = CR) THEN EXIT END;
		IF terminal THEN
			CASE ch OF
			| 4X: IF len = 0 THEN quit := TRUE; EXIT END;
			| 3X: line := ""; context.out.String("^C"); EXIT;
			| 08X, 7FX:
				IF cursor > 0 THEN
					DEC(cursor); DEC(len);
					FOR i := cursor TO len DO line[i] := line[i+1] END;
				END;
			| TAB: Complete(context.out, line, len, cursor);
			| ESC:
				context.in.Char(ch);
				IF ch = '[' THEN
					context.in.Char(ch);
					CASE ch OF
					| 'A':
						IF hist > 0 THEN
							IF hist = historyCount THEN draft := line END;
							DEC(hist); line := history[hist]; len := Strings.Length(line); cursor := len;
						END;
					| 'B':
						IF hist < historyCount THEN
							INC(hist); IF hist = historyCount THEN line := draft ELSE line := history[hist] END;
							len := Strings.Length(line); cursor := len;
						END;
					| 'C': IF cursor < len THEN INC(cursor) END;
					| 'D': IF cursor > 0 THEN DEC(cursor) END;
					| 'H': cursor := 0;
					| 'F': cursor := len;
					| '3':
						context.in.Char(ch);
						IF (ch = '~') & (cursor < len) THEN
							DEC(len); FOR i := cursor TO len DO line[i] := line[i+1] END;
						END;
					ELSE
					END;
				END;
			ELSE
				IF (ch >= ' ') & (len < MaxLine-1) THEN
					FOR i := len TO cursor BY -1 DO line[i+1] := line[i] END;
					line[cursor] := ch; INC(cursor); INC(len);
				END;
			END;
			Redraw(context.out, line, len, cursor);
		ELSE
			IF len < MaxLine-1 THEN line[len] := ch; INC(len); line[len] := 0X ELSE overflow := TRUE END;
		END;
	END;
	IF terminal THEN context.out.Ln; context.out.Update END;
	IF overflow THEN
		context.error.String("Shell: input line too long"); context.error.Ln;
		context.result := Commands.CommandParseError;
	END;
	RETURN ~overflow;
END ReadLine;

PROCEDURE Start*(context: Commands.Context);
VAR line: Line; quit, valid: BOOLEAN; ignored: SIGNED32; result: INTEGER;
	reader: Streams.StringReader; command: Commands.Context; session: ShellCommands.Session;
	outer: Commands.Context;
	isTerminal, outerTerminal: BOOLEAN; term, outerSaved, outerEditing: Unix.Termios;
BEGIN
	ShellCommands.Initialize(context);
	IF context.result # Commands.Ok THEN RETURN END;
	session := ShellCommands.NewSession(context.caller);
	IF session.depth > 32 THEN context.result := Commands.CommandError; RETURN END;
	outer := context; context := ShellCommands.Context(context, context.arg, session);
	outerTerminal := terminal; outerSaved := saved; outerEditing := editing;
	isTerminal := (context.in = StdIO.env.in) & (tcgetattr(0, term) = 0);
	IF isTerminal THEN
		terminal := TRUE; saved := term;
		editing := saved;
		editing.lflags := editing.lflags - {0, 1, 3, 6, 15}; (* ISIG, ICANON, ECHO, ECHONL, IEXTEN *)
		EXCL(editing.iflags, 10); (* IXON *)
		editing.cc[6] := 1X; editing.cc[5] := 0X; (* VMIN, VTIME *)
	END;
	quit := FALSE; result := Commands.Ok;
	WHILE ~quit & ~session.quit DO
		IF isTerminal THEN
			ignored := tcsetattr(0, 0, editing);
			context.out.String("> "); context.out.Update;
		END;
		valid := ReadLine(context, isTerminal, line, quit);
		IF isTerminal THEN Restore END;
		IF ~valid THEN
			result := Commands.CommandParseError;
			IF ~isTerminal THEN quit := TRUE END;
		ELSIF ~quit THEN
			Strings.TrimWS(line);
			IF (line = "exit") OR (line = "quit") THEN quit := TRUE
			ELSIF line # "" THEN
				IF isTerminal THEN Remember(line) END;
				Streams.OpenStringReader(reader, line);
				command := ShellCommands.Context(context, reader, session);
				Execute(command);
				IF command.result # Commands.Ok THEN
					result := command.result;
					IF ~isTerminal THEN quit := TRUE END;
				END;
			END;
		END;
		context.out.Update; context.error.Update;
	END;
	IF isTerminal THEN Restore; terminal := outerTerminal; saved := outerSaved; editing := outerEditing END;
	outer.result := result;
END Start;

PROCEDURE RunFile*(context: Commands.Context);
BEGIN
	Source(context);
	IF context.result = Commands.Ok THEN Start(context) END;
END RunFile;

BEGIN
	Unix.Dlsym(Unix.libc, "tcgetattr", ADDRESS OF tcgetattr);
	Unix.Dlsym(Unix.libc, "tcsetattr", ADDRESS OF tcsetattr);
	Modules.InstallTermHandler(Restore);
END Shell.
