# A gentle introduction to concurrent Active Oberon

## Contents

- Background
- Sequential, concurrent and parallel execution
- Objects and activities
- What happens when we call a method?
- Why shared variables need a protocol
- Exclusive regions and monitors
- Waiting for a condition
- Two independent workers
- Two workers using one counter
- Choosing the extent of an operation
- A producer and a consumer
- Understanding the channel protocol
- Deadlocks and nested calls
- State, references and ownership
- Completion, failure and shutdown
- Parallelism and performance
- Reading the implementation
- Questions to try

## Background

This note is for someone who has used Pascal, Modula-2, C or C++ and would like
to understand Active Oberon's concurrency facilities. We assume familiarity
with ordinary procedure calls and the small programs in [INTRO.md](INTRO.md).
We will not repeat the discussion of compilation, shell commands or standard
input and output. Instead, we will examine what happens when several activities
use the same objects.

We will introduce a problem, write a small example, and then ask what its
statements mean. Each example adds a little to the previous discussion. There
is no need to begin with the implementation of the scheduler; ordinary calls,
shared variables and a few carefully chosen waits will give us a starting point.

Three questions are particularly useful starting points:

> If an object is a monitor, why must we write `{EXCLUSIVE}`?
>
> If another object calls an exclusive method, does the current procedure stop,
> let the incoming method run, and then continue?
>
> Can non-exclusive methods execute simultaneously, or is only the object's
> main `BEGIN ... END` body concurrent?

To answer them, we must distinguish an object, an activity and a monitor.
These concepts cooperate, but none is a substitute for the others.

This discussion concerns the Linux x86-64 runtime included in aoe. Statements
about native threads, recursive locking and trap recovery describe that
implementation; they should not be read as promises about every Oberon system.

## Sequential, concurrent and parallel execution

Suppose a procedure calls two other procedures:

```oberon
ReadInput;
Calculate;
```

In ordinary sequential execution, `ReadInput` must return before `Calculate`
starts. If `ReadInput` waits for a character, the caller cannot execute
`Calculate` during that wait. Moving the two procedures into different objects
does not change this rule.

Concurrent execution means that two activities have overlapping lifetimes and
can make progress independently. While one waits for input, another may do a
calculation. On one processor core, the scheduler can alternate between them.
On several cores, some instructions may execute at the same time. This latter
case is parallel execution.

Thus a concurrent program need not always run in parallel. Its correctness
must not depend on which activity happens to run first, how many cores are
available, or where the scheduler interrupts a sequence of ordinary statements.

Question: Is this the same as Modula-2's `TRANSFER`?

No. With explicit coroutine transfer, a program deliberately passes execution
from one coroutine to another. In our aoe runtime, active bodies use native
Linux threads. Scheduling is not restricted to programmer-written transfer
points. A calculation can overlap another calculation without either calling
an input operation or voluntarily yielding.

The A2 runtime often calls an activity a *process*. In this note, that does not
mean an independent Linux process with a separate address space. Activities
inside one aoe runtime share its modules and heap.

## Objects and activities

An object groups state and operations. It need not have any independently
executing code. A counter used by several threads can be an ordinary, passive
object. The threads calling it supply the execution.

An active body introduces independent execution:

```oberon
BEGIN {ACTIVE}
  Work
END Worker;
```

This is the body of an object type, not the body of the module containing the
type. For the simple worker types used below, constructing an instance starts
its body as a new activity. `{ACTIVE}` does not imply an infinite loop. If
`Work` returns, this body finishes.

The initializer, declared with `&`, runs before the object's body is started.
Use it to establish the state needed by that body. However, do not assume that
the body waits for the next statement after `NEW`: it can start, or even finish,
before the creating thread reaches that statement.

Question: Does returning from `NEW` mean that the work is complete?

No. Construction starts an active body; it does not normally wait for that
body's complete calculation. If the caller needs a result, we must supply a
completion protocol. The examples will use a protected `done` condition.

Nor does finishing an active body destroy its object. An object can remain
reachable and have methods called after its activity finishes. Object lifetime
and activity lifetime are separate matters.

## What happens when we call a method?

Suppose thread A calls `worker.SetLimit(100)`, while the worker's active body is
running on thread B:

```text
thread A: caller ----> worker.SetLimit ----> caller continues
thread B: worker's active body ---------------------------->
```

`SetLimit` executes on A. The call does not become a message delivered to B.
Thread A waits for the ordinary call to return, but B may continue its own
execution at the same time.

Consequently, an active object is not automatically an actor with a mailbox.
It has an independently running body, but ordinary method calls retain their
ordinary call-and-return meaning. A mailbox is a data structure and protocol
which we can build explicitly.

Question: Can two threads execute the same method at once?

Yes, if the method does not exclude them. They have different procedure
activations and local variables, but may refer to the same object fields.
A third thread may also be running that object's active body. All three can
access shared state unless the program prevents it.

Conversely, a non-exclusive method does not create a thread. With only one
calling thread, ordinary calls still execute sequentially. Lack of a lock is
not itself a source of concurrency.

These observations answer part of our original question: the active body is
one source of execution, not the only code allowed to execute in the object.
The identity of the caller determines which thread executes an ordinary call.

## Why shared variables need a protocol

Consider two threads incrementing the same counter. It is tempting to regard
`INC(value)` as one indivisible action. For reasoning about unsynchronized
shared state, however, it is not safe to assume that property. Think of the
increment as reading a value, calculating its successor, and writing it back.

Starting from zero, the following interleaving loses an increment:

```text
A reads 0.
B reads 0.
A calculates 1 and writes 1.
B calculates 1 and writes 1.
```

Two increments have been attempted, but the final value is one. The problem
is not that either thread's arithmetic is wrong. The problem is the interaction
between operations on the shared variable.

Question: Does this problem disappear on a single-core machine?

No. The scheduler can switch threads between the read and the write. More cores
make simultaneous execution possible, but interleaving is already sufficient
to expose the problem.

A *data race* concerns competing accesses to shared memory without the required
synchronization, including at least one write. A more general *race condition*
can occur even when individual accesses are locked: the program's result may
still depend on an unintended ordering of several separate operations. We will
return to that distinction when choosing the extent of an exclusive region.

Do not try to establish correctness by observing that an aligned integer load
looks atomic on a particular CPU. An increment, a relationship between fields,
and publication of a completed result require more than that observation.

## Exclusive regions and monitors

An exclusive region uses the monitor associated with its object or module:

```oberon
PROCEDURE Increment;
BEGIN {EXCLUSIVE}
  INC(value)
END Increment;
```

For one object instance, only one thread can own this monitor at a time.
Different exclusive methods of that instance compete for the **same** monitor;
they do not acquire independent method-specific locks. Different object
instances have independent monitors, even if they have the same type.

An exclusive region in a module procedure uses that module's monitor. This
is useful for module variables shared between commands. It is not a global
lock on every module or object that the procedure happens to call.

Question: If an object provides a monitor, why write `{EXCLUSIVE}`?

Because this does not automatically serialize every access to the object.
`{EXCLUSIVE}` identifies the regions which participate in the monitor protocol.
A non-exclusive method does not acquire that monitor merely because another
method uses it.

Suppose B is already executing an exclusive region and A tries to enter another
exclusive region of the same instance. A waits. B is not interrupted to execute
A's call. When A eventually acquires the monitor, A executes its own call.
Normal OS scheduling can still pause B; mutual exclusion is not an instruction
to disable interrupts or monopolize a processor.

If B is instead executing non-exclusive code, A may enter the exclusive region
while B continues. Calling A's method exclusive does not freeze the entire
object. Both reads and writes which compete for protected state must follow
the same discipline.

The monitor also coordinates access to state across threads in this runtime;
it is not merely a convention for making output look orderly. Protect the
state being exchanged, not just the act of announcing that it is ready.

### The active body's monitor

`{ACTIVE}` and `{EXCLUSIVE}` have separate purposes. They may be combined:

```oberon
BEGIN {ACTIVE, EXCLUSIVE}
  Work
END Worker;
```

The activity now acquires the worker's monitor for this body. Another thread
cannot enter that worker's exclusive methods until the monitor is released.
Non-exclusive calls remain outside this protection.

A sleep, blocking file read or lengthy calculation does not automatically
release the monitor. Holding it throughout a forever loop can prevent other
exclusive callers from ever entering. When substantial work need not examine
protected state, it is often better to do that work outside the exclusive
region and acquire the monitor briefly to publish the result.

## Waiting for a condition

Mutual exclusion answers "who may access the state?" It does not answer "what
should a thread do when the state is not ready?" For that we use a condition.
`AWAIT` must appear within an exclusive region.

Suppose a worker has `done: BOOLEAN` and a result field. A caller can wait with:

```oberon
PROCEDURE Wait;
BEGIN {EXCLUSIVE}
  AWAIT(done)
END Wait;
```

If `done` is already true, execution continues. Otherwise the caller joins the
monitor's condition waiters and releases this monitor. That release is essential:
the worker can now enter an exclusive region and make `done` true.

At monitor handover, the runtime examines waiting conditions and can arrange
for an eligible waiter to continue. The caller resumes after `AWAIT` with the
monitor held. If it accesses the protected result before releasing that monitor,
another participating thread cannot intervene in the middle of that access.

Question: Is `AWAIT(done)` an ordinary procedure call with a Boolean argument?

No. Passing `FALSE` to an ordinary procedure would not preserve a connection
to the variable. `AWAIT` is a language construct. The compiler arranges for its
condition to be evaluated as part of the waiting protocol.

The Linux implementation saves a condition procedure and its context. Its
handover code can evaluate that predicate while selecting a waiter. The thread
checking it can therefore be the one handing over the monitor, not the waiting
thread itself. For this reason, write simple, side-effect-free predicates over
state protected by the same monitor. Do not put printing, counter increments,
or calls which acquire locks into the condition.

### Waiting is not polling

`AWAIT` does not repeatedly consume CPU time reading `done`. It allows the thread
to wait. It is also not equivalent to sleeping for an estimated duration.
A delay supplies no evidence that another thread has finished.

There is no programmer-written `notify` in this pattern. The runtime performs
the condition selection when the monitor is handed over. Updating a variable
outside the corresponding monitor protocol is not a reliable substitute for
that handover.

If the worker completes before the caller begins waiting, the caller simply
finds `done` true. This avoids treating completion as a fleeting notification
which can be missed before a waiter starts.

However, `AWAIT` is a wait for **state**, not a recorder of past events. If a
writer sets `ready := TRUE` and then `ready := FALSE` before releasing the
monitor, a waiter need never observe the intermediate value. Use a queue or
counter when several events must be remembered.

Finally, a true condition makes a waiter eligible; it does not give a deadline
or a portable fairness guarantee. Some execution must make the condition true,
and the resumed thread must still be scheduled.

## Two independent workers

Our first complete example divides a calculation between two objects. It is
deliberately small enough to follow, rather than large enough to benchmark.
Save it as `ParallelSum.Mod`:

```oberon
MODULE ParallelSum;

IMPORT Commands;

TYPE Task = OBJECT
VAR first, last: SIGNED32; answer: SIGNED64; done: BOOLEAN;

  PROCEDURE &Init(first, last: SIGNED32);
  BEGIN
    SELF.first := first; SELF.last := last;
    answer := 0; done := FALSE
  END Init;

  PROCEDURE Calculate;
  VAR i: SIGNED32; sum: SIGNED64;
  BEGIN
    sum := 0;
    FOR i := first TO last DO sum := sum + i END;
    BEGIN {EXCLUSIVE}
      answer := sum; done := TRUE
    END
  END Calculate;

  PROCEDURE Result(): SIGNED64;
  BEGIN {EXCLUSIVE}
    AWAIT(done);
    RETURN answer
  END Result;

BEGIN {ACTIVE}
  Calculate
END Task;

PROCEDURE Run*(context: Commands.Context);
VAR left, right: Task; a, b: SIGNED64;
BEGIN
  NEW(left, 1, 10000);
  NEW(right, 10001, 20000);
  a := left.Result();
  b := right.Result();
  context.out.Int(a + b, 0); context.out.Ln
END Run;

END ParallelSum.
```

Compile and call it using the familiar commands:

```text
> Compiler.Compile ParallelSum.Mod
> ParallelSum.Run
200010000
```

Both tasks are created before either result is requested. Their activities can
therefore overlap. Waiting for the left result does not stop the right activity.
If we instead created the left task, immediately waited for it, and only then
created the right task, we would remove this opportunity for overlap.

The two activities have separate `sum` and `i` locals. Their `first` and `last`
fields are set before their active bodies start and are not changed afterwards.
No shared accumulator is updated during the calculation.

Only publication of `answer` and `done` uses an exclusive region. `Result` reads
the answer through the same monitor after completion. The order is intentional:
first establish the result, then establish the condition permitting its use.
The result is not subsequently changed.

Question: Is `Calculate` asynchronous because it belongs to an active object?

No. The active body calls it normally, on that body's thread. A hypothetical
ordinary call from another thread would execute on that other thread. In this
design, `Calculate` is an internal operation invoked only by the active body;
it is not intended to be called concurrently a second time.

`Result` is also an ordinary method call. Its caller waits when necessary, but
the calculation is performed by the task's activity, not by the caller of
`Result`. This distinction is the basis of a future-like result object.

## Two workers using one counter

The sum example avoids shared updates. Sometimes sharing is the point. The
following example creates a passive counter and two active users of it. Save
it as `SharedCounter.Mod`:

```oberon
MODULE SharedCounter;

IMPORT Commands;

TYPE Counter = OBJECT
VAR value: SIGNED32;

  PROCEDURE &Init;
  BEGIN value := 0 END Init;

  PROCEDURE Increment;
  BEGIN {EXCLUSIVE}
    INC(value)
  END Increment;

  PROCEDURE Value(): SIGNED32;
  BEGIN {EXCLUSIVE}
    RETURN value
  END Value;
END Counter;

TYPE Incrementer = OBJECT
VAR counter: Counter; limit: SIGNED32; done: BOOLEAN;

  PROCEDURE &Init(counter: Counter; limit: SIGNED32);
  BEGIN
    SELF.counter := counter; SELF.limit := limit; done := FALSE
  END Init;

  PROCEDURE Work;
  VAR i: SIGNED32;
  BEGIN
    FOR i := 1 TO limit DO counter.Increment END;
    BEGIN {EXCLUSIVE} done := TRUE END
  END Work;

  PROCEDURE Wait;
  BEGIN {EXCLUSIVE}
    AWAIT(done)
  END Wait;

BEGIN {ACTIVE}
  Work
END Incrementer;

PROCEDURE Run*(context: Commands.Context);
VAR counter: Counter; left, right: Incrementer;
BEGIN
  NEW(counter);
  NEW(left, counter, 10000);
  NEW(right, counter, 10000);
  left.Wait; right.Wait;
  context.out.Int(counter.Value(), 0); context.out.Ln
END Run;

END SharedCounter.
```

After compilation, `SharedCounter.Run` prints `20000`. The increments from the
two activities may be interleaved in many orders. The final result does not
depend on that order because each complete increment acquires the same counter's
monitor.

Notice that there are three different monitor instances: the counter's monitor
and one monitor for each incrementer. `counter.Increment` uses the counter's
monitor. The small region which sets an incrementer's `done` field uses that
incrementer's monitor. Neither lock silently substitutes for the other.

Question: Would making the whole incrementer body exclusive protect the counter?

No. The two incrementers have different monitors. Both could hold their own
monitors and still compete for the same counter. Protection must be associated
with the shared state, not merely with the activities which happen to use it.

The counter has no active body and needs none. Its callers perform its
operations. `Value` is exclusive too, since reading shared mutable state also
requires the synchronization discipline.

The main command waits for both workers before asking for the final value.
Without those waits, a protected call to `Value` could still return a valid
intermediate count. Locking makes an observation safe; it does not make the
whole calculation complete.

Note: Removing the counter's exclusive regions is not a sound experiment for
proving anything about scheduling. A broken version may sometimes print the
expected answer. That only means that a particular run did not expose the bug.

## Choosing the extent of an operation

A monitor should protect an operation's invariant, not just an individual
assignment. An invariant is a condition which must hold whenever another
participating caller is allowed to examine the state.

For our channel below, an invariant will be that the number of stored items is
between zero and the buffer capacity. Adding an item requires updating both
the buffer and the count as one protected operation.

A more subtle error occurs when separate operations are individually protected.
Suppose a bounded counter has exclusive `Value` and `Increment` methods:

```oberon
IF counter.Value() < maximum THEN
  counter.Increment
END;
```

Two callers can both observe room for one more increment, release the monitor,
and then each increment. There need be no unprotected field access, yet the
limit can be exceeded. The test and the update must be one operation, such as
`TryIncrement(maximum)`, which checks and updates under the counter's monitor.

Question: Can we hold our own object's monitor around these calls instead?

Only if every competitor uses that same monitor as part of a deliberate
protocol. Different callers holding their own unrelated locks do not coordinate
with one another. Usually the operation belongs in the object which owns the
counter state.

### Small regions and internal helpers

It is useful to separate an exclusive entry operation from its implementation
helper. For example, a private helper might update several fields under a
documented rule: "the caller already holds this object's monitor". Such a helper
does not acquire the monitor again. It must not also be called without the
required protection.

This matters because our runtime's object monitors are not recursive locks.
Calling one exclusive method from another exclusive method of the same instance
can deadlock. The compiler rejects lexically nested exclusive regions, but it
does not make every possible indirect call safe. Callbacks can re-enter an
object just as easily as direct calls can.

An exclusive region is not a transaction. If a trap occurs after one field has
been modified, the runtime does not automatically undo the modification.
Invariants, failure handling and cleanup remain part of the program's design.

## A producer and a consumer

Our next example uses a bounded channel. One activity produces integers, and
another consumes them. The channel is passive: it stores values and coordinates
the callers, but has no activity of its own.

A full channel must make a producer wait. An empty channel must make a consumer
wait. It must also be possible to close the channel, so that a consumer does not
wait forever after the last item. Save this as `ChannelDemo.Mod`:

```oberon
MODULE ChannelDemo;

IMPORT Commands;

TYPE Channel = OBJECT
VAR items: ARRAY 4 OF SIGNED32; head, count: SIZE; closed: BOOLEAN;

  PROCEDURE &Init;
  BEGIN head := 0; count := 0; closed := FALSE END Init;

  PROCEDURE Put(value: SIGNED32): BOOLEAN;
  BEGIN {EXCLUSIVE}
    AWAIT((count < LEN(items)) OR closed);
    IF closed THEN RETURN FALSE END;
    items[(head + count) MOD LEN(items)] := value;
    INC(count);
    RETURN TRUE
  END Put;

  PROCEDURE Get(VAR value: SIGNED32): BOOLEAN;
  BEGIN {EXCLUSIVE}
    AWAIT((count > 0) OR closed);
    IF count = 0 THEN RETURN FALSE END;
    value := items[head];
    head := (head + 1) MOD LEN(items);
    DEC(count);
    RETURN TRUE
  END Get;

  PROCEDURE Close;
  BEGIN {EXCLUSIVE}
    closed := TRUE
  END Close;
END Channel;

TYPE Producer = OBJECT
VAR channel: Channel; done: BOOLEAN;

  PROCEDURE &Init(channel: Channel);
  BEGIN SELF.channel := channel; done := FALSE END Init;

  PROCEDURE Produce;
  VAR i: SIGNED32;
  BEGIN
    i := 1;
    LOOP
      IF i > 20 THEN EXIT END;
      IF ~channel.Put(i) THEN EXIT END;
      INC(i)
    END;
    channel.Close;
    BEGIN {EXCLUSIVE} done := TRUE END
  END Produce;

  PROCEDURE Wait;
  BEGIN {EXCLUSIVE} AWAIT(done) END Wait;

BEGIN {ACTIVE}
  Produce
END Producer;

TYPE Consumer = OBJECT
VAR channel: Channel; answer: SIGNED64; done: BOOLEAN;

  PROCEDURE &Init(channel: Channel);
  BEGIN SELF.channel := channel; answer := 0; done := FALSE END Init;

  PROCEDURE Consume;
  VAR value: SIGNED32; sum: SIGNED64;
  BEGIN
    sum := 0;
    WHILE channel.Get(value) DO sum := sum + value END;
    BEGIN {EXCLUSIVE} answer := sum; done := TRUE END
  END Consume;

  PROCEDURE Result(): SIGNED64;
  BEGIN {EXCLUSIVE} AWAIT(done); RETURN answer END Result;

BEGIN {ACTIVE}
  Consume
END Consumer;

PROCEDURE Run*(context: Commands.Context);
VAR channel: Channel; producer: Producer; consumer: Consumer; sum: SIGNED64;
BEGIN
  NEW(channel);
  NEW(producer, channel);
  NEW(consumer, channel);
  producer.Wait;
  sum := consumer.Result();
  context.out.Int(sum, 0); context.out.Ln
END Run;

END ChannelDemo.
```

Compile it and call `ChannelDemo.Run`. It prints `210`, the sum of 1 through 20.
The example deliberately uses a buffer smaller than the number of produced
values. There must be cooperation; the producer cannot finish merely by placing
all its values in an oversized buffer.

## Understanding the channel protocol

Suppose the producer runs first. After four successful calls, the channel is
full. Its next `Put` waits in `AWAIT`, releasing the **channel's** monitor.
The consumer can now enter `Get`, remove an item and release that monitor.
The waiting producer can become eligible to continue.

If the consumer runs first, its initial `Get` waits for an item or closure.
Again, the channel monitor is released during the wait. Either starting order
is valid; the design does not need a sleep to arrange the "right" one.

This is backpressure: the bounded buffer limits how far a producer can get
ahead of its consumer. It bounds queued storage; it does not promise equal
CPU time or a particular order among several competing producers.

Question: Why include `closed` in both conditions?

Without it, an empty consumer could wait forever after the final item, and a
producer blocked on a full channel could remain stuck after someone closes
the channel. Closure must provide a way out of both waits.

After closure, `Put` refuses new items. `Get` still returns items already queued;
only a closed **and empty** channel reports end of input. The consumer can
therefore drain the buffer before finishing. `Close` records persistent state,
so a caller arriving after closure sees the same decision.

The Boolean result from `Get` is also necessary. `FALSE` means that no item was
returned; the caller must not use the old value left in its `VAR` argument.
No special integer value has to be reserved as an end marker.

Both buffer indices and the count are protected by one monitor. There is no
gap between confirming that an item exists and taking it. A different consumer
cannot remove that item between those statements while obeying this monitor.

### Who closes the channel?

Our example has one producer, so that producer closes it after its final item.
With several producers, this rule needs changing: the first producer to finish
must not close the channel while the others are still producing. A coordinator
could wait for all producers and then close it, or the channel could maintain
a protected count of registered producers.

Likewise, the interface allows several consumers to compete safely for items,
but it does not promise a particular distribution of items among them. FIFO
storage order is not a fairness guarantee for the calling threads.

Question: What if we put `producer.Wait` before creating the consumer?

For this example it would deadlock. The producer would fill four slots and
wait for space. The main thread would wait for the producer to finish before
creating the only activity able to make space. Neither could progress.
Create the participants before waiting for their completion.

The aoe shell's streaming pipes use the same broad idea: a bounded buffer,
exclusive access, conditions for space and data, and closure. See
[source/Pipes.Mod](source/Pipes.Mod). The shell also closes pipe endpoints when
stages finish, so a failed or departing consumer need not leave a producer
blocked forever on a full pipe.

## Deadlocks and nested calls

A deadlock is not a slow computation. It is a set of waits for which the program
has supplied no remaining route to progress. Correct mutual exclusion alone
does not prevent it.

We have already seen self-deadlock through recursive monitor entry, and a
producer waiting for a consumer which has not been created. Two different
objects provide another common example:

```text
thread A owns object's X monitor and waits to enter Y.
thread B owns object's Y monitor and waits to enter X.
```

Neither owner can reach the statement which would release its first monitor.
A consistent ordering of lock acquisition can prevent this particular cycle.
An even simpler design, where practical, holds only one application monitor
at a time.

Question: Does `AWAIT` solve this by releasing every lock the caller holds?

No. It releases the monitor associated with that `AWAIT`, not all monitors on
the call stack. If a method owns X, calls an exclusive method of Y, and then
waits in Y, X remains held. A thread needed to satisfy Y's condition may itself
be waiting for X.

The same danger appears with callbacks, output sinks and seemingly innocent
helper methods. A call made while holding a monitor may enter other objects or
block for an unbounded time. For example, writing to a full pipe can wait for a
consumer. That consumer may need the monitor held by the writer.

A useful pattern is to take a protected snapshot, release the monitor, perform
slow work, and reacquire the monitor to publish a result. This is not magic:
if other callers can change relevant state during the slow work, you may need
to check a version or revalidate the assumptions before committing the result.

Do not repair a deadlock by adding arbitrary sleeps or increasing thread
priority. Those can alter its timing without removing the wait dependency.
Write down who owns each monitor, what each activity is waiting for, and which
activity is supposed to make each condition true.

## State, references and ownership

Synchronization becomes easier when less state is shared. In `ParallelSum`,
each task computes with its own locals and publishes one final result. In
`SharedCounter`, sharing is intentional and every access uses one monitor.
These are different designs, not competing spellings of the same design.

Object variables contain references. Assigning `second := first` gives another
reference to the same instance; it does not copy its fields, monitor or activity.
Two workers receiving the same counter therefore really do share one counter.

Conversely, protecting an object reference does not automatically protect the
referenced object. A monitor around a record containing a pointer is not a lock
on every structure reachable through that pointer. Follow the ownership rule
all the way to the state being accessed.

Local variables are private to a procedure activation, but a local variable
may still refer to a shared object. `VAR` parameters can also refer to another
caller's storage. "Declared locally" and "owns independent data" are not the
same claim.

Module globals survive between commands and are shared by concurrent callers.
Exporting a field, or making an export read-only to its clients, concerns
visibility; it does not prevent the owning module from changing that field on
another thread. An accessor needs an appropriate synchronization contract too.

Question: Can we pass the same `Commands.Context` to several workers?

We can pass the reference, but that does not make its mutable readers and writer
buffers safe for arbitrary concurrent use. In the examples, workers compute
results and the main command prints them afterwards. For simultaneous streaming,
use the shell's per-command streams or an explicitly synchronized output
interface rather than casually sharing one writer buffer.

Useful ownership rules include keeping input immutable after construction,
having one activity own a mutable structure, or transferring responsibility
through a channel. Sending an object reference through a queue does not by
itself enforce transfer: the sender must actually stop modifying it if the
protocol promises sole ownership to the receiver.

## Completion, failure and shutdown

Our `Wait` and `Result` methods wait for **application-defined completion**.
The `done` flag means that the promised work and publication are complete.
It is not a direct call to a native thread-join operation. A worker may still
be returning through its final runtime code after publishing `done`; the
examples perform no further application work after publication.

If a worker can fail, `done: BOOLEAN` alone is often insufficient. A useful
result protocol records both completion and an outcome, such as success,
failure or cancellation. A caller waits for completion and then examines that
outcome. Every intended termination path must settle the protocol.

Question: What happens if a worker traps before setting `done`?

These teaching examples do not implement trap recovery. The waiting caller
may remain blocked because no activity is left to satisfy its condition.
Real services must arrange failure reporting and cleanup, including closure
of channels which other activities may be waiting on. A Boolean named `done`
does not provide that policy automatically.

`{SAFE}` does not mean "thread-safe" or "cannot fail". In this runtime it enables
an active-body restart facility after a trap. A2's command runners use explicit
state to distinguish normal execution from recovery. Simply adding `{SAFE}`
does not undo partial state changes or make blindly repeating work correct.
Do not assume C++ exception unwinding or destructor behavior either.

### Asking an activity to stop

A long-lived service needs a cooperative shutdown protocol. For a queue-based
service, closing its input can allow it to finish queued work and exit its
receive loop, as our consumer does. A different policy might discard queued
work. The interface must say which behavior is intended.

A protected stop flag can also be useful, but it must participate in the
conditions where the worker waits. A worker waiting only for `jobs > 0` cannot
necessarily notice that `stopping` has changed. Its condition might instead
be `(jobs > 0) OR stopping`, followed by an explicit decision about draining
or abandoning the remaining work.

Furthermore, a flag on one object does not wake a waiter on an unrelated
channel. Shutdown must reach the actual wait dependency, perhaps by closing
that channel. Nor can a stop flag immediately interrupt an arbitrary blocking
system call; the I/O design needs an appropriate way to finish or cancel it.

Normal shutdown is therefore a sequence: stop accepting new work, make blocked
participants eligible to finish, wait for their completion, and only then
discard the service's resources. In the simple channel example, closure and
the two completion methods provide these steps.

Garbage collection manages memory, not this application protocol. Losing a
reference is not a reliable way to stop work gracefully. Similarly,
`System.Kill` is low-level thread termination, not a substitute for closing
channels, settling results and preserving shared invariants.

Returning from a shell command does not establish that all active objects it
created have finished. Shell `wait` waits for shell-started background commands,
not for arbitrary child objects whose creating commands have already returned.
A command should await its own required work before reporting completion.

## Parallelism and performance

Two active workers permit parallel execution; they do not guarantee a speedup.
Native thread creation, scheduling, synchronization and garbage collection all
have costs. The small sums in this note may be faster sequentially. Their
purpose is to make execution and ownership easy to follow.

The counter example serializes every increment through one monitor. Adding
more incrementers adds contenders, not more simultaneous updates to that
counter. Computing private subtotals and combining them once may scale better
when the problem permits it. That is an algorithm change, not a lock trick.

A channel improves overlap between stages when their work can proceed
independently. It cannot make a permanently slower consumer keep up with an
unbounded producer. Its backpressure is how the program copes with that fact.

Neither priorities nor a particular run's output order establish correctness.
Do not assume equal scheduling, FIFO monitor admission or eventual progress
from an unjustified condition. A program can avoid data races and still
starve an activity or wait forever for work which will never arrive.

For large numbers of small jobs, consider a bounded set of worker activities
fed by a queue rather than creating an active object for every tiny operation.
Our current active-body implementation uses native threads, not an implicit
lightweight task pool.

## Reading the implementation

The following sources connect these examples to the running system:

- [source/Unix.Objects.Mod](source/Unix.Objects.Mod): `CreateProcess` and
  `BodyStarter` start activities; `Lock`, `Await`, `Unlock` and `FindCondition`
  implement monitor entry and condition handover.
- [source/Linux.Unix.Mod](source/Linux.Unix.Mod): thread, mutex and condition
  operations are implemented using pthread facilities. Object monitors use
  the ordinary mutex constructor, not the separate recursive-mutex constructor.
- [source/FoxIntermediateBackend.Mod](source/FoxIntermediateBackend.Mod): the
  compiler's object-construction and body-call code distinguishes ordinary
  bodies from active ones. Inheritance can introduce additional body processing;
  the simple types in this note do not use it.
- [source/Pipes.Mod](source/Pipes.Mod): `Pipe` applies bounded-buffer conditions
  to streams. Its `Send`, `Receive` and `Close` methods are useful comparisons
  with our channel.
- [source/ShellCommands.Mod](source/ShellCommands.Mod): pipeline workers run
  concurrently, publish completion and close their pipe endpoints.

`System.ShowProcesses` can help inspect runtime activities in an ongoing shell.
It is not a list of independent Linux applications. To investigate a hang,
combine such observations with the source-level ownership and wait protocol;
the fact that a thread is waiting does not by itself identify a bug.

## Questions to try

1. In `ParallelSum`, move the second `NEW` after the first `Result` call. Why
   is the answer unchanged while the opportunity for overlap changes?
2. In `SharedCounter`, explain why protecting each incrementer's body would
   not permit us to remove protection from the shared counter.
3. Give an interleaving in which two individually protected `Value` and
   `Increment` calls exceed a limit checked outside the counter.
4. In `ChannelDemo`, reduce the buffer capacity from four to one. Why should
   the answer still be `210`? Which activities may spend more time waiting?
5. Explain how a closed channel with two items differs from an empty channel
   which has not been closed.
6. Suppose a consumer fails before draining a full channel. Who is responsible
   for releasing the producer from its wait, and how will the producer learn
   whether the whole operation succeeded?
7. Draw a wait dependency involving two objects where `AWAIT` releases one
   monitor but an outer held monitor still prevents progress.

For each example, ask three questions before adding another lock:

> Which thread executes this code? Who may change the state it uses? Which
> monitor, ownership rule or completion protocol makes that interaction valid?

Once these questions have precise answers, the flags in an Active Oberon
program become much less mysterious. `{ACTIVE}` supplies independent execution;
`{EXCLUSIVE}` coordinates participating accesses; `AWAIT` expresses when a
waiting participant may continue. The program still supplies the design which
makes all three useful together.
