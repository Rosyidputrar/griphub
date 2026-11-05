#!/usr/bin/env python3
"""Keeps CHANGELOG.md and RELEASE_NOTES.md in step with the releases (run by .github/workflows/release.yml).

  stamp  --version 1.0.130 --date 2026-11-03
      CHANGELOG.md: the "## Belum dirilis" section becomes "## v1.0.130 (3 November 2026)", and a new, empty
      "## Belum dirilis" goes above it for what comes next. A section with no entries is left as it is (a release of
      tests or build changes has nothing to tell users). Run before the build, so the APK carries the version's notes.
  reset
      RELEASE_NOTES.md: back to its header (the comment) and empty headings, once the release has used it.
  has-notes
      Exit 0 when RELEASE_NOTES.md has at least one entry, 1 when not (the release then gets a one-line body).

Paths default to the repository's own; --changelog / --notes point elsewhere (the tests). Nothing here reads or writes
anything else, and no repository, account or link is ever put into either file.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MONTHS = [
    "Januari", "Februari", "Maret", "April", "Mei", "Juni",
    "Juli", "Agustus", "September", "Oktober", "November", "Desember",
]
UNRELEASED = "## Belum dirilis"
# Said under the empty section, so a reader of the file sees why it is empty.
EMPTY = "_Belum ada perubahan._"


def long_date(iso: str) -> str:
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", iso)
    if not m:
        raise SystemExit(f"--date must be YYYY-MM-DD, not {iso!r}")
    year, month, day = int(m[1]), int(m[2]), int(m[3])
    if not 1 <= month <= 12 or not 1 <= day <= 31:
        raise SystemExit(f"--date is not a date: {iso!r}")
    return f"{day} {MONTHS[month - 1]} {year}"


def has_entries(section: str) -> bool:
    return any(line.startswith("- ") for line in section.splitlines())


def stamp(changelog: Path, version: str, date: str) -> bool:
    """True when the section was versioned."""
    if not re.fullmatch(r"\d+(\.\d+)+", version):
        raise SystemExit(f"--version must be dotted numbers, not {version!r}")
    text = changelog.read_text(encoding="utf-8")
    lines = text.split("\n")
    starts = [i for i, l in enumerate(lines) if l.rstrip() == UNRELEASED]
    if len(starts) != 1:
        raise SystemExit(f'CHANGELOG.md must have exactly one "{UNRELEASED}" section, found {len(starts)}')
    start = starts[0]
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ") or lines[i] == "---"), len(lines))
    if not has_entries("\n".join(lines[start:end])):
        return False
    if any(l.startswith(f"## v{version} ") or l.rstrip() == f"## v{version}" for l in lines):
        raise SystemExit(f"CHANGELOG.md already has v{version}")
    lines[start] = f"## v{version} ({long_date(date)})"
    # The rule that closed the old section now closes the new empty one, above it: the released versions have none
    # between them, and a second rule would sit between two of them.
    if end < len(lines) and lines[end] == "---":
        del lines[end]
        if end < len(lines) and lines[end] == "":
            del lines[end]
    lines[start:start] = [UNRELEASED, "", EMPTY, "", "---", ""]
    changelog.write_text("\n".join(lines), encoding="utf-8")
    return True


def reset(notes: Path) -> None:
    first = notes.read_text(encoding="utf-8").split("\n", 1)[0]
    if not first.startswith("<!--"):
        raise SystemExit("RELEASE_NOTES.md should start with its comment line; not touching it")
    notes.write_text(f"{first}\n\n## Bahasa Indonesia\n\n\n## English\n\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["stamp", "reset", "has-notes"])
    ap.add_argument("--version")
    ap.add_argument("--date")
    ap.add_argument("--changelog", type=Path, default=ROOT / "CHANGELOG.md")
    ap.add_argument("--notes", type=Path, default=ROOT / "RELEASE_NOTES.md")
    a = ap.parse_args()
    if a.command == "stamp":
        if not a.version or not a.date:
            ap.error("stamp needs --version and --date")
        print("versioned" if stamp(a.changelog, a.version, a.date) else "nothing to version")
    elif a.command == "reset":
        reset(a.notes)
    else:
        return 0 if has_entries(a.notes.read_text(encoding="utf-8")) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
