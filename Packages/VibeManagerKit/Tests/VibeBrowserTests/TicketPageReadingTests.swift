import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeBrowser

/// A ticket's page, read in a session's web view (#89): real pages, served on this Mac.
@Suite("Reading a ticket's title in the web view", .serialized)
@MainActor
struct TicketPageReadingTests {
  private static func page(title: String, ogTitle: String? = nil, script: String = "") -> String {
    let meta = ogTitle.map { #"<meta property="og:title" content="\#($0)">"# } ?? ""
    return "<html><head>\(meta)<title>\(title)</title></head><body>\(script)</body></html>"
  }

  private func resolvers(port: UInt16) -> (TicketResolverSet, TicketResolver) {
    let resolver = TicketResolver(
      name: "Tracker", pattern: #"http://127\.0\.0\.1:\#(port)/issues/(?<number>[0-9]+)"#,
      shortID: "#{number}", titleCleanup: [" - Tracker$"])
    return (TicketResolverSet([resolver]), resolver)
  }

  @Test("The page's title is read, cleaned, and its tab let go once read")
  func title() async throws {
    let server = try TestPageServer(pages: [
      "/issues/1": Self.page(title: "ignored", ogTitle: "Fix the export - Tracker")
    ])
    defer { server.stop() }
    let (set, _) = resolvers(port: server.port)
    let ticket = try #require(set.recognize(server.url("/issues/1").absoluteString))
    let workspace = BrowserWorkspace()
    let session = SessionID()
    var progress: [TicketPageProgress] = []

    let outcome = await workspace.readTicket(ticket, resolvers: set, in: session) {
      progress.append($0)
    }

    #expect(outcome == .title("Fix the export", raw: "Fix the export - Tracker"))
    #expect(progress == [.loading])
    let tab = try #require(workspace.browser(for: session).tabs.first)
    #expect(tab.url == server.url("/issues/1"))
    #expect(!tab.isLoaded)
    #expect(!workspace.isVisible(session))
  }

  @Test("A missing ticket is said, and gives no title")
  func notFound() async throws {
    let server = try TestPageServer(pages: [:])
    defer { server.stop() }
    let (set, _) = resolvers(port: server.port)
    let ticket = try #require(set.recognize(server.url("/issues/2").absoluteString))
    let outcome = await BrowserWorkspace().testTicketPage(ticket, resolvers: set)
    #expect(outcome == .notFound(status: 404))
  }

  @Test("An error page is not a title")
  func serverError() async throws {
    let server = try TestPageServer(pages: ["/issues/5": Self.page(title: "Oops")])
    server.setStatus("/issues/5", 500)
    defer { server.stop() }
    let (set, _) = resolvers(port: server.port)
    let ticket = try #require(set.recognize(server.url("/issues/5").absoluteString))
    let outcome = await BrowserWorkspace().testTicketPage(ticket, resolvers: set)
    #expect(outcome == .failed(.http(status: 500)))
  }

  @Test("A redirection to another page — a sign-in, another ticket — never gives its title")
  func redirected() async throws {
    let server = try TestPageServer(pages: [
      "/login": Self.page(title: "Sign in - Tracker"),
      "/issues/4": Self.page(title: "Another ticket - Tracker"),
    ])
    server.setRedirect("/issues/3", to: "/issues/4")
    defer { server.stop() }
    let (set, _) = resolvers(port: server.port)
    let ticket = try #require(set.recognize(server.url("/issues/3").absoluteString))
    let outcome = await BrowserWorkspace().testTicketPage(ticket, resolvers: set)
    #expect(outcome == .signInRequired(host: "127.0.0.1"))
  }

  @Test("A sign-in page is waited out: the title comes once the ticket's page is back")
  func signInThenTitle() async throws {
    let server = try TestPageServer(pages: [
      "/login": Self.page(title: "Sign in - Tracker")
    ])
    server.setRedirect("/issues/6", to: "/login")
    defer { server.stop() }
    let (set, _) = resolvers(port: server.port)
    let url = server.url("/issues/6")
    let ticket = try #require(set.recognize(url.absoluteString))
    let workspace = BrowserWorkspace()
    let session = SessionID()
    var waited = false

    let reading = Task {
      await workspace.readTicket(ticket, resolvers: set, in: session) { progress in
        if case .signInRequired = progress { waited = true }
      }
    }
    for _ in 0..<80 where !waited { try await Task.sleep(for: .milliseconds(100)) }
    #expect(waited)

    // The user signs in; the site sends them back to the ticket.
    server.setPageClearingRedirect("/issues/6", Self.page(title: "Signed in at last - Tracker"))
    workspace.browser(for: session).tabs.first?.load(url)

    #expect(await reading.value == .title("Signed in at last", raw: "Signed in at last - Tracker"))
  }

  @Test("A title a page writes after loading is the one read, not its placeholder")
  func singlePageApplication() async throws {
    let script =
      "<script>setTimeout(() => { document.title = 'Real title - Tracker' }, 400)</script>"
    let server = try TestPageServer(pages: [
      "/issues/7": Self.page(title: "Tracker", script: script)
    ])
    defer { server.stop() }
    let (set, _) = resolvers(port: server.port)
    let ticket = try #require(set.recognize(server.url("/issues/7").absoluteString))
    let outcome = await BrowserWorkspace().testTicketPage(ticket, resolvers: set)
    #expect(outcome == .title("Real title", raw: "Real title - Tracker"))
  }

  @Test("The tab that already shows the ticket is the one read, and a closed tab ends the reading")
  func existingTab() async throws {
    let server = try TestPageServer(pages: [
      "/login": Self.page(title: "Sign in - Tracker")
    ])
    server.setRedirect("/issues/8", to: "/login")
    defer { server.stop() }
    let (set, _) = resolvers(port: server.port)
    let url = server.url("/issues/8")
    let ticket = try #require(set.recognize(url.absoluteString))
    let workspace = BrowserWorkspace()
    let session = SessionID()
    // Opened by an agent, in the background: not loaded yet, so still on its address.
    let existing = workspace.open(url, in: session, openedBy: .agent, activate: false)
    var waited = false

    let reading = Task {
      await workspace.readTicket(ticket, resolvers: set, in: session) { progress in
        if case .signInRequired = progress { waited = true }
      }
    }
    for _ in 0..<80 where !waited { try await Task.sleep(for: .milliseconds(100)) }
    #expect(workspace.browser(for: session).tabs.count == 1)
    workspace.close(existing.id, in: session)

    #expect(await reading.value == .abandoned)
  }

  @Test("A page that moves to another ticket without a navigation does not give its title")
  func pushState() async throws {
    let script = """
      <script>setTimeout(() => {
        history.pushState({}, '', '/issues/10'); document.title = 'Another ticket - Tracker'
      }, 50)</script>
      """
    let server = try TestPageServer(pages: [
      "/issues/9": Self.page(title: "Tracker", script: script)
    ])
    defer { server.stop() }
    let (set, _) = resolvers(port: server.port)
    let ticket = try #require(set.recognize(server.url("/issues/9").absoluteString))
    let outcome = await BrowserWorkspace().testTicketPage(ticket, resolvers: set)
    #expect(outcome == .signInRequired(host: "127.0.0.1"))
  }

  @Test("A ticket not found yet is waited out: signed in, its title comes")
  func notFoundThenSignedIn() async throws {
    let server = try TestPageServer(pages: [:])
    defer { server.stop() }
    let (set, _) = resolvers(port: server.port)
    let url = server.url("/issues/11")
    let ticket = try #require(set.recognize(url.absoluteString))
    let workspace = BrowserWorkspace()
    let session = SessionID()
    var notFound = false

    let reading = Task {
      await workspace.readTicket(ticket, resolvers: set, in: session) { progress in
        if case .notFound = progress { notFound = true }
      }
    }
    for _ in 0..<80 where !notFound { try await Task.sleep(for: .milliseconds(100)) }
    #expect(notFound)

    server.setPage("/issues/11", Self.page(title: "Private at last - Tracker"))
    workspace.browser(for: session).tabs.first?.reload()

    #expect(await reading.value == .title("Private at last", raw: "Private at last - Tracker"))
  }
}
