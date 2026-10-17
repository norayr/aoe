MODULE grep;

(** Adapted from polpo's src/cli/grep.Mod for aoe's Commands.Context streams. *)
IMPORT Commands, Streams, Files, Strings, Unix, regex;

(* Preserve polpo's glob rules; the A2 filesystem enumerator only handles '*'. *)
PROCEDURE GlobMatchAt(CONST pat, name: ARRAY OF CHAR; pi, ni: SIZE): BOOLEAN;
VAR i: SIZE;
BEGIN
  LOOP
    IF pat[pi] = "*" THEN
      INC(pi);
      IF pat[pi] = 0X THEN RETURN TRUE END;
      i := ni;
      WHILE name[i] # 0X DO
        IF GlobMatchAt(pat, name, pi, i) THEN RETURN TRUE END;
        INC(i)
      END;
      RETURN GlobMatchAt(pat, name, pi, i)
    ELSIF pat[pi] = "?" THEN
      IF name[ni] = 0X THEN RETURN FALSE END;
      INC(pi); INC(ni)
    ELSIF pat[pi] = 0X THEN RETURN name[ni] = 0X
    ELSIF pat[pi] # name[ni] THEN RETURN FALSE
    ELSE INC(pi); INC(ni)
    END
  END
END GlobMatchAt;

TYPE
  Search = OBJECT
  VAR
    context: Commands.Context;
    pattern: regex.Pattern;
    ignoreCase, invert, namesOnly, numbers, matched, failed: BOOLEAN;

    PROCEDURE &Init(context: Commands.Context);
    BEGIN SELF.context := context END Init;

    PROCEDURE Error(CONST message, name: ARRAY OF CHAR);
    BEGIN
      context.error.String("grep: "); context.error.String(message);
      IF name # "" THEN context.error.String(" "); context.error.String(name) END;
      context.error.Ln; failed := TRUE
    END Error;

    (* Like polpo's argument reader, preserve regex backslashes literally.
       Reject oversized arguments. *)
    PROCEDURE NextArg(VAR arg: ARRAY OF CHAR): BOOLEAN;
    VAR ch, quote: CHAR; n: SIZE; overflow, valid: BOOLEAN;
    BEGIN
      context.arg.SkipWhitespace; ch := context.arg.Peek();
      IF (context.arg.res # Streams.Ok) OR (ch = 0X) THEN RETURN FALSE END;
      quote := 0X; n := 0; overflow := FALSE; valid := TRUE;
      IF (ch = "'") OR (ch = '"') THEN quote := ch; context.arg.Char(ch) END;
      LOOP
        ch := context.arg.Peek();
        IF (context.arg.res # Streams.Ok) OR (ch = 0X) THEN
          IF quote # 0X THEN Error("unterminated argument", ""); valid := FALSE END;
          EXIT
        END;
        IF quote # 0X THEN
          IF ch = quote THEN context.arg.Char(ch); EXIT END
        ELSIF ch <= " " THEN EXIT
        END;
        context.arg.Char(ch);
        IF n < LEN(arg)-1 THEN arg[n] := ch; INC(n) ELSE overflow := TRUE END
      END;
      arg[n] := 0X;
      IF overflow THEN Error("argument too long", ""); valid := FALSE END;
      RETURN valid
    END NextArg;

    PROCEDURE MatchLine(CONST name, line: ARRAY OF CHAR; lineNo: SIGNED64): BOOLEAN;
    VAR beg, end: INTEGER; found: BOOLEAN;
    BEGIN
      regex.Search(pattern, line, beg, end); found := end >= 0;
      IF invert THEN found := ~found END;
      IF found THEN
        matched := TRUE;
        IF ~namesOnly THEN
          IF name # "" THEN context.out.String(name); context.out.Char(":") END;
          IF numbers THEN context.out.Int(lineNo, 0); context.out.Char(":") END;
          context.out.String(line); context.out.Char(0AX)
        END
      END;
      RETURN found
    END MatchLine;

    PROCEDURE SearchStream(reader: Streams.Reader; CONST name: ARRAY OF CHAR);
    VAR line, larger: POINTER TO ARRAY OF CHAR; n, i: INTEGER; lineNo: SIGNED64;
      ch: CHAR; afterCR, fileMatched, found: BOOLEAN;
    BEGIN
      NEW(line, 8192); n := 0; lineNo := 1; afterCR := FALSE; fileMatched := FALSE;
      LOOP
        reader.Char(ch);
        IF reader.res # Streams.Ok THEN EXIT END;
        IF afterCR & (ch = 0AX) THEN afterCR := FALSE
        ELSE
          afterCR := FALSE;
          IF (ch = 0DX) OR (ch = 0AX) THEN
            line[n] := 0X; found := MatchLine(name, line^, lineNo);
            fileMatched := fileMatched OR found;
            n := 0; INC(lineNo); afterCR := ch = 0DX
          ELSIF ch = 0X THEN
            Error("NUL byte in text input", name); RETURN
          ELSE
            IF n = LEN(line)-1 THEN
              IF LEN(line) > MAX(INTEGER) DIV 2 THEN Error("line too long", name); RETURN END;
              NEW(larger, 2*LEN(line));
              FOR i := 0 TO n-1 DO larger[i] := line[i] END;
              line := larger
            END;
            line[n] := ch; INC(n)
          END
        END;
        IF context.out.res # Streams.Ok THEN Error("write failed", ""); RETURN END
      END;
      IF n > 0 THEN
        line[n] := 0X; found := MatchLine(name, line^, lineNo);
        fileMatched := fileMatched OR found
      END;
      IF reader.res # Streams.EOF THEN Error("read failed", name) END;
      IF namesOnly & fileMatched THEN
        IF name = "" THEN context.out.String("(standard input)") ELSE context.out.String(name) END;
        context.out.Char(0AX)
      END
    END SearchStream;

    PROCEDURE SearchFile(CONST path, name: ARRAY OF CHAR);
    VAR file: Files.File; reader: Files.Reader; status: Unix.Status; res: SIGNED32;
    BEGIN
      res := Unix.stat(ADDRESS OF path[0], status);
      IF (res = 0) & (status.mode DIV 1000H MOD 10H = 4) THEN Error("is a directory", name); RETURN END;
      file := Files.Old(path);
      IF file = NIL THEN Error("cannot open", name); RETURN END;
      Files.OpenReader(reader, file, 0); SearchStream(reader, name)
    END SearchFile;

    PROCEDURE SearchMask(CONST mask: ARRAY OF CHAR);
    VAR path, cwd, name, directory, base, entryDir, entryName: Files.FileName; enum: Files.Enumerator;
      flags: SET; time, date: SIGNED32; size: Files.Size; i: SIZE; wildcard, any: BOOLEAN;
    BEGIN
      IF mask = "-" THEN SearchStream(context.in, ""); RETURN END;
      IF mask = "" THEN Error("empty filename", ""); RETURN END;
      IF Strings.Length(mask) >= LEN(path) THEN Error("filename too long", ""); RETURN END;
      (* Only caller-relative paths, never installation search-path fallbacks. *)
      IF mask[0] = "/" THEN COPY(mask, path)
      ELSE
        IF Unix.getcwd(ADDRESS OF cwd, LEN(cwd)) = NIL THEN Error("cannot resolve directory", ""); RETURN END;
        IF Strings.Length(cwd)+1+Strings.Length(mask) >= LEN(path) THEN Error("filename too long", ""); RETURN END;
        Files.JoinPath(cwd, mask, path)
      END;
      i := 0; wildcard := FALSE;
      WHILE mask[i] # 0X DO wildcard := wildcard OR (mask[i] = "*") OR (mask[i] = "?"); INC(i) END;
      IF ~wildcard THEN SearchFile(path, mask); RETURN END;
      Files.SplitPath(path, directory, base); Files.JoinPath(directory, "*", path);
      NEW(enum); enum.Open(path, {}); any := FALSE;
      WHILE enum.GetEntry(name, flags, time, date, size) DO
        Files.SplitPath(name, entryDir, entryName);
        IF ~(Files.Directory IN flags) & GlobMatchAt(base, entryName, 0, 0) THEN
          any := TRUE; SearchFile(name, name)
        END
      END;
      enum.Close;
      IF ~any THEN Error("no files matched", mask) END
    END SearchMask;

    PROCEDURE Run(literal: BOOLEAN);
    VAR arg: ARRAY 4096 OF CHAR; expression: ARRAY 4096 OF CHAR;
      error, pos: INTEGER; i: SIZE; havePattern, haveFile, options: BOOLEAN;
    BEGIN
      havePattern := FALSE; haveFile := FALSE; options := TRUE;
      WHILE ~havePattern & NextArg(arg) DO
        IF options & (arg = "--") THEN options := FALSE
        ELSIF options & (arg[0] = "-") & (arg[1] # 0X) THEN
          i := 1;
          WHILE arg[i] # 0X DO
            CASE arg[i] OF
            | "i": ignoreCase := TRUE
            | "v": invert := TRUE
            | "l": namesOnly := TRUE
            | "n": numbers := TRUE
            ELSE Error("unknown option", arg); context.result := Commands.CommandParseError; RETURN
            END;
            INC(i)
          END
        ELSE COPY(arg, expression); havePattern := TRUE
        END
      END;
      IF failed THEN context.result := Commands.CommandParseError; RETURN END;
      IF ~havePattern THEN Error("pattern expected", ""); context.result := Commands.CommandParseError; RETURN END;
      IF literal THEN regex.CompileLiteral(expression, ignoreCase, pattern, error, pos)
      ELSE regex.Compile(expression, ignoreCase, pattern, error, pos)
      END;
      IF error # regex.noerror THEN
        context.error.String("grep: invalid pattern at "); context.error.Int(pos, 0); context.error.Ln;
        context.result := Commands.CommandParseError; RETURN
      END;
      WHILE NextArg(arg) DO haveFile := TRUE; SearchMask(arg) END;
      IF ~haveFile & ~failed THEN SearchStream(context.in, "") END;
      context.out.Update;
      IF context.out.res # Streams.Ok THEN Error("write failed", "") END;
      IF failed THEN context.result := Commands.CommandError
      ELSIF ~matched THEN context.result := Commands.NoMatch
      END
    END Run;
  END Search;

PROCEDURE Word*(context: Commands.Context);
VAR search: Search;
BEGIN NEW(search, context); search.Run(TRUE) END Word;

PROCEDURE Regex*(context: Commands.Context);
VAR search: Search;
BEGIN NEW(search, context); search.Run(FALSE) END Regex;

PROCEDURE Help*(context: Commands.Context);
BEGIN
  context.out.String("grep.Word [-ivln] [--] pattern [file...]"); context.out.Ln;
  context.out.String("grep.Regex [-ivln] [--] pattern [file...]"); context.out.Ln;
  context.out.String("No files, or file '-': read standard input (including pipes)."); context.out.Ln;
  context.out.String("-i ASCII ignore case; -v invert; -l matching filenames; -n line numbers."); context.out.Ln;
  context.out.String("Word searches literal substrings, not whole words. Files prefix matching lines with their paths."); context.out.Ln;
  context.out.String("Regex: . ^ $ [] [^] ranges * + ? and backslash escapes; no groups or alternation."); context.out.Ln;
  context.out.String("Patterns: at most 255 compiled bytes (literal metacharacters need escaping internally)."); context.out.Ln;
  context.out.String("LF, CRLF and CR text; output uses LF. No match is a nonzero command result."); context.out.Ln
END Help;

END grep.
