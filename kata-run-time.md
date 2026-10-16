# Where a kotlin-kotest run's time goes, and what takes it out

All figures are from an arm64 MacBook (Apple M5: 4 performance cores and 6
efficiency cores, Docker Desktop), JDK 27, Kotlin 2.4, Kotest 6.2, mockk 1.14.
"Harness" figures come from the start-point's own `run_tests.sh
--lights-only`, six runs each. "Probe" figures come from running
`cyber-dojo.sh` inside the image configured as the runner configures a kata
(sandbox user, no network, 768MB, the runner's ulimits), which leaves out the
runner's own cost of about 0.1s a run.

## The result

    harness, six runs     red          amber        green
    before                1.25-1.28s   0.47s        1.25-1.28s
    after                 0.66-0.67s   0.47-0.50s   0.67-0.70s

All 29 fixtures pass. 90 probe runs (30 each of red, amber and green) all
ended with the right status, none timed out.

## Where the time went before

A run is two JVMs one after the other, each started cold:

    compiler JVM (kotlinc)       about 590ms
    test JVM (console launcher)  about 630ms

Inside the test JVM, mockk was the largest single cost: loading mockk and
byte-buddy and attaching mockk's agent took about 300ms, and none of it can
come from the AOT cache (see "Tried and dropped").

## What takes it out

1. The test JVM starts first and warms up while the kata compiles
   (`docker/kata_tests/KataTests.java`). It runs a kata the image holds, on
   one thread, while a second thread mocks once, which attaches mockk's agent.
   It then waits on a pipe for "go". This hides about 0.4s of the test JVM's
   0.6s behind the compile, and after "go" a red run's tests take about 60ms.
   Run one after the other the two warm-ups took longer than the compile, so
   they run on separate threads.

2. The warm-up uses what a learner's first run does: a failing test as well
   as a passing one, the same `--details=summary`, and mockk's every,
   returns, throws, slot and verify. Each of those loads classes a learner's
   run would otherwise load after "go": about 80ms after "go" became about
   60ms.

3. The test JVM puts the framework jars on its own classpath instead of on
   the launcher's `--class-path`, so a warm-up and the learner's run share
   one copy of every framework class. Measured alone, without the warm-up,
   this was about 90ms faster too (465ms against 559ms).

4. The test JVM loads, before mockk starts, every class the image's
   recording run loaded (`/kotlin/kata-tests/preload.txt`). Once mockk has
   attached its agent the JVM serves only the JDK's own classes from the
   cache, so loading them first takes AOT-served classes from 2806 to 3832
   and the compile, sharing the CPU, about 10ms faster.

5. Compiler flags, each measured on its own:

       -XX:+AOTCompileEagerly           about 560ms -> 510ms
       -XX:InitialCodeCacheSize=128m    about 510ms -> 480ms (no full GC)
       -Xms256m -Xmn200m                about 15ms (13 collections -> 1)
       cache recorded from a kata that mocks, rather than one that does not
                                        about 505ms -> 455ms
       -XX:CICompilerCount=2            about 30ms, beside the test JVM
       -Xdisable-default-scripting-plugin   about 5-10ms

6. On a compile error the test JVM is killed. A JVM told to halt while mockk
   is attaching its agent can hang: 3 amber runs in 10 hung until a 20s
   timeout, and a SIGQUIT got no thread dump. `pkill -KILL` ends it at once.

## What the warm-up must not change

- A learner's `io.kotest.provided.ProjectConfig`. Kotest looks for one once
  per JVM and keeps what it found, so the warm-up would hide the learner's.
  KataTests names a project config that does not exist for the warm-up, then
  resets kotest's record of it. That reset reaches into kotest's internals,
  so `record_startup_archives.sh` runs a kata with a project config through
  KataTests, and fails the image build if it is not seen.
- What the learner reads. The warm-up's output is discarded. The JVM warnings
  the cold run printed (dynamic agent loading, final field mutation, class
  sharing) are now switched off, so a run's output is shorter, not longer.

## Costs

- Memory: peak 410MB for the whole container during a green run, against the
  runner's 768MB limit. Peak processes and threads 57, against 128.
- The test JVM uses about 0.4 CPU-seconds while the compile runs. On this
  machine that slows the compile by about 50ms (about 440ms alone, about 490ms
  beside it), because the two JVMs spill onto the efficiency cores: three
  `yes` loops beside the compile slow it by about 140ms. Homogeneous server
  cores should lose less.
- Amber is about the same as before. The compile ends the run and the test
  JVM is killed.

## Tried and dropped

- Mocking while recording the test JVM's cache, on JDK 27: still refused,
  `Critical class java.lang.NullPointerException has been excluded`.
- Loading mockk's and byte-buddy's 1444 classes (without mocking) while
  recording: JDK 27 records it (41MB cache), but runs were no faster.
- Stopping mockk appending its jar to the boot classpath, which is what ends
  class sharing: mockk always appends, and when it cannot make its temp file
  it writes the jar into the current directory, which is the learner's.
- Recording the compiler's cache from three or six compiles in one JVM
  (`-Xbuild-file`): slower, 465ms and 550ms against 455ms.
- Compiler JVM: full tiered compilation (640ms), lower C1 thresholds (600ms),
  `-XX:-BackgroundCompilation` (much slower), `-XX:+UseCompactObjectHeaders`,
  `-XX:-UsePerfData`, a shorter compile classpath: none faster.
- Compiler args `-Xlambdas=class`, `-Xskip-metadata-version-check`,
  `-Xno-source-debug-extension`: none faster.
- Test JVM: `-XX:+UseSerialGC`, `nice`, `-XX:CICompilerCount=1`, starting it
  100-200ms after the compiler: none faster.
- A FIFO for "go": a reader that opened it after the shell had closed the
  writer blocked for good. The pipe is a process substitution instead, which
  exists before either process starts.

## Not possible without changing the runner

- A JVM kept warm in a spare container between runs:
  `_spare_warmup_script.md` sections 14 and 15. About 0.58s, but it needs the
  runner to start it and holds about 370MB per spare.
- CRaC (checkpoint/restore of a warmed JVM) needs capabilities the runner's
  containers do not have.
