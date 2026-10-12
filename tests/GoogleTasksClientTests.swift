import Foundation

// No Keychain, browser, OAuth, or network access: the real auth implementation
// is intentionally excluded from this test executable.
@MainActor
final class GoogleOAuth {
    var calls = 0
    var token = "synthetic-unit-test-token"
    var hasWriteAccess = true
    var downgradeOnAccess = false
    func accessToken() async throws -> String {
        calls += 1
        if downgradeOnAccess { hasWriteAccess = false }
        return token
    }
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
    static func body(_ script: Script, index: Int = 0) throws -> [String: Any] {
        guard let data = script.requests[index].httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(description: "Expected a JSON request body")
        }
        return body
    }
    static func rejects(_ expected: GoogleTasksError, _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            throw TestFailure(description: "Expected error: \(expected.localizedDescription)")
        } catch let error as GoogleTasksError {
            try expect(error.localizedDescription == expected.localizedDescription, "Unexpected validation or transport error")
            try expect(!error.localizedDescription.contains("synthetic-unit-test-token"), "Credential exposed in error")
        }
    }
    static let writes: [(String, (GoogleTasksClient) async throws -> Void)] = [
        ("create", { _ = try await $0.createTask(listID: "list", title: "Synthetic task") }),
        ("update", { _ = try await $0.updateTask(listID: "list", taskID: "task", title: "Synthetic task", notes: nil, due: nil) }),
        ("complete", { _ = try await $0.setCompleted(listID: "list", taskID: "task", completed: true) }),
        ("reopen", { _ = try await $0.setCompleted(listID: "list", taskID: "task", completed: false) }),
        ("delete", { try await $0.deleteTask(listID: "list", taskID: "task") })
    ]

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
            try expect(filters["showCompleted"] == "true" && filters["showHidden"] == "true"
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

        try await run("includes completed and hidden tasks for reopening, excludes deleted tasks") {
            let script = Script([
                .init(#"{"items":[{"id":"list","title":"List"}]}"#),
                .init(#"{"items":[{"id":"active","title":"Keep"},{"id":"completed","title":"Done","status":"completed"},{"id":"hidden","title":"Hide","hidden":true},{"id":"deleted","deleted":true}]}"#),
            ])
            let tasks = try await client(script).fetchLists()[0].tasks
            try expect(tasks.map(\.id) == ["active", "completed", "hidden"], "Completed or hidden tasks were not retained")
            try expect(tasks[0].status == "needsAction", "Status default missing")
            try expect(tasks[1].isCompleted, "Completion status lost")
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
            for (status, text) in [(401, "Sign in again"), (403, "requested Google Tasks access"), (404, "list changed"),
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
            for token in ["", "bad\r\nInjected: value", "bad\u{0000}token", String(repeating: "x", count: 32769)] {
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

        try await run("creates exactly one task with a validated title and encoded list ID") {
            let script = Script([.init(#"{"id":"created-task","title":"Synthetic task","status":"needsAction"}"#, status: 201)])
            let result = try await client(script).createTask(listID: "a/b?c#d%20+é", title: "  Synthetic task  ")
            try expect(result.id == "created-task" && !result.isCompleted, "Create did not return the created task")
            try expect(script.requests.count == 1, "Create made extra requests")
            let request = script.requests[0]
            try expect(request.httpMethod == "POST", "Create must POST")
            try expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/tasks/v1/lists/a%2Fb%3Fc%23d%2520%2B%C3%A9/tasks", "Create list ID escaped the path")
            try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8", "Missing JSON content type")
            let json = try body(script)
            try expect(Set(json.keys) == ["title"] && json["title"] as? String == "Synthetic task", "Create sent unrelated fields or failed to trim the title")
        }

        try await run("editing patches only title notes and date without changing completion or hierarchy") {
            let script = Script([.init(#"{"id":"t/a?b%+","title":"Renamed fixture","notes":"Notes\nwith a second line","due":"2026-10-13T00:00:00.000Z","status":"completed","parent":"parent-task"}"#)])
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let chosenDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 0))!
            let updated = try await client(script).updateTask(listID: "list", taskID: "t/a?b%+", title: "Renamed fixture", notes: "Notes\nwith a second line", due: chosenDate)
            try expect(updated.isCompleted && updated.parent == "parent-task", "Update lost fields outside the edit")
            let request = script.requests[0]
            try expect(request.httpMethod == "PATCH", "Edit must use PATCH")
            try expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/tasks/v1/lists/list/tasks/t%2Fa%3Fb%25%2B", "Task ID escaped its path component")
            let json = try body(script)
            try expect(Set(json.keys) == ["title", "notes", "due"], "Edit included unrelated fields")
            try expect(json["notes"] as? String == "Notes\nwith a second line", "Notes were modified")
            try expect(json["due"] as? String == "2026-10-13T00:00:00.000Z", "Chosen local date shifted when serialized")
        }

        try await run("clearing notes and due sends explicit JSON nulls") {
            let script = Script([.init(#"{"id":"task","title":"Synthetic task"}"#)])
            _ = try await client(script).updateTask(listID: "list", taskID: "task", title: "Synthetic task", notes: nil, due: nil)
            let json = try body(script)
            try expect(json["notes"] is NSNull && json["due"] is NSNull, "Cleared fields were omitted instead of explicitly cleared")
        }

        try await run("complete and reopen patch only completion fields") {
            let script = Script([.init(#"{"id":"task","title":"Synthetic task","status":"completed"}"#),
                                 .init(#"{"id":"task","title":"Synthetic task","status":"needsAction"}"#)])
            let api = client(script)
            let completed = try await api.setCompleted(listID: "list", taskID: "task", completed: true)
            let reopened = try await api.setCompleted(listID: "list", taskID: "task", completed: false)
            try expect(completed.isCompleted && !reopened.isCompleted, "Completion responses lost state")
            let completeBody = try body(script), reopenBody = try body(script, index: 1)
            try expect(Set(completeBody.keys) == ["status"] && completeBody["status"] as? String == "completed", "Completing changed unrelated fields")
            try expect(Set(reopenBody.keys) == ["status", "completed"] && reopenBody["status"] as? String == "needsAction" && reopenBody["completed"] is NSNull, "Reopening did not clear the completion date")
            try expect(script.requests.allSatisfy { $0.httpMethod == "PATCH" }, "Completion must use PATCH")
        }

        try await run("delete accepts an empty 204 response and sends no body") {
            let script = Script([.init("", status: 204)])
            try await client(script).deleteTask(listID: "list", taskID: "task/with+symbols")
            try expect(script.requests.count == 1 && script.requests[0].httpMethod == "DELETE", "Delete request mismatch")
            try expect(script.requests[0].httpBody == nil, "Delete must not send a body")
            try expect(script.requests[0].url!.absoluteString.hasSuffix("task%2Fwith%2Bsymbols"), "Delete did not encode the task ID")
        }

        try await run("every write requires granted write permission before and after token refresh") {
            for (_, write) in writes {
                let oauth = GoogleOAuth()
                oauth.hasWriteAccess = false
                let script = Script([])
                try await rejects(.writeAccessRequired) { try await write(client(script, oauth: oauth)) }
                try expect(script.requests.isEmpty && oauth.calls == 0, "Read-only credentials started a write")
                oauth.hasWriteAccess = true
                oauth.downgradeOnAccess = true
                try await rejects(.writeAccessRequired) { try await write(client(script, oauth: oauth)) }
                try expect(script.requests.isEmpty, "A token refresh that lost write permission still sent a write")
            }
        }

        try await run("every write validates tokens, origins, redirects and cancellation") {
            for (_, write) in writes {
                let oauth = GoogleOAuth()
                oauth.token = "bad\u{0000}token"
                let noTransport = Script([])
                try await rejects(.signInRequired) { try await write(client(noTransport, oauth: oauth)) }
                try expect(noTransport.requests.isEmpty, "Invalid write token reached transport")
                for url in ["https://other.example/", "http://tasks.googleapis.com/", "https://tasks.googleapis.com:8443/", "https://user:pass@tasks.googleapis.com/"] {
                    let script = Script([.init(url: url)])
                    try await rejects(.invalidResponse) { try await write(client(script)) }
                    try expect(script.requests.count == 1, "Origin failure retried a write")
                }
                let redirect = Script([.init(status: 307)])
                try await rejects(.invalidResponse) { try await write(client(redirect)) }
                try expect(redirect.requests.count == 1, "Redirect was followed or retried")
                let cancelled = Script([.init(error: URLError(.cancelled))])
                do { try await write(client(cancelled)); throw TestFailure(description: "Write cancellation was swallowed") }
                catch is CancellationError { }
            }
        }

        try await run("uncertain writes never retry and ask the user to refresh before repeating") {
            for (_, write) in writes {
                let script = Script([.init(error: URLError(.networkConnectionLost))])
                try await rejects(.writeOutcomeUnknown) { try await write(client(script)) }
                try expect(script.requests.count == 1, "An uncertain write was automatically retried")
                let failed = Script([.init(status: 503)])
                try await rejects(.unavailable) { try await write(client(failed)) }
                try expect(failed.requests.count == 1, "A server failure retried a write")
            }
            for reply in [#"{"id":"wrong-task","title":"Synthetic task"}"#, #"{"id":"task"}"#, "{broken"] {
                let script = Script([.init(reply)])
                try await rejects(.writeOutcomeUnknown) {
                    _ = try await client(script).updateTask(listID: "list", taskID: "task", title: "Synthetic task", notes: nil, due: nil)
                }
                try expect(script.requests.count == 1, "An unexpected write response retried the mutation")
            }
        }

        try await run("validates title notes identifiers and due before any mutation request") {
            for title in ["", " \n ", "two\nlines", String(repeating: "a", count: 1025)] {
                let script = Script([])
                try await rejects(.invalidTitle) { _ = try await client(script).createTask(listID: "list", title: title) }
                try expect(script.requests.isEmpty, "Invalid title reached Google")
            }
            for notes in [String(repeating: "x", count: 8193), "bad\u{0000}note"] {
                let script = Script([])
                try await rejects(.invalidNotes) { _ = try await client(script).updateTask(listID: "list", taskID: "task", title: "Synthetic", notes: notes, due: nil) }
                try expect(script.requests.isEmpty, "Invalid notes reached Google")
            }
            for identifier in ["", " ", ".", "..", "bad\nID", String(repeating: "x", count: 1025)] {
                let script = Script([])
                try await rejects(.invalidIdentifier) { _ = try await client(script).createTask(listID: identifier, title: "Synthetic") }
                try await rejects(.invalidIdentifier) { _ = try await client(script).updateTask(listID: "list", taskID: identifier, title: "Synthetic", notes: nil, due: nil) }
                try await rejects(.invalidIdentifier) { _ = try await client(script).setCompleted(listID: "list", taskID: identifier, completed: false) }
                try await rejects(.invalidIdentifier) { try await client(script).deleteTask(listID: "list", taskID: identifier) }
                try expect(script.requests.isEmpty, "Invalid identifiers reached Google")
            }
            let invalidDate = Script([])
            try await rejects(.invalidDueDate) {
                _ = try await client(invalidDate).updateTask(listID: "list", taskID: "task", title: "Synthetic", notes: nil, due: Date(timeIntervalSince1970: .infinity))
            }
            try expect(invalidDate.requests.isEmpty, "Invalid due date reached Google")
        }

        try await run("date-only encoding preserves the chosen calendar day across extreme timezones") {
            let instant = ISO8601DateFormatter().date(from: "2026-01-01T01:30:00Z")!
            let west = try GoogleTasksClient.dueDateString(instant, timeZone: TimeZone(secondsFromGMT: -8 * 3600)!)
            let east = try GoogleTasksClient.dueDateString(instant, timeZone: TimeZone(secondsFromGMT: 14 * 3600)!)
            try expect(west == "2025-12-31T00:00:00.000Z", "Western local date shifted to the UTC date")
            try expect(east == "2026-01-01T00:00:00.000Z", "Eastern local date shifted")
        }

        print("\(passed) API client tests passed. No network, Keychain, or app cache used.")
    }
}
