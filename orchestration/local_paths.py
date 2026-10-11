"""Reject redirects before accessing clone-owned state, including direct hooks."""

from __future__ import annotations

import os
from pathlib import Path
import stat


INSTALL_ROOT = Path(__file__).resolve().parents[1]


def assert_local_path(path: Path, root: Path = INSTALL_ROOT) -> None:
    path = Path(os.path.abspath(path))
    root = Path(os.path.abspath(root))
    if not path.is_relative_to(root):
        raise RuntimeError(f"Path escapes the installation root: {path}")
    for candidate in (path, *path.parents):
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise RuntimeError(f"Reparse points are not supported in installation paths: {candidate}")


def assert_local_tree(path: Path, root: Path = INSTALL_ROOT) -> None:
    assert_local_path(path, root)
    if not path.is_dir():
        return
    pending = [path]
    while pending:
        with os.scandir(pending.pop()) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                    raise RuntimeError(f"Reparse points are not supported in installation paths: {entry.path}")
                if stat.S_ISDIR(info.st_mode):
                    pending.append(Path(entry.path))
