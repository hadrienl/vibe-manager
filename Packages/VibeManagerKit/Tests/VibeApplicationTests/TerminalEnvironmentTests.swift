import Testing
import VibeApplication

@Test("The environment is built from an allowlist")
func environmentUsesAnAllowlist() {
  let environment = TerminalEnvironment.make(
    inheriting: [
      "HOME": "/Users/test",
      "PATH": "/usr/bin",
      "AWS_SECRET_ACCESS_KEY": "secret",
      "ANTHROPIC_API_KEY": "secret",
      "XPC_SERVICE_NAME": "com.apple.xpc",
    ]
  )

  #expect(environment["HOME"] == "/Users/test")
  #expect(environment["PATH"] == "/usr/bin")
  #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
  #expect(environment["ANTHROPIC_API_KEY"] == nil)
  #expect(environment["XPC_SERVICE_NAME"] == nil)
}

@Test("The terminal announces colour support and a locale")
func environmentDeclaresTerminalCapabilities() {
  let environment = TerminalEnvironment.make(inheriting: [:])

  #expect(environment["TERM"] == "xterm-256color")
  #expect(environment["COLORTERM"] == "truecolor")
  #expect(environment["TERM_PROGRAM"] == "VibeManager")
  #expect(environment["LANG"] == "en_US.UTF-8")
  #expect(environment["PATH"] == TerminalEnvironment.fallbackPath)
}

@Test("An inherited locale is preserved")
func environmentPreservesInheritedLocale() {
  let environment = TerminalEnvironment.make(inheriting: ["LANG": "fr_FR.UTF-8"])

  #expect(environment["LANG"] == "fr_FR.UTF-8")
}

@Test("Additions override the inherited environment")
func environmentAdditionsWin() {
  let environment = TerminalEnvironment.make(
    inheriting: ["PATH": "/usr/bin"],
    adding: ["PATH": "/opt/homebrew/bin:/usr/bin", "VIBE_SESSION": "1"]
  )

  #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
  #expect(environment["VIBE_SESSION"] == "1")
}
