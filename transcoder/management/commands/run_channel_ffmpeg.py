# transcoder/management/commands/run_channel_ffmpeg.py
import os, shutil, subprocess
from django.core.management.base import BaseCommand, CommandError
from transcoder.ffmpeg_runner import FFmpegJobConfig
from transcoder.models import Channel


class Command(BaseCommand):
    help = "Run ffmpeg for a single channel (v3): record or playback."

    def add_arguments(self, parser):
        parser.add_argument("channel_id", type=int)
        parser.add_argument(
            "--target-id", type=int, default=None, help="OutputTarget id (required for playback in Phase 2+)")
        parser.add_argument(
            "--purpose",
            default="record",
            choices=["record", "playback"],
            help="Job purpose: record or playback (default: record)",
        )

    def handle(self, *args, **options):
        channel_id = options["channel_id"]
        purpose = options["purpose"]

        if shutil.which("ffmpeg") is None:
            raise CommandError("ffmpeg not found in PATH. Install ffmpeg or add it to PATH.")

        try:
            chan = Channel.objects.get(pk=channel_id)
        except Channel.DoesNotExist:
            raise CommandError(f"Channel id={channel_id} not found.")

        target_id = options.get('target_id')
        output_target = None
        if purpose == 'playback':
            if not target_id:
                raise CommandError('For playback, you must provide --target-id')
            from transcoder.models import OutputTarget
            output_target = OutputTarget.objects.get(pk=target_id)
        job = FFmpegJobConfig(channel=chan, purpose=purpose, output_target=output_target)
        cmd = job.build_command()

        self.stdout.write(self.style.SUCCESS("Running FFmpeg:"))
        self.stdout.write(" ".join(cmd))
        self.stdout.flush()

        # Run FFmpeg and stream output to terminal
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
        except Exception as e:
            raise CommandError(f"Failed to start ffmpeg: {e}")

        try:
            for line in proc.stdout:
                self.stdout.write(line.rstrip("\n"))
        except KeyboardInterrupt:
            self.stdout.write(self.style.WARNING("Stopping FFmpeg (Ctrl+C)..."))
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        finally:
            rc = proc.wait()
            if rc == 0:
                self.stdout.write(self.style.SUCCESS("FFmpeg exited normally."))
            else:
                self.stdout.write(self.style.ERROR(f"FFmpeg exited with code {rc}."))
