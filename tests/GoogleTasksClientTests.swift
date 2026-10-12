import Foundation

// No Keychain, browser, OAuth, or network access: the real auth implementation
// is intentionally excluded from this test executable.
@MainActor
final class GoogleOAuth {
    var calls = 0
    var token = "synthetic-unit-test-token"
    func accessToken() async throws -> String { calls += 1; return token }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class Script {
    struct Reply {
        let body: Data
        var status = 200
        var url: URL?
        var error: Error?
        init(_ json: String = "{}", status: Int = 200, url: String? = nil, error: Error? = nil) {
            body = Data(json.utf8)
            self.status = status
            self.url = url.flatMap(URL.init(string:))
            self.error = error
        }
    }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw TestFailure(description: "Unexpected extra request") }
        let reply = replies.removeFirst()
        if let error = reply.error { throw error }
        return (reply.body, HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status,
                                          httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@main
@MainActor
struct GoogleTasksClientTests {
    static var passed = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw TestFailure(description: message) }
    }
    static func run(_ name: String, _ body: () async throws -> Void) async throws {
        print("RUN: \(name)")
        try await body()
        passed += 1
        print("PASS: \(name)")
    }
    static func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
    }
    static func client(_ script: Script, oauth: GoogleOAuth? = nil) -> GoogleTasksClient {
        GoogleTasksClient(oauth: oauth ?? GoogleOAuth(), transport: { try await script.send($0) })
    }
    static func failure(_ script: Script, contains text: String) async throws {
        do {
            _ = try await client(script).fetchLists()
            throw TestFailure(description: "Expected failure containing \(text)")
        } catch let error as GoogleTasksError {
            try expect(error.localizedDescription.contains(text), "Unexpected scoped error: \(error.localizedDescription)")
            try expect(!error.localizedDescription.contains("synthetic-unit-test-token"), "Token leaked in error")
        }
    }

    static func main() async throws {
        try await run("paginates every list and task page in API order, preserving metadata") {
            let script = Script([
                .init(#"{"items":[{"id":"list-one","title":"First"}],"nextPageToken":"lists +&?="}"#),
                .init(#"{"items":[{"id":"list-two","title":"Second"}]}"#),
                .init(#"{"items":[{"id":"task-z","title":"Z first","notes":"Details","due":"2026-10-13T00:00:00.000Z","extra":true}],"nextPageToken":"tasks +&?="}"#),
                .init(#"{"items":[{"id":"task-a","title":"A second","status":"needsAction","parent":"task-z"}]}"#),
                .init(#"{"items":[]}"#),
            ])
            let oauth = GoogleOAuth()
            let lists = try await client(script, oauth: oauth).fetchLists()
            try expect(lists.map(\.id) == ["list-one", "list-two"], "List order changed")
            try expect(lists[0].tasks.map(\.id) == ["task-z", "task-a"], "Task order changed")
            try expect(lists[0].tasks[0].notes == "Details", "Notes lost")
            try expect(lists[0].tasks[0].due == "2026-10-13T00:00:00.000Z", "Due date lost")
            try expect(lists[0].tasks[1].parent == "task-z", "Parent lost")
            try expect(lists[1].tasks.isEmpty, "Empty list missing")
            try expect(oauth.calls == 1, "Unexpected OAuth call count")
            try expect(script.requests.count == 5, "Pagination request count")
            try expect(query(script.requests[0])["maxResults"] == "1000", "List page size")
            try expect(query(script.requests[1])["pageToken"] == "lists +&?=", "List page token encoding")
            try expect(query(script.requests[3])["pageToken"] == "tasks +&?=", "Task page token encoding")
            try expect(script.requests[1].url!.absoluteString.contains("lists%20%2B%26%3F%3D"), "Plus in opaque page token could be decoded as a space")
            for request in script.requests {
                try expect(request.httpMethod == "GET", "Only read methods permitted")
                try expect(request.httpBody == nil, "Unexpected request body")
                try expect(request.url?.host == "tasks.googleapis.com", "Wrong API host")
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-unit-test-token", "Missing authorization")
                try expect(request.timeoutInterval == 30, "No bounded request timeout")
            }
            let filters = query(script.requests[2])
            try expect(filters["maxResults"] == "100", "Task page size")
            try expect(filters["showCompleted"] == "false" && filters["showHidden"] == "false"
                       && filters["showDeleted"] == "false" && filters["showAssigned"] == "true", "Task visibility filters")
        }

        try await run("identifiers are encoded as a single path component") {
            let identifier = "a/b?c#d%20+é"
            let body = try JSONSerialization.data(withJSONObject: ["items": [["id": identifier, "title": "Special"]]])
            let script = Script([.init(String(data: body, encoding: .utf8)!), .init()])
            _ = try await client(script).fetchLists()
            let parts = URLComponents(url: script.requests[1].url!, resolvingAgainstBaseURL: false)!
            try expect(parts.percentEncodedPath == "/tasks/v1/lists/a%2Fb%3Fc%23d%2520%2B%C3%A9/tasks", "Identifier escaped incorrectly")
            try expect(parts.fragment == nil && query(script.requests[1]).count == 5, "Identifier escaped path boundary")
        }

        try await run("empty or absent items are valid, empty pagination token terminates") {
            for body in [#"{"items":[]}"#, #"{"kind":"tasks#taskLists","nextPageToken":""}"#] {
                let script = Script([.init(body)])
                let lists = try await client(script).fetchLists()
                try expect(lists.isEmpty && script.requests.count == 1, "Empty collection mishandled")
            }
        }

        try await run("filters completed, hidden, deleted; active status defaults correctly") {
            let script = Script([
                .init(#"{"items":[{"id":"list","title":"List"}]}"#),
                .init(#"{"items":[{"id":"active","title":"Keep"},{"id":"completed","title":"Done","status":"completed"},{"id":"hidden","title":"Hide","hidden":true},{"id":"deleted","deleted":true}]}"#),
            ])
            let tasks = try await client(script).fetchLists()[0].tasks
            try expect(tasks.map(\.id) == ["active"], "Inactive tasks leaked")
            try expect(tasks[0].status == "needsAction", "Status default missing")
        }

        try await run("rejects pagination token cycles") {
            try await failure(Script([.init(#"{"nextPageToken":"loop"}"#),
                                     .init(#"{"nextPageToken":"loop"}"#)]), contains: "unexpected response")
        }

        try await run("rejects malformed JSON and missing required active fields") {
            try await failure(Script([.init("{broken")]), contains: "unexpected response")
            try await failure(Script([.init(#"{"items":[{"id":"list"}]}"#)]), contains: "unexpected response")
            for task in [#"{"id":"active"}"#, #"{"title":"No ID"}"#, #"{"id":"","title":"Empty ID"}"#,
                         #"{"id":"active","title":"Unknown status","status":"other"}"#] {
                try await failure(Script([.init(#"{"items":[{"id":"list","title":"List"}]}"#),
                                         .init("{\"items\":[\(task)]}")]), contains: "unexpected response")
            }
        }

        try await run("duplicate IDs fail before returning an inconsistent view") {
            try await failure(Script([.init(#"{"items":[{"id":"same","title":"A"},{"id":"same","title":"B"}]}"#), .init()]), contains: "unexpected response")
            try await failure(Script([.init(#"{"items":[{"id":"list","title":"List"}]}"#),
                                     .init(#"{"items":[{"id":"same","title":"A"},{"id":"same","title":"B"}]}"#)]), contains: "unexpected response")
        }

        try await run("HTTP failures are actionable without raw server content") {
            for (status, text) in [(401, "Sign in again"), (403, "read-only access"), (404, "list changed"),
                                   (429, "Wait a minute"), (500, "temporarily unavailable"), (503, "temporarily unavailable"),
                                   (400, "HTTP 400"), (302, "unexpected response")] {
                try await failure(Script([.init("synthetic-unit-test-token", status: status)]), contains: text)
            }
            try await failure(Script([.init(#"{"error":{"details":[{"reason":"SERVICE_DISABLED"}]}}"#, status: 403)]), contains: "Enable the Google Tasks API")
            try await failure(Script([.init(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#, status: 403)]), contains: "Wait a minute")
        }

        try await run("rejects a response from a different origin") {
            for url in ["https://other.example/", "http://tasks.googleapis.com/", "https://tasks.googleapis.com:8443/"] {
                try await failure(Script([.init(url: url)]), contains: "unexpected response")
            }
        }

        try await run("network failures get a scoped reconnect message") {
            try await failure(Script([.init(error: URLError(.notConnectedToInternet))]), contains: "internet connection")
        }

        try await run("cancellation stays cancellation") {
            for error in [CancellationError() as Error, URLError(.cancelled)] {
                do {
                    _ = try await client(Script([.init(error: error)])).fetchLists()
                    throw TestFailure(description: "Cancellation was swallowed")
                } catch is CancellationError { }
            }
        }

        try await run("invalid token never reaches transport") {
            for token in ["", "bad\r\nInjected: value"] {
                let oauth = GoogleOAuth()
                oauth.token = token
                let script = Script([])
                do {
                    _ = try await client(script, oauth: oauth).fetchLists()
                    throw TestFailure(description: "Invalid token accepted")
                } catch GoogleTasksError.signInRequired { }
                try expect(script.requests.isEmpty, "Invalid token sent")
            }
        }

        print("\(passed) API client tests passed. No network, Keychain, or app cache used.")
    }
}
