import CoreServices
import Foundation

final class FolderSyncWatcher {
    fileprivate final class CallbackBox {
        let onChange: @Sendable () -> Void

        init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }
    }

    private let callbackBox: CallbackBox
    private let queue = DispatchQueue(label: "com.gphilcoder.folder-sync-watcher")
    private var stream: FSEventStreamRef?

    init(urls: [URL], latency: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        callbackBox = CallbackBox(onChange: onChange)
        let paths = urls.map { $0.standardizedFileURL.path } as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderSyncEventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

private func folderSyncEventCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let box = Unmanaged<FolderSyncWatcher.CallbackBox>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()
    box.onChange()
}
