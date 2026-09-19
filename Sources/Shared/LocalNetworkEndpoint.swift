import Darwin
import Foundation
import InferPeerCore

enum LocalNetworkEndpoint {
  static func current(port: UInt16 = 57_421) throws -> PeerEndpoint {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else {
      throw LocalNetworkEndpointError.addressUnavailable
    }
    defer { freeifaddrs(pointer) }
    for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
      if let host = wifiIPv4(item.pointee) {
        return try PeerEndpoint(host: host, port: port)
      }
    }
    throw LocalNetworkEndpointError.addressUnavailable
  }

  private static func wifiIPv4(_ interface: ifaddrs) -> String? {
    guard String(cString: interface.ifa_name) == "en0",
      let address = interface.ifa_addr,
      address.pointee.sa_family == UInt8(AF_INET)
    else { return nil }
    var value = address.pointee
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let status = getnameinfo(
      &value,
      socklen_t(address.pointee.sa_len),
      &host,
      socklen_t(host.count),
      nil,
      0,
      NI_NUMERICHOST
    )
    guard status == 0 else { return nil }
    let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(bytes: bytes, encoding: .utf8)
  }
}

enum LocalNetworkEndpointError: LocalizedError {
  case addressUnavailable

  var errorDescription: String? {
    "No active Wi-Fi IPv4 address is available. Connect this device to Wi-Fi."
  }
}
