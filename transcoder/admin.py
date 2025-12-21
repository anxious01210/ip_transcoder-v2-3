from datetime import timedelta
import os, signal, sys, subprocess, shlex
from django.conf import settings
from django.contrib import admin, messages
from django.http import HttpRequest, HttpResponseRedirect
from django.urls import path, reverse
from django.utils import timezone

from .models import Channel, InputType, TimeShiftProfile, OutputProfile, OutputTarget
from .models import VideoMode, AudioMode

from django.utils.html import format_html, format_html_join
from django.utils.safestring import mark_safe


# class OutputTargetInline(admin.TabularInline):
#     model = OutputTarget
#     extra = 0
#     fields = ("enabled", "name", "target_url", "pkt_size", "overrun_nonfatal", "ttl")
#     ordering = ("id",)
class OutputTargetInline(admin.TabularInline):
    model = OutputTarget
    extra = 0
    fields = ("enabled", "name", "target_url", "pkt_size", "overrun_nonfatal", "ttl", "edit_popup")
    readonly_fields = ("edit_popup",)

    @admin.display(description="Edit")
    def edit_popup(self, obj):
        if not obj or not obj.pk:
            return "-"
        url = reverse("admin:transcoder_outputtarget_change", args=[obj.pk])
        # Django admin popup mode
        return format_html(
            '<a class="button" href="{}?_popup=1" onclick="return showAddAnotherPopup(this);">Edit</a>',
            url
        )

class TimeShiftProfileInline(admin.StackedInline):
    """Edit delay settings directly from the Channel page."""
    model = TimeShiftProfile
    extra = 0
    can_delete = False
    fields = ("enabled", "delay_seconds")


@admin.register(OutputProfile)
class OutputProfileAdmin(admin.ModelAdmin):
    """
    OutputProfile = HOW we build the stream (COPY vs ENCODE).
    Targets = WHERE we send it (OutputTarget).

    Admin guidance (PC/TV-first):
    - COPY is preferred when input is already stable MPEG-TS with H.264/AAC and you just restream.
    - ENCODE is preferred when:
        * input codecs are unknown/inconsistent,
        * you want stable H.264 + AAC for TVs/players,
        * you want scaling/FPS limiting,
        * or you're generating INTERNAL test stream (always encoded).
    """

    # ---------- List view ----------
    list_display = (
        "id",
        "name",
        "is_active",
        "video_mode",
        "audio_mode",
        "encoder_preference",
        "video_summary",
        "audio_summary",
        "realtime_input",
        "loop_input",
        "default_pkt_size",
        "default_overrun_nonfatal",
        "default_ttl",
        "created_at",
    )
    list_filter = ("is_active", "video_mode", "audio_mode", "encoder_preference", "realtime_input", "loop_input")
    search_fields = ("name",)
    ordering = ("name",)

    # Keep name clickable
    list_display_links = ("name",)

    # Quick edit from list (best productivity fields)
    list_editable = (
        "is_active",
        "video_mode",
        "audio_mode",
        "encoder_preference",
        "realtime_input",
        "loop_input",
    )

    # ---------- Form layout ----------
    fieldsets = (
        ("Profile Identity", {
            "fields": ("name", "is_active"),
            "description": (
                "Tip: Keep one default COPY profile for normal restreaming, and optionally one ENCODE profile "
                "for 'stable H.264 + AAC' output (best for TVs/PC players)."
            ),
        }),
        ("When to use this profile", {
            "fields": ("video_mode", "audio_mode", "encoder_preference"),
            "description": (
                "<b>Recommended:</b><br>"
                "• <b>COPY</b> when the source is already H.264/AAC in MPEG-TS and plays well.<br>"
                "• <b>ENCODE</b> when you want maximum receiver compatibility (TV/PC), or input codecs vary.<br>"
                "• <b>Internal Generator</b> (test channel) is always encoded regardless of COPY settings."
            ),
        }),
        ("FILE input behavior (only for input_type=FILE)", {
            "fields": ("realtime_input", "loop_input"),
            "description": (
                "• <b>realtime_input</b> adds <code>-re</code> so file playback behaves like a live stream "
                "(recommended for 'live file channel').<br>"
                "• <b>loop_input</b> adds <code>-stream_loop -1</code> to loop forever."
            ),
        }),
        ("Video encoding (only used when video_mode=ENCODE)", {
            "fields": (
                "video_codec",
                ("x264_preset", "x264_tune"),
                ("video_bitrate_k", "video_maxrate_k", "video_bufsize_k"),
                ("gop_size", "fps_limit"),
                ("scale_width", "scale_height"),
            ),
            "description": (
                "<b>PC/TV stability defaults:</b> libx264 + yuv420p + repeat headers + zerolatency.<br>"
                "Suggested starting point: video_bitrate_k=2500–5000, gop_size=50 (for 25fps).<br>"
                "Leave blank to use ffmpeg defaults."
            ),
        }),
        ("Audio encoding (used when audio_mode=ENCODE)", {
            "fields": ("audio_codec", "audio_bitrate_k"),
            "description": (
                "<b>Recommended for compatibility:</b> AAC at 128k or 192k.<br>"
                "If audio_mode=COPY, audio_codec/audio_bitrate are ignored."
            ),
        }),
        ("UDP output defaults (applied when target_url lacks params)", {
            "fields": ("default_pkt_size", "default_overrun_nonfatal", "default_ttl"),
            "description": (
                "These are used as defaults when an OutputTarget leaves the override fields blank "
                "and when the target_url does not already contain those query parameters."
            ),
        }),
        ("Timestamps", {
            "fields": ("created_at",),
        }),
    )

    readonly_fields = ("created_at",)

    # ---------- Summaries ----------
    @admin.display(description="Video")
    def video_summary(self, obj: OutputProfile) -> str:
        if obj.video_mode == VideoMode.COPY:
            return "COPY (no re-encode)"

        parts = []
        if getattr(obj, "video_codec", None):
            parts.append(obj.video_codec)

        vb = getattr(obj, "video_bitrate_k", None)
        if vb:
            parts.append(f"{vb}k")

        sw = getattr(obj, "scale_width", None)
        sh = getattr(obj, "scale_height", None)
        if sw and sh:
            parts.append(f"{sw}x{sh}")

        fps = getattr(obj, "fps_limit", None)
        if fps:
            parts.append(f"{fps}fps")

        return "ENCODE: " + (" / ".join(parts) if parts else "defaults")

    @admin.display(description="Audio")
    def audio_summary(self, obj: OutputProfile) -> str:
        mode = getattr(obj, "audio_mode", AudioMode.COPY) or AudioMode.COPY

        if mode == AudioMode.COPY:
            return "COPY (no re-encode)"
        if mode == AudioMode.DISABLE:
            return "DISABLED"

        # ENCODE
        codec = (getattr(obj, "audio_codec", "") or "aac").strip()
        br = getattr(obj, "audio_bitrate_k", None) or 128
        return f"ENCODE: {codec} {br}k"


@admin.register(OutputTarget)
class OutputTargetAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "channel", "enabled", "protocol", "target_url", "overrun_nonfatal", "fifo_size",
                    "buffer_size", "pkt_size", "ttl", "created_at")
    list_filter = ("enabled", "protocol")
    search_fields = ("name", "target_url", "channel__name")
    list_display_links = ("name",)
    # Editable in list view (no legacy output fields)
    list_editable = ["enabled", "target_url", "overrun_nonfatal", "fifo_size", "buffer_size", "pkt_size", "protocol",
                     "ttl"]


@admin.register(Channel)
class ChannelAdmin(admin.ModelAdmin):
    @admin.display(description="Primary target")
    def primary_target(self, obj: Channel):
        t = obj.output_targets.filter(enabled=True).order_by("id").first()
        return (t.target_url if t else "-")

    def save_model(self, request, obj, form, change):
        # Ensure new channels default to COPY profile (requested)
        if obj.output_profile_id is None:
            prof, _ = OutputProfile.objects.get_or_create(
                name="Default (Copy)",
                defaults={
                    "is_active": True,
                    "video_mode": "copy",
                    "encoder_preference": "cpu_only",
                    "audio_mode": "copy",
                    "default_pkt_size": 1316,
                    "default_overrun_nonfatal": True,
                },
            )
            obj.output_profile = prof
        super().save_model(request, obj, form, change)

        if obj.output_targets.count() == 0:
            # No legacy bootstrap: always seed from TEST_CHANNEL_OUTPUT_URL (or default).
            OutputTarget.objects.create(
                channel=obj,
                name="Target 1",
                enabled=True,
                protocol="udp_mpegts",
                target_url=self._test_output_url(),
                pkt_size=None,  # inherit profile
                overrun_nonfatal=None,  # inherit profile
                ttl=None,
            )

    change_list_template = "admin/transcoder/channel/change_list.html"

    @admin.display(description="Output targets")
    def output_targets_list(self, obj):
        """
        Show all OutputTargets:
        - Enabled first (green)
        - Disabled after (red)
        """
        qs = obj.output_targets.all().order_by("-enabled", "id")
        # qs = obj.output_targets.filter(enabled=True).order_by("id") # Show only enabled targets
        if not qs.exists():
            return "-"

        rows = []
        for t in qs:
            if t.enabled:
                # Green for enabled
                label = format_html(
                    '<span style="color:#3fb950; font-weight:500;">{}</span>',
                    t.target_url,
                )
            else:
                # Red for disabled
                label = format_html(
                    # '<span style="color:#f85149;">{} (disabled)</span>',
                    '<span style="color:#f85149;">{}</span>',
                    t.target_url,
                )

            rows.append((label,))

        return format_html_join(mark_safe("<br>"), "{}", rows)

    def get_queryset(self, request):
        qs = super().get_queryset(request)
        return qs.prefetch_related("output_targets")

    list_display = (
        "id",
        "enabled",
        "name",
        "is_test_channel",
        "input_type",
        "input_url",
        # "primary_target",
        "output_targets_list",
        "auto_delete_enabled",
        "playback_tail_enabled",
    )
    search_fields = ("name", "input_url")
    list_display_links = ("name",)
    # Editable in list view (no legacy output fields)
    list_editable = ["enabled", "input_type", "input_url"]
    list_filter = (
        "enabled",
        "input_type",
        "auto_delete_enabled",
        "playback_tail_enabled",
    )

    inlines = [TimeShiftProfileInline, OutputTargetInline]

    fieldsets = (
        ("Basics", {"fields": ("name", "enabled", "is_test_channel")}),
        ("Input", {"fields": ("input_type", "input_url", "multicast_interface")}),
        ("Output Profile & Playback tail", {"fields": ("output_profile", "playback_tail_enabled")}),
        ("Schedule", {
            "fields": (
                ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"),
                ("start_time", "end_time"),
                ("date_from", "date_to"),
            )
        }),
        ("Recording & Auto-delete", {
            "fields": (
                "recording_path_template",
                "recording_segment_minutes",
                "auto_delete_enabled",
                "auto_delete_after_segments",
                "auto_delete_after_days",
            )
        }),
        ("Timestamps", {"fields": ("created_at", "updated_at")}),
    )

    readonly_fields = ("created_at", "updated_at")

    def _get_ts_profile(self, chan: Channel):
        # supports either related_name="timeshift_profile" OR Django default "timeshiftprofile"
        return (
                getattr(chan, "timeshift_profile", None)
                or getattr(chan, "timeshiftprofile", None)
        )

    def timeshift_delay(self, obj: Channel):
        prof = self._get_ts_profile(obj)
        if not prof or not getattr(prof, "enabled", False):
            return "-"

        sec = int(getattr(prof, "delay_seconds", 0) or 0)
        if sec <= 0:
            return "LIVE (0s)"

        # show as H:MM:SS
        h = sec // 3600
        m = (sec % 3600) // 60
        s = sec % 60
        if h > 0:
            return f"{h}h {m:02d}m {s:02d}s"
        if m > 0:
            return f"{m}m {s:02d}s"
        return f"{s}s"

    timeshift_delay.short_description = "Delay"
    timeshift_delay.admin_order_field = "timeshiftprofile__delay_seconds"

    # ------------------------
    # Admin tools (no JS)
    # ------------------------
    def get_urls(self):
        """
        IMPORTANT: our custom URLs must come BEFORE the default ModelAdmin URLs,
        otherwise 'tools/...' can be interpreted as <object_id>.
        """
        urls = super().get_urls()
        my_urls = [
            path(
                "tools/create-test/",
                self.admin_site.admin_view(self.create_test_channel_view),
                name="transcoder_channel_create_test",
            ),
            path(
                "tools/delete-test/",
                self.admin_site.admin_view(self.delete_test_channel_view),
                name="transcoder_channel_delete_test",
            ),
            path(
                "tools/start-test/",
                self.admin_site.admin_view(self.start_test_channel_view),
                name="transcoder_channel_start_test",
            ),
            path(
                "tools/stop-test/",
                self.admin_site.admin_view(self.stop_test_channel_view),
                name="transcoder_channel_stop_test",
            ),
        ]
        return my_urls + urls

    def _changelist_redirect(self) -> HttpResponseRedirect:
        return HttpResponseRedirect(reverse("admin:transcoder_channel_changelist"))

    def _ensure_superuser(self, request: HttpRequest) -> bool:
        if not request.user.is_superuser:
            self.message_user(request, "Superuser permission required.", level=messages.ERROR)
            return False
        return True

    def _test_output_url(self) -> str:
        return getattr(settings, "TEST_CHANNEL_OUTPUT_URL", "udp://127.0.0.1:5002")

    def _get_test_channel(self):
        return Channel.objects.filter(is_test_channel=True).order_by("-id").first()

    def _build_test_defaults(self):
        now = timezone.localtime()
        today = now.date()
        return {
            "name": "__TEST__ Internal Generator",
            "enabled": False,
            "is_test_channel": True,
            "input_type": InputType.INTERNAL_GENERATOR,
            "input_url": "internal://generator",
            "recording_segment_minutes": 1,
            "auto_delete_enabled": True,
            "auto_delete_after_segments": 5,
            "auto_delete_after_days": None,
            "monday": True,
            "tuesday": True,
            "wednesday": True,
            "thursday": True,
            "friday": True,
            "saturday": True,
            "sunday": True,
            "start_time": None,
            "end_time": None,
            "date_from": today,
            "date_to": today + timedelta(days=2),
        }

    def create_test_channel_view(self, request):
        if not self._ensure_superuser(request):
            return self._changelist_redirect()

        # delete existing test channel if you want, or keep one
        chan = self._get_test_channel()
        if chan:
            self.message_user(request, "Test channel already exists.", level=messages.WARNING)
            return self._changelist_redirect()

        profile = OutputProfile.get_default_copy()

        defaults = self._build_test_defaults()
        defaults.pop("output_profile", None)  # just in case (safe)
        chan = Channel.objects.create(
            **defaults,
            output_profile=profile,
        )

        # create the default target from settings
        OutputTarget.objects.create(
            channel=chan,
            name="Target 1",
            enabled=True,
            protocol="udp_mpegts",
            target_url=self._test_output_url(),  # e.g. udp://127.0.0.1:5002
            pkt_size=None,  # IMPORTANT -> inherit from profile
            overrun_nonfatal=None,  # IMPORTANT -> inherit from profile
        )

        self.message_user(request, f"Test channel created (id={chan.id}).", level=messages.SUCCESS)
        return self._changelist_redirect()

    def delete_test_channel_view(self, request: HttpRequest):
        if request.method != "POST":
            return self._changelist_redirect()
        if not self._ensure_superuser(request):
            return self._changelist_redirect()

        chan = self._get_test_channel()
        if not chan:
            self.message_user(request, "No test channel found.", level=messages.WARNING)
            return self._changelist_redirect()

        cid = chan.id
        chan.delete()
        self.message_user(request, f"Deleted test channel (id={cid}).", level=messages.SUCCESS)
        return self._changelist_redirect()

    def start_test_channel_view(self, request: HttpRequest):
        if request.method != "POST":
            return self._changelist_redirect()
        if not self._ensure_superuser(request):
            return self._changelist_redirect()

        chan = self._get_test_channel()
        if not chan:
            self.message_user(request, "No test channel found. Create it first.", level=messages.ERROR)
            return self._changelist_redirect()

        # Enable channel only. Enforcer will start playback for ALL enabled OutputTargets.
        chan.enabled = True
        chan.save(update_fields=["enabled"])

        enabled_targets = list(chan.output_targets.filter(enabled=True).order_by("id"))
        if not enabled_targets:
            self.message_user(
                request,
                "Test channel enabled, but it has no enabled OutputTargets. Enable/create at least one target.",
                level=messages.WARNING,
            )
            return self._changelist_redirect()

        self.message_user(
            request,
            f"Started test channel (id={chan.id}). Enforcer should start {len(enabled_targets)} output target(s).",
            level=messages.SUCCESS,
        )
        return self._changelist_redirect()

    def stop_test_channel_view(self, request: HttpRequest):
        if request.method != "POST":
            return self._changelist_redirect()
        if not self._ensure_superuser(request):
            return self._changelist_redirect()

        chan = self._get_test_channel()
        if not chan:
            self.message_user(request, "No test channel found.", level=messages.ERROR)
            return self._changelist_redirect()

        # Disable only. Enforcer will stop all per-target processes.
        chan.enabled = False
        chan.save(update_fields=["enabled"])

        self.message_user(
            request,
            f"Stopped test channel (id={chan.id}). Enforcer should terminate its ffmpeg processes.",
            level=messages.SUCCESS,
        )
        return self._changelist_redirect()

    # ------------------------
    # Display helper
    # ------------------------
    @admin.display(description="Schedule")
    def schedule_summary(self, obj: Channel) -> str:
        days = []
        if obj.monday:
            days.append("Mon")
        if obj.tuesday:
            days.append("Tue")
        if obj.wednesday:
            days.append("Wed")
        if obj.thursday:
            days.append("Thu")
        if obj.friday:
            days.append("Fri")
        if obj.saturday:
            days.append("Sat")
        if obj.sunday:
            days.append("Sun")
        days_text = ",".join(days) if days else "-"

        if obj.start_time and obj.end_time:
            time_text = f"{obj.start_time.strftime('%H:%M')}–{obj.end_time.strftime('%H:%M')}"
        else:
            time_text = "Full day"

        date_from = obj.date_from.isoformat() if obj.date_from else "any"
        date_to = obj.date_to.isoformat() if obj.date_to else "any"
        return f"{days_text} {time_text} [{date_from} → {date_to}]"
