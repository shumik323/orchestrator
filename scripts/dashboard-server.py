#!/usr/bin/env python3
"""Сервер дашборда: статика из корня репозитория + два действия над очередью.

POST /api/run   {"conf": "projects/x.conf", "id": "t-1"}  → run-task.sh в фоне, 202 {"pid": N}
POST /api/ready {"conf": "projects/x.conf", "id": "t-1"}  → queue_set_status … ready (переходы держит
                                                           библиотека очереди), 200 / 409

Только 127.0.0.1 и только с заголовком X-Orc: чужая страница в браузере может отправить POST на
localhost, но кастомный заголовок требует preflight, на который сервер не отвечает. Python stdlib —
тот же рантайм, что у dashboard.sh, новых зависимостей у оркестратора не появляется.
"""
import json, os, re, subprocess, sys, threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
STATE = os.environ.get("ORC_STATE") or os.path.expanduser("~/.orchestrator")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}$")
CONF_RE = re.compile(r"^projects/[A-Za-z0-9_.-]+\.conf$")
running = {}  # id → Popen; повторный запуск той же задачи, пока первая идёт, — отказ
run_lock = threading.Lock()  # ThreadingHTTPServer: два клика подряд не должны дать два раннера
# Наружу отдаются только эти пути: статика из корня целиком открывала /.git и /state/runs с промптами
# (ревью 20.09). projects/*.conf, включая *.local.conf, отдаются намеренно: дашборду нужен QUEUE_FILE
# для кнопок, секретов в них нет — токены живут в окружении. Всё остальное — 404.
GET_ALLOWED = re.compile(r"^/(dashboard/[^/]*|queue/|queue/[^/]+\.jsonl|mr/[^/]+\.md|projects/|projects/[^/]+\.conf|state/logs/[^/]+/(events\.jsonl|scratch/[^/]+\.md|stdout/[^/]+|review/[^/]+\.(md|json|patch|log)))$")
# Ходы бота из stream-json генератора: вызовы тулов по мере записи файла, без чтения его целиком
# клиентом (init-строка одна весит ~8 KB, лог прогона — сотни KB).
STEPS_RE = re.compile(r"^/state/logs/([A-Za-z0-9_.-]+)/steps\.json$")
HOST_OK = re.compile(r"^(localhost|127\.0\.0\.1)(:\d+)?$")


def reap():
    for tid, p in list(running.items()):
        if p.poll() is not None:
            del running[tid]


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def log_message(self, fmt, *args):  # тихий доступ к статике; действия печатаем сами
        if self.path.startswith("/api/"):
            sys.stderr.write("%s %s\n" % (self.command, fmt % args))

    def do_GET(self):
        if not HOST_OK.match(self.headers.get("Host", "")):
            return self._json(403, {"error": "Host не localhost"})
        if self.path in ("/", "/dashboard"):
            self.send_response(302); self.send_header("Location", "/dashboard/"); self.end_headers(); return
        # Белый список сверяется с ДЕКОДИРОВАННЫМ путём: translate_path делает unquote после проверки,
        # и /dashboard/..%2f.git%2fHEAD проходил регексп как dashboard/<файл> (ревью 21.09).
        path = unquote(self.path.split("?", 1)[0])
        if ".." in path.split("/"):
            return self._json(404, {"error": "нет такого пути"})
        m = STEPS_RE.match(path)
        if m:
            return self.steps(m.group(1))
        if not GET_ALLOWED.match(path):
            return self._json(404, {"error": "нет такого пути"})
        return super().do_GET()

    def steps(self, tid):
        path = os.path.join(STATE, "logs", tid, "stdout", "implement.log")
        steps, done = [], False
        # Расход по ходу: usage лежит в каждой assistant-строке, но один message.id повторяется в
        # нескольких строках (параллельные блоки), а output_tokens там заглушка — считаем вход и кэш
        # один раз на id, выход не считаем (нижняя оценка). Итоговая цена приходит только в result.
        seen, usage = set(), {"turns": 0, "input": 0, "cache_write": 0, "cache_read": 0}
        # Цикл линта: бот повторяет один и тот же вызов с теми же аргументами. Пять подряд — сигнал
        # владельцу до того, как бюджет кончится (faqs 20.09: 18 ходов в lint-all до $2.50).
        prev_key, run_n, worst = None, 0, {"n": 0, "tool": "", "target": ""}
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if not line.startswith("{"):
                        continue
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        continue
                    if ev.get("type") == "assistant":
                        msg = ev.get("message") or {}
                        mid = msg.get("id")
                        if mid and mid not in seen:
                            seen.add(mid)
                            u = msg.get("usage") or {}
                            usage["turns"] += 1
                            usage["input"] += int(u.get("input_tokens") or 0)
                            usage["cache_write"] += int(u.get("cache_creation_input_tokens") or 0)
                            usage["cache_read"] += int(u.get("cache_read_input_tokens") or 0)
                        for block in msg.get("content") or []:
                            if block.get("type") == "tool_use":
                                inp = block.get("input") or {}
                                target = inp.get("file_path") or inp.get("command") or inp.get("pattern") or inp.get("description") or ""
                                step = {"tool": block.get("name", "?"), "target": str(target)[:160]}
                                steps.append(step)
                                key = (step["tool"], json.dumps(inp, sort_keys=True, ensure_ascii=False))
                                run_n = run_n + 1 if key == prev_key else 1
                                prev_key = key
                                if run_n > worst["n"]:
                                    worst = {"n": run_n, "tool": step["tool"], "target": step["target"]}
                    elif ev.get("type") == "result":
                        done = True
        except OSError:
            pass  # лога ещё нет (фаза клона) или генератор старого формата — пустой список, не ошибка
        return self._json(200, {"total": len(steps), "done": done, "last": steps[-8:], "usage": usage,
                                "repeat": worst if worst["n"] >= 5 else None})

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not HOST_OK.match(self.headers.get("Host", "")):
            return self._json(403, {"error": "Host не localhost"})
        if self.headers.get("X-Orc") != "1":
            return self._json(403, {"error": "нет заголовка X-Orc"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
            if not isinstance(req, dict):
                raise ValueError("не объект")
            conf, tid = req.get("conf", ""), req.get("id", "")
            if not isinstance(conf, str) or not isinstance(tid, str):
                raise ValueError("conf и id — строки")
        except (ValueError, TypeError):
            return self._json(400, {"error": "тело не JSON"})
        if not CONF_RE.match(conf) or not os.path.isfile(os.path.join(ROOT, conf)):
            return self._json(400, {"error": "conf: ожидается projects/<имя>.conf"})
        if not ID_RE.match(tid):
            return self._json(400, {"error": "id: буквы, цифры, _ . -"})
        if self.path == "/api/run":
            return self.run_task(conf, tid)
        if self.path == "/api/ready":
            return self.set_ready(conf, tid)
        return self._json(404, {"error": "нет такого действия"})

    def run_task(self, conf, tid):
        with run_lock:
            reap()
            if tid in running:
                return self._json(409, {"error": "уже идёт", "pid": running[tid].pid})
            # Одна очередь — один прогон за раз: лок в queue.sh бережёт файл, но два раннера на одной
            # очереди делят и рабочие каталоги, и лимит подписки.
            busy = [t for t, p in running.items() if getattr(p, "conf", None) == conf]
            if busy:
                return self._json(409, {"error": "очередь занята: идёт " + ", ".join(busy)})
            logdir = os.path.join(STATE, "logs", tid)
            os.makedirs(logdir, exist_ok=True)
            out = open(os.path.join(logdir, "dashboard-run.log"), "ab")
            p = subprocess.Popen(
                ["bash", os.path.join(ROOT, "scripts", "run-task.sh"), conf, tid],
                cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
            p.conf = conf
            running[tid] = p
        return self._json(202, {"pid": p.pid, "log": out.name})

    def set_ready(self, conf, tid):
        # Файл очереди берётся из conf так же, как в run-task.sh: парсинг строки, не source.
        qf = queue_file(conf)
        if not qf:
            return self._json(400, {"error": "в conf нет QUEUE_FILE"})
        r = subprocess.run(
            ["bash", "-c", '. "$1/scripts/lib/queue.sh" && queue_set_status "$2" "$3" ready', "_", ROOT, qf, tid],
            cwd=ROOT, capture_output=True, text=True,
        )
        if r.returncode != 0:
            return self._json(409, {"error": r.stderr.strip() or "переход запрещён"})
        return self._json(200, {"id": tid, "status": "ready"})


def queue_file(conf):
    with open(os.path.join(ROOT, conf), encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^\s*QUEUE_FILE\s*=\s*"?([^"\n]+)"?\s*$', line)
            if m:
                return m.group(1).replace("$ORC_ROOT", ROOT).replace("$HOME", os.path.expanduser("~"))
    return None


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("дашборд: http://localhost:%d/dashboard/  (Ctrl-C — остановить)" % port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
