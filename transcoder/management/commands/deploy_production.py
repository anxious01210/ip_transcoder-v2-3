# transcoder/management/commands/deploy_production.py
import os
import shlex
import subprocess
from typing import Optional

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management import BaseCommand, call_command
from django.db import connections


def _print_box(lines: list[str]) -> None:
    width = max(len(x) for x in lines) if lines else 0
    border = "─" * (width + 2)
    print(f"┌{border}┐")
    for ln in lines:
        print(f"│ {ln.ljust(width)} │")
    print(f"└{border}┘")


class Command(BaseCommand):
    help = (
        "Production deploy helper: migrate + collectstatic + optional superuser + optional systemd restart."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            "--app-name",
            default=os.getenv("APP_NAME", "ip_transcoder"),
            help="Used to build default service names: <app>_gunicorn and <app>_enforcer (default: ip_transcoder).",
        )
        parser.add_argument(
            "--web-service",
            default=None,
            help="Override the gunicorn systemd service name (without .service).",
        )
        parser.add_argument(
            "--enforcer-service",
            default=None,
            help="Override the enforcer systemd service name (without .service).",
        )
        parser.add_argument(
            "--no-restart",
            action="store_true",
            help="Do not restart systemd services (still prints commands).",
        )
        parser.add_argument(
            "--no-superuser",
            action="store_true",
            help="Skip superuser creation check/prompt.",
        )
        parser.add_argument(
            "--database",
            default="default",
            help="Django database alias to check connectivity (default: default).",
        )

    def handle(self, *args, **opts):
        app_name: str = opts["app_name"]
        web_service: str = opts["web_service"] or f"{app_name}_gunicorn"
        enforcer_service: str = opts["enforcer_service"] or f"{app_name}_enforcer"
        no_restart: bool = bool(opts["no_restart"])
        no_superuser: bool = bool(opts["no_superuser"])
        db_alias: str = opts["database"]

        _print_box([
            "Deploy Production",
            f"Project: {app_name}",
            f"Web service: {web_service}.service",
            f"Enforcer service: {enforcer_service}.service",
            f"DB alias: {db_alias}",
        ])

        # 0) Quick DB connectivity check
        self.stdout.write(self.style.MIGRATE_HEADING("0) Checking database connectivity..."))
        try:
            conn = connections[db_alias]
            conn.ensure_connection()
            self.stdout.write(self.style.SUCCESS("   DB connection: OK"))
        except Exception as e:
            self.stdout.write(self.style.ERROR(f"   DB connection failed: {e}"))
            self.stdout.write(self.style.WARNING("   Fix DB settings/.env before deploying."))
            return

        # 1) Migrate
        self.stdout.write(self.style.MIGRATE_HEADING("1) Running migrations..."))
        call_command("migrate", interactive=True, verbosity=1)

        # 2) Collectstatic
        self.stdout.write(self.style.MIGRATE_HEADING("2) Collecting static files..."))
        # If STATIC_ROOT not set, collectstatic can fail; warn early.
        if not getattr(settings, "STATIC_ROOT", None):
            self.stdout.write(self.style.WARNING(
                "   STATIC_ROOT is not set. collectstatic may fail unless configured."
            ))
        call_command("collectstatic", interactive=False, verbosity=1, clear=False, noinput=True)

        # 3) Superuser (optional)
        if not no_superuser:
            self.stdout.write(self.style.MIGRATE_HEADING("3) Superuser check..."))
            User = get_user_model()
            has_admin = User.objects.filter(is_superuser=True).exists()
            if has_admin:
                self.stdout.write(self.style.SUCCESS("   Superuser exists: OK"))
            else:
                self.stdout.write(self.style.WARNING("   No superuser found."))
                if self._ask_yes_no("   Create a superuser now?", default_yes=True):
                    call_command("createsuperuser", interactive=True)
                else:
                    self.stdout.write(self.style.WARNING("   Skipped superuser creation."))

        # 4) Restart services (optional)
        self.stdout.write(self.style.MIGRATE_HEADING("4) Restart services..."))
        cmds = [
            f"systemctl restart {shlex.quote(web_service)}.service",
            f"systemctl restart {shlex.quote(enforcer_service)}.service",
            f"systemctl status {shlex.quote(web_service)}.service --no-pager -l",
            f"systemctl status {shlex.quote(enforcer_service)}.service --no-pager -l",
        ]

        # If user disabled restarts, just print commands
        if no_restart:
            self._print_restart_instructions(cmds)
            self.stdout.write(self.style.SUCCESS("Deploy steps completed (no restart)."))
            return

        # Try restarting directly if root, otherwise print sudo commands
        if os.geteuid() != 0:
            self.stdout.write(self.style.WARNING("   Not running as root, cannot restart systemd directly."))
            self._print_restart_instructions(cmds, use_sudo=True)
            self.stdout.write(self.style.SUCCESS("Deploy steps completed (restart commands printed)."))
            return

        # We are root: execute restarts
        for c in cmds[:2]:
            self._run_shell(c)

        # Show status
        for c in cmds[2:]:
            self._run_shell(c, check=False)

        self.stdout.write(self.style.SUCCESS("Deploy steps completed successfully."))

    def _ask_yes_no(self, prompt: str, default_yes: bool = True) -> bool:
        suffix = "[Y/n]" if default_yes else "[y/N]"
        ans = input(f"{prompt} {suffix} ").strip().lower()
        if not ans:
            return default_yes
        return ans in ("y", "yes")

    def _print_restart_instructions(self, cmds: list[str], use_sudo: bool = True) -> None:
        self.stdout.write("")
        self.stdout.write(self.style.WARNING("Run these commands on the server:"))
        for c in cmds:
            if use_sudo and not c.startswith("sudo "):
                print("  sudo " + c)
            else:
                print("  " + c)
        self.stdout.write("")

    def _run_shell(self, cmd: str, check: bool = True) -> None:
        self.stdout.write(self.style.HTTP_INFO(f"   $ {cmd}"))
        subprocess.run(cmd, shell=True, check=check)



# from the project root:
# # run deploy (non-root): will print sudo systemctl commands
# python manage.py deploy_production --app-name ip_transcoder
#
# # run deploy as root: will restart services automatically
# sudo /srv/ip_transcoder/venv/bin/python /srv/ip_transcoder/app/manage.py deploy_production --app-name ip_transcoder
# If your service names differ:
# python manage.py deploy_production --web-service my_web --enforcer-service my_enforcer
# Skip superuser step:
# python manage.py deploy_production --no-superuser
# Skip restart step:
# python manage.py deploy_production --no-restart