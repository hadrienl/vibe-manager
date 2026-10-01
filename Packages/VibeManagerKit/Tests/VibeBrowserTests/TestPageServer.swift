import Darwin
import Foundation

/// A web server on 127.0.0.1, for the pages the tests drive: one route per page, bodies changeable
/// while it runs.
final class TestPageServer: @unchecked Sendable {
  private let lock = NSLock()
  private var pages: [String: String]
  private var redirects: [String: String] = [:]
  private var statuses: [String: Int] = [:]
  private var contentTypes: [String: String] = [:]
  /// Paths whose answer waits until they are released, and those already asked for.
  private let held = NSCondition()
  private var heldPaths: Set<String> = []
  private var askedPaths: Set<String> = []
  private var descriptor: Int32 = -1
  private(set) var port: UInt16 = 0

  init(pages: [String: String]) throws {
    self.pages = pages
    descriptor = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(descriptor, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    port = UInt16(bigEndian: address.sin_port)
    let listener = descriptor
    Thread.detachNewThread { [self] in
      while true {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        Thread.detachNewThread { self.serve(client) }
      }
    }
  }

  func url(_ path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
  }

  func setPage(_ path: String, _ body: String) {
    lock.withLock { pages[path] = body }
  }

  /// `path` answers `302 Found` towards `location`, until it is given a page again.
  func setRedirect(_ path: String, to location: String) {
    lock.withLock {
      redirects[path] = location
      pages[path] = nil
    }
  }

  /// `path` answers its page with `status` rather than `200`.
  func setStatus(_ path: String, _ status: Int) {
    lock.withLock { statuses[path] = status }
  }

  func setPageClearingRedirect(_ path: String, _ body: String) {
    lock.withLock {
      redirects[path] = nil
      pages[path] = body
    }
  }

  /// `path` answers with `type` rather than an HTML page.
  func setContentType(_ path: String, _ type: String) {
    lock.withLock { contentTypes[path] = type }
  }

  /// `path` keeps its answer until `release(_:)`: a download whose server takes its time.
  func hold(_ path: String) {
    held.withLock { _ = heldPaths.insert(path) }
  }

  func release(_ path: String) {
    held.withLock {
      heldPaths.remove(path)
      held.broadcast()
    }
  }

  /// Whether `path` was asked for, held or not.
  func wasAsked(_ path: String) -> Bool {
    held.withLock { askedPaths.contains(path) }
  }

  func stop() {
    close(descriptor)
  }

  private func serve(_ client: Int32) {
    defer { close(client) }
    var buffer = [UInt8](repeating: 0, count: 8_192)
    let count = read(client, &buffer, buffer.count)
    guard count > 0 else { return }
    let request = String(decoding: buffer[0..<count], as: UTF8.self)
    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    // A page that takes its time: a navigation still under way.
    if path == "/slow" { Thread.sleep(forTimeInterval: 3) }
    held.withLock {
      askedPaths.insert(path)
      while heldPaths.contains(path) { held.wait() }
    }
    let (body, redirect, code, type) = lock.withLock {
      (pages[path], redirects[path], statuses[path], contentTypes[path])
    }
    if let redirect {
      let header =
        "HTTP/1.1 302 Found\r\nLocation: \(redirect)\r\nContent-Length: 0\r\n"
        + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
      Data(header.utf8).withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
      return
    }
    let status = body == nil ? "404 Not Found" : code.map { "\($0) Status" } ?? "200 OK"
    let payload = Data((body ?? "<h1>Not found</h1>").utf8)
    let header =
      "HTTP/1.1 \(status)\r\nContent-Type: \(type ?? "text/html; charset=utf-8")\r\n"
      + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    let response = Data(header.utf8) + payload
    response.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
  }
}
