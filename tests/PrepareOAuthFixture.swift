import Foundation

// Build a temporary copy of the current production source, replacing only its
// side-effect boundaries. Never use a checked-in copy that could become stale.
enum FixturePreparationError: Error, CustomStringConvertible {
    case invalidArguments, changedBoundary(String), forbiddenOperation(String)
    var description: String {
        switch self {
        case .invalidArguments: return "Expected source and temporary destination paths."
        case .changedBoundary(let name): return "OAuth test boundary changed: \(name). Review the fixture generator before running tests."
        case .forbiddenOperation(let name): return "An unmocked operation remains in the test copy: \(name)."
        }
    }
}

func removeDeclaration(_ source: inout String, start: String, next: String) throws {
    guard source.components(separatedBy: start).count == 2,
          source.components(separatedBy: next).count == 2,
          let first = source.range(of: start),
          let following = source.range(of: next, range: first.upperBound..<source.endIndex) else {
        throw FixturePreparationError.changedBoundary(start)
    }
    source.replaceSubrange(first.lowerBound..<following.lowerBound,
                           with: "// Replaced by OAuthTestDoubles.swift in this temporary test copy.\n")
}

do {
    guard CommandLine.arguments.count == 3 else { throw FixturePreparationError.invalidArguments }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    var source = try String(contentsOf: input, encoding: .utf8)
    try removeDeclaration(&source, start: "private enum GoogleOAuthKeychain {\n",
                          next: "struct GoogleOAuthTokenResponse: Decodable {")
    try removeDeclaration(&source, start: "private enum GoogleOAuthHTTP {\n",
                          next: "enum GoogleOAuthCallbackResult {")
    let browser = "NSWorkspace.shared.open(authorizationURL)"
    guard source.components(separatedBy: browser).count == 2 else {
        throw FixturePreparationError.changedBoundary("system-browser opening")
    }
    source = source.replacingOccurrences(of: browser, with: "GoogleOAuthTestBrowser.open(authorizationURL)")
    for forbidden in ["SecItemCopyMatching(", "SecItemAdd(", "SecItemUpdate(", "SecItemDelete(",
                      "NSWorkspace.shared.open(", "URLSession(configuration:", "URLSession.shared"] {
        guard !source.contains(forbidden) else { throw FixturePreparationError.forbiddenOperation(forbidden) }
    }
    try ("// Generated from current Sources/GoogleOAuth.swift for isolated tests only.\n" + source)
        .write(to: output, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("Could not prepare isolated OAuth tests: \(error)\n".utf8))
    exit(1)
}
