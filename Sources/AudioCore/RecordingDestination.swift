import Foundation

public enum RecordingDestinationError: LocalizedError {
    case downloadsUnavailable, notDirectory, cannotReserve
    public var errorDescription: String? {
        switch self {
        case .downloadsUnavailable: return "无法找到下载文件夹。请检查账户的下载文件夹设置。"
        case .notDirectory: return "默认录音位置不是可用的文件夹，未创建录音文件。"
        case .cannotReserve: return "暂时无法生成不重名的录音文件，请重试。原文件不会被覆盖。"
        }
    }
}

public enum RecordingDestination {
    /// Only resolves the system's Downloads location; this does not create files.
    public static func downloadsDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let url = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw RecordingDestinationError.downloadsUnavailable
        }
        return url
    }

    public static func prepareDirectory(_ directory: URL, fileManager: FileManager = .default) throws {
        guard directory.isFileURL else { throw RecordingDestinationError.notDirectory }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw RecordingDestinationError.notDirectory }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public static func uniqueURL(in directory: URL, format: RecordingFormat, date: Date = Date(),
                                 timeZone: TimeZone = .current, fileManager: FileManager = .default) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let base = "声流_\(formatter.string(from: date))"
        for index in 1...1000 {
            let suffix = index == 1 ? "" : "-\(index)"
            let url = directory.appendingPathComponent("\(base)\(suffix).\(format.fileExtension)", isDirectory: false)
            // A dangling symlink also occupies a name and must not be followed.
            if !fileManager.fileExists(atPath: url.path),
               (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil {
                return url
            }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString).\(format.fileExtension)", isDirectory: false)
    }

    /// Reserves the name using AudioFileRecorder's O_EXCL creation. A competing
    /// instance cannot cause an overwrite between the name check and creation.
    public static func createRecorder(in directory: URL, format: RecordingFormat, date: Date = Date(),
                                      timeZone: TimeZone = .current, fileManager: FileManager = .default) throws -> AudioFileRecorder {
        try prepareDirectory(directory, fileManager: fileManager)
        for _ in 0..<64 {
            let url = uniqueURL(in: directory, format: format, date: date, timeZone: timeZone, fileManager: fileManager)
            do { return try AudioFileRecorder(url: url, outputFormat: format) }
            catch AudioError.fileExists { continue }
        }
        throw RecordingDestinationError.cannotReserve
    }
}
