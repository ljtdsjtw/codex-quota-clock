#!/usr/bin/python3
"""One interruption per Codex weekly quota window on the current Mac."""

import argparse
import contextlib
import ctypes
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import threading


THRESHOLD = 8
INTERVAL = 30
LABEL = "local.codex-weekly-quota-guard"
ROOT = Path.home() / "Library/Application Support/CodexQuotaGuard"
STATE = ROOT / "state.json"
INSTALLED = ROOT / "quota_guard.py"
PLIST = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
DOMAIN = "gui/" + str(os.getuid())
SETTINGS = ROOT / "settings.json"
INTERVALS = (30, 60, 120, 300)
TARGET = DOMAIN + "/" + LABEL
CTL = "/bin/launchctl"
wake = threading.Event()


def atomic_write(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        temporary = Path(f.name)
        try:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def codex_binaries():
    paths = []
    for applications in (Path("/Applications"), Path.home() / "Applications"):
        for app in ("ChatGPT", "Codex"):
            resources = applications / (app + ".app") / "Contents/Resources"
            paths.extend((resources / "codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          resources / "codex"))
    paths.extend(Path(p) for p in ("/opt/homebrew/bin/codex", "/usr/local/bin/codex"))
    found = shutil.which("codex")
    if found:
        paths.append(Path(found))
    return [path.resolve() for path in paths if path.is_file() and os.access(path, os.X_OK)]


class AppSampler:
    """The signed clock reads one fresh sample and updates its WidgetKit container."""
    def __init__(self, executable):
        self.process = subprocess.Popen(
            [str(executable), "--quota-feed"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )

    def read(self):
        signal.alarm(35)
        try:
            self.process.stdin.write(b"sample\n")
            self.process.stdin.flush()
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("额度时钟的读取进程已退出")
            reply = json.loads(line)
            if "error" in reply:
                raise RuntimeError(reply["error"])
            now = time.time()
            if not 0 <= now - reply["checkedAt"] < 30:
                raise ValueError("本次读数已过期")
            return reply
        finally:
            signal.alarm(0)

    def close(self):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()


def weekly_quota(result, now):
    buckets = result.get("rateLimitsByLimitId")
    bucket = (buckets or {}).get("codex") or result.get("rateLimits") or {}
    if bucket.get("limitId") not in (None, "codex"):
        raise ValueError("额度数据属于其他产品")
    for name in ("primary", "secondary"):
        window = bucket.get(name) or {}
        if window.get("windowDurationMins") != 7 * 24 * 60:
            continue
        used, reset = window.get("usedPercent"), window.get("resetsAt")
        if (type(used) not in (int, float) or not 0 <= used <= 100
                or type(reset) is not int or reset <= now):
            raise ValueError("周额度数据无效或已过期")
        account = result.get("accountId")
        if not isinstance(account, str) or not account:
            raise ValueError("周额度缺少账户标识")
        return hashlib.sha256(account.encode()).hexdigest(), 100 - used, reset
    raise ValueError("服务端暂未提供 Codex 周额度")


# Darwin's KERN_PROCARGS2 preserves argument boundaries, including prompts with spaces.
# Keep only argv. The environment, paths in prompts, and prompt text are never logged.
def process_args(pid):
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)
    length = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(length), None, 0) != 0:
        raise OSError(ctypes.get_errno(), "读取 Codex 进程参数长度失败")
    buffer = ctypes.create_string_buffer(length.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(length), None, 0) != 0:
        raise OSError(ctypes.get_errno(), "读取 Codex 进程参数失败")
    raw = buffer.raw[:length.value]
    count = struct.unpack_from("=i", raw)[0]
    start = raw.index(b"\0", 4)
    while start < len(raw) and raw[start] == 0:
        start += 1
    return [os.fsdecode(x) for x in raw[start:].split(b"\0", count)[:count]]


VALUE_FLAGS = set((
    "-c --config --enable --disable -i --image -m --model --local-provider -p --profile "
    "-s --sandbox -C --cd --add-dir -a --ask-for-approval --remote --remote-auth-token-env "
    "--listen --startup-client-info --cloud-skills-snapshot --code-mode-host "
    "--ws-auth --ws-token-file --ws-token-sha256 --ws-shared-secret-file --ws-issuer "
    "--ws-audience --ws-max-clock-skew-seconds"
).split())
NON_CHAT = set((
    "login logout mcp plugin app-remote app remote-control completion update doctor sandbox debug "
    "apply queue archive delete migrate-rollouts migrate-nfs-db unarchive cloud exec-server "
    "features help"
).split())


def positional(args):
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            return (None, [])
        if arg in ("-h", "--help", "-V", "--version", "--print-startup-config", "--oss"):
            return ("help", [])
        if arg == "--remote" or arg.startswith(("--remote=", "--codex-run-as-")):
            return ("remote-control", [])
        if not arg.startswith("-"):
            return (arg, args[i + 1:])
        if arg in ("--plugin-mcp-launch-cwd", "--mcp-launch-cwd"):
            i += 4
        else:
            i += 2 if arg in VALUE_FLAGS else 1
    return (None, [])


def chat_process(args):
    if not args or Path(args[0]).name in ("apply_patch", "apply-patch", "codex-command-runner"):
        return False
    command, rest = positional(args[1:])
    if command == "app-server":
        for flag, value in zip(rest, rest[1:]):
            if flag == "--startup-client-info":
                try:
                    if json.loads(value).get("name") in ("local_quota_guard", "quota_clock"):
                        return False
                except (ValueError, AttributeError):
                    pass
        subcommand, _ = positional(rest)
        return subcommand is None
    return command not in NON_CHAT


def processes():
    output = subprocess.check_output(
        ["/bin/ps", "-U", str(os.getuid()), "-ww", "-o", "pid=,ppid=,stat=,lstart=,comm="],
        env={**os.environ, "LC_ALL": "C"}, text=True, errors="replace", timeout=5,
    )
    records = {}
    for line in output.splitlines():
        fields = line.split(None, 8)
        if len(fields) != 9 or "Z" in fields[2] or not fields[8].startswith("/"):
            continue
        pid = int(fields[0])
        records[pid] = {"pid": pid, "parent": int(fields[1]),
                        "started": " ".join(fields[3:8]), "path": fields[8]}
    return records


def is_codex_binary(path, known):
    binary = Path(path)
    if binary.name not in ("codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"):
        return False
    if str(binary.resolve()) in known:
        return True
    # Native children of the official npm and editor launchers can have a different path.
    parts = binary.parts
    npm = "@openai" in parts and "vendor" in parts and any(
        p == "codex" or p.startswith("codex-darwin-") for p in parts[:-1])
    editor = "extensions" in parts and any(p.startswith("openai.chatgpt-") for p in parts)
    return npm or editor


def snapshot_targets(excluded_pid):
    known = {str(path) for path in codex_binaries()}
    targets = []
    table = processes()
    for pid, record in table.items():
        if pid == excluded_pid or not is_codex_binary(record["path"], known):
            continue
        parent_path = table.get(record["parent"], {}).get("path", "")
        if "/Codex 额度时钟.app/Contents/" in parent_path:
            continue
        try:
            args = process_args(pid)
        except ProcessLookupError:
            continue
        except OSError:
            if processes().get(pid) != record:
                continue
            raise
        if chat_process(args):
            targets.append({key: record[key] for key in ("pid", "started", "path")})
    return targets


def survivors(targets):
    current = processes()
    return [t for t in targets if t["pid"] in current
            and all(current[t["pid"]][key] == value for key, value in t.items())]


def stop_targets(targets):
    remaining = survivors(targets) if targets else []
    for sig, grace in ((signal.SIGTERM, 2.0), (signal.SIGKILL, 0.5)):
        if not remaining:
            break
        for target in remaining:
            try:
                os.kill(target["pid"], sig)
            except ProcessLookupError:
                pass
        time.sleep(grace)
        remaining = survivors(remaining)
    return remaining


def observe(state, result, now, snapshot, stop, save, threshold=THRESHOLD):
    account, remaining, reset = weekly_quota(result, now)
    state.update(remaining_percent=remaining, resets_at=reset, checked_at=now, error=None)
    cycles = state.setdefault("interruptions", {})
    for key in list(cycles):
        if now - cycles[key]["resets_at"] > 8 * 86400:
            del cycles[key]
    event = cycles.get(account)
    # The backend can round reset times by a few seconds between observations.
    same_window = event and (abs(event["resets_at"] - reset) < 300 or
                             (now < event["resets_at"] and reset - 7 * 86400 < event["triggered_at"]))
    if remaining < threshold:
        if not same_window:
            targets = snapshot()
            event = {"triggered_at": now, "resets_at": reset, "count": len(targets),
                     "pending": targets}
            cycles[account] = event
            # Persist the exact cohort before the first signal. A restart must never
            # rescan this week's new, manually started conversations.
            save(state)
            same_window = True
        if event["pending"]:
            event["pending"] = stop(event["pending"])
    state["phase"] = ("stopping" if event["pending"] else "triggered") if same_window else "armed"
    save(state)


def save_state(state):
    atomic_write(STATE, (json.dumps(state, ensure_ascii=False, indent=2) + "\n").encode())


def read_state():
    try:
        return json.loads(STATE.read_text())
    except FileNotFoundError:
        return {}


def settings():
    try:
        data = json.loads(SETTINGS.read_text())
    except FileNotFoundError:
        return {"enabled": False, "threshold": THRESHOLD, "interval": INTERVAL}
    if (type(data.get("enabled")) is not bool or type(data.get("threshold")) is not int
            or not 1 <= data["threshold"] <= 100 or data.get("interval") not in INTERVALS):
        raise ValueError("额度保护设置无效")
    return data


def write_settings(data):
    atomic_write(SETTINGS, json.dumps(data).encode())


@contextlib.contextmanager
def locked(name):
    with (ROOT / name).open("a") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        yield


def run_watch(sampler_path):
    with (ROOT / "watch.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = read_state()
        sampler = None
        try:
            while settings()["enabled"]:
                wake.clear()
                started = time.monotonic()
                try:
                    if sampler is None:
                        sampler = AppSampler(sampler_path)
                    sample = sampler.read()
                    # Re-read the switch after I/O. Turning protection off while a
                    # request is in flight cannot authorize a new interruption.
                    with locked("action.lock"):
                        policy = settings()
                        if not policy["enabled"]:
                            return
                        state["display_error"] = sample.get("displayError")
                        observe(state, sample["result"], sample["checkedAt"],
                                lambda: snapshot_targets(None), stop_targets, save_state,
                                threshold=policy["threshold"])
                except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as e:
                    state.update(error=str(e), last_error_at=int(time.time()))
                    save_state(state)
                    if sampler is not None:
                        sampler.close()
                        sampler = None
                wait = settings()["interval"] - (time.monotonic() - started)
                wake.wait(max(1, wait))
        finally:
            if sampler is not None:
                sampler.close()


def loaded():
    return subprocess.run([CTL, "print", TARGET], capture_output=True).returncode == 0


def unload():
    if loaded():
        subprocess.run([CTL, "bootout", TARGET], check=True)
        for _ in range(50):
            if not loaded():
                return
            time.sleep(0.1)
        raise RuntimeError("后台服务仍在退出，请重试")


def signal_refresh():
    subprocess.run([CTL, "kill", "SIGUSR1", TARGET], check=True)


def agent_plist(sampler_path):
    return plistlib.dumps({
        "Label": LABEL, "ProgramArguments": ["/usr/bin/python3", "-I", "-B", str(INSTALLED),
                                            "watch", "--sampler", str(sampler_path)],
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
        "ProcessType": "Background", "StandardErrorPath": str(ROOT / "service-errors.log"),
    })


def configure(policy, sampler_path):
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with locked("control.lock"):
        if not policy["enabled"]:
            with locked("action.lock"):
                write_settings(policy)
            subprocess.run([CTL, "disable", TARGET], check=True)
            unload()
            # When migrating an installed agent, keep its on-disk command in sync
            # without registering a new login item on a display-only installation.
            if INSTALLED.exists() and PLIST.exists() and sampler_path:
                atomic_write(INSTALLED, Path(__file__).read_bytes())
                atomic_write(PLIST, agent_plist(sampler_path))
            return
        if not sampler_path or not os.access(sampler_path, os.X_OK):
            raise ValueError("找不到额度时钟的可执行文件")
        source = Path(__file__).read_bytes()
        plist_bytes = agent_plist(sampler_path)
        try:
            current = INSTALLED.read_bytes() == source and PLIST.read_bytes() == plist_bytes
        except FileNotFoundError:
            current = False
        running = loaded()
        try:
            if running and current:
                with locked("action.lock"):
                    write_settings(policy)
                signal_refresh()
                return
            # Boot out the legacy service before installing the replacement.
            unload()
            PLIST.parent.mkdir(parents=True, exist_ok=True)
            atomic_write(INSTALLED, source)
            atomic_write(PLIST, plist_bytes)
            with locked("action.lock"):
                write_settings(policy)
            subprocess.run([CTL, "enable", TARGET], check=True)
            subprocess.run([CTL, "bootstrap", DOMAIN, str(PLIST)], check=True)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            with locked("action.lock"):
                write_settings({**policy, "enabled": False})
            subprocess.run([CTL, "disable", TARGET], capture_output=True)
            unload()
            raise


def timed_out(_signum, _frame):
    raise TimeoutError("Codex 额度读取超时")


def exit_watch(_signum, _frame):
    raise SystemExit(0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("configure", "disable", "status", "watch", "refresh"))
    parser.add_argument("--enabled", choices=("on", "off"))
    parser.add_argument("--threshold", type=int, choices=range(1, 101), metavar="1..100")
    parser.add_argument("--interval", type=int, choices=INTERVALS)
    parser.add_argument("--sampler", type=Path)
    args = parser.parse_args()
    if args.command == "watch":
        if not args.sampler:
            parser.error("watch requires --sampler")
        signal.signal(signal.SIGUSR1, lambda *_: wake.set())
        signal.signal(signal.SIGALRM, timed_out)
        signal.signal(signal.SIGTERM, exit_watch)
        run_watch(args.sampler)
    elif args.command == "configure":
        if None in (args.enabled, args.threshold, args.interval):
            parser.error("configure requires --enabled, --threshold and --interval")
        configure({"enabled": args.enabled == "on", "threshold": args.threshold,
                   "interval": args.interval}, args.sampler)
    elif args.command == "disable":
        configure({**settings(), "enabled": False}, None)
    elif args.command == "refresh":
        signal_refresh()
    else:
        print(json.dumps({"settings": settings(), "loaded": loaded(), "state": read_state()}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
