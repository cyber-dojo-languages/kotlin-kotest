#!/bin/sh -eu

# Dumps a class-data archive for the compiler and one for the test launcher.
#
# A kata is compiled and run in a container that is thrown away afterwards, so
# both JVMs load every class from the jars each time. An archive holds those
# classes in the form the JVM wants them, and replaying one costs a fraction of
# parsing the jars again. It is worth about half a second of a run, which is a
# quarter of what a run took without them.
#
# The classes recorded are the ones a run actually loads, so the throwaway kata
# below is shaped like a real one: a source file, and a kotest spec asserting
# against it. Archives dumped from this kata speed up any other, the classes
# being the compiler's and the engine's rather than the kata's.

readonly WORK_DIR=/tmp/dump_cds_archives
readonly CLASSES=".:$(ls /kotlin/*.jar | tr '\n' ':')"
readonly LAUNCHER="$(ls /kotlin/junit-platform-console-standalone-*.jar)"

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
        "the archive is dumped from a passing test" {
            answer() shouldBe 42
        }
    }
}
KOTLIN

JAVA_OPTS="-XX:ArchiveClassesAtExit=/kotlin/kotlinc.jsa" \
  kotlinc Answer.kt AnswerTest.kt -cp "${CLASSES}"

java -XX:ArchiveClassesAtExit=/kotlin/junit.jsa \
  -jar "${LAUNCHER}" \
  execute \
  --class-path "${CLASSES}" \
  --scan-classpath . \
  --details=summary \
  --disable-ansi-colors

# The sandbox user reads these at run time and owns nothing here.
chmod 0644 /kotlin/kotlinc.jsa /kotlin/junit.jsa

cd /
rm -rf "${WORK_DIR}"

ls -l /kotlin/kotlinc.jsa /kotlin/junit.jsa
