#!/usr/bin/env python3
"""Fixed Ubuntu operations. Input is data only; subprocess never uses shell=True.

Run by Wsl.psm1 as root. Runtime/tool downloads execute as the normal Linux user.
The Windows manifest is mirrored with root-owned, atomic per-package Linux state.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import urllib.request


def run(args, capture=False, user=False, check=True):
    if user:
        args = ["runuser", "-u", PLAN["user"], "--", "env", "HOME=" + str(HOME),
                "PATH=" + str(HOME / ".local/bin") + ":/usr/local/bin:/usr/bin:/bin",
                "MISE_YES=1"] + list(args)
    print("+ " + " ".join(args), flush=True)
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None,
                            env={**os.environ, "DEBIAN_FRONTEND": "noninteractive", "LC_ALL": "C"})
    if check and result.returncode:
        raise RuntimeError("exit %s: %s\n%s" % (result.returncode, args, result.stderr or ""))
    return result.stdout.strip() if capture and check else result


def save():
    temp = ROOT / "state.tmp"
    temp.write_text(json.dumps(STATE, indent=2), encoding="utf-8")
    os.replace(temp, ROOT / "state.json")


def step(name, action, satisfied=None):
    try:
        if satisfied is not None and satisfied():
            STATE["steps"][name] = {"status": "satisfied", "error": None}
            save()
            return True
        if satisfied is None and STATE["steps"].get(name, {}).get("status") == "done":
            return True
        STATE["steps"][name] = {"status": "running", "error": None}
        save()
        action()
        STATE["steps"][name] = {"status": "done", "error": None}
        save()
        return True
    except Exception as exc:
        STATE["steps"][name] = {"status": "failed", "error": str(exc)}
        save()
        print("FAILED %s: %s" % (name, exc), file=sys.stderr, flush=True)
        return False


def backup(path):
    key = str(path)
    if key not in STATE["backups"]:
        dest = ROOT / ("backup-" + hashlib.sha256(key.encode()).hexdigest())
        if path.exists():
            shutil.copy2(path, dest)
        STATE["backups"][key] = str(dest) if path.exists() else None
        save()


def write(path, content, user=False):
    backup(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # In-place writing preserves symlinks and existing modes/ownership.
    path.write_text(content, encoding="utf-8")
    if user:
        os.chown(path, ACCOUNT.pw_uid, ACCOUNT.pw_gid)


def installed(package):
    result = run(["dpkg-query", "-W", "-f=${Status}", package], capture=True, check=False)
    present = result.returncode == 0 and result.stdout == "install ok installed"
    if present:
        STATE.setdefault("observed", {})["apt:" + package] = run(["dpkg-query", "-W", "-f=${Version}", package], capture=True)
        save()
    return present


def apt_install(package):
    key = "apt:" + package
    if key not in STATE["versions"]:
        output = run(["apt-cache", "policy", package], capture=True)
        match = re.search(r"^\s*Candidate:\s+(\S+)", output, re.M)
        if not match or match[1] == "(none)":
            raise RuntimeError("No APT candidate: " + package)
        STATE["versions"][key] = match[1]
        save()
    run(["apt-get", "install", "-y", "--no-install-recommends", package + "=" + STATE["versions"][key]])
    if not installed(package):
        raise RuntimeError("Package missing after installation: " + package)


def get_https(url):
    request = urllib.request.Request(url, headers={"User-Agent": "perfect-win11/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        if not response.url.startswith("https://"):
            raise RuntimeError("HTTPS downgrade refused")
        return response.read()


def install_mise():
    if "mise" not in STATE["versions"]:
        release = json.loads(get_https("https://api.github.com/repos/jdx/mise/releases/latest"))
        version = release["tag_name"].removeprefix("v")
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise RuntimeError("Unexpected mise release")
        STATE["versions"]["mise"] = version
        save()
    installer = ROOT / "mise-install.sh"
    if not installer.exists():
        data = get_https("https://mise.run")
        STATE["installerSha256"] = hashlib.sha256(data).hexdigest()
        save()
        temporary = ROOT / "mise-install.tmp"
        temporary.write_bytes(data)
        os.replace(temporary, installer)
    if hashlib.sha256(installer.read_bytes()).hexdigest() != STATE.get("installerSha256"):
        raise RuntimeError("Cached mise installer checksum mismatch")
    # Official installer verifies release checksums. Never execute as root.
    run(["env", "MISE_VERSION=" + STATE["versions"]["mise"], "sh", str(installer)], user=True)
    run([str(MISE), "--version"], user=True)


def install_tool(tool, selector):
    key = "mise:" + tool
    if key not in STATE["versions"]:
        version = run([str(MISE), "latest", tool + "@" + selector], capture=True, user=True)
        if not re.fullmatch(r"[0-9][0-9A-Za-z.+_-]*", version):
            raise RuntimeError("Unexpected version for " + tool)
        STATE["versions"][key] = version
        save()
    config = HOME / ".config/mise/config.toml"
    backup(config)
    run([str(MISE), "use", "--global", tool + "@" + STATE["versions"][key]], user=True)


def tool_satisfied(tool):
    key = "mise:" + tool
    if key not in STATE["versions"]:
        return False
    return run([str(MISE), "where", tool + "@" + STATE["versions"][key]], capture=True, user=True, check=False).returncode == 0


def systemd():
    path = Path("/etc/wsl.conf")
    # Preserve other INI sections, comments, and keys rather than rewriting them.
    text = path.read_text() if path.exists() else ""
    section = re.search(r"(?ms)^\[boot\][ \t]*\n(.*?)(?=^\[|\Z)", text)
    if section:
        body = section[1]
        if re.search(r"(?m)^\s*systemd\s*=", body):
            body = re.sub(r"(?m)^\s*systemd\s*=.*$", "systemd=true", body)
        else:
            body += "\nsystemd=true\n"
        text = text[:section.start(1)] + body + text[section.end(1):]
    else:
        text += "\n[boot]\nsystemd=true\n"
    write(path, text)


def configure_bash():
    path = HOME / ".bashrc"
    text = path.read_text() if path.exists() else ""
    begin, end = "# >>> perfect-win11 >>>", "# <<< perfect-win11 <<<"
    if text.count(begin) != text.count(end) or text.count(begin) > 1:
        raise RuntimeError("Malformed existing managed Bash block; fix it before resuming")
    block = [begin, 'export PATH="$HOME/.local/bin:$PATH"']
    if "fd-find" in PLAN["apt"]:
        block.append("command -v fd >/dev/null || alias fd=fdfind")
    if "bat" in PLAN["apt"]:
        block.append("command -v bat >/dev/null || alias bat=batcat")
    if "mise" in PLAN["features"]:
        block.append('eval "$(mise activate bash)"')
    if "zoxide" in PLAN["apt"]:
        block.append('command -v zoxide >/dev/null && eval "$(zoxide init bash)"')
    if "starship" in PLAN["features"]:
        block.append('command -v starship >/dev/null && eval "$(starship init bash)"')
    block.append(end)
    replacement = "\n".join(block)
    pattern = re.escape(begin) + r".*?" + re.escape(end)
    text = re.sub(pattern, lambda _: replacement, text, flags=re.S) if begin in text else text.rstrip() + "\n\n" + replacement + "\n"
    write(path, text, user=True)


def docker_repo():
    conflicts = [p for p in ("docker.io", "docker-compose", "docker-compose-v2", "docker-doc", "podman-docker", "containerd", "runc") if installed(p)]
    if conflicts:
        raise RuntimeError("Existing Docker/container packages require manual migration before resume: " + ", ".join(conflicts))
    key = Path("/etc/apt/keyrings/perfect-win11-docker.asc")
    write(key, get_https("https://download.docker.com/linux/ubuntu/gpg").decode())
    key.chmod(0o644)
    source = Path("/etc/apt/sources.list.d/perfect-win11-docker.sources")
    write(source, "Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: " + str(key) + "\n")
    run(["apt-get", "update"])


def docker_service():
    run(["systemctl", "enable", "--now", "docker"])
    run(["usermod", "-aG", "docker", PLAN["user"]])
    run(["systemctl", "is-active", "--quiet", "docker"])


def verify():
    commands = []
    if "runtimes" in PLAN["features"]:
        commands.extend([["node", "--version"], ["python", "--version"], ["go", "version"], ["rustc", "--version"], ["ruby", "--version"]])
    if "starship" in PLAN["features"]:
        commands.append(["starship", "--version"])
    for command in commands:
        step("verify:" + command[0], lambda c=command: run([str(MISE), "exec", "--"] + c, user=True), satisfied=lambda: False)
    if "docker" in PLAN["features"]:
        for command in (["docker", "run", "--rm", "hello-world"], ["docker", "compose", "version"], ["docker", "buildx", "version"]):
            step("verify:" + " ".join(command[:2]), lambda c=command: run(c, user=True), satisfied=lambda: False)


def main():
    global PLAN, HOME, ACCOUNT, ROOT, STATE, MISE
    PLAN = json.loads(base64.b64decode(os.environ["PW11_PLAN"], validate=True))
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", PLAN["user"]) or PLAN["user"] == "root":
        raise ValueError("Invalid Linux user")
    if any(not isinstance(p, str) or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", p) for p in PLAN["apt"]):
        raise ValueError("Invalid APT package")
    if set(PLAN["features"]) - {"mise", "starship", "runtimes", "docker"}:
        raise ValueError("Invalid feature")
    ACCOUNT = pwd.getpwnam(PLAN["user"])
    HOME = Path(ACCOUNT.pw_dir)
    MISE = HOME / ".local/bin/mise"
    ROOT = Path("/var/lib/perfect-win11")
    ROOT.mkdir(mode=0o755, parents=True, exist_ok=True)
    state_path = ROOT / "state.json"
    STATE = json.loads(state_path.read_text()) if state_path.exists() else {"user": PLAN["user"], "versions": {}, "steps": {}, "backups": {}}
    if STATE["user"] != PLAN["user"]:
        raise RuntimeError("Linux state belongs to another user")
    os.chdir(HOME)  # Do not evaluate mise config in the invoking Windows project.
    if PLAN["phase"] == "systemd":
        return 0 if step("systemd", systemd) else 1
    if PLAN["phase"] == "verify":
        verify()
    elif PLAN["phase"] == "install":
        run(["apt-get", "update"])
        for package in PLAN["apt"]:
            step("apt:" + package, lambda p=package: apt_install(p), lambda p=package: installed(p))
        if "mise" in PLAN["features"]:
            mise_ok = step("mise", install_mise, lambda: MISE.is_file())
            if mise_ok:
                if "runtimes" in PLAN["features"]:
                    for tool, selector in (("core:node", "lts"), ("core:python", "latest"), ("core:go", "latest"), ("core:rust", "latest"), ("core:ruby", "latest")):
                        step(tool, lambda t=tool, s=selector: install_tool(t, s), lambda t=tool: tool_satisfied(t))
                if "starship" in PLAN["features"]:
                    step("starship", lambda: install_tool("aqua:starship/starship", "latest"), lambda: tool_satisfied("aqua:starship/starship"))
        step("bash", configure_bash)
        if "docker" in PLAN["features"] and step("docker-repository", docker_repo):
            ok = True
            for package in ("docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin"):
                ok = step("apt:" + package, lambda p=package: apt_install(p), lambda p=package: installed(p)) and ok
            if ok:
                step("docker-service", docker_service)
    else:
        raise ValueError("Unknown phase")
    failures = {k: v for k, v in STATE["steps"].items() if v["status"] in ("failed", "running")
                and (PLAN["phase"] != "install" or not k.startswith("verify:"))}
    print(json.dumps({"failures": failures}, indent=2), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
