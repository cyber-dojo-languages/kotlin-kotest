package cyberdojo.warmup

import io.kotest.assertions.throwables.shouldThrow
import io.kotest.core.spec.style.StringSpec
import io.kotest.matchers.shouldBe
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify

// The kata the test JVM warms up on, while the learner's kata compiles. Its
// spec does not mock, and warmUpMockk() does, because KataTests runs the two
// on separate threads at the same time. Run one after the other they take
// longer than the compile does, and the learner's tests then wait for them.
//
// Between them they use what a learner's first run does: a passing test, a
// failing one, shouldThrow, and mockk's every, returns, throws, slot and
// verify. Whatever the warm-up does not load, the learner's run loads itself.

interface Logger {
    fun log(message: String)
}

interface Calculator {
    fun times(a: Int, b: Int): Int
}

/** What the spec asserts on, there being no kata code to test. */
fun answer(): Int {
    return 6 * 7
}

/** Mocks with each of the words a learner's first test is likely to use. */
fun warmUpMockk() {
    val logger = mockk<Logger>(relaxed = true)
    logger.log("the answer is 42")
    verify(exactly = 1) { logger.log("the answer is 42") }

    val calculator = mockk<Calculator>()
    every { calculator.times(6, 7) } returns 42
    calculator.times(6, 7)
    every { calculator.times(any(), any()) } throws RuntimeException("no answer")
    try {
        calculator.times(1, 2)
    } catch (expected: RuntimeException) {
        // as stubbed
    }

    val captured = slot<String>()
    verify { logger.log(capture(captured)) }
}

class WarmUpTest : StringSpec() {
    init {
        "the warm-up passes" {
            answer() shouldBe 42
            shouldThrow<IllegalStateException> { error("expected") }
        }

        "the warm-up fails" {
            "the answer is 54" shouldBe "the answer is 42"
        }

        "the warm-up fails again" {
            answer() shouldBe 54
        }
    }
}
