import Foundation

/// Fires when entries in a directory are added, removed, or replaced. Claude Code rewrites a
/// session's registry file on every status change, so the change is seen as it happens rather
/// than at the next poll. A directory that does not exist yet is simply not watched.
final class DirectoryWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []

    init(directories: [URL], onChange: @escaping @Sendable () -> Void) {
        for directory in directories {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .global(qos: .utility))
            source.setEventHandler(handler: onChange)
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    deinit { for source in sources { source.cancel() } }
}
