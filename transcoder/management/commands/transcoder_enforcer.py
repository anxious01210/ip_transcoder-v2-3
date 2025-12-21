# transcoder/management/commands/transcoder_enforcer.py
import subprocess, time, logging
from typing import Dict, Tuple
from transcoder.models import OutputTarget
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand
from django.utils import timezone

from transcoder.ffmpeg_runner import FFmpegJobConfig
from transcoder.models import Channel, JobPurpose

logger = logging.getLogger(__name__)

JobKey = Tuple[str, int, int | None]  # (purpose, channel_id, target_id)

def _stop_and_reap(proc: subprocess.Popen, timeout: float = 3.0) -> None:
    """
    Terminate a child process and reap it so it doesn't stay <defunct>.
    """
    if proc is None:
        return

    # If already exited, still reap
    if proc.poll() is not None:
        try:
            proc.wait(timeout=0)
        except Exception:
            pass
        return

    try:
        proc.terminate()
    except Exception:
        pass

    try:
        proc.wait(timeout=timeout)
        return
    except subprocess.TimeoutExpired:
        pass

    # Hard kill if still alive
    try:
        proc.kill()
    except Exception:
        pass

    try:
        proc.wait(timeout=timeout)
    except Exception:
        pass



class Command(BaseCommand):
    help = (
        "Enforcer: starts/stops ffmpeg jobs based on each channel's schedule. "
        "Mode: Record + Time-shift playback (single output)."
    )

    POLL_INTERVAL = 5  # seconds

    def _auto_delete_for_channel(self, chan: Channel, now) -> None:
        """
        Delete old TS segments based on:
          - auto_delete_after_segments (keep last N)
          - auto_delete_after_days (delete older than N days)

        Also protects a window required for playback:
            delay_minutes + PLAYBACK_PLAYLIST_WINDOW_SECONDS (+ one segment)
        """
        from pathlib import Path
        from datetime import datetime, timedelta
        import re

        window_seconds = int(getattr(settings, "PLAYBACK_PLAYLIST_WINDOW_SECONDS", 3 * 3600))

        delay_seconds = 0
        profile = getattr(chan, "timeshift_profile", None) or getattr(chan, "timeshiftprofile", None)
        if profile and getattr(profile, "enabled", False):
            delay_seconds = int(getattr(profile, "delay_seconds", 0) or 0)

        protect_seconds = delay_seconds + window_seconds + (chan.recording_segment_minutes * 60)
        protect_after = (now - timedelta(seconds=protect_seconds)).replace(tzinfo=None)

        # Derive recordings root
        try:
            root_str = chan.recording_path_template.format(channel=chan.name, date="", time="")
        except Exception:
            root_str = chan.recording_path_template

        root = Path(root_str)
        if not root.is_absolute():
            root = Path(settings.MEDIA_ROOT) / root

        if not root.exists():
            root = Path(settings.MEDIA_ROOT) / "recordings" / chan.name

        ts_files = list(root.glob("**/*.ts"))
        if not ts_files:
            return

        rx = re.compile(rf"^{re.escape(chan.name)}_(\d{{8}})-(\d{{6}})\.ts$")
        items = []
        for p in ts_files:
            ts = None
            m = rx.match(p.name)
            if m:
                try:
                    ts = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
                except Exception:
                    ts = None
            if ts is None:
                ts = datetime.fromtimestamp(p.stat().st_mtime)
            items.append((ts, p))
        items.sort(key=lambda x: x[0])

        to_delete = set()

        # Age-based deletion
        if chan.auto_delete_after_days:
            cutoff = (now - timedelta(days=int(chan.auto_delete_after_days))).replace(tzinfo=None)
            for ts, p in items:
                if ts < cutoff and ts < protect_after:
                    to_delete.add(p)

        # Count-based deletion (keep last N)
        if chan.auto_delete_after_segments:
            keep_n = int(chan.auto_delete_after_segments)
            if keep_n > 0 and len(items) > keep_n:
                older = items[:-keep_n]
                for ts, p in older:
                    if ts < protect_after:
                        to_delete.add(p)

        for p in sorted(to_delete):
            try:
                p.unlink(missing_ok=True)
            except Exception:
                pass

    def handle(self, *args, **options):
        running: Dict[JobKey, subprocess.Popen] = {}
        last_cmd: Dict[JobKey, list[str]] = {}

        self.stdout.write(self.style.SUCCESS("Enforcer started. Press Ctrl+C to stop."))

        try:
            while True:
                now = timezone.localtime()
                channels = list(Channel.objects.filter(enabled=True))
                # Preload enabled targets for all channels in one query (avoids per-job .get())
                targets_by_id = {
                    t.id: t
                    for t in OutputTarget.objects.filter(channel__in=channels, enabled=True)
                }

                desired_jobs: Dict[JobKey, str] = {}

                # Reap any processes that exited on their own (prevents zombies)
                for key, p in list(running.items()):
                    rc = p.poll()
                    if rc is not None:
                        self.stdout.write(
                            self.style.WARNING(f"ffmpeg exited for {key} (rc={rc}). See media/logs/ffmpeg/*.log"))
                        _stop_and_reap(p)
                        running.pop(key, None)
                        last_cmd.pop(key, None)

                for chan in channels:
                    if not chan.is_active_now(now):
                        continue

                    # Delay logic
                    tsp = getattr(chan, "timeshift_profile", None)
                    enabled_prof = bool(tsp and getattr(tsp, "enabled", False))
                    delay_seconds = int(getattr(tsp, "delay_seconds", 0) or 0) if tsp else 0

                    # NEW: targets (multi output)
                    targets = list(OutputTarget.objects.filter(channel=chan, enabled=True))
                    has_targets = len(targets) > 0

                    # LIVE mode: playback only (no recording)
                    if has_targets and (not enabled_prof or delay_seconds <= 0):
                        for t in targets:
                            key_play: JobKey = (JobPurpose.PLAYBACK, chan.id, t.id)
                            desired_jobs[key_play] = f"{chan.name} [LIVE playback -> target {t.id}]"

                    # TIME-SHIFT mode: record + delayed playback
                    if enabled_prof and delay_seconds > 0:
                        key_rec: JobKey = (JobPurpose.RECORD, chan.id, None)
                        desired_jobs[key_rec] = f"{chan.name} [record]"

                        if has_targets:
                            for t in targets:
                                key_play: JobKey = (JobPurpose.PLAYBACK, chan.id, t.id)
                                desired_jobs[key_play] = f"{chan.name} [timeshift playback -> target {t.id}]"

                # START / RESTART missing or changed
                for key, descr in desired_jobs.items():
                    proc = running.get(key)

                    # If running, check if command changed (target url/profile/etc.)
                    if proc is not None and proc.poll() is None:
                        purpose, channel_id, target_id = key
                        if purpose == JobPurpose.PLAYBACK:
                            this_chan = next(c for c in channels if c.id == channel_id)
                            t = targets_by_id.get(target_id)
                            if not t:
                                # Target was disabled/deleted between loops; treat as not desired
                                logger.info("Skipping job for missing target_id=%s", target_id)
                                continue

                            try:
                                desired_cmd = FFmpegJobConfig(
                                    channel=this_chan,
                                    purpose=purpose,
                                    output_target=t,
                                ).build_command()
                            except Exception:
                                desired_cmd = None

                            prev = last_cmd.get(key)
                            if desired_cmd and prev and desired_cmd != prev:
                                self.stdout.write(self.style.WARNING(
                                    f"Restarting ffmpeg for {descr} (command changed)..."
                                ))
                                _stop_and_reap(proc)
                                running.pop(key, None)
                                last_cmd.pop(key, None)
                                # fall through to start
                            else:
                                if desired_cmd and not prev:
                                    last_cmd[key] = desired_cmd
                                continue
                        else:
                            # record: keep running unless it died
                            continue

                    # Start job
                    purpose, channel_id, target_id = key
                    chan = next(c for c in channels if c.id == channel_id)

                    try:
                        if purpose == JobPurpose.PLAYBACK:
                            t = targets_by_id.get(target_id)
                            if not t:
                                # Target was disabled/deleted between loops; treat as not desired
                                logger.info("Skipping job for missing target_id=%s", target_id)
                                continue
                            job = FFmpegJobConfig(channel=chan, purpose=purpose, output_target=t)
                        else:
                            job = FFmpegJobConfig(channel=chan, purpose=purpose)

                        cmd = job.build_command()
                    except FileNotFoundError as e:
                        self.stdout.write(self.style.WARNING(f"Skipping {descr} (not ready yet): {e}"))
                        continue
                    except Exception as e:
                        self.stdout.write(self.style.WARNING(f"Skipping {descr} (build error): {e}"))
                        continue

                    self.stdout.write(self.style.SUCCESS(f"Starting ffmpeg for {descr}: {' '.join(cmd)}"))
                    try:
                        log_dir = Path(settings.MEDIA_ROOT) / "logs" / "ffmpeg"
                        log_dir.mkdir(parents=True, exist_ok=True)

                        purpose, channel_id, target_id = key
                        suffix = f"ch{channel_id}_{purpose}_t{target_id or 'none'}"
                        log_path = log_dir / f"ffmpeg_{suffix}.log"

                        # Append mode so logs survive restarts
                        err_fh = open(log_path, "a", encoding="utf-8", buffering=1)

                        proc = subprocess.Popen(
                            cmd,
                            stdout=subprocess.DEVNULL,
                            stderr=err_fh,
                            start_new_session=True,
                        )

                    except Exception as e:
                        self.stdout.write(self.style.WARNING(f"Failed to start ffmpeg for {descr}: {e}"))
                        continue

                    running[key] = proc
                    last_cmd[key] = cmd

                # STOP no longer desired
                for key, proc in list(running.items()):
                    if key not in desired_jobs:
                        purpose, channel_id, target_id = key
                        self.stdout.write(self.style.WARNING(
                            f"Stopping ffmpeg for channel_id={channel_id}, purpose={purpose}, target_id={target_id}..."
                        ))
                        # Always reap (even if already exited)
                        _stop_and_reap(proc)
                        running.pop(key, None)
                        last_cmd.pop(key, None)

                # Auto-delete (optional; keep your current logic)
                for chan in channels:
                    if not chan.auto_delete_enabled:
                        continue
                    try:
                        self._auto_delete_for_channel(chan, now)
                    except Exception as e:
                        self.stdout.write(self.style.WARNING(f"Auto-delete warning for {chan.name}: {e}"))

                time.sleep(self.POLL_INTERVAL)

        except KeyboardInterrupt:
            self.stdout.write(self.style.WARNING("Enforcer stopping (Ctrl+C)..."))
            for key, proc in running.items():
                purpose, channel_id, target_id = key
                self.stdout.write(self.style.WARNING(
                    f"Terminating ffmpeg for channel_id={channel_id}, purpose={purpose}, target_id={target_id}..."
                ))
                _stop_and_reap(proc)
            self.stdout.write(self.style.SUCCESS("Enforcer stopped."))

