#!/usr/bin/env python3
"""在远端（集群）上安装/移除 AgentsDone 的 Claude Code hooks。

    python3 install_hooks.py --install
    python3 install_hooks.py --remove
"""
import json, os, sys, time, shutil

HOME = os.path.expanduser("~")
# Claude 的配置目录：默认 ~/.claude，可用 CLAUDE_CONFIG_DIR 覆盖（与 Claude Code 本身一致）
CLAUDE_DIR = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"))
SETTINGS = os.path.join(CLAUDE_DIR, "settings.json")
# spool 落盘位置，可用 AGENTSDONE_SPOOL 覆盖；安装时展开成绝对路径写进 hook
SPOOL_PATH = os.path.expanduser(os.environ.get("AGENTSDONE_SPOOL")
                                or os.path.join(HOME, ".agentsdone", "spool.jsonl"))
SPOOL = ("python3 -c \"import sys,json,os;"
         "p=" + repr(SPOOL_PATH) + ";"
         "os.makedirs(os.path.dirname(p),exist_ok=True);"
         "e=json.load(sys.stdin);"
         "e['_tp']=os.environ.get('TERM_PROGRAM','');"
         "open(p,'a').write(json.dumps(e,ensure_ascii=False)+chr(10))\"")
EVENTS = ["Stop", "Notification", "PermissionRequest", "SessionStart", "PostToolUse", "SessionEnd"]
MARK = "agentsdone"


def load():
    try:
        with open(SETTINGS, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def real(p):
    """settings.json 常是个符号链接（指向持久 home），要写到真实文件、保住链接"""
    try:
        return os.path.realpath(p)
    except Exception:
        return p


def dump(obj, path):
    target = real(path)
    tmp = target + ".agentsdone-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, target)


def backup(path):
    dst = "%s.agentsdone-backup-%d" % (path, int(time.time()))
    try:
        shutil.copy2(path, dst)
        print("    备份: %s" % dst)
    except Exception as e:
        print("    ! 备份失败: %s" % e)


def main():
    mode = "remove" if "--remove" in sys.argv else "install"
    root = load()
    hooks = root.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    changed = []

    for ev in EVENTS:
        arr = hooks.get(ev)
        if not isinstance(arr, list):
            arr = []
        has = any(MARK in json.dumps(e) for e in arr)
        if mode == "install":
            if not has:
                arr.append({"hooks": [{"type": "command", "command": SPOOL, "timeout": 5}]})
                changed.append(ev)
            hooks[ev] = arr
        else:
            kept = [e for e in arr if MARK not in json.dumps(e)]
            if len(kept) != len(arr):
                changed.append(ev)
            if kept:
                hooks[ev] = kept
            else:
                hooks.pop(ev, None)

    if hooks:
        root["hooks"] = hooks
    else:
        root.pop("hooks", None)

    if not changed:
        print("    hooks 已经是最新，无需改动")
        return 0

    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    if os.path.exists(SETTINGS):
        backup(real(SETTINGS))
    dump(root, SETTINGS)
    verb = "已加入" if mode == "install" else "已移除"
    print("    %s %s: %s" % (os.uname().nodename, verb, ", ".join(changed)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
