#!/bin/sh
# Invoked as [sh record_startup_archives.sh], and that ignores the shebang line, so
# the shell options have to be set here to have any effect. Set on the shebang
# alone they are silently absent, and a recording that failed would leave an
# image the build then reports as a success, running at full speed's half.
set -eu

# Records what each of the two JVMs a kata starts replays instead of doing the
# same work again.
#
# A kata is compiled and run in a container thrown away afterwards, so both
# JVMs would otherwise load every class from the jars every time. Compiling is
# about 85% of a run, so the compiler is where nearly all of the saving is.
#
# Both get an AOT cache. It holds classes already linked, which a class-data
# archive does not, and for the compiler that is worth about 700ms. For the
# test launcher the two measured level, so nothing is lost by using the same
# mechanism for both, and a dependency is: a class-data archive is written
# with -XX:ArchiveClassesAtExit, which refuses to run unless the JDK has a
# base archive loaded, and this one has none.
#
# The compiler's cache has to be recorded against the compiler started
# directly, as cyber-dojo.sh starts it. Recorded against the kotlinc script,
# which runs the compiler behind a Preloader with a classloader of its own,
# the cache made the run slower than having no cache at all.
#
# The classes recorded are the ones a run actually loads, so the throwaway kata
# below is shaped like a real one: a source file, and a kotest spec asserting
# against it. Archives recorded from this kata speed up any other, the classes
# being the compiler's and the engine's rather than the kata's.
#
# It does not mock, although the start-point does, and mockk's classes are
# not in either cache. That costs a test run about 0.43s, measured against
# the same kata with the mocking taken out, and four ways of recovering it
# were tried and none worked:
#
#   mocking while recording. mockk instruments through a byte-buddy agent it
#   loads at run time, and the writer excludes instrumented classes. It ends
#   up excluding java.lang.Object and reports
#     Critical class java.lang.Object has been excluded
#
#   loading mockk's classes while recording without mocking, which is where
#   0.26s of the 0.43s goes and which instruments nothing. The writer
#   segfaults in ArchiveBuilder::dump_ro_metadata.
#
#   naming the agent with -javaagent at startup rather than letting
#   byte-buddy attach it. Worth about 0.02s, which is noise.
#
#   -Dmockk.agent=subclass, which mocks by subclassing rather than
#   instrumenting. Level with the default, and it cannot mock a final class,
#   which every Kotlin class is unless opened.
#
# So what is cached here is everything around mockk. Do not spend the
# afternoon on it again without a newer JDK to try it on.

readonly WORK_DIR=/tmp/record_startup_archives
readonly CLASSES=".:$(ls /kotlin/*.jar | tr '\n' ':')"
readonly LAUNCHER="$(ls /kotlin/junit-platform-console-standalone-*.jar)"

# Named here and in cyber-dojo.sh both. The cache is validated against the
# classpath of the JVM that reads it, so the two have to name the same jar.
readonly COMPILER_JAR=/usr/share/kotlin/kotlinc/lib/kotlin-compiler.jar
readonly COMPILER_MAIN=org.jetbrains.kotlin.cli.jvm.K2JVMCompiler

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

cat > Answer.kt <<'KOTLIN'
package dojo

fun answer():Int {
    return 6 * 7
}
KOTLIN

cat > AnswerTest.kt <<'KOTLIN'
package dojo

import io.kotest.core.spec.style.StringSpec
import io.kotest.matchers.shouldBe

class AnswerTest : StringSpec() {

    init {
        "the archive is recorded from a passing test" {
            answer() shouldBe 42
        }
    }
}
KOTLIN

# The two --enable/--sun-misc flags are the ones the kotlinc script adds itself
# on jdk 24 and above. Starting the compiler directly means passing them here,
# and in cyber-dojo.sh, rather than inheriting them.
java -XX:AOTCacheOutput=/kotlin/kotlinc.aot \
  --enable-native-access=ALL-UNNAMED \
  --sun-misc-unsafe-memory-access=allow \
  -cp "${COMPILER_JAR}" "${COMPILER_MAIN}" \
  Answer.kt AnswerTest.kt -cp "${CLASSES}" -d .

java -XX:AOTCacheOutput=/kotlin/junit.aot \
  -jar "${LAUNCHER}" \
  execute \
  --class-path "${CLASSES}" \
  --scan-classpath . \
  --details=summary \
  --disable-ansi-colors

# The sandbox user reads these at run time and owns nothing here.
chmod 0644 /kotlin/kotlinc.aot /kotlin/junit.aot

cd /
rm -rf "${WORK_DIR}"

ls -l /kotlin/kotlinc.aot /kotlin/junit.aot
