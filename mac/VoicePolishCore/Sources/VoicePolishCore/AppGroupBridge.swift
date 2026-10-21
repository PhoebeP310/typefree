import Foundation

/// App Group shared storage for session-aware recording commands and snapshots.
public final class AppGroupBridge {
    public enum RecordingStatus: String, Codable {
        case idle
        case recording
        case processing
        case done
        case error
    }

    public struct RecordingResult: Codable {
        public let status: RecordingStatus
        public let text: String?
        public let errorMessage: String?
        public let timestamp: TimeInterval

        public init(status: RecordingStatus, text: String? = nil, errorMessage: String? = nil, timestamp: TimeInterval = Date().timeIntervalSince1970) {
            self.status = status
            self.text = text
            self.errorMessage = errorMessage
            self.timestamp = timestamp
        }
    }

    public static let shared = AppGroupBridge()
    private static let legacySessionID = "legacy"

    private let appGroupID = SharedContainer.appGroupID
    private let commandFileName = "recording_command.json"
    private let snapshotFileName = "recording_snapshot.json"
    private let containerURL: URL?
    private let fileManager = FileManager.default
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init(containerURL: URL? = nil) {
        self.containerURL = containerURL ?? fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)

        if let containerURL {
            try? fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)
        }
    }

    static func testingBridge(containerURL: URL? = nil) -> AppGroupBridge {
        let root = containerURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("VoicePolishCore-\(UUID().uuidString)", isDirectory: true)
        return AppGroupBridge(containerURL: root)
    }

    private var commandFileURL: URL? {
        containerURL?.appendingPathComponent(commandFileName)
    }

    private var snapshotFileURL: URL? {
        containerURL?.appendingPathComponent(snapshotFileName)
    }

    private func write<T: Encodable>(_ value: T, to fileURL: URL?) {
        guard let fileURL else { return }

        do {
            let data = try jsonEncoder.encode(value)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[AppGroupBridge] Write error: %@", error.localizedDescription)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from fileURL: URL?) -> T? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? jsonDecoder.decode(T.self, from: data)
    }

    private func clear(_ fileURL: URL?) {
        guard let fileURL else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    private func snapshotStatus(from legacyStatus: RecordingStatus) -> RecordingSessionStatus {
        switch legacyStatus {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .processing:
            return .processing
        case .done:
            return .done
        case .error:
            return .error
        }
    }

    private func legacyStatus(from snapshotStatus: RecordingSessionStatus) -> RecordingStatus {
        switch snapshotStatus {
        case .idle:
            return .idle
        case .launching:
            return .idle
        case .recording:
            return .recording
        case .processing:
            return .processing
        case .done:
            return .done
        case .error:
            return .error
        }
    }

    private func isTerminalLegacySnapshot(_ snapshot: RecordingSessionSnapshot) -> Bool {
        snapshot.sessionID == Self.legacySessionID && (snapshot.status == .done || snapshot.status == .error)
    }

    private func writeSnapshotStatus(
        _ status: RecordingSessionStatus,
        sessionID: String,
        text: String? = nil,
        errorMessage: String? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        write(
            RecordingSessionSnapshot(
                sessionID: sessionID,
                status: status,
                text: text,
                errorMessage: errorMessage,
                timestamp: timestamp
            ),
            to: snapshotFileURL
        )
    }

    public func writeCommand(_ command: RecordingSessionCommand) {
        write(command, to: commandFileURL)
    }

    public func readCommand() -> RecordingSessionCommand? {
        read(RecordingSessionCommand.self, from: commandFileURL)
    }

    public func clearCommand() {
        clear(commandFileURL)
    }

    public func writeSnapshot(_ snapshot: RecordingSessionSnapshot) {
        write(snapshot, to: snapshotFileURL)
    }

    public func readSnapshot() -> RecordingSessionSnapshot? {
        read(RecordingSessionSnapshot.self, from: snapshotFileURL)
    }

    public func clearSnapshot() {
        clear(snapshotFileURL)
    }

    public func writeLaunching(sessionID: String) {
        writeSnapshotStatus(.launching, sessionID: sessionID)
    }

    public func writeRecording(sessionID: String) {
        writeSnapshotStatus(.recording, sessionID: sessionID)
    }

    public func writeProcessing(sessionID: String) {
        writeSnapshotStatus(.processing, sessionID: sessionID)
    }

    public func writeDone(sessionID: String, text: String) {
        writeSnapshotStatus(.done, sessionID: sessionID, text: text)
    }

    public func writeError(sessionID: String, message: String) {
        writeSnapshotStatus(.error, sessionID: sessionID, errorMessage: message)
    }

    @available(*, deprecated, message: "Use typed snapshot APIs; this is a legacy compatibility shim.")
    public func writeResult(_ result: RecordingResult) {
        writeSnapshotStatus(
            snapshotStatus(from: result.status),
            sessionID: Self.legacySessionID,
            text: result.text,
            errorMessage: result.errorMessage,
            timestamp: result.timestamp
        )
    }

    @available(*, deprecated, message: "Use typed snapshot APIs; this is a legacy compatibility shim.")
    public func readResult() -> RecordingResult? {
        guard let snapshot = readSnapshot(), isTerminalLegacySnapshot(snapshot) else { return nil }
        return RecordingResult(
            status: legacyStatus(from: snapshot.status),
            text: snapshot.text,
            errorMessage: snapshot.errorMessage,
            timestamp: snapshot.timestamp
        )
    }

    @available(*, deprecated, message: "Use typed snapshot APIs; this is a legacy compatibility shim.")
    public func consumeResult() -> RecordingResult? {
        let result = readResult()
        if result != nil {
            clearSnapshot()
        }
        return result
    }

    @available(*, deprecated, message: "Use typed snapshot APIs; this is a legacy compatibility shim.")
    public func clearResult() {
        guard let snapshot = readSnapshot(), isTerminalLegacySnapshot(snapshot) else { return }
        clearSnapshot()
    }

    @available(*, deprecated, message: "Use typed snapshot APIs; this is a legacy compatibility shim.")
    public func markLaunching(sessionID: String) {
        writeLaunching(sessionID: sessionID)
    }

    @available(*, deprecated, message: "Use typed snapshot APIs; this is a legacy compatibility shim.")
    public func markRecording(sessionID: String = "legacy") {
        writeRecording(sessionID: sessionID)
    }

    @available(*, deprecated, message: "Use typed snapshot APIs; this is a legacy compatibility shim.")
    public func markProcessing(sessionID: String = "legacy") {
        writeProcessing(sessionID: sessionID)
    }

    @available(*, deprecated, message: "Use typed snapshot APIs; this is a legacy compatibility shim.")
    public func markDone(text: String, sessionID: String = "legacy") {
        writeDone(sessionID: sessionID, text: text)
    }

    @available(*, deprecated, message: "Use typed snapshot APIs; this is a legacy compatibility shim.")
    public func markError(message: String, sessionID: String = "legacy") {
        writeError(sessionID: sessionID, message: message)
    }

    public func hasPendingResult() -> Bool {
        guard let snapshot = readSnapshot() else { return false }
        return isTerminalLegacySnapshot(snapshot)
    }

    // MARK: - Standby

    public struct StandbyStatus: Codable {
        public let active: Bool
        public let expiresAt: TimeInterval
        public let heartbeat: TimeInterval

        public init(active: Bool, expiresAt: TimeInterval, heartbeat: TimeInterval) {
            self.active = active
            self.expiresAt = expiresAt
            self.heartbeat = heartbeat
        }
    }

    public struct StandbyCommand: Codable {
        public enum Action: String, Codable { case ping, start, stop }
        public let action: Action
        public let sessionID: String
        public let timestamp: TimeInterval

        public init(action: Action, sessionID: String, timestamp: TimeInterval = Date().timeIntervalSince1970) {
            self.action = action
            self.sessionID = sessionID
            self.timestamp = timestamp
        }
    }

    public struct StandbyResponse: Codable {
        public enum Kind: String, Codable { case pong }
        public let kind: Kind
        public let sessionID: String
        public let timestamp: TimeInterval

        public init(kind: Kind, sessionID: String, timestamp: TimeInterval = Date().timeIntervalSince1970) {
            self.kind = kind
            self.sessionID = sessionID
            self.timestamp = timestamp
        }
    }

    private var standbyStatusFileURL: URL? {
        containerURL?.appendingPathComponent("standby_status.json")
    }

    private var standbyCommandFileURL: URL? {
        containerURL?.appendingPathComponent("standby_command.json")
    }

    private var standbyResponseFileURL: URL? {
        containerURL?.appendingPathComponent("standby_response.json")
    }

    public func writeStandbyStatus(_ status: StandbyStatus) {
        write(status, to: standbyStatusFileURL)
    }

    public func readStandbyStatus() -> StandbyStatus? {
        read(StandbyStatus.self, from: standbyStatusFileURL)
    }

    public func clearStandbyStatus() {
        clear(standbyStatusFileURL)
    }

    public func writeStandbyCommand(_ command: StandbyCommand) {
        write(command, to: standbyCommandFileURL)
    }

    public func readStandbyCommand() -> StandbyCommand? {
        read(StandbyCommand.self, from: standbyCommandFileURL)
    }

    public func clearStandbyCommand() {
        clear(standbyCommandFileURL)
    }

    public func writeStandbyResponse(_ response: StandbyResponse) {
        write(response, to: standbyResponseFileURL)
    }

    public func readStandbyResponse() -> StandbyResponse? {
        read(StandbyResponse.self, from: standbyResponseFileURL)
    }

    public func clearStandbyResponse() {
        clear(standbyResponseFileURL)
    }

    // MARK: - Audio Level (mmap, real-time cross-process)

    private static let audioLevelFileName = "audioLevel.dat"
    private var audioLevelFileURL: URL? {
        containerURL?.appendingPathComponent(Self.audioLevelFileName)
    }

    private var audioLevelMmapPointer: UnsafeMutablePointer<Float32>?
    private var audioLevelFileDescriptor: Int32 = -1

    private func ensureAudioLevelMmap() -> UnsafeMutablePointer<Float32>? {
        if let ptr = audioLevelMmapPointer { return ptr }

        guard let fileURL = audioLevelFileURL else { return nil }
        let path = fileURL.path
        let size = MemoryLayout<Float32>.size

        // Create file if needed
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: Data(count: size))
        }

        let fd = open(path, O_RDWR)
        guard fd >= 0 else {
            NSLog("[AppGroupBridge] mmap open failed: %d", errno)
            return nil
        }

        // Ensure file is correct size
        ftruncate(fd, off_t(size))

        guard let ptr = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) else {
            close(fd)
            NSLog("[AppGroupBridge] mmap failed: %d", errno)
            return nil
        }

        if ptr == MAP_FAILED {
            close(fd)
            NSLog("[AppGroupBridge] mmap MAP_FAILED: %d", errno)
            return nil
        }

        audioLevelFileDescriptor = fd
        audioLevelMmapPointer = ptr.assumingMemoryBound(to: Float32.self)
        return audioLevelMmapPointer
    }

    /// Pre-initialize the mmap. Call from main thread before starting recording
    /// to avoid lazy init on the real-time audio thread.
    @discardableResult
    public func prepareAudioLevelMmap() -> Bool {
        return ensureAudioLevelMmap() != nil
    }

    /// Write audio level (0.0~1.0) from the recording process. Called at audio callback rate.
    /// Must call prepareAudioLevelMmap() before first write.
    public func writeAudioLevel(_ level: Float) {
        guard let ptr = audioLevelMmapPointer ?? ensureAudioLevelMmap() else { return }
        let clamped = min(max(level, 0), 1)
        ptr.pointee = clamped
    }

    /// Read audio level from the keyboard extension. Returns 0 if unavailable.
    public func readAudioLevel() -> Float {
        guard let ptr = ensureAudioLevelMmap() else { return 0 }
        return ptr.pointee
    }
}
