from __future__ import annotations

from pathlib import Path

import typer

from agent_sandbox import __version__
from agent_sandbox.config import (
    find_repo_root,
    initialize_config,
    load_provider_lock,
    load_settings,
    merged_env,
    provider_lock_file,
    write_provider_lock,
)
from agent_sandbox.constants import DEFAULT_LOG_FILE_NAME, DEFAULT_TIMEOUT_SECONDS
from agent_sandbox.docker_sandbox import (
    build_plan,
    execute_plan,
    fetch_network_logs,
    remove_sandbox,
    stop_sandbox,
)
from agent_sandbox.doctor import build_doctor_report
from agent_sandbox.errors import AgentSandboxError
from agent_sandbox.logging_utils import audit_event, get_logger
from agent_sandbox.opencode_config import render_opencode_config
from agent_sandbox.providers import probe_provider
from agent_sandbox.secrets import decrypt_env, encrypt_env, ensure_secret_backend
from agent_sandbox.subprocess_runner import SubprocessRunner

app = typer.Typer(help="Simple Docker Sandboxes wrapper for OpenCode.")
provider_app = typer.Typer(help="Provider operations.")
config_app = typer.Typer(help="Config operations.")
app.add_typer(provider_app, name="provider")
app.add_typer(config_app, name="config")


def _repo_root(path: Path | None) -> Path:
    start = path or Path.cwd()
    return find_repo_root(start)


def _logger(repo_root: Path):
    log_path = repo_root / ".agent-sandbox" / "logs" / DEFAULT_LOG_FILE_NAME
    return get_logger(log_path)


@app.command()
def version() -> None:
    typer.echo(__version__)


@app.command()
def init(path: Path = Path(".")) -> None:
    repo_root = _repo_root(path)
    settings = initialize_config(repo_root)
    audit_event(
        _logger(repo_root),
        "init",
        repo_root=str(repo_root),
        sandbox_name=settings.sandbox_name,
    )
    typer.echo(f"Initialized {repo_root / '.agent-sandbox' / 'config.toml'}")


@app.command()
def doctor(path: Path = Path(".")) -> None:
    repo_root = _repo_root(path)
    settings = load_settings(repo_root)
    overall_ok = True
    for name, ok, detail in build_doctor_report(settings):
        status = "OK" if ok else "FAIL"
        typer.echo(f"{status:>4}  {name:<16} {detail}")
        overall_ok = overall_ok and ok
    audit_event(_logger(repo_root), "doctor", ok=overall_ok, repo_root=str(repo_root))
    if not overall_ok:
        raise typer.Exit(code=1)


@provider_app.command("probe")
def provider_probe(path: Path = Path("."), timeout: int = DEFAULT_TIMEOUT_SECONDS) -> None:
    repo_root = _repo_root(path)
    settings = load_settings(repo_root)
    probe = probe_provider(settings, merged_env(repo_root), timeout)
    write_provider_lock(repo_root, probe)
    audit_event(
        _logger(repo_root),
        "provider_probe",
        repo_root=str(repo_root),
        model=probe.selected_model,
        provider_id=probe.provider_id,
    )
    typer.echo(f"Provider OK: {probe.provider_name} -> {probe.selected_model}")


@config_app.command("render")
def config_render(path: Path = Path("."), force_probe: bool = False) -> None:
    repo_root = _repo_root(path)
    settings = load_settings(repo_root)
    probe = None if force_probe else load_provider_lock(repo_root)
    if probe is None:
        probe = probe_provider(settings, merged_env(repo_root), DEFAULT_TIMEOUT_SECONDS)
        write_provider_lock(repo_root, probe)
    output = render_opencode_config(repo_root, settings, probe)
    audit_event(_logger(repo_root), "config_render", repo_root=str(repo_root), output=str(output))
    typer.echo(str(output))


@app.command()
def run(
    repo: Path = Path("."),
    dry_run: bool = typer.Option(False, help="Print commands instead of executing."),
) -> None:
    repo_root = _repo_root(repo)
    settings = load_settings(repo_root)
    ensure_secret_backend(settings.secret_backend)
    probe = load_provider_lock(repo_root)
    if probe is None:
        probe = probe_provider(settings, merged_env(repo_root), DEFAULT_TIMEOUT_SECONDS)
        write_provider_lock(repo_root, probe)
    render_opencode_config(repo_root, settings, probe)
    plan = build_plan(repo_root, settings)
    audit_event(
        _logger(repo_root),
        "run_planned",
        repo_root=str(repo_root),
        sandbox_name=settings.sandbox_name,
        dry_run=dry_run,
        lock_file=str(provider_lock_file(repo_root)),
    )
    if dry_run:
        for command in [plan.create_command, *plan.network_commands, plan.launch_command]:
            typer.echo(" ".join(command))
        return
    execute_plan(plan, SubprocessRunner())
    audit_event(
        _logger(repo_root),
        "run_started",
        repo_root=str(repo_root),
        sandbox_name=settings.sandbox_name,
    )


@app.command()
def stop(path: Path = Path(".")) -> None:
    repo_root = _repo_root(path)
    settings = load_settings(repo_root)
    stop_sandbox(settings.sandbox_name, SubprocessRunner())
    audit_event(_logger(repo_root), "stop", sandbox_name=settings.sandbox_name)
    typer.echo(f"Stopped {settings.sandbox_name}")


@app.command(name="remove")
def remove_cmd(path: Path = Path(".")) -> None:
    repo_root = _repo_root(path)
    settings = load_settings(repo_root)
    remove_sandbox(settings.sandbox_name, SubprocessRunner())
    audit_event(_logger(repo_root), "remove", sandbox_name=settings.sandbox_name)
    typer.echo(f"Removed {settings.sandbox_name}")


@app.command()
def logs(path: Path = Path("."), lines: int = typer.Option(20, min=1)) -> None:
    repo_root = _repo_root(path)
    log_path = repo_root / ".agent-sandbox" / "logs" / DEFAULT_LOG_FILE_NAME
    if not log_path.exists():
        typer.echo("No audit log found.")
        return
    for line in log_path.read_text(encoding="utf-8").splitlines()[-lines:]:
        typer.echo(line)


@app.command()
def netlogs(path: Path = Path(".")) -> None:
    repo_root = _repo_root(path)
    settings = load_settings(repo_root)
    typer.echo(fetch_network_logs(settings.sandbox_name, SubprocessRunner()))


@app.command()
def encrypt(path: Path = Path(".")) -> None:
    repo_root = _repo_root(path)
    encrypt_env(repo_root, SubprocessRunner())
    audit_event(_logger(repo_root), "encrypt", repo_root=str(repo_root))
    typer.echo("Encrypted .env -> .env.enc")


@app.command()
def decrypt(path: Path = Path(".")) -> None:
    repo_root = _repo_root(path)
    decrypt_env(repo_root, SubprocessRunner())
    audit_event(_logger(repo_root), "decrypt", repo_root=str(repo_root))
    typer.echo("Decrypted .env.enc -> .env")


def _main() -> int:
    try:
        app()
    except AgentSandboxError as exc:
        typer.echo(f"ERROR: {exc}", err=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
