import Foundation

/// Zips a folder of stems into one file. `NSFileCoordinator`'s `.forUploading` option does this
/// on macOS and iOS alike, with no tool to launch and nothing to bundle.
enum StemArchive {
    static func zip(folder: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading,
                                       error: &coordinationError) { zipped in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
    }
}
