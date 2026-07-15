# File Copy Job Format

GPhil MediaFlow File Copy jobs are UTF-8 JSON documents saved with the `.job`
extension. The document is versioned so incompatible files can be rejected
without replacing the queue currently open in the app.

## Version 2

The top-level document contains:

- `version`: `2`
- `savedAt`: ISO-8601 save timestamp
- `workflows`: ordered array of Copy workflows

Each workflow contains its stable `id`, `createdAt`, complete `sourceRoots`
array, `destinationRoot`, `destinationLayout`, media `filter`, optional
`selectedExtensions`, and `fileNameFilter`.

`destinationLayout` is one of:

- `sourceFolders`: each source folder is placed inside the selected destination.
- `mergeContents`: every source's relative contents target the selected
  destination directly. Cross-source final-path collisions are reported by the
  plan before execution.

All paths are decoded as local directory URLs. A saved path does not need to
exist at load time: the workflow remains in the queue as **NEEDS REPAIR**, keeps
its complete configuration, and cannot run until each missing folder is
relinked.

## Version 1 migration

Version 1 stored one `sourceRoot` per workflow and had no explicit destination
layout. Migration first resolves the destination exactly as the former queue
did, including its matching-leaf-name heuristic, then stores that resolved root
with `destinationLayout: mergeContents`. This preserves the old destination
tree without weakening the explicit version-2 `sourceFolders` rule. Missing
optional extension and filename filters receive their historical defaults.

After decoding, the in-memory document version is normalized to version 2. The
next save writes only the version-2 shape.

## Rejection behavior

- Versions newer than the current application supports are rejected with the
  found and supported version numbers.
- Workflows with an empty source set and structurally corrupt JSON are rejected.
- Decoding completes before the model replaces its current queue, so rejected
  files do not partially load or discard current work.
