# transcoder/ffmpeg_runner.py
import re
import shlex
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional, Tuple

from django.conf import settings
from django.utils import timezone

from transcoder.streaming.url_utils import build_udp_url
from .models import AudioMode, Channel, TimeShiftProfile, VideoMode, OutputTarget, OutputProfile, InputType


@dataclass
class FFmpegJobConfig:
    channel: Channel
    purpose: str
    output_target: OutputTarget | None = None  # "record" or "playback"

    def build_command(self) -> List[str]:
        """
        Build an ffmpeg command for this channel & purpose.

        Purposes:
        - record:
            Reads from live input and writes TS segments to disk.
        - playback:
            Outputs a UDP MPEG-TS stream to a specific OutputTarget.
            If delay_seconds > 0 -> reads from recorded segments (concat playlist window).
            If delay_seconds == 0 -> streams live input directly.
        """
        chan = self.channel
        profile = getattr(chan, "output_profile", None) or OutputProfile.get_default_copy()

        # Common header
        args: List[str] = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "warning"]

        # ------------------------
        # RECORD
        # ------------------------
        if self.purpose == "record":
            args += self._build_live_input_args()

            is_internal_gen = (chan.input_type == InputType.INTERNAL_GENERATOR)

            self._apply_av_modes(args, profile=profile, is_internal_gen=is_internal_gen)

            # Segment output (record to disk)
            self._build_record_output(args)
            return args

        # ------------------------
        # PLAYBACK (per target)
        # ------------------------
        if self.purpose == "playback":
            if not self.output_target:
                raise ValueError("For playback, FFmpegJobConfig.output_target is required.")

            # Resolve delay_seconds (support either a TimeShiftProfile, or channel field if you add one)
            delay_seconds = 0
            tsp = getattr(chan, "timeshift_profile", None)
            if tsp is not None:
                delay_seconds = int(getattr(tsp, "delay_seconds", 0) or 0)
                enabled = bool(getattr(tsp, "enabled", True))
                if delay_seconds > 0 and not enabled:
                    raise ValueError("Time-shift profile is not enabled for delayed playback.")
            else:
                # Optional fallback if you later add channel.timeshift_delay_seconds
                delay_seconds = int(getattr(chan, "timeshift_delay_seconds", 0) or 0)

            if delay_seconds > 24 * 60 * 60:
                raise ValueError("delay_seconds must be <= 86400 (24h).")

            output_udp_url = build_udp_url(profile=profile, target=self.output_target)

            # If delay=0 => LIVE output from live input
            if delay_seconds <= 0:
                args += self._build_live_input_args()

                is_internal_gen = (chan.input_type == InputType.INTERNAL_GENERATOR)
                self._apply_av_modes(args, profile=profile, is_internal_gen=is_internal_gen)

                args += [
                    "-f", "mpegts",
                    "-mpegts_flags", "+resend_headers",
                    "-muxdelay", "0",
                    "-muxpreload", "0",
                    output_udp_url,
                ]
                return args

            # If delay>0 => delayed playback from recorded segments window
            playlist_path = self._build_playback_concat_playlist(delay_seconds)

            args += [
                "-re",
                "-f", "concat",
                "-safe", "0",
                "-i", str(playlist_path),

                "-c:v", "copy",
                "-c:a", "copy",
            ]

            # Apply COPY/ENCODE modes here too (Phase 3 requirement)
            # Internal generator cannot reach this branch (delay>0 uses recorded segments),
            # so is_internal_gen=False is correct.
            self._apply_av_modes(args, profile=profile, is_internal_gen=False)

            args += [
                "-f", "mpegts",
                "-mpegts_flags", "+resend_headers",
                "-muxdelay", "0",
                "-muxpreload", "0",
                output_udp_url,
            ]
            return args

        raise ValueError(f"Unknown purpose: {self.purpose!r}")

    # ------------------------
    # Inputs
    # ------------------------
    def _build_live_input_args(self) -> List[str]:
        """
        Build ffmpeg input arguments for recording.

        - FILE: relative paths resolved under MEDIA_ROOT
        - UDP multicast: adds fifo_size/overrun tuning if missing
        - RTSP/RTMP: used as-is
        - INTERNAL_GENERATOR: lavfi test bars + sine tone (works everywhere)
        """
        chan = self.channel
        raw_input_url = (chan.input_url or "").strip()

        if chan.input_type == InputType.INTERNAL_GENERATOR:
            return [
                "-re",
                "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25",
                "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000",
                "-shortest",
                "-map", "0:v:0",
                "-map", "1:a:0",
            ]

        if chan.input_type == InputType.FILE:
            in_path = Path(raw_input_url)
            if not in_path.is_absolute():
                in_path = Path(settings.MEDIA_ROOT) / in_path
            args = []
            profile = getattr(chan, "output_profile", None) or OutputProfile.get_default_copy()
            if getattr(profile, "realtime_input", False):
                args += ["-re"]
            if getattr(profile, "loop_input", False):
                args += ["-stream_loop", "-1"]
            args += ["-i", str(in_path)]
            return args

        if chan.input_type == InputType.MULTICAST_UDP:
            input_url = raw_input_url
            if "fifo_size=" not in input_url:
                sep = "&" if "?" in input_url else "?"
                input_url = f"{input_url}{sep}fifo_size=1000000&overrun_nonfatal=1"
            return ["-i", input_url]

        return ["-i", raw_input_url]


    # ------------------------
    # A/V modes (COPY vs ENCODE)
    # ------------------------
    def _apply_av_modes(self, args: List[str], *, profile: OutputProfile, is_internal_gen: bool) -> None:
        """
        Apply video/audio COPY vs ENCODE based on OutputProfile.
        Phase 3: ENCODE uses CPU libx264 + AAC (HW fallback comes later).
        PC/TV stability goals:
          - repeat headers in TS
          - yuv420p
          - zerolatency tune for live UDP
        """
        # ---- Video ----
        vid_mode = getattr(profile, "video_mode", VideoMode.COPY)
        vid_codec = (getattr(profile, "video_codec", "") or "libx264").strip()

        # Internal generator MUST be encoded (no streamcopy possible)
        if (not is_internal_gen) and (vid_mode == VideoMode.COPY):
            args += ["-c:v", "copy"]
        else:
            args += ["-c:v", vid_codec]

            # Filters (only meaningful when encoding)
            vf_parts: List[str] = []
            sw = getattr(profile, "scale_width", None)
            sh = getattr(profile, "scale_height", None)
            if sw and sh:
                vf_parts.append(f"scale={int(sw)}:{int(sh)}")
            fps = getattr(profile, "fps_limit", None)
            if fps:
                vf_parts.append(f"fps={int(fps)}")
            if vf_parts:
                args += ["-vf", ",".join(vf_parts)]

            # x264 tuning for UDP stability (and internal gen)
            if vid_codec == "libx264":
                preset = (getattr(profile, "x264_preset", "") or "veryfast").strip()
                tune = (getattr(profile, "x264_tune", "") or "zerolatency").strip()
                gop = getattr(profile, "gop_size", None) or 50
                args += [
                    "-preset", preset,
                    "-tune", tune,
                    "-pix_fmt", "yuv420p",
                    "-g", str(int(gop)),
                    "-x264-params", "repeat-headers=1",
                ]

                # Optional rate control
                vb = getattr(profile, "video_bitrate_k", None)
                if vb:
                    args += ["-b:v", f"{int(vb)}k"]
                    vmax = getattr(profile, "video_maxrate_k", None)
                    vbuf = getattr(profile, "video_bufsize_k", None)
                    if vmax:
                        args += ["-maxrate", f"{int(vmax)}k"]
                    if vbuf:
                        args += ["-bufsize", f"{int(vbuf)}k"]

        # ---- Audio ----
        aud_mode = getattr(profile, "audio_mode", AudioMode.COPY)

        if (not is_internal_gen) and (aud_mode == AudioMode.COPY):
            args += ["-c:a", "copy"]
            return

        if aud_mode == AudioMode.DISABLE:
            args += ["-an"]
            return

        # Encode audio (internal gen always encodes)
        aud_codec = (getattr(profile, "audio_codec", "") or "aac").strip()
        args += ["-c:a", aud_codec]
        if aud_codec == "aac":
            abr = getattr(profile, "audio_bitrate_k", None) or 128
            args += ["-b:a", f"{int(abr)}k", "-ac", "2"]


    # ------------------------
    # Record output
    # ------------------------
    def _build_record_output(self, args: List[str]) -> None:
        """
        Write TS segments under MEDIA_ROOT with timestamped filenames.
        Example: ChannelName_YYYYMMDD-HHMMSS.ts
        """
        chan = self.channel
        now = datetime.now()
        date_str = now.strftime("%Y%m%d")

        base_dir_str = chan.recording_path_template.format(
            channel=chan.name,
            date=date_str,
            time=now.strftime("%H%M%S"),
        )
        base_dir = Path(base_dir_str)
        if not base_dir.is_absolute():
            base_dir = Path(settings.MEDIA_ROOT) / base_dir

        base_dir.mkdir(parents=True, exist_ok=True)

        segment_seconds = chan.recording_segment_minutes * 60
        segment_pattern = str(base_dir / f"{chan.name}_%Y%m%d-%H%M%S.ts")

        args += [
            "-f", "segment",
            "-segment_time", str(segment_seconds),
            "-reset_timestamps", "1",
            "-strftime", "1",
            segment_pattern,
        ]

    # ------------------------
    # Playback playlist builder
    # ------------------------
    def _iter_recording_segments(self) -> List[Tuple[datetime, Path]]:
        """
        Return a sorted list of (timestamp, path) for TS segments for this channel.
        Timestamp is parsed from filenames like: <channel>_YYYYMMDD-HHMMSS.ts
        Falls back to mtime if parsing fails.
        """
        chan = self.channel

        tmpl = chan.recording_path_template
        try:
            root_str = tmpl.format(channel=chan.name, date="", time="")
        except Exception:
            root_str = tmpl

        root = Path(root_str)
        if not root.is_absolute():
            root = Path(settings.MEDIA_ROOT) / root

        if not root.exists():
            root = Path(settings.MEDIA_ROOT) / "recordings" / chan.name

        candidates = list(root.glob("**/*.ts"))
        items: List[Tuple[datetime, Path]] = []

        rx = re.compile(rf"^{re.escape(chan.name)}_(\d{{8}})-(\d{{6}})\.ts$")

        for p in candidates:
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
        return items

    def _build_playback_concat_playlist(self, delay_seconds: int) -> Path:
        """
        Build a finite concat playlist window that ENDS at the delayed timestamp.

        Important:
        - We must NOT include segments newer than the delayed target time.
          If we do, playback will drift toward "live" as soon as any new segment exists
          (including the currently-being-written segment), making a 1-minute delay look
          like only a few seconds.
        - Therefore, the playlist is chosen from [target-window, target].

        Enforcer will restart playback after it exits, which keeps playback continuous.
        """
        window_seconds = int(getattr(settings, "PLAYBACK_PLAYLIST_WINDOW_SECONDS", 3 * 3600))

        # localtime -> make naive for filename timestamps
        now = timezone.localtime().replace(tzinfo=None)
        target = now - timedelta(seconds=delay_seconds)

        # Choose a historical window that ENDS at the target (delayed) time.
        start_ts = target - timedelta(seconds=window_seconds)
        end_ts = target

        segments = self._iter_recording_segments()
        # Only pick segments that are not newer than the delayed target.
        chosen = [p for (ts, p) in segments if (start_ts <= ts <= end_ts)]

        if not chosen:
            raise FileNotFoundError(
                f"No TS segments found for playback yet for channel {self.channel.name!r} "
                f"(delay={delay_seconds}s, window={window_seconds}s). "
                f"Recording may still be warming up; enforcer will retry."
            )

        out_dir = Path(settings.MEDIA_ROOT) / "playlists" / f"channel_{self.channel.id}"
        out_dir.mkdir(parents=True, exist_ok=True)
        playlist_path = out_dir / "concat.txt"

        lines = [f"file {shlex.quote(str(p))}" for p in chosen]
        playlist_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return playlist_path
