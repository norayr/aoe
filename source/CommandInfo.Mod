MODULE CommandInfo; (** Discover callable commands without loading their modules. *)
(* SPDX-License-Identifier: GPL-3.0-only *)

IMPORT SYSTEM, Machine, Modules, Commands, Streams, Strings, Files, ObjectFile, GenericLinker;

TYPE
	Name* = POINTER TO RECORD next-: Name; name-: Modules.Name END;

	(* The non-cooperative runtime's dynamic-array header. Locations refer to
	   bytes in object-file sections, never to executable memory addresses. *)
	ArrayHeader = RECORD
		pointerCount: SIZE; firstPointer: ADDRESS; length: SIZE;
	END;
	Location = RECORD block: GenericLinker.Block; offset: SIZE END;

	Reader = OBJECT
	VAR file: Files.File; moduleName: Modules.Name; names: Name;
		reader: Files.Reader; linker: GenericLinker.Linker; done, entered, found: BOOLEAN;

		PROCEDURE &Init(file: Files.File; CONST module: ARRAY OF CHAR);
		BEGIN
			SELF.file := file; COPY(module, moduleName);
		END Init;

		PROCEDURE Inspect;
		VAR header: ArrayHeader; command: Modules.Command; name: ObjectFile.SectionName;
			identifier: ObjectFile.Identifier; root, module, array: Location; layout: Modules.Module;
			offset, size, argOffset, retOffset, fieldOffset, i, n: SIZE;
		BEGIN
			COPY(moduleName, name); Strings.Append(name, ".@Module");
			ObjectFile.StringToSegmentedName(name, identifier.name);
			root.block := linker.FindBlock(identifier); root.offset := 0;
			(* Same module-root indirection as Loader.LoadObj, but follow the
			   relocation instead of linking or dereferencing a native pointer. *)
			IF ~Follow(linker, root, 2*SIZEOF(ADDRESS)+SIZEOF(SIZE), module) THEN RETURN END;
			layout := Modules.ModuleByName("Commands");
			fieldOffset := ADDRESS OF layout.command - SYSTEM.VAL(ADDRESS, layout);
			IF ~Follow(linker, module, fieldOffset, array) THEN RETURN END;
			IF ~Read(array, ADDRESS OF header, SIZEOF(ArrayHeader)) THEN RETURN END;
			offset := array.offset+SIZEOF(ArrayHeader); size := array.block.bits.GetSize() DIV 8;
			IF (header.length < 0) OR (header.length > (size-offset) DIV SIZEOF(Modules.Command)) THEN RETURN END;
			found := TRUE;
			argOffset := ADDRESS OF command.argTdAdr - ADDRESS OF command;
			retOffset := ADDRESS OF command.retTdAdr - ADDRESS OF command;
			FOR n := 0 TO header.length-1 DO
				IF TypeMatches(array.block^, offset+argOffset, TRUE) & TypeMatches(array.block^, offset+retOffset, FALSE) THEN
					i := 0;
					REPEAT
						command.name[i] := CHR(array.block.bits.GetBits((offset+i)*8, 8)); INC(i);
					UNTIL (command.name[i-1] = 0X) OR (i = LEN(command.name));
					IF (i > 1) & (command.name[i-1] = 0X) THEN Add(names, command.name) END;
				END;
				INC(offset, SIZEOF(Modules.Command));
			END;
		END Inspect;

		PROCEDURE Result(VAR names: Name): BOOLEAN;
		BEGIN {EXCLUSIVE} AWAIT(done); names := SELF.names; RETURN found END Result;

	BEGIN {ACTIVE, SAFE}
		IF ~entered THEN
			entered := TRUE; Files.OpenReader(reader, file, 0);
			NEW(linker, NIL, NIL, {}, NIL, NIL); GenericLinker.Load(reader, linker); linker.EnterBlocks;
			Inspect;
		ELSE names := NIL; found := FALSE;
		END;
	FINALLY
		BEGIN {EXCLUSIVE} done := TRUE END;
	END Reader;

PROCEDURE Add(VAR names: Name; CONST name: Modules.Name);
VAR entry: Name;
BEGIN
	NEW(entry); entry.name := name; entry.next := names; names := entry;
END Add;

PROCEDURE Normalize(VAR location: Location): BOOLEAN;
BEGIN
	IF location.block = NIL THEN RETURN FALSE END;
	WHILE location.block.aliasOf # NIL DO
		INC(location.offset, location.block.address); location.block := location.block.aliasOf;
	END;
	RETURN (location.offset >= 0) & (location.offset <= location.block.bits.GetSize() DIV 8);
END Normalize;

(* Merged sections are handled through their exported aliases and relocation
   records, just as by the linker. No search for strings or guessed table offsets. *)
PROCEDURE Follow(linker: GenericLinker.Linker; source: Location; field: SIZE; VAR target: Location): BOOLEAN;
VAR i, j: SIZE;
BEGIN
	IF ~Normalize(source) THEN RETURN FALSE END;
	FOR i := 0 TO source.block.fixups-1 DO
		FOR j := 0 TO source.block.fixup[i].patches-1 DO
			IF source.block.fixup[i].patch[j].offset = source.offset+field THEN
				target.block := linker.FindBlock(source.block.fixup[i].identifier);
				target.offset := source.block.fixup[i].patch[j].displacement;
				RETURN Normalize(target);
			END;
		END;
	END;
	RETURN FALSE;
END Follow;

PROCEDURE Read(source: Location; address: ADDRESS; size: SIZE): BOOLEAN;
VAR i: SIZE;
BEGIN
	IF ~Normalize(source) OR (source.offset+size > source.block.bits.GetSize() DIV 8) THEN RETURN FALSE END;
	FOR i := 0 TO size-1 DO
		SYSTEM.PUT(address+i, CHR(source.block.bits.GetBits((source.offset+i)*8, 8)));
	END;
	RETURN TRUE;
END Read;

(* These are the two signatures requested by Commands.Runner's GETPROCEDURE
   calls. In an object file, descriptor slots are zero, ANY (1), or a relocation
   to a named type. Relocations already resolve source-level type aliases. *)
PROCEDURE TypeMatches(CONST section: ObjectFile.Section; offset: SIZE; allowContext: BOOLEAN): BOOLEAN;
VAR i, j: SIZE; name: ObjectFile.SectionName;
BEGIN
	FOR i := 0 TO section.fixups-1 DO
		FOR j := 0 TO section.fixup[i].patches-1 DO
			IF section.fixup[i].patch[j].offset = offset THEN
				ObjectFile.SegmentedNameToString(section.fixup[i].identifier.name, name);
				RETURN allowContext & (name = "Commands.Context");
			END;
		END;
	END;
	FOR i := 0 TO SIZEOF(ADDRESS)-1 DO
		IF section.bits.GetBits((offset+i)*8, 8) # 0 THEN RETURN FALSE END;
	END;
	RETURN TRUE;
END TypeMatches;

PROCEDURE List*(CONST module: ARRAY OF CHAR; VAR names: Name): BOOLEAN;
VAR file: Files.File; filename: Files.FileName; reader: Reader; i: SIZE; loaded: Modules.Module;
BEGIN
	names := NIL;
	COPY(module, filename); Strings.Append(filename, Machine.DefaultObjectFileExtension); file := Files.Old(filename);
	IF file # NIL THEN
		NEW(reader, file, module);
		IF reader.Result(names) THEN RETURN TRUE END;
	END;
	(* Statically linked modules remain discoverable without their object files.
	   Looking them up does not load or initialize any additional module. *)
	loaded := Modules.ModuleByName(module);
	IF loaded = NIL THEN RETURN FALSE END;
	IF loaded.command # NIL THEN
		FOR i := 0 TO LEN(loaded.command^)-1 DO
			IF (loaded.command[i].retTdAdr = 0) & ((loaded.command[i].argTdAdr = 0) OR
				(loaded.command[i].argTdAdr = SYSTEM.TYPECODE(Commands.Context))) THEN Add(names, loaded.command[i].name) END;
		END;
	END;
	RETURN TRUE;
END List;

END CommandInfo.
