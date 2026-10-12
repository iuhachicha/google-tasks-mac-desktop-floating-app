import Foundation

/// Read-only Google Tasks API access. All requests use the readonly OAuth scope
/// configured by GoogleOAuth; this client contains no mutation endpoints.
/// API references:
/// https://developers.google.com/workspace/tasks/reference/rest/v1/tasklists/list
/// https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list
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
        let token = try await oauth.accessToken()
        guard !token.isEmpty, token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw GoogleTasksError.signInRequired
        }

        let listRecords: [ListRecord] = try await pages(
            path: "/tasks/v1/users/@me/lists",
            query: [URLQueryItem(name: "maxResults", value: "1000")], token: token)
        var lists: [TaskList] = []
        var listIDs = Set<String>()
        for list in listRecords {
            try Task.checkCancellation()
            guard !list.id.isEmpty, listIDs.insert(list.id).inserted else {
                throw GoogleTasksError.invalidResponse
            }
            // Treat the entire identifier as one path component, even if it
            // contains a slash, percent sign, or a query delimiter.
            guard let identifier = list.id.addingPercentEncoding(
                withAllowedCharacters: Self.componentCharacters) else {
                throw GoogleTasksError.invalidResponse
            }
            let records: [TaskRecord] = try await pages(
                path: "/tasks/v1/lists/\(identifier)/tasks",
                query: [URLQueryItem(name: "maxResults", value: "100"),
                        URLQueryItem(name: "showCompleted", value: "false"),
                        URLQueryItem(name: "showHidden", value: "false"),
                        URLQueryItem(name: "showDeleted", value: "false"),
                        URLQueryItem(name: "showAssigned", value: "true")], token: token)
            var tasks: [GoogleTask] = []
            var taskIDs = Set<String>()
            for task in records where !task.deleted && !task.hidden && task.status != "completed" {
                guard !task.id.isEmpty, let title = task.title, task.status == "needsAction",
                      taskIDs.insert(task.id).inserted else {
                    throw GoogleTasksError.invalidResponse
                }
                tasks.append(GoogleTask(id: task.id, title: title, notes: task.notes,
                                        due: task.due, status: task.status, parent: task.parent))
            }
            lists.append(TaskList(id: list.id, title: list.title, tasks: tasks))
        }
        return lists
    }

    private func pages<Item: Decodable>(path: String, query: [URLQueryItem], token: String) async throws -> [Item] {
        var items: [Item] = []
        var pageToken: String?
        var seenTokens = Set<String>()
        repeat {
            try Task.checkCancellation()
            var components = URLComponents()
            components.scheme = "https"
            components.host = "tasks.googleapis.com"
            components.percentEncodedPath = path
            let pageQuery = query + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            // URLComponents normally leaves '+' literal. Encode it too so
            // Google cannot interpret it as a space inside an opaque token.
            components.percentEncodedQueryItems = pageQuery.map {
                URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.componentCharacters))
            }
            guard let url = components.url else { throw GoogleTasksError.invalidResponse }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await transport(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw GoogleTasksError.connection
            }
            guard let http = response as? HTTPURLResponse,
                  let responseURL = http.url, responseURL.scheme == "https",
                  responseURL.host == "tasks.googleapis.com",
                  responseURL.port == nil || responseURL.port == 443 else {
                throw GoogleTasksError.invalidResponse
            }
            guard http.statusCode == 200 else {
                throw GoogleTasksError.from(status: http.statusCode, data: data)
            }
            guard data.count <= 16 * 1024 * 1024 else { throw GoogleTasksError.invalidResponse }
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

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Your Google session expired. Sign in again in Settings to reconnect your tasks."
        case .apiDisabled:
            return "Enable the Google Tasks API in the Google Cloud project for your OAuth client, then refresh."
        case .forbidden:
            return "Google denied access to your tasks. Sign in again and allow read-only access to Google Tasks."
        case .rateLimited:
            return "Google Tasks is receiving too many requests. Wait a minute, then refresh."
        case .unavailable:
            return "Google Tasks is temporarily unavailable. Try refreshing in a moment."
        case .connection:
            return "Couldn’t connect to Google Tasks. Check your internet connection, then refresh."
        case .listChanged:
            return "A task list changed while syncing. Refresh to load your latest lists."
        case .invalidResponse:
            return "Google Tasks returned an unexpected response. Your saved view is unchanged; try refreshing."
        case .requestFailed(let status):
            return "Google Tasks could not complete the request (HTTP \(status)). Try refreshing."
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
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: GoogleTasksRedirectBlocker(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
