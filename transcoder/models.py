from __future__ import annotations

import datetime
from django.db import models
from django.utils import timezone
from django.core.validators import MaxValueValidator
from django.utils.translation import gettext_lazy as _


class InputType(models.TextChoices):
    MULTICAST_UDP = "udp_multicast", "UDP Multicast (MPEG-TS)"
    RTSP = "rtsp", "RTSP"
    RTMP = "rtmp", "RTMP"
    FILE = "file", "File"
    INTERNAL_GENERATOR = "internal_gen", "Internal Generator (Test)"


class OutputType(models.TextChoices):
    UDP_TS = "udp_ts", "UDP TS Unicast"
    HLS = "hls", "HLS (m3u8)"
    RTMP = "rtmp", "RTMP"
    FILE_TS = "file_ts", "File (TS)"
    FILE_MP4 = "file_mp4", "File (MP4)"


class VideoMode(models.TextChoices):
    COPY = "copy", "Copy (no re-encode)"
    ENCODE = "encode", "Encode (re-encode)"


class AudioMode(models.TextChoices):
    COPY = "copy", "Copy (no re-encode)"
    ENCODE = "encode", "Encode (re-encode)"
    DISABLE = "disable", "Disable (no audio)"


class X264Preset(models.TextChoices):
    # Practical presets for real-time systems (avoid placebo)
    ULTRAFAST = "ultrafast", _("ultrafast")
    SUPERFAST = "superfast", _("superfast")
    VERYFAST = "veryfast", _("veryfast")
    FASTER = "faster", _("faster")
    FAST = "fast", _("fast")
    MEDIUM = "medium", _("medium")
    SLOW = "slow", _("slow")
    SLOWER = "slower", _("slower")
    VERYSLOW = "veryslow", _("veryslow")


class X264Tune(models.TextChoices):
    # Practical tunes (UDP live: zerolatency is usually best)
    ZEROLATENCY = "zerolatency", _("zerolatency")
    FASTDECODE = "fastdecode", _("fastdecode")
    FILM = "film", _("film")
    ANIMATION = "animation", _("animation")
    GRAIN = "grain", _("grain")
    STILLIMAGE = "stillimage", _("stillimage")


class JobPurpose(models.TextChoices):
    RECORD = "record", "Record"
    PLAYBACK = "playback", "Playback (time-shift)"


class EncoderPreference(models.TextChoices):
    AUTO = "auto", "Auto (NVENC → QSV → CPU)"
    NVIDIA_FIRST = "nvidia_first", "NVIDIA first (NVENC → QSV → CPU)"
    INTEL_FIRST = "intel_first", "Intel first (QSV → NVENC → CPU)"
    CPU_ONLY = "cpu_only", "CPU only"


class OutputProfile(models.Model):
    """Defines HOW a stream is produced (copy vs encode). Phase 3 uses COPY/ENCODE only (HW fallback comes later)."""

    name = models.CharField(max_length=120, unique=True)
    is_active = models.BooleanField(default=True, db_index=True)

    video_mode = models.CharField(max_length=20, choices=VideoMode.choices, default=VideoMode.COPY)
    encoder_preference = models.CharField(
        max_length=30,
        choices=EncoderPreference.choices,
        default=EncoderPreference.AUTO,
        help_text="Used in Phase 4 for NVENC/QSV/CPU fallback. In Phase 3, ENCODE uses CPU (libx264).",
    )

    # FILE input behavior
    realtime_input = models.BooleanField(
        default=False,
        help_text="For FILE inputs, add -re to pace input in real-time (recommended for 'live file playback').",
    )
    loop_input = models.BooleanField(
        default=False,
        help_text="For FILE inputs, add -stream_loop -1 to loop indefinitely.",
    )

    # Encoding settings (Phase 3 keeps this minimal; extended in later phases)
    video_codec = models.CharField(max_length=50, blank=True, default="libx264",
                                   help_text="When encoding video, e.g. libx264")
    audio_mode = models.CharField(max_length=20, choices=AudioMode.choices, default=AudioMode.COPY)
    audio_codec = models.CharField(max_length=50, blank=True, default="aac", help_text="When encoding audio, e.g. aac")

    # ---- Phase 3 encode knobs (PC/TV stability first) ----
    # If blank/null -> ffmpeg defaults apply.
    video_bitrate_k = models.PositiveIntegerField(
        null=True, blank=True,
        help_text="Target video bitrate in kbits (e.g. 2500). Only used when video_mode=ENCODE.",
    )
    video_maxrate_k = models.PositiveIntegerField(
        null=True, blank=True,
        help_text="Optional maxrate in kbits for VBV (e.g. 3000). Only used when video_mode=ENCODE.",
    )
    video_bufsize_k = models.PositiveIntegerField(
        null=True, blank=True,
        help_text="Optional bufsize in kbits for VBV (e.g. 6000). Only used when video_mode=ENCODE.",
    )
    x264_preset = models.CharField(
        max_length=30,
        choices=X264Preset.choices,
        default=X264Preset.VERYFAST,
        help_text="x264 preset. Recommended: veryfast (good default), faster/fast (better quality), "
                  "superfast/ultrafast (lowest CPU). Used only when video_codec=libx264.",
    )
    x264_tune = models.CharField(
        max_length=30,
        choices=X264Tune.choices,
        default=X264Tune.ZEROLATENCY,
        help_text="x264 tune. Recommended for live UDP: zerolatency. Used only when video_codec=libx264.",
    )
    gop_size = models.PositiveIntegerField(
        null=True, blank=True,
        help_text="GOP size (e.g. 50 for 25fps). Only used when encoding.",
    )
    scale_width = models.PositiveIntegerField(
        null=True, blank=True,
        help_text="Optional scale width (must set height too). Only used when encoding.",
    )
    scale_height = models.PositiveIntegerField(
        null=True, blank=True,
        help_text="Optional scale height (must set width too). Only used when encoding.",
    )
    fps_limit = models.PositiveIntegerField(
        null=True, blank=True,
        help_text="Optional output FPS cap (e.g. 25). Only used when encoding.",
    )
    audio_bitrate_k = models.PositiveIntegerField(
        null=True, blank=True,
        help_text="Audio bitrate in kbits (e.g. 128). Only used when audio_mode=ENCODE.",
    )

    # UDP transport defaults (applied if missing in target_url; per-target fields can override)
    default_pkt_size = models.PositiveIntegerField(null=True, blank=True,
                                                   help_text="Default pkt_size for UDP output (e.g. 1316).")
    default_overrun_nonfatal = models.BooleanField(default=True,
                                                   help_text="Default overrun_nonfatal=1 for UDP outputs.")
    default_ttl = models.PositiveIntegerField(null=True, blank=True, validators=[MaxValueValidator(255)],
                                              help_text="Default TTL for multicast outputs (optional).")

    created_at = models.DateTimeField(auto_now_add=True)

    @classmethod
    def get_default_copy(cls):
        obj = cls.objects.filter(is_active=True, video_mode=VideoMode.COPY).order_by("id").first()
        if obj:
            return obj

        # Create if missing
        obj, _ = cls.objects.get_or_create(
            name="Default (Copy)",
            defaults=dict(
                is_active=True,
                video_mode=VideoMode.COPY,
                encoder_preference=EncoderPreference.CPU_ONLY,
                default_pkt_size=1316,
                default_overrun_nonfatal=True,
                default_ttl=None,
                audio_mode=AudioMode.COPY,
                video_codec="libx264",  # only used when encoding/internal gen
                audio_codec="aac",  # only used when encoding/internal gen
            ),
        )
        return obj

    class Meta:
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name

    def clean(self):
        # If one scale dimension is set, require the other too.
        if (self.scale_width is None) ^ (self.scale_height is None):
            raise ValueError("scale_width and scale_height must be set together (or both blank).")


class OutputTarget(models.Model):
    """Defines WHERE the stream is sent. One Channel can have many OutputTargets."""

    channel = models.ForeignKey("Channel", on_delete=models.CASCADE, related_name="output_targets")
    name = models.CharField(max_length=80, default="Target")
    enabled = models.BooleanField(default=True, db_index=True)
    process_pid = models.IntegerField(null=True, blank=True, editable=False)

    # For now we support UDP MPEG-TS
    protocol = models.CharField(max_length=40, default="udp_mpegts",
                                help_text="Future: srt/hls/etc. Phase 1-4 uses udp_mpegts.")
    target_url = models.CharField(max_length=500, help_text="e.g. udp://192.168.1.26:5002")

    # Per-target UDP overrides (optional)
    pkt_size = models.PositiveIntegerField(null=True, blank=True)
    overrun_nonfatal = models.BooleanField(null=True, blank=True,
                                           help_text="Override overrun_nonfatal (1/0). Leave blank to inherit profile default.")
    fifo_size = models.PositiveIntegerField(null=True, blank=True)
    buffer_size = models.PositiveIntegerField(null=True, blank=True)
    ttl = models.PositiveIntegerField(null=True, blank=True, validators=[MaxValueValidator(255)],
                                      help_text="TTL for multicast (optional).")

    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["channel_id", "id"]

    def __str__(self) -> str:
        return f"{self.channel_id}:{self.name}"


class Channel(models.Model):
    """
    v3 baseline:
    - Single mode: Record + Time-shift (delayed playback) with ONE output target.
    - Recording writes .ts segments to disk.
    - Playback restreams from recorded segments according to delay (TimeShiftProfile).
    """

    name = models.CharField(max_length=100, unique=True)

    is_test_channel = models.BooleanField(
        default=False,
        db_index=True,
        help_text="Marks a channel as an internal test channel (created from admin tools).",
    )

    output_profile = models.ForeignKey(
        "OutputProfile",
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        related_name="channels",
        help_text="Defines how the stream is produced (COPY vs ENCODE). New channels default to COPY.",
    )

    enabled = models.BooleanField(
        default=True,
        help_text="If off, enforcer will not run this channel.",
    )

    # Input
    input_type = models.CharField(
        max_length=20,
        choices=InputType.choices,
        default=InputType.MULTICAST_UDP,  # ✅ default prevents migration prompt
    )

    input_url = models.CharField(
        max_length=512,
        default="udp://@239.0.0.1:5000",  # ✅ safe placeholder for existing rows
        help_text=(
            "For multicast: e.g. udp://@239.10.10.10:5001 "
            "(fifo_size & overrun options may be added automatically). "
            "For Internal Generator, this can be internal://generator."
        ),
    )

    multicast_interface = models.CharField(
        max_length=64,
        blank=True,
        default="",
        help_text="Optional: network interface/IP for multicast receiving (advanced usage).",
    )

    # Tail behavior (your earlier requirement)
    playback_tail_enabled = models.BooleanField(
        default=False,
        help_text=(
            "If enabled: when schedule ends, recording stops immediately but playback continues "
            "until (schedule_end + delay). Useful to flush the delayed buffer."
        ),
    )

    # Recording
    recording_path_template = models.CharField(
        max_length=512,
        default="recordings/{channel}/{date}/",
        help_text=(
            "Recording path. Relative paths are under MEDIA_ROOT. "
            "Use {channel}, {date}, {time} placeholders."
        ),
    )

    recording_segment_minutes = models.PositiveIntegerField(
        default=60,
        help_text="Length of each recording segment in minutes.",
    )

    # Auto-delete (segments and/or days)
    auto_delete_enabled = models.BooleanField(
        default=False,
        help_text="If enabled, old recording segments will be deleted automatically.",
    )

    auto_delete_after_segments = models.PositiveIntegerField(
        null=True,
        blank=True,
        help_text="Keep last N segments. Leave blank to ignore.",
    )

    auto_delete_after_days = models.PositiveIntegerField(
        null=True,
        blank=True,
        help_text="Delete segments older than N days. Leave blank to ignore.",
    )

    # Weekly schedule directly on Channel
    monday = models.BooleanField(default=True)
    tuesday = models.BooleanField(default=True)
    wednesday = models.BooleanField(default=True)
    thursday = models.BooleanField(default=True)
    friday = models.BooleanField(default=True)
    saturday = models.BooleanField(default=True)
    sunday = models.BooleanField(default=True)

    start_time = models.TimeField(
        null=True,
        blank=True,
        help_text="Local start time. If blank, treated as 00:00.",
    )

    end_time = models.TimeField(
        null=True,
        blank=True,
        help_text="Local end time. If blank, treated as 00:00. If start == end -> full day.",
    )

    date_from = models.DateField(null=True, blank=True, help_text="First active date (inclusive).")
    date_to = models.DateField(null=True, blank=True, help_text="Last active date (inclusive).")

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ("name",)

    def __str__(self) -> str:
        return self.name

    def is_active_now(self, now: datetime.datetime | None = None) -> bool:
        """
        Schedule semantics:
        - If start_time == end_time (and not null)  -> active FULL day for selected weekdays.
        - If start_time < end_time                  -> active between start and end.
        - If start_time > end_time                  -> overnight window (e.g. 20:00 -> 06:00).
        - If start_time or end_time is null         -> treated as 00:00.
        """
        if not self.enabled:
            return False

        if now is None:
            now = timezone.localtime()

        local_date = now.date()
        local_time = now.time()

        # Date range check
        if self.date_from and local_date < self.date_from:
            return False
        if self.date_to and local_date > self.date_to:
            return False

        # Weekday check
        weekday = local_date.weekday()  # Mon=0..Sun=6
        weekday_flags = [
            self.monday,
            self.tuesday,
            self.wednesday,
            self.thursday,
            self.friday,
            self.saturday,
            self.sunday,
        ]
        if not weekday_flags[weekday]:
            return False

        start_time = self.start_time or datetime.time(0, 0)
        end_time = self.end_time or datetime.time(0, 0)

        if start_time == end_time:
            return True

        if start_time < end_time:
            return start_time <= local_time < end_time

        # Overnight
        return (local_time >= start_time) or (local_time < end_time)


# class TimeShiftProfile(models.Model):
#     """
#     Delay configuration for a channel.
#     Output destination is channel.output_target (single output design).
#     """
#     channel = models.OneToOneField(Channel, on_delete=models.CASCADE, related_name="timeshift_profile")
#     enabled = models.BooleanField(default=False)
#
#     delay_minutes = models.PositiveIntegerField(
#         default=60,
#         validators=[MaxValueValidator(24 * 60)],  # 0..1440
#         help_text="Delay amount in minutes (0..1440).",
#     )
#
#     created_at = models.DateTimeField(auto_now_add=True)
#     updated_at = models.DateTimeField(auto_now=True)
#
#     class Meta:
#         verbose_name = "Time-shift profile"
#         verbose_name_plural = "Time-shift profiles"
#
#     def __str__(self) -> str:
#         return f"TimeShift({self.channel.name}, {self.delay_minutes} min)"
# models.py

class TimeShiftProfile(models.Model):
    channel = models.OneToOneField(Channel, on_delete=models.CASCADE, related_name="timeshift_profile")
    enabled = models.BooleanField(default=False)

    delay_seconds = models.PositiveIntegerField(
        default=0,
        validators=[MaxValueValidator(24 * 60 * 60)],  # 0..86400
        help_text=(
            "Delay in seconds (0..86400). "
            "0 = LIVE mode (no recording, direct restream from input to output). "
            ">0 = Time-shift mode (records to disk then plays back with this delay)."
        ),
    )

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Time-shift profile"
        verbose_name_plural = "Time-shift profiles"

    def __str__(self) -> str:
        return f"TimeShift({self.channel.name}, {self.delay_seconds}s)"
