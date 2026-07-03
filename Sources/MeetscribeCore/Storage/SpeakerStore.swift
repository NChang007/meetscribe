import Foundation
import GRDB

public struct KnownSpeaker: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: String
    public var label: String?
    public var createdAt: Date

    public init(id: String = "spk_" + UUID().uuidString.lowercased(), label: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
    }

    public static let databaseTableName = "speakers"
}

public struct SpeakerEmbeddingRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var speakerId: String
    public var vector: Data
    public var sessionId: String?
    public var segmentStart: Double?
    public var segmentEnd: Double?

    public var asFloats: [Float] {
        vector.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }

    public init(
        id: Int64? = nil,
        speakerId: String,
        vector: [Float],
        sessionId: String? = nil,
        segmentStart: Double? = nil,
        segmentEnd: Double? = nil
    ) {
        self.id = id
        self.speakerId = speakerId
        self.vector = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        self.sessionId = sessionId
        self.segmentStart = segmentStart
        self.segmentEnd = segmentEnd
    }

    public static let databaseTableName = "speaker_embeddings"
}

public final class SpeakerStore: @unchecked Sendable {
    public let dbQueue: DatabaseQueue

    public init(path: URL = MeetscribePaths.speakerDatabaseURL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbQueue = try DatabaseQueue(path: path.path, configuration: configuration)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in
            try database.create(table: "speakers") { table in
                table.column("id", .text).primaryKey()
                table.column("label", .text)
                table.column("createdAt", .datetime).notNull()
            }
            try database.create(table: "speaker_embeddings") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("speakerId", .text).notNull().references("speakers", onDelete: .cascade)
                table.column("vector", .blob).notNull()
                table.column("sessionId", .text)
                table.column("segmentStart", .double)
                table.column("segmentEnd", .double)
            }
            try database.execute(sql: """
                CREATE VIRTUAL TABLE transcript_fts USING fts5(
                    sessionId,
                    speakerId,
                    text
                )
            """)
        }
        try migrator.migrate(dbQueue)
    }

    public func allSpeakers() throws -> [KnownSpeaker] {
        try dbQueue.read { database in
            try KnownSpeaker.order(Column("createdAt").asc).fetchAll(database)
        }
    }

    public func insertSpeaker(_ speaker: KnownSpeaker) throws {
        try dbQueue.write { database in
            var mutable = speaker
            try mutable.insert(database)
        }
    }

    public func updateLabel(id: String, label: String?) throws {
        try dbQueue.write { database in
            try database.execute(
                sql: "UPDATE speakers SET label = ? WHERE id = ?",
                arguments: [label, id]
            )
        }
    }

    public func mergeSpeakers(from sourceId: String, into targetId: String) throws {
        try dbQueue.write { database in
            try database.execute(
                sql: "UPDATE speaker_embeddings SET speakerId = ? WHERE speakerId = ?",
                arguments: [targetId, sourceId]
            )
            try database.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [sourceId])
        }
    }

    @discardableResult
    public func insertEmbedding(_ embedding: SpeakerEmbeddingRecord) throws -> Int64 {
        try dbQueue.write { database in
            var mutable = embedding
            try mutable.insert(database)
            return mutable.id ?? 0
        }
    }

    public func embeddings(for speakerId: String) throws -> [SpeakerEmbeddingRecord] {
        try dbQueue.read { database in
            try SpeakerEmbeddingRecord
                .filter(Column("speakerId") == speakerId)
                .fetchAll(database)
        }
    }

    public func sessionIds(for speakerId: String) throws -> [String] {
        try dbQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT sessionId FROM speaker_embeddings
                    WHERE speakerId = ? AND sessionId IS NOT NULL
                """,
                arguments: [speakerId]
            )
            return rows.compactMap { row in row["sessionId"] as String? }
        }
    }

    public func replaceTranscriptIndex(sessionId: String, segments: [TranscriptSegment]) throws {
        try dbQueue.write { database in
            try database.execute(
                sql: "DELETE FROM transcript_fts WHERE sessionId = ?",
                arguments: [sessionId]
            )
            for segment in segments {
                let speakerId = segment.resolvedSpeaker ?? segment.speakerLabel ?? "unknown"
                try database.execute(
                    sql: "INSERT INTO transcript_fts (sessionId, speakerId, text) VALUES (?, ?, ?)",
                    arguments: [sessionId, speakerId, segment.text]
                )
            }
        }
    }

    public func indexTranscript(sessionId: String, segments: [TranscriptSegment]) throws {
        try dbQueue.write { database in
            for segment in segments {
                let speakerId = segment.resolvedSpeaker ?? segment.speakerLabel ?? "unknown"
                try database.execute(
                    sql: "INSERT INTO transcript_fts (sessionId, speakerId, text) VALUES (?, ?, ?)",
                    arguments: [sessionId, speakerId, segment.text]
                )
            }
        }
    }

    public struct SearchHit: Sendable {
        public let sessionId: String
        public let speakerId: String
        public let snippet: String
    }

    public func search(_ query: String, limit: Int = 20) throws -> [SearchHit] {
        let ftsQuery = Self.escapeFTSQuery(query)
        return try dbQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT sessionId, speakerId, snippet(transcript_fts, 2, '<b>', '</b>', '…', 24) AS snippet
                    FROM transcript_fts
                    WHERE transcript_fts MATCH ?
                    LIMIT ?
                """,
                arguments: [ftsQuery, limit]
            )
            return rows.map { row in
                SearchHit(
                    sessionId: row["sessionId"] ?? "",
                    speakerId: row["speakerId"] ?? "",
                    snippet: row["snippet"] ?? ""
                )
            }
        }
    }

    private static func escapeFTSQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
