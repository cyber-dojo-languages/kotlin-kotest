import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintStream;
import java.io.PrintWriter;
import java.lang.reflect.Field;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;

import org.junit.platform.console.ConsoleLauncher;

/**
 * Runs a kata's tests in a JVM that cyber-dojo.sh starts while the kata is
 * still compiling, so the cost of getting the test engine and mockk going is
 * paid at the same time as the compile rather than after it.
 *
 * It warms up first, on the kata the image holds in the directory named by
 * the kata.tests.warm.up property: one thread runs that kata's spec, and
 * another mocks once, which is what makes mockk attach its agent. It then
 * waits for a line on stdin. "go" runs the console launcher with this JVM's
 * own arguments, exactly as starting the launcher directly would, exit status
 * included. Anything else, or the end of stdin, halts the JVM. cyber-dojo.sh
 * kills it instead when a kata does not compile, because a halt that arrives
 * while mockk is attaching its agent can hang rather than end.
 */
public final class KataTests {

    /** The system property kotest reads a project config's class name from. */
    private static final String PROJECT_CONFIG = "kotest.framework.config.fqn";

    /** Warms up, waits for "go", then runs the console launcher on args. */
    public static void main(String[] args) throws InterruptedException {
        CountDownLatch go = new CountDownLatch(1);
        start("kata-tests-gate", () -> awaitGo(go));
        String warmUp = System.getProperty("kata.tests.warm.up");
        if (warmUp != null) {
            // The kata's directory is on this JVM's classpath, and the kata may
            // finish compiling while the warm-up runs. Naming a project config
            // that does not exist stops the warm-up running the learner's.
            System.setProperty(PROJECT_CONFIG, "cyberdojo.warmup.NoProjectConfig");
            warmUp(warmUp);
            System.clearProperty(PROJECT_CONFIG);
            forgetProjectConfig();
        }
        go.await();
        ConsoleLauncher.main(args);
    }

    /** Answers a daemon thread already running body. */
    private static Thread start(String name, Runnable body) {
        Thread thread = new Thread(body, name);
        thread.setDaemon(true);
        thread.start();
        return thread;
    }

    /** Counts go down on a "go" line, and halts the JVM on anything else. */
    private static void awaitGo(CountDownLatch go) {
        try {
            BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
            if ("go".equals(in.readLine())) {
                go.countDown();
                return;
            }
        } catch (IOException ignored) {
            // read as the end of stdin
        }
        Runtime.getRuntime().halt(0);
    }

    /**
     * Runs the spec in dir, and mocks once through the helper beside it, on two
     * threads, with every byte either prints thrown away. A warm-up that fails
     * leaves the run slower and nothing else, so its failures are ignored.
     */
    private static void warmUp(String dir) throws InterruptedException {
        PrintStream out = System.out;
        PrintStream err = System.err;
        PrintStream sink = new PrintStream(OutputStream.nullOutputStream());
        System.setOut(sink);
        System.setErr(sink);
        try {
            preload(Path.of(dir).resolveSibling("preload.txt"));
            Thread mockk = start("kata-tests-mockk", () -> mockOnce(dir));
            try {
                PrintWriter discard = new PrintWriter(sink);
                ConsoleLauncher.run(discard, discard,
                    "execute", "--class-path", dir, "--scan-classpath", dir,
                    "--details=summary", "--disable-ansi-colors");
            } catch (Throwable ignored) {
                // see above
            }
            mockk.join();
            // System.exit asks this logger whether to log the exit, and the
            // console launcher ends the run with System.exit.
            System.getLogger("java.lang.Runtime").isLoggable(System.Logger.Level.DEBUG);
        } finally {
            System.setOut(out);
            System.setErr(err);
        }
    }

    /**
     * Makes kotest look for a project config again, as it would in a JVM that
     * had not run the warm-up. Kotest looks once per JVM and keeps what it found,
     * so without this a learner's io.kotest.provided.ProjectConfig would never
     * be seen, the warm-up having already found there was none. The image build
     * runs a kata with a project config through this class, so a kotest that
     * keeps its config some other way fails the build rather than a kata.
     */
    private static void forgetProjectConfig() {
        try {
            Class<?> loader = Class.forName("io.kotest.engine.config.ProjectConfigLoader");
            Field config = loader.getDeclaredField("config");
            config.setAccessible(true);
            // null is "not looked for yet". What the warm-up left is kotest's
            // marker for "looked for, and there is none".
            ((AtomicReference<?>) config.get(null)).set(null);
        } catch (ReflectiveOperationException | ClassCastException e) {
            throw new IllegalStateException("kotest's project config cannot be reset", e);
        }
    }

    /**
     * Loads, without initialising, each class the image's recording run
     * loaded, as listed in classList. They come from the AOT cache only until
     * mockk attaches its agent, after which the JVM reads them from the jars,
     * so they are loaded here, before the warm-up lets mockk start.
     */
    private static void preload(Path classList) {
        ClassLoader loader = KataTests.class.getClassLoader();
        try (var lines = Files.lines(classList)) {
            lines.filter(line -> !line.startsWith("@") && !line.startsWith("#"))
                .filter(line -> !line.contains(" source: "))
                .map(line -> line.split(" ", 2)[0].replace('/', '.'))
                .forEach(name -> {
                    try {
                        Class.forName(name, false, loader);
                    } catch (Throwable ignored) {
                        // see warmUp
                    }
                });
        } catch (IOException | RuntimeException ignored) {
            // see warmUp
        }
    }

    /** Calls warmUpMockk() in the warm-up kata held in dir. */
    private static void mockOnce(String dir) {
        try {
            URL[] urls = { Path.of(dir).toUri().toURL() };
            ClassLoader parent = KataTests.class.getClassLoader();
            URLClassLoader loader = new URLClassLoader(urls, parent);
            loader.loadClass("cyberdojo.warmup.WarmUpKt").getMethod("warmUpMockk").invoke(null);
        } catch (Throwable ignored) {
            // see warmUp
        }
    }
}
