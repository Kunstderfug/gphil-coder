#!/usr/bin/env python3
"""Plan restoration of flat Trash-recovered files using a structured backup tree.

This tool is intentionally non-destructive by default. It compares files copied
out of Trash with files in a backup tree, infers the original relative path from
the backup match, then writes a JSON/CSV restore plan and a reviewable shell
copy script.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shlex
import shutil
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class FileInfo:
    path: Path
    name_key: str
    size: int


@dataclass
class PlanRecord:
    status: str
    deleted_path: str
    backup_path: str | None
    restore_path: str | None
    relative_path: str | None
    size: int
    sha256: str | None
    note: str
    candidates: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Match files copied from Trash against a structured backup and "
            "produce a non-destructive restore plan."
        )
    )
    parser.add_argument(
        "--deleted-dir",
        required=True,
        type=Path,
        help="Folder containing files copied out of Trash. It may be flat or nested.",
    )
    parser.add_argument(
        "--backup-root",
        required=True,
        type=Path,
        help="Root of the structured backup, for example /Volumes/STUDIO_PROJECTS.",
    )
    parser.add_argument(
        "--restore-root",
        required=True,
        type=Path,
        help="Root to restore into, for example /Volumes/PROJECTS.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Where to write restore_plan.json, restore_plan.csv, and restore_copy.sh.",
    )
    parser.add_argument(
        "--hash-mode",
        choices=("auto", "always", "never"),
        default="auto",
        help=(
            "auto hashes only ambiguous same-name/same-size matches; always hashes "
            "every match candidate; never trusts filename and size only."
        ),
    )
    parser.add_argument(
        "--case-sensitive",
        action="store_true",
        help="Match filenames case-sensitively. Default is case-insensitive.",
    )
    parser.add_argument(
        "--include-hidden",
        action="store_true",
        help="Include dotfiles and AppleDouble files such as .DS_Store or ._name.",
    )
    parser.add_argument(
        "--extensions",
        default="",
        help="Optional comma-separated extensions to scan, for example .wav,.flac,.wv.",
    )
    parser.add_argument(
        "--copy-source",
        choices=("deleted", "backup"),
        default="deleted",
        help="Source used by generated restore_copy.sh and --apply.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually copy matched files to restore paths after writing the plan.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Allow --apply and restore_copy.sh to overwrite existing restore paths.",
    )
    return parser.parse_args()


def normalized_extensions(raw: str) -> set[str]:
    result: set[str] = set()
    for part in raw.split(","):
        value = part.strip().lower()
        if not value:
            continue
        result.add(value if value.startswith(".") else f".{value}")
    return result


def should_skip(path: Path, include_hidden: bool, extensions: set[str]) -> bool:
    if not include_hidden:
        for part in path.parts:
            if part.startswith("."):
                return True
    if extensions and path.suffix.lower() not in extensions:
        return True
    return False


def iter_files(root: Path, include_hidden: bool, extensions: set[str]) -> Iterable[FileInfo]:
    for current_root, dirnames, filenames in os.walk(root):
        current = Path(current_root)

        if not include_hidden:
            dirnames[:] = [name for name in dirnames if not name.startswith(".")]

        for filename in filenames:
            path = current / filename
            if should_skip(path, include_hidden, extensions):
                continue
            try:
                stat = path.stat()
            except OSError as error:
                print(f"warning: cannot stat {path}: {error}", file=sys.stderr)
                continue
            if not path.is_file():
                continue
            yield FileInfo(path=path, name_key=filename, size=stat.st_size)


def name_key(name: str, case_sensitive: bool) -> str:
    return name if case_sensitive else name.casefold()


def sha256(path: Path, cache: dict[Path, str]) -> str:
    cached = cache.get(path)
    if cached is not None:
        return cached

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    value = digest.hexdigest()
    cache[path] = value
    return value


def build_backup_index(
    backup_root: Path,
    include_hidden: bool,
    extensions: set[str],
    case_sensitive: bool,
) -> dict[tuple[str, int], list[FileInfo]]:
    index: dict[tuple[str, int], list[FileInfo]] = {}
    count = 0
    for file_info in iter_files(backup_root, include_hidden, extensions):
        key = (name_key(file_info.path.name, case_sensitive), file_info.size)
        index.setdefault(key, []).append(file_info)
        count += 1
        if count % 5000 == 0:
            print(f"indexed {count} backup files...", file=sys.stderr)
    print(f"indexed {count} backup files", file=sys.stderr)
    return index


def relative_to_backup(path: Path, backup_root: Path) -> Path:
    try:
        return path.relative_to(backup_root)
    except ValueError:
        return Path(path.name)


def make_record(
    deleted: FileInfo,
    status: str,
    note: str,
    backup_match: FileInfo | None = None,
    restore_root: Path | None = None,
    backup_root: Path | None = None,
    digest: str | None = None,
    candidates: list[FileInfo] | None = None,
) -> PlanRecord:
    relative_path: Path | None = None
    restore_path: Path | None = None
    if backup_match is not None and restore_root is not None and backup_root is not None:
        relative_path = relative_to_backup(backup_match.path, backup_root)
        restore_path = restore_root / relative_path

    return PlanRecord(
        status=status,
        deleted_path=str(deleted.path),
        backup_path=str(backup_match.path) if backup_match else None,
        restore_path=str(restore_path) if restore_path else None,
        relative_path=str(relative_path) if relative_path else None,
        size=deleted.size,
        sha256=digest,
        note=note,
        candidates=[str(item.path) for item in candidates or []],
    )


def plan_restore(args: argparse.Namespace) -> list[PlanRecord]:
    extensions = normalized_extensions(args.extensions)
    backup_root = args.backup_root.expanduser().resolve()
    restore_root = args.restore_root.expanduser()
    deleted_dir = args.deleted_dir.expanduser().resolve()

    backup_index = build_backup_index(
        backup_root=backup_root,
        include_hidden=args.include_hidden,
        extensions=extensions,
        case_sensitive=args.case_sensitive,
    )
    hash_cache: dict[Path, str] = {}
    records: list[PlanRecord] = []

    deleted_files = list(iter_files(deleted_dir, args.include_hidden, extensions))
    print(f"scanning {len(deleted_files)} deleted files", file=sys.stderr)

    for index, deleted in enumerate(deleted_files, start=1):
        if index % 500 == 0:
            print(f"planned {index} deleted files...", file=sys.stderr)

        key = (name_key(deleted.path.name, args.case_sensitive), deleted.size)
        candidates = backup_index.get(key, [])
        if not candidates:
            records.append(
                make_record(
                    deleted,
                    status="missing",
                    note="No backup file with the same filename and size.",
                )
            )
            continue

        digest: str | None = None
        if args.hash_mode == "always" or (args.hash_mode == "auto" and len(candidates) > 1):
            try:
                digest = sha256(deleted.path, hash_cache)
            except OSError as error:
                records.append(
                    make_record(
                        deleted,
                        status="missing",
                        note=f"Could not hash deleted file: {error}",
                        candidates=candidates,
                    )
                )
                continue

            hashed_candidates: list[FileInfo] = []
            for candidate in candidates:
                try:
                    if sha256(candidate.path, hash_cache) == digest:
                        hashed_candidates.append(candidate)
                except OSError as error:
                    print(f"warning: cannot hash {candidate.path}: {error}", file=sys.stderr)
            candidates = hashed_candidates

        if len(candidates) == 1:
            match = candidates[0]
            relative_path = relative_to_backup(match.path, backup_root)
            restore_path = restore_root / relative_path
            conflict = restore_path.exists()
            note = "Matched by filename and size."
            if digest is not None:
                note = "Matched by filename, size, and SHA-256."
            if conflict:
                note += " Restore path already exists."
            records.append(
                make_record(
                    deleted,
                    status="matched_conflict" if conflict else "matched",
                    note=note,
                    backup_match=match,
                    restore_root=restore_root,
                    backup_root=backup_root,
                    digest=digest,
                    candidates=candidates,
                )
            )
        elif candidates:
            records.append(
                make_record(
                    deleted,
                    status="ambiguous",
                    note="Multiple backup paths match; original path cannot be inferred safely.",
                    digest=digest,
                    candidates=candidates,
                )
            )
        else:
            records.append(
                make_record(
                    deleted,
                    status="missing",
                    note="Same filename and size existed, but SHA-256 did not match.",
                    digest=digest,
                )
            )

    return records


def default_output_dir() -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return Path.cwd() / f"restore-plan-{stamp}"


def write_json(path: Path, args: argparse.Namespace, records: list[PlanRecord]) -> None:
    totals: dict[str, int] = {}
    for record in records:
        totals[record.status] = totals.get(record.status, 0) + 1

    payload = {
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "deletedDir": str(args.deleted_dir.expanduser()),
        "backupRoot": str(args.backup_root.expanduser()),
        "restoreRoot": str(args.restore_root.expanduser()),
        "hashMode": args.hash_mode,
        "copySource": args.copy_source,
        "totals": totals,
        "records": [asdict(record) for record in records],
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def write_csv(path: Path, records: list[PlanRecord]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "status",
                "deleted_path",
                "backup_path",
                "restore_path",
                "relative_path",
                "size",
                "sha256",
                "note",
                "candidates",
            ],
        )
        writer.writeheader()
        for record in records:
            row = asdict(record)
            row["candidates"] = json.dumps(record.candidates, ensure_ascii=False)
            writer.writerow(row)


def write_copy_script(
    path: Path,
    records: list[PlanRecord],
    copy_source: str,
    overwrite: bool,
) -> None:
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "# Generated by scripts/plan_restore_from_backup.py",
        "# Review this file before running it.",
        "",
    ]

    matched = [record for record in records if record.status in {"matched", "matched_conflict"}]
    for record in matched:
        if not overwrite and record.status == "matched_conflict":
            lines.append(
                f"echo {shlex.quote('SKIP existing restore path: ' + (record.restore_path or ''))}"
            )
            continue

        source = record.deleted_path if copy_source == "deleted" else record.backup_path
        if source is None or record.restore_path is None:
            continue
        restore_path = Path(record.restore_path)
        overwrite_flag = "1" if overwrite else "0"
        lines.extend(
            [
                f"mkdir -p {shlex.quote(str(restore_path.parent))}",
                f"if [[ -e {shlex.quote(str(restore_path))} && {overwrite_flag} != 1 ]]; then",
                f"  echo {shlex.quote('SKIP existing restore path: ' + str(restore_path))}",
                "else",
                f"  cp -p {shlex.quote(source)} {shlex.quote(str(restore_path))}",
                f"  echo {shlex.quote('RESTORED ' + str(restore_path))}",
                "fi",
                "",
            ]
        )

    path.write_text("\n".join(lines), encoding="utf-8")
    path.chmod(0o755)


def apply_plan(records: list[PlanRecord], copy_source: str, overwrite: bool) -> tuple[int, int, int]:
    copied = 0
    skipped = 0
    failed = 0

    for record in records:
        if record.status not in {"matched", "matched_conflict"}:
            continue
        if record.restore_path is None:
            skipped += 1
            continue
        if record.status == "matched_conflict" and not overwrite:
            skipped += 1
            continue

        source = record.deleted_path if copy_source == "deleted" else record.backup_path
        if source is None:
            skipped += 1
            continue

        try:
            destination = Path(record.restore_path)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists() and not overwrite:
                skipped += 1
                continue
            shutil.copy2(source, destination)
            copied += 1
        except OSError as error:
            failed += 1
            print(f"warning: could not copy {source} -> {record.restore_path}: {error}", file=sys.stderr)

    return copied, skipped, failed


def print_summary(records: list[PlanRecord]) -> None:
    totals: dict[str, int] = {}
    for record in records:
        totals[record.status] = totals.get(record.status, 0) + 1

    print("Restore plan summary:")
    for status in ("matched", "matched_conflict", "ambiguous", "missing"):
        print(f"  {status}: {totals.get(status, 0)}")


def main() -> int:
    args = parse_args()
    for label, path in (("deleted-dir", args.deleted_dir), ("backup-root", args.backup_root)):
        if not path.expanduser().is_dir():
            print(f"error: --{label} is not a readable directory: {path}", file=sys.stderr)
            return 2

    output_dir = (args.output_dir or default_output_dir()).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)

    records = plan_restore(args)
    write_json(output_dir / "restore_plan.json", args, records)
    write_csv(output_dir / "restore_plan.csv", records)
    write_copy_script(output_dir / "restore_copy.sh", records, args.copy_source, args.overwrite)
    print_summary(records)
    print(f"Wrote {output_dir / 'restore_plan.json'}")
    print(f"Wrote {output_dir / 'restore_plan.csv'}")
    print(f"Wrote {output_dir / 'restore_copy.sh'}")

    if args.apply:
        copied, skipped, failed = apply_plan(records, args.copy_source, args.overwrite)
        print(f"Applied plan: copied={copied}, skipped={skipped}, failed={failed}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
