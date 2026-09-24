public struct CenterFloatingCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .centerFloating,
        help: center_floating_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--width": singleValueSubArgParser(\.width, "<size>", parseFloatingSize),
            "--height": singleValueSubArgParser(\.height, "<size>", parseFloatingSize),
        ],
        posArgs: [],
    )

    public var width: FloatingSize? = nil
    public var height: FloatingSize? = nil

    public enum FloatingSize: Equatable, Sendable {
        case percent(UInt)
        case points(UInt)
    }
}

private func parseFloatingSize(_ str: String) -> ResOrStr<CenterFloatingCmdArgs.FloatingSize> {
    if str.hasSuffix("%") {
        guard let number = UInt(str.dropLast()), (1 ... 100).contains(number) else {
            return .failure("Percentage must be in 1%...100% range")
        }
        return .success(.percent(number))
    }
    guard let number = UInt(str), number > 0 else {
        return .failure("<size> must be a positive number or a percentage (e.g. 70%)")
    }
    return .success(.points(number))
}
