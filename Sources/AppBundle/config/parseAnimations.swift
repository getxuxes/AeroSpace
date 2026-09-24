private let animationsParserTable: [String: any ParserProtocol<Animations>] = [
    "enabled": Parser(\.enabled, parseBool),
    "duration-ms": Parser(\.durationMs, parseAnimationDuration),
]

func parseAnimations(_ rawConfig: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Animations {
    parseTable(rawConfig, Animations(), animationsParserTable, backtrace, &c)
}

private func parseAnimationDuration(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace).flatMap {
        (0 ... 2000).contains($0) ? .success($0) : .failure(.init(backtrace, "duration-ms must be in range 0..2000"))
    }
}
