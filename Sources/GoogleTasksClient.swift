import Foundation

/// Google Tasks API access. Mutations require a separately granted write scope;
/// requests are never retried automatically, including after uncertain writes.
/// API references:
/// https://developers.google.com/workspace/tasks/reference/rest/v1/tasklists/list
/// https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list
/// https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/insert
/// https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/patch
/// https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/delete
@MainActor
final class GoogleTasksClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private let oauth: GoogleOAuth
    private let transport: Transport
    private static let componentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    init(oauth: GoogleOAuth, transport: Transport? = nil) {
        self.oauth = oauth
        if let transport {
            self.transport = transport
        } else {
            let connection = GoogleTasksConnection()
            self.transport = { request in try await connection.data(for: request) }
        }
    }

    func fetchLists() async throws -> [TaskList] {
        let token = try await accessToken()

        let listRecords: [ListRecord] = try await pages(
            path: "/tasks/v1/users/@me/lists",
            query: [URLQueryItem(name: "maxResults", value: "1000")], token: token)
        var lists: [TaskList] = []
        var listIDs = Set<String>()
        for list in listRecords {
            try Task.checkCancellation()
            guard Self.validIdentifier(list.id, maximum: 512), listIDs.insert(list.id).inserted else {
                throw GoogleTasksError.invalidResponse
            }
            // Treat the entire identifier as one path component, even if it
            // contains a slash, percent sign, or a query delimiter.
            let identifier = try Self.encodedIdentifier(list.id, maximum: 512)
            let records: [TaskRecord] = try await pages(
                path: "/tasks/v1/lists/\(identifier)/tasks",
                query: [URLQueryItem(name: "maxResults", value: "100"),
                        URLQueryItem(name: "showCompleted", value: "true"),
                        URLQueryItem(name: "showHidden", value: "true"),
                        URLQueryItem(name: "showDeleted", value: "false"),
                        URLQueryItem(name: "showAssigned", value: "true")], token: token)
            var tasks: [GoogleTask] = []
            var taskIDs = Set<String>()
            for task in records where !task.deleted {
                guard taskIDs.insert(task.id).inserted else {
                    throw GoogleTasksError.invalidResponse
                }
                tasks.append(try task.model())
            }
            lists.append(TaskList(id: list.id, title: list.title, tasks: tasks))
        }
        return lists
    }

    func createTask(listID: String, title: String) async throws -> GoogleTask {
        let path = try Self.tasksPath(listID: listID)
        let body: [String: Any] = ["title": try Self.validatedTitle(title)]
        let token = try await accessToken(requireWrite: true)
        let data = try await send(method: "POST", path: path, token: token, body: body, accepted: [200, 201])
        return try decodeWrittenTask(data)
    }

    func updateTask(listID: String, taskID: String, title: String, notes: String?, due: Date?) async throws -> GoogleTask {
        let path = try Self.tasksPath(listID: listID, taskID: taskID)
        let title = try Self.validatedTitle(title)
        if let notes {
            guard notes.unicodeScalars.count <= 8192,
                  !notes.unicodeScalars.contains(where: { Self.isControl($0) && ![9, 10, 13].contains($0.value) }) else {
                throw GoogleTasksError.invalidNotes
            }
        }
        // A nil value means clear this editable field. Omitted unrelated fields
        // retain Google's values, including status, parent, and position.
        let body: [String: Any] = ["title": title, "notes": notes as Any? ?? NSNull(),
                                   "due": try due.map { try Self.dueDateString($0) } as Any? ?? NSNull()]
        let token = try await accessToken(requireWrite: true)
        let data = try await send(method: "PATCH", path: path, token: token, body: body)
        return try decodeWrittenTask(data, expectedID: taskID)
    }

    func setCompleted(listID: String, taskID: String, completed: Bool) async throws -> GoogleTask {
        let path = try Self.tasksPath(listID: listID, taskID: taskID)
        let status = completed ? "completed" : "needsAction"
        var body: [String: Any] = ["status": status]
        if !completed { body["completed"] = NSNull() }
        let token = try await accessToken(requireWrite: true)
        let data = try await send(method: "PATCH", path: path, token: token, body: body)
        let task = try decodeWrittenTask(data, expectedID: taskID)
        guard task.status == status else { throw GoogleTasksError.writeOutcomeUnknown }
        return task
    }

    func deleteTask(listID: String, taskID: String) async throws {
        let path = try Self.tasksPath(listID: listID, taskID: taskID)
        let token = try await accessToken(requireWrite: true)
        _ = try await send(method: "DELETE", path: path, token: token, accepted: [200, 204])
    }

    private func accessToken(requireWrite: Bool = false) async throws -> String {
        try Task.checkCancellation()
        if requireWrite && !oauth.hasWriteAccess { throw GoogleTasksError.writeAccessRequired }
        let token = try await oauth.accessToken()
        // A refresh may report a reduced scope, so check again after the await.
        if requireWrite && !oauth.hasWriteAccess { throw GoogleTasksError.writeAccessRequired }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/=")
        guard !token.isEmpty, token.utf8.count <= 32768,
              token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw GoogleTasksError.signInRequired
        }
        return token
    }

    nonisolated private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value != "." && value != ".."
            && !value.unicodeScalars.contains(where: { isControl($0) || CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    private static func encodedIdentifier(_ value: String, maximum: Int) throws -> String {
        guard validIdentifier(value, maximum: maximum),
              let encoded = value.addingPercentEncoding(withAllowedCharacters: componentCharacters) else {
            throw GoogleTasksError.invalidIdentifier
        }
        return encoded
    }

    private static func tasksPath(listID: String, taskID: String? = nil) throws -> String {
        let list = try encodedIdentifier(listID, maximum: 512)
        let base = "/tasks/v1/lists/\(list)/tasks"
        return try taskID.map { base + "/" + (try encodedIdentifier($0, maximum: 1024)) } ?? base
    }

    nonisolated private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 32 || (127...159).contains(scalar.value)
    }

    private static func validatedTitle(_ value: String) throws -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= 1024,
              !title.unicodeScalars.contains(where: { isControl($0) || CharacterSet.newlines.contains($0) }) else {
            throw GoogleTasksError.invalidTitle
        }
        return title
    }

    // Google stores the calendar date and discards the time. Extract the chosen
    // local Gregorian day before emitting UTC midnight, avoiding a timezone shift.
    static func dueDateString(_ date: Date, timeZone: TimeZone = .current) throws -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw GoogleTasksError.invalidDueDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, let year = parts.year, (1...9999).contains(year),
              let month = parts.month, let day = parts.day else { throw GoogleTasksError.invalidDueDate }
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", locale: Locale(identifier: "en_US_POSIX"), year, month, day)
    }

    private func decodeWrittenTask(_ data: Data, expectedID: String? = nil) throws -> GoogleTask {
        do {
            let task = try JSONDecoder().decode(TaskRecord.self, from: data).model()
            guard expectedID == nil || task.id == expectedID else { throw GoogleTasksError.invalidResponse }
            return task
        } catch { throw GoogleTasksError.writeOutcomeUnknown }
    }

    private func send(method: String, path: String, query: [URLQueryItem] = [], token: String,
                      body: [String: Any]? = nil, accepted: Set<Int> = [200]) async throws -> Data {
        try Task.checkCancellation()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tasks.googleapis.com"
        components.percentEncodedPath = path
        if !query.isEmpty {
            // Encode '+' too, preventing opaque page tokens from becoming spaces.
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.componentCharacters))
            }
        }
        guard let url = components.url else { throw GoogleTasksError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw method == "GET" ? GoogleTasksError.connection : GoogleTasksError.writeOutcomeUnknown }
        guard let http = response as? HTTPURLResponse,
              let responseURL = http.url, responseURL.scheme == "https",
              responseURL.host == "tasks.googleapis.com", responseURL.user == nil, responseURL.password == nil,
              responseURL.fragment == nil, responseURL.port == nil || responseURL.port == 443,
              data.count <= 16 * 1024 * 1024 else { throw GoogleTasksError.invalidResponse }
        guard accepted.contains(http.statusCode) else { throw GoogleTasksError.from(status: http.statusCode, data: data) }
        return data
    }

    private func pages<Item: Decodable>(path: String, query: [URLQueryItem], token: String) async throws -> [Item] {
        var items: [Item] = []
        var pageToken: String?
        var seenTokens = Set<String>()
        repeat {
            try Task.checkCancellation()
            let pageQuery = query + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let data = try await send(method: "GET", path: path, query: pageQuery, token: token)
            let page: Page<Item>
            do {
                page = try JSONDecoder().decode(Page<Item>.self, from: data)
            } catch {
                throw GoogleTasksError.invalidResponse
            }
            items.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let pageToken, !seenTokens.insert(pageToken).inserted {
                throw GoogleTasksError.invalidResponse
            }
        } while pageToken != nil
        return items
    }

    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]?
        let nextPageToken: String?
    }

    private struct ListRecord: Decodable {
        let id: String
        let title: String
    }

    private struct TaskRecord: Decodable {
        let id: String
        let title: String?
        let notes: String?
        let due: String?
        let parent: String?
        let status: String
        let deleted: Bool
        let hidden: Bool

        func model() throws -> GoogleTask {
            guard GoogleTasksClient.validIdentifier(id, maximum: 1024), let title,
                  title.utf8.count <= 80000, (notes?.utf8.count ?? 0) <= 200000,
                  ["needsAction", "completed"].contains(status), !deleted else {
                throw GoogleTasksError.invalidResponse
            }
            return GoogleTask(id: id, title: title, notes: notes, due: due, status: status, parent: parent)
        }

        enum CodingKeys: String, CodingKey { case id, title, notes, due, parent, status, deleted, hidden }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            title = try values.decodeIfPresent(String.self, forKey: .title)
            notes = try values.decodeIfPresent(String.self, forKey: .notes)
            due = try values.decodeIfPresent(String.self, forKey: .due)
            parent = try values.decodeIfPresent(String.self, forKey: .parent)
            status = try values.decodeIfPresent(String.self, forKey: .status) ?? "needsAction"
            deleted = try values.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
            hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        }
    }
}

enum GoogleTasksError: LocalizedError {
    case signInRequired, apiDisabled, forbidden, rateLimited, unavailable
    case connection, listChanged, invalidResponse, requestFailed(Int)
    case writeAccessRequired, invalidTitle, invalidNotes, invalidIdentifier, invalidDueDate, writeOutcomeUnknown

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Your Google session expired. Sign in again in Settings to reconnect your tasks."
        case .apiDisabled:
            return "Enable the Google Tasks API in the Google Cloud project for your OAuth client, then refresh."
        case .forbidden:
            return "Google denied access to your tasks. Sign in again and allow the requested Google Tasks access."
        case .rateLimited:
            return "Google Tasks is receiving too many requests. Wait a minute, then refresh."
        case .unavailable:
            return "Google Tasks is temporarily unavailable. Try refreshing in a moment."
        case .connection:
            return "Couldn’t connect to Google Tasks. Check your internet connection, then refresh."
        case .listChanged:
            return "A task or list changed. Refresh to load the latest tasks before trying again."
        case .invalidResponse:
            return "Google Tasks returned an unexpected response. Refresh to check the latest state."
        case .requestFailed(let status):
            return "Google Tasks could not complete the request (HTTP \(status)). Try refreshing."
        case .writeAccessRequired:
            return "Allow editing in Settings and sign in again to create or change Google Tasks."
        case .invalidTitle:
            return "Enter a task title from 1 to 1024 characters, without line breaks."
        case .invalidNotes:
            return "Keep task notes within 8192 characters and remove unsupported control characters."
        case .invalidIdentifier:
            return "This task or list has an invalid identifier. Refresh your tasks and try again."
        case .invalidDueDate:
            return "Choose a valid due date."
        case .writeOutcomeUnknown:
            return "Couldn’t confirm whether Google saved this change. Refresh your tasks before trying again."
        }
    }

    fileprivate static func from(status: Int, data: Data) -> GoogleTasksError {
        switch status {
        case 401: return .signInRequired
        case 403:
            // Inspect only documented error codes. Never surface raw response
            // bodies, request URLs, or authorization values in UI or logs.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any] {
                let details = (error["errors"] as? [[String: Any]] ?? [])
                    + (error["details"] as? [[String: Any]] ?? [])
                let reasons = details.compactMap { $0["reason"] as? String }
                if reasons.contains("accessNotConfigured") || reasons.contains("SERVICE_DISABLED") {
                    return .apiDisabled
                }
                if reasons.contains("rateLimitExceeded") || reasons.contains("userRateLimitExceeded") || reasons.contains("quotaExceeded") {
                    return .rateLimited
                }
            }
            return .forbidden
        case 404: return .listChanged
        case 429: return .rateLimited
        case 500...599: return .unavailable
        case 300...399: return .invalidResponse
        default: return .requestFailed(status)
        }
    }
}

/// Refuse every redirect so a bearer token is never forwarded to another host.
private final class GoogleTasksRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class GoogleTasksConnection: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: GoogleTasksRedirectBlocker(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
