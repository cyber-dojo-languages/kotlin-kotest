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
# The two are not recorded the same way, because measuring them said they want
# different things:
#
#   the compiler gets an AOT cache. It holds classes already linked, which a
#   class-data archive does not, and that is worth about 700ms. It has to be
#   recorded against the compiler started directly, as cyber-dojo.sh starts it.
#   Recorded against the kotlinc script, which runs the compiler behind a
#   Preloader with a classloader of its own, the cache made the run slower than
#   having no cache at all.
#
#   the test launcher keeps a class-data archive. An AOT cache was measured
#   here too and came out level with it, so there is nothing to be gained by
#   changing it.
#
# The classes recorded are the ones a run actually loads, so the throwaway kata
# below is shaped like a real one: a source file, and a kotest spec asserting
# against it. Archives recorded from this kata speed up any other, the classes
# being the compiler's and the engine's rather than the kata's.

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

java -XX:ArchiveClassesAtExit=/kotlin/junit.jsa \
  -jar "${LAUNCHER}" \
  execute \
  --class-path "${CLASSES}" \
  --scan-classpath . \
  --details=summary \
  --disable-ansi-colors

# The sandbox user reads these at run time and owns nothing here.
chmod 0644 /kotlin/kotlinc.aot /kotlin/junit.jsa

cd /
rm -rf "${WORK_DIR}"

ls -l /kotlin/kotlinc.aot /kotlin/junit.jsa
