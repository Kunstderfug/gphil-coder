import Foundation

/// Creates and resolves security-scoped bookmarks for the folder-sync workflow.
///
/// Bookmarks persist folder access grants across launches (required by the
/// sandboxed App Store build). `BookmarkStore` centralizes creation and
/// resolution so the view model does not carry these as scattered private
/// methods, and — critically — so the stale-bookmark case is handled rather
/// than ignored.
@MainActor
final class BookmarkStore {
    /// Creates a security-scoped bookmark for `url`, or nil if the URL cannot
    /// be bookmarked (e.g. it does not exist or is outside the sandbox grant).
    func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves a security-scoped bookmark to a URL.
    ///
    /// - Parameters:
    ///   - data: The persisted bookmark data, or nil to use `fallbackURL`.
    ///   - fallbackURL: Used when there is no bookmark data or resolution fails.
    ///   - onStale: Invoked with the resolved URL when macOS reports the
    ///     bookmark as stale (the folder was renamed/moved). The caller should
    ///     re-create the bookmark from this URL and persist it back so the next
    ///     launch resolves cleanly. This closes the previous bug where
    ///     `isStale` was captured and then discarded.
    /// - Returns: The resolved URL (which may still be usable even when stale).
    func resolveSecurityScopedBookmark(
        _ data: Data?,
        fallbackURL: URL,
        onStale: ((URL) -> Void)? = nil
    ) -> URL {
        guard let data else { return fallbackURL }
        var isStale = false
        let resolved =
            (try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )) ?? fallbackURL
        if isStale {
            onStale?(resolved)
        }
        return resolved
    }

    /// Returns the bookmark data for `url` from `grantedBookmarks` whose URL
    /// contains `url` (i.e. an ancestor folder the user authorized).
    func bookmarkData(
        for url: URL,
        in grantedBookmarks: [(url: URL, data: Data)]
    ) -> Data? {
        grantedBookmarks.first {
            SecurityScopeManager.containsFileURL(url, in: $0.url)
        }?.data
    }
}
