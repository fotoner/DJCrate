#if DEBUG
enum KeyRoutingSelfTestMode: String {
    case inactive, active

    static func requested(arguments: [String], environment: [String: String]) -> Self? {
        guard arguments.contains("--key-routing-selftest"),
              let home = environment["DJC_HOME"], !home.isEmpty,
              let rekordbox = environment["DJC_REKORDBOX_DIR"], !rekordbox.isEmpty else { return nil }
        let modes = arguments.filter { $0.hasPrefix("--key-routing-mode") }
        guard modes.count <= 1 else { return nil }
        guard let argument = modes.first else { return .inactive }
        guard argument.hasPrefix("--key-routing-mode=") else { return nil }
        return Self(rawValue: String(argument.dropFirst("--key-routing-mode=".count)))
    }
}
#endif
