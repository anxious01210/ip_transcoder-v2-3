# transcoder/retention.py
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, List, Dict, Tuple
import glob
import os

from django.conf import settings
from django.utils import timezone

from transcoder.models import Channel
PLAYBACK_PLAYLIST_WINDOW_SECONDS = int(getattr(settings, "PLAYBACK_PLAYLIST_WINDOW_SECONDS", 3 * 3600))

SAFETY_MARGIN_SECONDS = 3600  # 1 hour extra buffer (protect against clock drift & edge cases)


@dataclass(frozen=True)
class SegmentFile:
    path: Path
    ts: dt.datetime  # naive datetime derived from filename or mtime


def _parse_ts_from_filename(channel_name: str, p: Path) -> Optional[dt.datetime]:
    """
    Expected filename:
      <channel>_YYYYMMDD-HHMMSS.ts
    Returns a naive datetime or None if not parseable.
    """
    prefix = f"{channel_name}_"
    stem = p.stem
    if not stem.startswith(prefix):
        return None
    ts_str = stem[len(prefix):]
    try:
        return dt.datetime.strptime(ts_str, "%Y%m%d-%H%M%S")
    except ValueError:
        return None


def _segment_ts(channel_name: str, p: Path) -> dt.datetime:
    ts = _parse_ts_from_filename(channel_name, p)
    if ts is not None:
        return ts
    # fallback: use filesystem mtime
    try:
        return dt.datetime.fromtimestamp(p.stat().st_mtime)
    except Exception:
        return dt.datetime.min


def _recording_glob_pattern(chan: Channel) -> str:
    """
    Expand recording_path_template into a glob pattern (absolute).
    We replace placeholders with wildcards to match any date/time folders.
    """
    base = Path(settings.MEDIA_ROOT)
    tpl = chan.recording_path_template or "recordings/{channel}/{date}/"

    # build a directory glob: allow any date/time placeholders
    dir_pattern = tpl.format(channel=chan.name, date="*", time="*")

    # resolve relative under MEDIA_ROOT
    dir_path = Path(dir_pattern)
    if not dir_path.is_absolute():
        dir_path = base / dir_path

    # Match TS files named <channel>_*.ts under those folders (non-recursive)
    # because date is already wildcarded at folder level.
    return str(dir_path / f"{chan.name}_*.ts")


def list_segments(chan: Channel) -> List[SegmentFile]:
    pattern = _recording_glob_pattern(chan)
    paths = [Path(p) for p in glob.glob(pattern)]
    segs = [SegmentFile(path=p, ts=_segment_ts(chan.name, p)) for p in paths if p.exists()]
    segs.sort(key=lambda s: s.ts)
    return segs


def _protect_threshold_dt(chan: Channel, now_aware) -> dt.datetime:
    """
    Never delete anything newer than:
      now - (delay_seconds + PLAYBACK_PLAYLIST_WINDOW_SECONDS + SAFETY_MARGIN_SECONDS)
    This guarantees playback never references deleted files.
    """
    delay = int(getattr(chan, "delay_seconds", 0) or 0)
    required = delay + int(PLAYBACK_PLAYLIST_WINDOW_SECONDS) + int(SAFETY_MARGIN_SECONDS)
    threshold_aware = now_aware - dt.timedelta(seconds=required)
    return threshold_aware.replace(tzinfo=None)  # compare to naive segment timestamps


def prune_channel_recordings(chan: Channel, *, dry_run: bool = False) -> Dict[str, int]:
    """
    Applies retention rules safely:
      - auto_delete_after_days: delete segments older than N days
      - auto_delete_after_segments: keep newest N segments per folder
      - BUT: never delete files newer than the protect threshold

    Returns counters for logging.
    """
    counters = {
        "scanned": 0,
        "deleted": 0,
        "skipped_protected": 0,
        "skipped_missing": 0,
        "skipped_errors": 0,
    }

    if not chan.auto_delete_enabled:
        return counters

    now_aware = timezone.localtime()
    protect_dt = _protect_threshold_dt(chan, now_aware)

    segs = list_segments(chan)
    counters["scanned"] = len(segs)

    # Group by folder (per-day folder typically)
    by_folder: Dict[Path, List[SegmentFile]] = {}
    for s in segs:
        by_folder.setdefault(s.path.parent, []).append(s)

    delete_set: set[Path] = set()

    # Rule 1: age-based deletion (older than N days)
    if chan.auto_delete_after_days is not None:
        days = int(chan.auto_delete_after_days)
        if days > 0:
            cutoff = now_aware - dt.timedelta(days=days)
            cutoff_dt = cutoff.replace(tzinfo=None)
            for s in segs:
                if s.ts < cutoff_dt:
                    delete_set.add(s.path)

    # Rule 2: count-based deletion (per folder keep newest N)
    if chan.auto_delete_after_segments is not None:
        keep_n = int(chan.auto_delete_after_segments)
        if keep_n > 0:
            for folder, items in by_folder.items():
                items_sorted = sorted(items, key=lambda x: x.ts)
                # delete everything except newest keep_n
                if len(items_sorted) > keep_n:
                    for s in items_sorted[:-keep_n]:
                        delete_set.add(s.path)

    # Safety: never delete protected range
    final_delete: List[Path] = []
    for p in delete_set:
        if not p.exists():
            counters["skipped_missing"] += 1
            continue

        ts = _segment_ts(chan.name, p)
        if ts >= protect_dt:
            counters["skipped_protected"] += 1
            continue

        final_delete.append(p)

    # Execute deletions
    for p in sorted(final_delete):
        try:
            if not dry_run:
                p.unlink(missing_ok=True)
            counters["deleted"] += 1
        except Exception:
            counters["skipped_errors"] += 1

    # Optional: remove empty date folders (safe cleanup)
    # Only attempt to delete folders that match the pattern and are empty.
    try:
        pattern_dir = chan.recording_path_template.format(channel=chan.name, date="*", time="*")
        base = Path(settings.MEDIA_ROOT)
        dir_path = Path(pattern_dir)
        if not dir_path.is_absolute():
            dir_path = base / dir_path
        for d in glob.glob(str(dir_path)):
            dp = Path(d)
            if dp.is_dir():
                # If folder is empty, remove it
                if not any(dp.iterdir()):
                    if not dry_run:
                        dp.rmdir()
    except Exception:
        pass

    return counters
