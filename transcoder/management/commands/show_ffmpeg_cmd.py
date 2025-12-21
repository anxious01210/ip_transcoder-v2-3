# transcoder/management/commands/show_ffmpeg_cmd.py
from django.core.management.base import BaseCommand, CommandError

from transcoder.ffmpeg_runner import FFmpegJobConfig
from transcoder.models import Channel


class Command(BaseCommand):
    help = "Show the ffmpeg command that would be used for a given Channel."

    def add_arguments(self, parser):
        parser.add_argument("channel_id", type=int, help="ID of the Channel")
        parser.add_argument(
            "--target-id", type=int, default=None, help="OutputTarget id (required for playback in Phase 2+)")
        parser.add_argument(
            "--purpose",
            default="record",
            choices=["record", "playback"],
            help="Purpose: record or playback (default: record)",
        )

    def handle(self, *args, **options):
        channel_id = options["channel_id"]
        purpose = options["purpose"]

        try:
            chan = Channel.objects.get(pk=channel_id)
        except Channel.DoesNotExist:
            raise CommandError(f"Channel with id={channel_id} does not exist.")

        target_id = options.get('target_id')
        output_target = None
        if purpose == 'playback':
            if not target_id:
                raise CommandError('For playback, you must provide --target-id')
            from transcoder.models import OutputTarget
            output_target = OutputTarget.objects.get(pk=target_id)
        cmd = FFmpegJobConfig(channel=chan, purpose=purpose, output_target=output_target).build_command()

        self.stdout.write(self.style.SUCCESS(f"Channel: {chan.name}"))
        self.stdout.write(f"Purpose: {purpose}")
        self.stdout.write("FFmpeg command:")
        self.stdout.write(" ".join(cmd))
