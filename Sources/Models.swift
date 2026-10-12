import Foundation

struct GoogleTask: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let notes: String?
    let due: String?
    let status: String
    let parent: String?
    var isCompleted: Bool { status == "completed" }
}

struct TaskList: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    var tasks: [GoogleTask]
}

struct TaskSnapshot: Codable {
    let version: Int
    var source: String
    var capturedAt: String
    let sourceURL: String
    let lists: [TaskList]
    var receivedAt: String?
}

enum AppPaths {
    static var support: URL {
        if let override = ProcessInfo.processInfo.environment["FLOATTASKS_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.iuhachicha.floattasks", isDirectory: true)
    }
    static var snapshot: URL { support.appendingPathComponent("tasks.json") }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func validate(_ snapshot: TaskSnapshot) throws {
        guard snapshot.version == 1,
              snapshot.source == "google_api",
              let url = URL(string: snapshot.sourceURL), url.scheme == "https",
              url.host == "tasks.google.com", (url.port == nil || url.port == 443),
              url.user == nil, url.password == nil,
              AppPaths.date(snapshot.capturedAt) != nil,
              snapshot.lists.count <= 2000 else {
            throw SnapshotError.invalid
        }
        var listIDs = Set<String>()
        for list in snapshot.lists {
            guard !list.id.isEmpty, list.id.count <= 512, !list.title.isEmpty,
                  list.title.count <= 4096, list.tasks.count <= 20000,
                  listIDs.insert(list.id).inserted else { throw SnapshotError.invalid }
            var taskIDs = Set<String>()
            for task in list.tasks {
                guard !task.id.isEmpty, task.id.count <= 1024,
                      task.title.count <= 20000, (task.notes?.count ?? 0) <= 50000,
                      ["needsAction", "completed"].contains(task.status),
                      taskIDs.insert(task.id).inserted else { throw SnapshotError.invalid }
            }
        }
    }
    static func save(_ snapshot: TaskSnapshot) throws {
        try validate(snapshot)
        try prepare()
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: self.snapshot, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.snapshot.path)
    }
}

enum SnapshotError: Error { case invalid }
