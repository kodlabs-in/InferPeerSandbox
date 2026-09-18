import Darwin
import Foundation

enum SandboxSystemMetrics {
    static var machineIdentifier: String {
        #if os(macOS)
            return macModelIdentifier()
        #else
            return unameMachineIdentifier()
        #endif
    }

    private static func unameMachineIdentifier() -> String {
        var information = utsname()
        guard uname(&information) == 0 else { return "unknown" }
        var machine = information.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self, capacity: capacity
            ) {
                String(cString: $0)
            }
        }
    }

    #if os(macOS)
        private static func macModelIdentifier() -> String {
            var size = 0
            guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
                return unameMachineIdentifier()
            }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
                return unameMachineIdentifier()
            }
            let bytes = value.dropLast().map { UInt8(bitPattern: $0) }
            return String(bytes: bytes, encoding: .utf8) ?? unameMachineIdentifier()
        }
    #endif

    static var operatingSystem: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var peakResidentMemoryBytes: UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss >= 0 else { return nil }
        return UInt64(usage.ru_maxrss)
    }
}
