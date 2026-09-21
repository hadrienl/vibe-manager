import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeTerminal

@Test("A command runs in a pseudo terminal and reports its output and exit code")
func runsCommandAndReportsExitCode() async throws {
  let session = try TerminalTestSupport.makeSession(script: "echo hello world")

  let outcome = await runToCompletion(session)

  #expect(outcome.text.contains("hello world"))
  #expect(outcome.state == .exited(code: 0))
}

@Test("A non-zero exit code is reported faithfully")
func reportsNonZeroExitCode() async throws {
  let session = try TerminalTestSupport.makeSession(script: "exit 7")

  let outcome = await runToCompletion(session)

  #expect(outcome.state == .exited(code: 7))
}

@Test("A process killed by a signal is distinguished from a normal exit")
func reportsTerminatingSignal() async throws {
  let session = try TerminalTestSupport.makeSession(script: "kill -TERM $$; sleep 5")

  let outcome = await runToCompletion(session)

  #expect(outcome.state == .terminated(signal: SIGTERM))
}

@Test("The command runs inside a real terminal, not a pipe")
func runsInsideATerminal() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: "if [ -t 0 ]; then echo IS_TTY; else echo NOT_TTY; fi"
  )

  let outcome = await runToCompletion(session)

  #expect(outcome.text.contains("IS_TTY"))
  #expect(!outcome.text.contains("NOT_TTY"))
}

@Test("Input written to the session reaches the process")
func writesInputToTheProcess() async throws {
  let session = try TerminalTestSupport.makeSession(script: "read line; echo \"got:$line\"")
  let observer = await TerminalObserver.attach(to: session)

  await session.write("ping\n")

  #expect(await observer.waitForText("got:ping"))
  await session.stop(gracePeriod: .seconds(2))
}

@Test("The initial input is delivered without being interpreted by a shell")
func deliversInitialInput() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: "read line; echo \"prompt:$line\"",
    initialInput: "a b \"c\" 'd' $HOME\n"
  )

  let outcome = await runToCompletion(session)

  #expect(outcome.text.contains("prompt:a b \"c\" 'd' $HOME"))
}

@Test("The terminal reports the size it was started with, and follows a resize")
func followsWindowResize() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: """
      trap 'stty size' WINCH
      stty size
      i=0
      while [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      """,
    size: TerminalSize(columns: 100, rows: 30)
  )
  let observer = await TerminalObserver.attach(to: session)

  #expect(await observer.waitForText("30 100"))

  await session.resize(to: TerminalSize(columns: 132, rows: 43))

  #expect(await observer.waitForText("43 132"))
  await session.stop(gracePeriod: .seconds(2))
}

@Test("An unusable or unchanged size is ignored")
func ignoresUnusableResize() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: """
      trap 'stty size' WINCH
      stty size
      i=0
      while [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      """,
    size: TerminalSize(columns: 100, rows: 30)
  )
  let observer = await TerminalObserver.attach(to: session)
  #expect(await observer.waitForText("30 100"))

  await session.resize(to: TerminalSize(columns: 0, rows: 0))
  await session.resize(to: TerminalSize(columns: 100, rows: 30))
  await session.resize(to: TerminalSize(columns: 120, rows: 40))

  #expect(await observer.waitForText("40 120"))
  // A single resize was applied, so the reported size never went through an unusable value.
  #expect(await !observer.text.contains("0 0"))
  await session.stop(gracePeriod: .seconds(2))
}

@Test("Multi-byte characters survive reads that split them")
func preservesMultiByteCharacters() async throws {
  // Each write is small and unaligned, so the reader repeatedly sees partial UTF-8 sequences.
  let session = try TerminalTestSupport.makeSession(
    script: """
      i=0
      while [ $i -lt 200 ]; do
        printf 'héllo → 🌍 ✓'
        i=$((i + 1))
      done
      printf '\\nDONE\\n'
      """
  )

  let outcome = await runToCompletion(session)
  let text = outcome.text

  #expect(text.contains("DONE"))
  #expect(text.components(separatedBy: "héllo → 🌍 ✓").count == 201)
  #expect(!text.unicodeScalars.contains("\u{FFFD}"))
}

@Test("ANSI escape sequences are forwarded unchanged")
func forwardsAnsiSequences() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: "printf '\\033[31mred\\033[0m\\n'"
  )

  let outcome = await runToCompletion(session)

  #expect(outcome.text.contains("\u{1B}[31mred\u{1B}[0m"))
}

@Test("A graceful stop lets the process handle SIGTERM")
func stopsGracefully() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: """
      trap 'exit 42' TERM
      i=0
      while [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      """
  )
  let observer = await TerminalObserver.attach(to: session)
  try await Task.sleep(for: .milliseconds(200))

  await session.stop(gracePeriod: .seconds(5))

  #expect(await session.state() == .exited(code: 42))
  await observer.cancel()
}

@Test("A process ignoring SIGTERM is killed after the grace period")
func forcesStopAfterGracePeriod() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: """
      trap '' TERM
      i=0
      while [ $i -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
      """
  )
  let observer = await TerminalObserver.attach(to: session)
  try await Task.sleep(for: .milliseconds(200))

  let start = ContinuousClock.now
  await session.stop(gracePeriod: .milliseconds(300))
  let elapsed = ContinuousClock.now - start

  #expect(await session.state() == .terminated(signal: SIGKILL))
  #expect(elapsed < .seconds(5))
  await observer.cancel()
}

@Test("Stopping a session terminates the whole process tree")
func stopsTheWholeProcessTree() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: """
      sleep 120 &
      echo "child:$!"
      i=0
      while [ $i -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
      """
  )
  let observer = await TerminalObserver.attach(to: session)
  #expect(await observer.waitForText("child:"))

  let text = await observer.text
  let digits = text.components(separatedBy: "child:").dropFirst().first?
    .prefix { $0.isNumber }
  let childIdentifier = try #require(Int32(String(digits ?? "")))
  #expect(isProcessAlive(childIdentifier))

  await session.stop(gracePeriod: .milliseconds(300))
  try await Task.sleep(for: .milliseconds(300))

  #expect(!isProcessAlive(childIdentifier))
  await observer.cancel()
}

@Test("Parallel sessions never mix their output")
func keepsParallelSessionsIsolated() async throws {
  let first = try TerminalTestSupport.makeSession(
    script: "i=0; while [ $i -lt 200 ]; do echo AAAA; i=$((i + 1)); done"
  )
  let second = try TerminalTestSupport.makeSession(
    script: "i=0; while [ $i -lt 200 ]; do echo BBBB; i=$((i + 1)); done"
  )

  async let firstOutcome = runToCompletion(first)
  async let secondOutcome = runToCompletion(second)
  let outcomes = await (firstOutcome, secondOutcome)

  #expect(!outcomes.0.text.contains("BBBB"))
  #expect(!outcomes.1.text.contains("AAAA"))
  #expect(outcomes.0.text.components(separatedBy: "AAAA").count == 201)
  #expect(outcomes.1.text.components(separatedBy: "BBBB").count == 201)
}

@Test("A late attachment replays the bounded history and keeps receiving events")
func replaysHistoryOnAttachment() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: """
      echo EARLY
      i=0
      while [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      """
  )
  let observer = await TerminalObserver.attach(to: session)
  #expect(await observer.waitForText("EARLY"))

  let attachment = await session.attach()

  #expect(String(decoding: attachment.history.bytes, as: UTF8.self).contains("EARLY"))
  await session.stop(gracePeriod: .seconds(2))
  await observer.cancel()
}

@Test("A large burst of output stays within the history limits")
func boundsHistoryOnLargeOutput() async throws {
  let session = try TerminalTestSupport.makeSession(
    script: """
      i=0
      while [ $i -lt 4000 ]; do
        echo "0123456789012345678901234567890123456789012345678901234567890123"
        i=$((i + 1))
      done
      echo TAIL_MARKER
      """,
    scrollback: TerminalScrollbackLimits(maximumLineCount: 200, maximumByteCount: 64 * 1_024)
  )

  let outcome = await runToCompletion(session)
  let history = await session.history()

  #expect(outcome.state == .exited(code: 0))
  #expect(history.bytes.count <= 256 * 1_024)
  #expect(history.droppedByteCount > 0)
  #expect(String(decoding: history.bytes, as: UTF8.self).contains("TAIL_MARKER"))
}

@Test("Writes and resizes on a finished session are ignored")
func ignoresOperationsAfterCompletion() async throws {
  let session = try TerminalTestSupport.makeSession(script: "exit 0")
  _ = await runToCompletion(session)

  await session.write("ignored\n")
  await session.resize(to: TerminalSize(columns: 200, rows: 60))
  await session.stop(gracePeriod: .milliseconds(100))

  #expect(await session.state() == .exited(code: 0))
}
