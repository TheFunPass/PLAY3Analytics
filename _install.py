"""
One-shot installer: pushes PLAY3_SDK into the connected Studio place
via the PLAY3RBX coordinator. Run after `node dist/index.js`.

Server side  → ServerScriptService.PLAY3_SDK
Client side  → StarterPlayer.StarterPlayerScripts.PLAY3_SDK_Client

API keys in Config are preserved across reinstalls.
"""
import json, os, re, urllib.request, urllib.error

SDK_ROOT = os.path.dirname(os.path.abspath(__file__))
COORDINATOR = "http://localhost:4001"
SLOT = 3002

SERVER_ROOT = "game.ServerScriptService.PLAY3_SDK"
CLIENT_ROOT = "game.StarterPlayer.StarterPlayerScripts.PLAY3_SDK_Client"

# Folders to create (parent already exists)
FOLDERS = [
    ("PLAY3_SDK",        "game.ServerScriptService"),
    ("Core",             SERVER_ROOT),
    ("Analytics",        SERVER_ROOT),
    ("Modules",          SERVER_ROOT),
    ("Addons",           SERVER_ROOT),
    ("Leaderboard",      f"{SERVER_ROOT}.Addons"),
    ("PLAY3_SDK_Client", "game.StarterPlayer.StarterPlayerScripts"),
]

# (name, className, parent path, source file relative to SDK_ROOT)
SCRIPTS = [
    ("Main",            "Script",       SERVER_ROOT,                "Main.server.lua"),
    ("Config",          "ModuleScript", SERVER_ROOT,                "Config.lua"),
    ("HttpQueue",       "ModuleScript", f"{SERVER_ROOT}.Core",      "Core/HttpQueue.lua"),
    ("PlayerState",     "ModuleScript", f"{SERVER_ROOT}.Core",      "Core/PlayerState.lua"),
    ("DeviceTracker",   "ModuleScript", f"{SERVER_ROOT}.Core",      "Core/DeviceTracker.lua"),
    ("HashLib",         "ModuleScript", f"{SERVER_ROOT}.Core",      "Core/HashLib/init.lua"),
    ("Base64",          "ModuleScript", f"{SERVER_ROOT}.Core.HashLib", "Core/HashLib/Base64.lua"),
    ("SessionTracker",  "Script",       f"{SERVER_ROOT}.Analytics", "Analytics/SessionTracker.server.lua"),
    ("PlayerAnalyzer",  "Script",       f"{SERVER_ROOT}.Analytics", "Analytics/PlayerAnalyzer.server.lua"),
    ("PurchaseTracker", "Script",       f"{SERVER_ROOT}.Analytics", "Analytics/PurchaseTracker.server.lua"),
    ("ChatTracker",     "Script",       f"{SERVER_ROOT}.Analytics", "Analytics/ChatTracker.server.lua"),
    ("Attribution",     "ModuleScript", f"{SERVER_ROOT}.Modules",   "Modules/Attribution.lua"),
    ("Leaderboard",     "ModuleScript", f"{SERVER_ROOT}.Modules",   "Modules/Leaderboard.lua"),
    ("LeaderboardBoard","ModuleScript", f"{SERVER_ROOT}.Modules",   "Modules/LeaderboardBoard.lua"),
    ("Mount",           "Script",       f"{SERVER_ROOT}.Addons.Leaderboard", "Addons/Leaderboard/Mount.server.lua"),
    ("DeviceInfoClient","LocalScript",  CLIENT_ROOT,                "Client/DeviceInfoClient.client.lua"),
]

KEY_PATTERNS = ["PLAY3_API_KEY", "ATTRIBUTION_API_KEY"]


def post(tool, payload):
    url = f"{COORDINATOR}/api/tools/{SLOT}/{tool}"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def read_existing_config_keys():
    """Read API keys from the currently-installed Config so we can restore
    them after the wipe. Returns {} if the SDK isn't installed yet."""
    status, body = post("get_script_source", {"instancePath": f"{SERVER_ROOT}.Config"})
    if not (200 <= status < 300):
        return {}
    try:
        src = json.loads(body).get("source", "")
    except Exception:
        return {}
    out = {}
    for key in KEY_PATTERNS:
        m = re.search(rf'{key}\s*=\s*"([^"]*)"', src)
        if m and not m.group(1).startswith("YOUR_"):
            out[key] = m.group(1)
    return out


def wipe_existing():
    code = (
        'local sss = game.ServerScriptService:FindFirstChild("PLAY3_SDK"); '
        'if sss then sss:Destroy() end; '
        'local sps = game.StarterPlayer:FindFirstChild("StarterPlayerScripts"); '
        'local c = sps and sps:FindFirstChild("PLAY3_SDK_Client"); '
        'if c then c:Destroy() end; '
        'return "ok"'
    )
    return post("execute_lua", {"code": code})


def restore_config_keys(preserved):
    """After Config has been pushed (with placeholders), substitute the keys
    we saved. Done via Source.gsub in Studio so we don't have to re-read+write
    the whole file from Python."""
    if not preserved:
        return
    # Build a Lua snippet that gsubs each placeholder line in place.
    replacements = []
    for key, value in preserved.items():
        # Escape value just enough for a Lua string literal.
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        replacements.append(
            f'src = src:gsub(\'{key} = "YOUR_[^"]*"\', \'{key} = "{escaped}"\')'
        )
    code = (
        f'local cfg = {SERVER_ROOT}.Config; '
        'local src = cfg.Source; '
        + "; ".join(replacements) + "; "
        'cfg.Source = src; '
        'return "restored: " .. tostring(#src)'
    )
    return post("execute_lua", {"code": code})


def main():
    print("[1/5] Reading existing API keys (for preservation) …")
    preserved = read_existing_config_keys()
    if preserved:
        print(f"        preserved: {', '.join(preserved.keys())}")
    else:
        print("        (none — fresh install or all placeholders)")

    print("[2/5] Wiping any existing PLAY3_SDK + client …")
    status, body = wipe_existing()
    print("       ", status, body[:200])

    print("[3/5] Creating folders …")
    for name, parent in FOLDERS:
        status, _ = post("create_object", {"className": "Folder", "parent": parent, "name": name})
        print(f"        {parent}.{name}: {status}")

    print("[4/5] Creating scripts + pushing source …")
    for name, cls, parent, rel in SCRIPTS:
        path = os.path.join(SDK_ROOT, rel.replace("/", os.sep))
        with open(path, "r", encoding="utf-8") as f:
            source = f.read()
        instance_path = f"{parent}.{name}"
        # create_object then set_script_source — coordinator's create_object
        # doesn't accept a source parameter.
        status, body = post("create_object", {"className": cls, "parent": parent, "name": name})
        if not (200 <= status < 300):
            print(f"        [FAIL] create {instance_path} ({cls}): {body[:200]}")
            continue
        status, body = post("set_script_source", {"instancePath": instance_path, "source": source})
        marker = "OK" if 200 <= status < 300 else "FAIL"
        print(f"        [{marker}] {instance_path}  ({cls}, {len(source)} bytes)")
        if marker == "FAIL":
            print("               ", body[:300])

    print("[5/5] Restoring preserved API keys …")
    if preserved:
        status, body = restore_config_keys(preserved)
        print("       ", status, body[:120])
    else:
        print("        (skipped — none to restore)")

    print("Done.")


if __name__ == "__main__":
    main()
