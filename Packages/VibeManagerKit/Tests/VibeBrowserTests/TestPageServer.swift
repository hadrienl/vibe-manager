import Darwin
import Foundation

/// A web server on 127.0.0.1, for the pages the tests drive: one route per page, bodies changeable
/// while it runs.
final class TestPageServer: @unchecked Sendable {
  private let lock = NSLock()
  private var pages: [String: String]
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
    let body = lock.withLock { pages[path] }
    let status = body == nil ? "404 Not Found" : "200 OK"
    let payload = Data((body ?? "<h1>Not found</h1>").utf8)
    let header =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    let response = Data(header.utf8) + payload
    response.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
  }
}
