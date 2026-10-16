#!/bin/sh
# Invoked as [sh record_startup_archives.sh], and that ignores the shebang line, so
# the shell options have to be set here to have any effect. Set on the shebang
# alone they are silently absent, and a recording that failed would leave an
# image the build then reports as a success, running at full speed's half.
set -eu

# Builds what the test JVM runs, and records what each of the two JVMs a kata
# starts replays instead of doing the same work again.
#
# A kata is compiled and run in a container thrown away afterwards, so both
# JVMs would otherwise load every class from the jars every time. Both get an
# AOT cache, which holds classes already linked, and for the compiler also
# which of its methods the recording run found hot, so the compiler can
# compile those as soon as it starts rather than after it has run them slowly
# for a while.
#
# The compiler's cache has to be recorded against the compiler started
# directly, as cyber-dojo.sh starts it. Recorded against the kotlinc script,
# which runs the compiler behind a Preloader with a classloader of its own,
# the cache made the run slower than having no cache at all.
#
# Archives recorded from the throwaway katas below speed up any other, the
# classes being the compiler's and the engine's rather than the kata's. The
# compiler is recorded compiling a kata that mocks, as the start-point's does,
# because mockk's every and verify are inline functions the compiler has to
# inline, and a recording that never saw that leaves the compile about 50ms
# slower.
#
# The test JVM is recorded running a kata that does not mock, and mockk's
# classes are not in its cache. Mocking while recording fails: mockk
# instruments through a byte-buddy agent it attaches at run time, the writer
# excludes instrumented classes, and it ends up excluding a class it cannot do
# without and refuses to write anything:
#   Critical class java.lang.NullPointerException has been excluded
# So mockk is started on a thread of its own while the kata compiles instead.
# KataTests.java explains how.

readonly WORK_DIR=/tmp/record_startup_archives
readonly JARS="$(ls /kotlin/*.jar | tr '\n' ':')"
readonly CLASSES=".:${JARS}"
readonly LAUNCHER="$(ls /kotlin/junit-platform-console-standalone-*.jar)"

# Named here and in cyber-dojo.sh both. A cache is validated against the
# classpath of the JVM that reads it, so the two have to name the same jars.
readonly COMPILER_JAR=/usr/share/kotlin/kotlinc/lib/kotlin-compiler.jar
readonly COMPILER_MAIN=org.jetbrains.kotlin.cli.jvm.K2JVMCompiler
readonly KATA_TESTS=/kotlin/kata-tests
readonly KATA_TESTS_JAR="${KATA_TESTS}/kata-tests.jar"
# cyber-dojo.sh appends the kata's directory to this, and a JVM may append
# to the classpath its cache was recorded with.
readonly TEST_CLASSPATH="${KATA_TESTS_JAR}:${LAUNCHER}:${JARS%:}"

# The two --enable/--sun-misc flags are the ones the kotlinc script adds itself
# on jdk 24 and above. Starting the compiler directly means passing them here,
# and in cyber-dojo.sh, rather than inheriting them.
kotlinc()
{
  java \
    --enable-native-access=ALL-UNNAMED \
    --sun-misc-unsafe-memory-access=allow \
    "$@"
}

mkdir -p "${WORK_DIR}/compiler" "${WORK_DIR}/tests" "${WORK_DIR}/classes" "${KATA_TESTS}/warm-up"

# What the test JVM runs, and the kata it warms up on.
javac -d "${WORK_DIR}/classes" -cp "${LAUNCHER}" kata_tests/KataTests.java
jar --create --file "${KATA_TESTS_JAR}" -C "${WORK_DIR}/classes" .
kotlinc -cp "${COMPILER_JAR}" "${COMPILER_MAIN}" -jvm-target 17 \
  kata_tests/WarmUp.kt -cp "${CLASSES}" -d "${KATA_TESTS}/warm-up"

cd "${WORK_DIR}/compiler"

cat > Hiker.kt <<'KOTLIN'
package dojo

interface Logger {
    fun log(message: String)
}

fun answer(logger: Logger): Int {
    val answer = 6 * 7
    logger.log("the answer is $answer")
    return answer
}

class Hiker(private val logger: Logger) {
    fun instanceAnswer(): Int {
        return answer(logger)
    }
}
KOTLIN

cat > HikerTest.kt <<'KOTLIN'
package dojo

import io.kotest.core.spec.style.StringSpec
import io.kotest.matchers.shouldBe
import io.kotest.assertions.throwables.shouldThrow
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify

class HikerTest : StringSpec() {
    init {
        "top level function" {
            val logger = mockk<Logger>(relaxed = true)
            answer(logger) shouldBe 42
            verify(exactly = 1) { logger.log("the answer is 42") }
        }

        "class method" {
            val logger = mockk<Logger>(relaxed = true)
            Hiker(logger).instanceAnswer() shouldBe 42
        }

        "stubs and captures" {
            val calculator = mockk<Calculator>()
            every { calculator.times(6, 7) } returns 42
            calculator.times(6, 7) shouldBe 42
            every { calculator.times(any(), any()) } throws RuntimeException("no")
            shouldThrow<RuntimeException> { calculator.times(1, 2) }
            val captured = slot<String>()
            val logger = mockk<Logger>(relaxed = true)
            logger.log("x")
            verify { logger.log(capture(captured)) }
            captured.captured shouldBe "x"
        }
    }
}

interface Calculator {
    fun times(a: Int, b: Int): Int
}
KOTLIN

kotlinc -XX:AOTCacheOutput=/kotlin/kotlinc.aot \
  -cp "${COMPILER_JAR}" "${COMPILER_MAIN}" -jvm-target 17 \
  -Xdisable-default-scripting-plugin \
  Hiker.kt HikerTest.kt -cp "${CLASSES}" -d .

cd "${WORK_DIR}/tests"

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

kotlinc -cp "${COMPILER_JAR}" "${COMPILER_MAIN}" -jvm-target 17 \
  Answer.kt AnswerTest.kt -cp "${CLASSES}" -d .

# Recorded on the classpath, and with the module option, that cyber-dojo.sh
# starts the test JVM with. A cache recorded without the option is refused by
# a JVM started with it.
java -XX:AOTCacheOutput=/kotlin/junit.aot \
  --enable-final-field-mutation=ALL-UNNAMED \
  -cp "${TEST_CLASSPATH}" \
  org.junit.platform.console.ConsoleLauncher \
  execute \
  --class-path . \
  --scan-classpath . \
  --details=summary \
  --disable-ansi-colors

# Kotest looks for a project config with Class.forName, which only sees the
# classpath kotest itself was loaded from, so cyber-dojo.sh puts the kata's
# own directory there too, after the jars.
#
# The classes the recording run loaded, which KataTests loads before mockk
# attaches its agent. Once the agent is attached the JVM serves only the
# JDK's own classes from the cache, so whatever is loaded after it comes off
# the jars instead.
cd "${WORK_DIR}/tests"
java -XX:DumpLoadedClassList="${KATA_TESTS}/preload.txt" \
  --enable-final-field-mutation=ALL-UNNAMED \
  -cp "${TEST_CLASSPATH}" \
  org.junit.platform.console.ConsoleLauncher \
  execute \
  --class-path . \
  --scan-classpath . \
  --details=summary \
  --disable-ansi-colors > /dev/null

# KataTests runs a learner's tests in a JVM that has already run kotest once,
# for the warm-up, and kotest keeps the project config it finds the first time.
# KataTests makes it look again, through kotest's internals, so this checks a
# learner's project config is still seen, and stops the build if a newer
# kotest keeps it some other way.
mkdir -p "${WORK_DIR}/config"
cd "${WORK_DIR}/config"

cat > ProjectConfig.kt <<'KOTLIN'
package io.kotest.provided

import io.kotest.core.config.AbstractProjectConfig

class ProjectConfig : AbstractProjectConfig() {
    override suspend fun beforeProject() {
        println("the learner's project config was seen")
    }
}
KOTLIN

cp ../tests/Answer.kt ../tests/AnswerTest.kt .
kotlinc -cp "${COMPILER_JAR}" "${COMPILER_MAIN}" -jvm-target 17 \
  ProjectConfig.kt Answer.kt AnswerTest.kt -cp "${CLASSES}" -d .

echo go | java \
  -Djdk.attach.allowAttachSelf=true \
  -Dkata.tests.warm.up="${KATA_TESTS}/warm-up" \
  -cp "${TEST_CLASSPATH}:." \
  KataTests \
  execute \
  --class-path . \
  --scan-classpath . \
  --details=summary \
  --disable-ansi-colors \
  > config.out 2>&1 || true

if ! grep -q "the learner's project config was seen" config.out; then
  cat config.out >&2
  echo "KataTests no longer lets kotest see a learner's project config" >&2
  exit 1
fi

# The sandbox user reads these at run time and owns nothing here.
chmod 0644 /kotlin/kotlinc.aot /kotlin/junit.aot "${KATA_TESTS_JAR}"
chmod -R a+rX "${KATA_TESTS}"

cd /
rm -rf "${WORK_DIR}"

ls -l /kotlin/kotlinc.aot /kotlin/junit.aot "${KATA_TESTS_JAR}"
