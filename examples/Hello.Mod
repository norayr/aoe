MODULE Hello;

IMPORT Commands;

TYPE Worker = OBJECT
	VAR context: Commands.Context; done: BOOLEAN;

	PROCEDURE &Init(context: Commands.Context);
	BEGIN SELF.context := context; done := FALSE
	END Init;

	PROCEDURE Wait;
	BEGIN {EXCLUSIVE} AWAIT(done)
	END Wait;

	BEGIN {ACTIVE, EXCLUSIVE}
		context.out.String("Hello from an Active Oberon CLI object!"); context.out.Ln;
		done := TRUE;
	END Worker;

PROCEDURE Run*(context: Commands.Context);
VAR worker: Worker;
BEGIN
	NEW(worker, context);
	worker.Wait;
END Run;

END Hello.
