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

    var isWatching: Bool {
        stream != nil
    }

    init(urls: [URL], latency: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        callbackBox = CallbackBox(onChange: onChange)
        let paths = urls.map { $0.standardizedFileURL.path } as CFArray
        // Pass the callback box retained and supply balancing retain/release
        // callbacks. The stream releases its reference during invalidate, so
        // the box stays alive for any callback already dispatched to the
        // private serial queue until invalidate completes — closing the
        // use-after-free window that passUnretained leaves during teardown.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(callbackBox).toOpaque(),
            retain: callbackBoxRetain,
            release: callbackBoxRelease,
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

        guard let createdStream = stream else { return }

        FSEventStreamSetDispatchQueue(createdStream, queue)
        guard FSEventStreamStart(createdStream) else {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            stream = nil
            return
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

// Balancing retain/release for the retained callback box passed into the
// FSEventStreamContext. They are plain C-callable functions matching the
// CFAllocatorRetainCallBack / CFAllocatorReleaseCallBack signatures.
private let callbackBoxRetain: @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer? = { info in
    guard let info else { return info }
    _ = Unmanaged<FolderSyncWatcher.CallbackBox>.fromOpaque(info).retain()
    return info
}

private let callbackBoxRelease: @convention(c) (UnsafeRawPointer?) -> Void = { info in
    guard let info else { return }
    Unmanaged<FolderSyncWatcher.CallbackBox>.fromOpaque(info).release()
}
