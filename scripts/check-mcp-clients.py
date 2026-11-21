#!/usr/bin/env python3
"""Check that every agent CLI installed here still gets Lamp's tools from lamp-mcp.

Each CLI is started against lamp-mcp behind a recorder that keeps both sides of the
conversation, and the script reports how the CLI opened (its first methods and the MCP
revisions it offered), whether it was given Lamp's tools, and any request lamp-mcp never
answered. That last is the failure that hides: a client left waiting gives up and carries
on without the tools, saying nothing (Antigravity did, on MCP 2026-07-28's
`server/discover`, until Mac dc97a27).

The openings are compared with scripts/mcp-client-handshakes.json. A changed opening is
reported rather than failed: copy the new messages from the transcript into
LampMCPClientCompatibilityTests as a verbatim fixture, then record it with --update.

    scripts/check-mcp-clients.py                 # every CLI found on PATH
    scripts/check-mcp-clients.py --only agy,codex
    scripts/check-mcp-clients.py --no-prompt     # only those that open without a model call
    scripts/check-mcp-clients.py --update        # record today's openings as the baseline

The CLIs are started the way Lamp starts them, with only lamp-mcp configured, against an
empty library in a temporary folder. Antigravity is checked over ACP by starting a session,
and OpenCode with `opencode mcp list`; neither sends a prompt. Claude Code and Codex each
answer a one-word prompt, which spends a little of the reader's quota. Run it after a CLI
updates and before an install.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BASELINE = REPO / "scripts" / "mcp-client-handshakes.json"
INSTALLED_HELPER = Path.home() / "Applications/Lamp Bible.app/Contents/Helpers/lamp-mcp"
BUILT_HELPER = REPO / ".build/debug/lamp-mcp"
PROMPT = "Reply with the single word OK."
CLIENTS = ["agy", "claude", "codex", "opencode"]
NEEDS_PROMPT = {"claude", "codex"}
TIMEOUT = 180


@dataclass
class Exchange:
    """One lamp-mcp process: what the client sent and what came back."""

    sent: list[dict] = field(default_factory=list)
    received: list[dict] = field(default_factory=list)

    def requests(self) -> list[dict]:
        return [m for m in self.sent if "method" in m and "id" in m]

    def reply(self, request_id) -> dict | None:
        return next((m for m in self.received if m.get("id") == request_id and "method" not in m), None)

    def tool_count(self) -> int | None:
        for request in self.requests():
            if request["method"] == "tools/list":
                reply = self.reply(request["id"])
                if reply and "result" in reply:
                    return len(reply["result"].get("tools", []))
        return None


@dataclass
class Result:
    client: str
    version: str
    exchanges: list[Exchange]
    skipped: str | None = None
    note: str = ""

    def best(self) -> Exchange | None:
        listed = [e for e in self.exchanges if e.tool_count() is not None]
        pool = listed or self.exchanges
        return max(pool, key=lambda e: len(e.sent), default=None)

    def opening(self) -> dict:
        exchange = self.best()
        if exchange is None:
            return {}
        methods, offered = [], []
        for message in exchange.sent:
            method = message.get("method")
            if method is None or method.startswith("notifications/"):
                continue
            if method == "tools/list":
                break
            methods.append(method)
            params = message.get("params") or {}
            version = params.get("protocolVersion") or (params.get("_meta") or {}).get(
                "io.modelcontextprotocol/protocolVersion")
            if version and version not in offered:
                offered.append(version)
        return {"methods": methods, "protocolVersions": offered}

    def unanswered(self) -> list[str]:
        missing = []
        for exchange in self.exchanges:
            for request in exchange.requests():
                if exchange.reply(request["id"]) is None:
                    missing.append(f'{request["method"]} (id {request["id"]})')
        return missing


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    messages = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            messages.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return messages


def recorder(directory: Path, helper: Path) -> Path:
    """A stand-in for lamp-mcp that keeps both directions, one pair of files per process."""
    script = directory / "lamp-mcp-recorder"
    script.write_text(
        "#!/bin/bash\n"
        f'dir={json.dumps(str(directory))}\n'
        'tee -a "$dir/sent.$$.jsonl" | '
        f'{json.dumps(str(helper))} "$@" 2>>"$dir/stderr.$$.log" | '
        'tee -a "$dir/received.$$.jsonl"\n'
    )
    script.chmod(0o755)
    return script


def exchanges(directory: Path) -> list[Exchange]:
    found = []
    for sent in sorted(directory.glob("sent.*.jsonl")):
        pid = sent.name.split(".")[1]
        found.append(Exchange(read_jsonl(sent), read_jsonl(directory / f"received.{pid}.jsonl")))
    return found


def child_environment() -> dict:
    # A CLI started from a Claude Code shell otherwise runs as that session's child.
    return {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}


def run(command: list[str], cwd: Path) -> tuple[int | None, str]:
    try:
        done = subprocess.run(command, cwd=cwd, env=child_environment(), stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=TIMEOUT)
        return done.returncode, (done.stdout + done.stderr)[-600:]
    except subprocess.TimeoutExpired:
        return None, f"timed out after {TIMEOUT}s"


def version_of(client: str) -> str:
    try:
        out = subprocess.run([client, "--version"], capture_output=True, text=True, timeout=30,
                             stdin=subprocess.DEVNULL, env=child_environment())
        return (out.stdout or out.stderr).strip().splitlines()[0]
    except Exception:
        return "?"


def check_claude(work: Path, server: Path, arguments: list[str]) -> str:
    config = work / "mcp.json"
    config.write_text(json.dumps({"mcpServers": {"lamp": {"type": "stdio", "command": str(server), "args": arguments}}}))
    # The prompt goes before the flags: some swallow the arguments after them.
    status, tail = run(["claude", "-p", PROMPT, "--mcp-config", str(config), "--strict-mcp-config",
                        "--model", "haiku"], work)
    return "" if status == 0 else f"exit {status}: {tail}"


def check_codex(work: Path, server: Path, arguments: list[str]) -> str:
    quoted = lambda value: json.dumps(value)
    table = (f"mcp_servers={{lamp={{command={quoted(str(server))},"
             f"args=[{', '.join(quoted(a) for a in arguments)}],required=true}}}}")
    status, tail = run(["codex", "exec", "--skip-git-repo-check", "-s", "read-only", "-c", table, PROMPT], work)
    return "" if status == 0 else f"exit {status}: {tail}"


def check_opencode(work: Path, server: Path, arguments: list[str]) -> str:
    (work / "opencode.json").write_text(json.dumps({
        "$schema": "https://opencode.ai/config.json",
        "mcp": {"lamp": {"type": "local", "command": [str(server), *arguments], "enabled": True}},
    }))
    # Not `opencode run`: OpenCode connects to its MCP servers lazily, and a short
    # prompt is answered before it has. `mcp list` has its background server open the
    # project, which connects them, though often only after the command has returned.
    status, tail = run(["opencode", "mcp", "list"], work)
    deadline = time.time() + 30
    while time.time() < deadline and not any(e.tool_count() is not None for e in exchanges(work)):
        time.sleep(0.5)
    return "" if status == 0 else f"exit {status}: {tail}"


def check_agy(work: Path, server: Path, arguments: list[str]) -> str:
    """Starts an ACP session with lamp-mcp attached, which makes agy connect to it, and
    sends no prompt."""
    process = subprocess.Popen(["agy", "acp"], cwd=work, env=child_environment(), text=True, bufsize=1,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    lines: queue.Queue[str] = queue.Queue()
    threading.Thread(target=lambda: [lines.put(l) for l in process.stdout], daemon=True).start()

    def call(request_id: int, method: str, params: dict) -> dict | None:
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n")
        process.stdin.flush()
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            try:
                line = lines.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue  # agy can print a sign-in link on stdout
            if message.get("id") == request_id and "method" not in message:
                return message
        return None

    try:
        call(1, "initialize", {"protocolVersion": 1, "clientInfo": {"name": "lamp-mcp-check", "version": "1"},
                               "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False},
                                                      "terminal": False}})
        session = call(2, "session/new", {"cwd": str(work), "mcpServers": [
            {"name": "lamp", "command": str(server), "args": arguments, "env": []}]})
        if session is None:
            return "no answer to session/new"
        if "error" in session:
            return f'session/new: {session["error"].get("message")} (sign in with `agy` first)'
        return ""
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()


CHECKS = {"agy": check_agy, "claude": check_claude, "codex": check_codex, "opencode": check_opencode}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--only", help="comma-separated clients (default: every one found on PATH)")
    parser.add_argument("--no-prompt", action="store_true", help="skip clients that need a model call")
    parser.add_argument("--lamp-mcp", type=Path,
                        help=f"helper to test (default: {BUILT_HELPER.relative_to(REPO)} if built, else the installed app's)")
    parser.add_argument("--update", action="store_true", help="record today's openings in the baseline")
    parser.add_argument("--keep", action="store_true", help="keep the transcripts and print where")
    options = parser.parse_args()

    helper = options.lamp_mcp or (BUILT_HELPER if BUILT_HELPER.exists() else INSTALLED_HELPER)
    if not helper.exists():
        print(f"No lamp-mcp at {helper}. Build it (swift build --product lamp-mcp) or pass --lamp-mcp.")
        return 1
    built = time.strftime("%Y-%m-%d %H:%M", time.localtime(helper.stat().st_mtime))
    print(f"lamp-mcp: {helper} (built {built})\n")

    wanted = options.only.split(",") if options.only else CLIENTS
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    root = Path(tempfile.mkdtemp(prefix="lamp-mcp-check-"))
    library = root / "library"
    library.mkdir()
    arguments = ["--library-root", str(library)]

    results: list[Result] = []
    for client in wanted:
        if client not in CHECKS:
            print(f"{client}: unknown client; choose from {', '.join(CLIENTS)}")
            return 1
        if shutil.which(client) is None:
            results.append(Result(client, "", [], skipped="not installed"))
            continue
        if options.no_prompt and client in NEEDS_PROMPT:
            results.append(Result(client, version_of(client), [], skipped="needs a model call (--no-prompt)"))
            continue
        work = root / client
        work.mkdir()
        print(f"Checking {client}…", flush=True)
        note = CHECKS[client](work, recorder(work, helper), arguments)
        results.append(Result(client, version_of(client), exchanges(work), note=note))
        # OpenCode's background server keeps the servers it started running after
        # the command exits; whatever is left of this check goes with it.
        subprocess.run(["pkill", "-f", str(root)], stdin=subprocess.DEVNULL)

    failed, changed = False, False
    print()
    for result in results:
        if result.skipped:
            print(f"- {result.client}: skipped, {result.skipped}")
            continue
        opening = result.opening()
        tools = result.best().tool_count() if result.best() else None
        missing = result.unanswered()
        known = baseline.get(result.client)
        status = "ok" if tools else "FAIL"
        failed |= not tools
        print(f"- {result.client} {result.version}: {status}")
        print(f"    opened with {' → '.join(opening.get('methods') or ['nothing'])}, "
              f"offering MCP {', '.join(opening.get('protocolVersions') or ['?'])}")
        print(f"    {'given ' + str(tools) + ' tools' if tools else 'never given the tools'}")
        if missing:
            print(f"    UNANSWERED: {', '.join(missing)}")
        if result.note:
            print(f"    {result.note.strip()}")
        if known is not None and known != opening and opening:
            changed = True
            print(f"    CHANGED since the baseline, which has {' → '.join(known.get('methods', []))} "
                  f"offering {', '.join(known.get('protocolVersions', []))}")
        if options.update and opening:
            baseline[result.client] = opening

    if options.update:
        BASELINE.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
        print(f"\nRecorded the openings in {BASELINE.relative_to(REPO)}.")
    elif changed:
        print("\nAn opening changed. Add its messages from the transcript to LampMCPClientCompatibilityTests "
              "as a verbatim fixture, then run again with --update.")
    if options.keep or failed or changed:
        print(f"\nTranscripts: {root}")
    else:
        shutil.rmtree(root, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
