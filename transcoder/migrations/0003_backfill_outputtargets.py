from django.db import migrations


def backfill_targets(apps, schema_editor):
    Channel = apps.get_model("transcoder", "Channel")
    OutputTarget = apps.get_model("transcoder", "OutputTarget")

    for chan in Channel.objects.all():
        if OutputTarget.objects.filter(channel_id=chan.id).exists():
            continue

        # one-time conversion from legacy field (while it still exists)
        legacy_url = (chan.output_target or "").strip() or "udp://127.0.0.1:5002"
        OutputTarget.objects.create(
            channel_id=chan.id,
            name="Target 1",
            enabled=True,
            protocol="udp_mpegts",
            target_url=legacy_url,
            pkt_size=None,
            overrun_nonfatal=None,
            ttl=None,
        )


class Migration(migrations.Migration):
    dependencies = [
        ("transcoder", "0002_remove_channel_audio_codec_remove_channel_audio_mode_and_more"),
    ]

    operations = [
        migrations.RunPython(backfill_targets, migrations.RunPython.noop),
    ]
