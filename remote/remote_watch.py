#!/usr/bin/env python3
"""AgentDone 远端监听：把集群上的 Codex/Claude 事件吐成 NDJSON。

用法（Mac 侧通过 ssh 喂进来）：  ssh <host> python3 - [--dump]
  --dump  只跑一轮并把历史全吐出来（调试用）
"""
import os, sys, json, glob, time

HOME = os.path.expanduser("~")
CODEX = os.path.join(HOME, ".codex", "sessions")
SPOOL = os.path.join(HOME, ".agentdone", "spool.jsonl")
DUMP = "--dump" in sys.argv
INTERVAL = 1.5

offs = {}
meta = {}
spool_off = 0
primed = False


def out(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def read_new(path, off):
    try:
        size = os.path.getsize(path)
    except OSError:
        return off, b""
    if size <= off:
        return size, b""
    if size - off > 8 * 1024 * 1024:      # 异常大就跳到尾部，别把内存撑爆
        off = size - 128 * 1024
    try:
        with open(path, "rb") as f:
            f.seek(off)
            return size, f.read()
    except OSError:
        return off, b""


def codex_title(path):
    """会话名 = rollout 里第一条真实用户输入（跳过 <environment_context> 这类系统包装）"""
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for _, line in zip(range(400), f):
                line = line.strip()
                if '"response_item"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                p = obj.get("payload", {}) or {}
                if obj.get("type") != "response_item" or p.get("type") != "message" or p.get("role") != "user":
                    continue
                text = "".join(c.get("text", "") for c in p.get("content", [])
                               if isinstance(c, dict)).replace("\n", " ").strip()
                if not text or text.startswith("<"):
                    continue
                return text[:60]
    except Exception:
        pass
    return ""


def codex_meta(path):
    if path in meta:
        return meta[path]
    info = ("", "", "", "")
    try:
        with open(path, "rb") as f:
            p = json.loads(f.readline()).get("payload", {}) or {}
        info = (p.get("cwd") or "", p.get("originator") or "", p.get("source") or "",
                codex_title(path))
    except Exception:
        pass
    meta[path] = info
    return info


def last_assistant(path):
    """从 Claude transcript 尾巴里取最后一条助手文本"""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 96 * 1024))
            tail = f.read().decode("utf-8", "ignore")
    except Exception:
        return ""
    for line in reversed(tail.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("isSidechain"):
            continue
        msg = obj.get("message") or {}
        if obj.get("type") == "assistant" and msg.get("role") == "assistant":
            content = msg.get("content")
            texts = []
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "text":
                        texts.append(c.get("text") or "")
            elif isinstance(content, str):
                texts.append(content)
            joined = " ".join(t for t in texts if t).strip()
            if joined:
                return joined[:80]
    return ""


def claude_title(path):
    """会话名：transcript 里最后一行的 custom-title"""
    if not path:
        return ""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 96 * 1024))
            tail = f.read().decode("utf-8", "ignore")
    except Exception:
        return ""
    title = ""
    for line in tail.splitlines():
        if '"custom-title"' not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") == "custom-title" and obj.get("customTitle"):
            title = obj["customTitle"]
    return title[:60]


CLAUDE_KIND = {
    "Stop": "done",
    "Notification": "needs",
    "SessionStart": "working",
    "SessionEnd": "gone",
}


def scan(emit):
    global spool_off
    # ---- Codex：直接读它的 rollout 日志 ----
    for path in sorted(glob.glob(os.path.join(CODEX, "*", "*", "*", "rollout-*.jsonl"))):
        off = offs.get(path, 0)
        new, data = read_new(path, off)
        offs[path] = new
        if not data or not emit:
            continue
        text = data.decode("utf-8", "ignore")
        cwd, originator, source, title = codex_meta(path)
        sid = os.path.basename(path).replace("rollout-", "").replace(".jsonl", "")
        for line in text.splitlines():
            if '"task_started"' not in line and '"task_complete"' not in line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("type") != "event_msg":
                continue
            p = obj.get("payload", {}) or {}
            kind = p.get("type")
            if kind == "task_started":
                out({"agent": "codex", "kind": "working", "session": sid, "cwd": cwd,
                     "originator": originator, "source": source, "title": title, "detail": ""})
            elif kind == "task_complete":
                out({"agent": "codex", "kind": "done", "session": sid, "cwd": cwd,
                     "originator": originator, "source": source, "title": title,
                     "detail": (p.get("last_agent_message") or "")[:80]})

    # ---- Claude：读 hook 写进来的 spool ----
    new, data = read_new(SPOOL, spool_off)
    spool_off = new
    if not data or not emit:
        return
    for line in data.decode("utf-8", "ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        name = ev.get("hook_event_name") or ""
        kind = CLAUDE_KIND.get(name)
        if not kind:
            continue
        detail = ""
        if kind in ("done", "needs"):
            if kind == "needs":
                detail = (ev.get("message") or "")[:80]
            if not detail:
                detail = last_assistant(ev.get("transcript_path") or "")
        out({"agent": "claude", "kind": kind,
             "session": ev.get("session_id") or "",
             "cwd": ev.get("cwd") or "",
             "tp": ev.get("_tp") or "",
             "title": claude_title(ev.get("transcript_path") or ""),
             "detail": detail})


if DUMP:
    scan(emit=True)
    sys.exit(0)

# 启动时静默打底：把历史偏移量吃掉，不往外发
scan(emit=False)
primed = True

while True:
    time.sleep(INTERVAL)
    try:
        scan(emit=True)
    except Exception as e:
        out({"err": str(e)})
