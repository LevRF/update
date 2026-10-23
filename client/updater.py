#!/usr/bin/env python3
"""Клиент обновлений: сверяет локальную версию проекта с manifest.json
в репозитории обновлений и ставит последний релиз (только stdlib).

    python updater.py genom --dir "C:\\Program Files\\Genom"
    python updater.py genom-db --dir data --asset "*.db"
    python updater.py genom --check        # код выхода 10, если есть обновление

Коды выхода: 0 — всё актуально/обновлено, 10 — есть обновление (--check), 1 — ошибка.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import shutil
import sys
import time
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_REPO = "LevRF/update"
STATE_FILE = ".update.json"


def version_key(v):
    main, _, pre = v.partition("-")
    nums = [int(x) for x in main.split(".")]
    while len(nums) > 1 and nums[-1] == 0:
        nums.pop()
    return tuple(nums), pre == "", pre


def open_url(url):
    req = urllib.request.Request(url, headers={"User-Agent": "updater"})
    return urllib.request.urlopen(req, timeout=60)


def load_manifest(src):
    if src.startswith(("http://", "https://")):
        # raw.githubusercontent.com кэширует ~5 минут, параметр обходит кэш
        sep = "&" if "?" in src else "?"
        with open_url(f"{src}{sep}t={int(time.time())}") as r:
            return json.load(r)
    return json.loads(Path(src).read_text(encoding="utf-8"))


def download(url, dest, sha256):
    h = hashlib.sha256()
    part = dest.with_name(dest.name + ".part")
    if url.startswith(("http://", "https://")):
        src = open_url(url)
    else:
        src = open(url, "rb")
    with src, open(part, "wb") as out:
        for chunk in iter(lambda: src.read(1 << 20), b""):
            h.update(chunk)
            out.write(chunk)
    if h.hexdigest().lower() != sha256.lower():
        part.unlink()
        raise RuntimeError(f"{dest.name}: контрольная сумма не совпала")
    os.replace(part, dest)


def extract_zip(archive, target):
    staging = target / ".update-staging"
    shutil.rmtree(staging, ignore_errors=True)
    with zipfile.ZipFile(archive) as z:
        for name in z.namelist():
            # защита от путей вида ../../ внутри архива
            if not (staging / name).resolve().is_relative_to(staging.resolve()):
                raise RuntimeError(f"Небезопасный путь в архиве: {name}")
        z.extractall(staging)
    for path in sorted(staging.rglob("*")):
        if path.is_file():
            dst = target / path.relative_to(staging)
            dst.parent.mkdir(parents=True, exist_ok=True)
            os.replace(path, dst)
    shutil.rmtree(staging, ignore_errors=True)


def main():
    p = argparse.ArgumentParser(description="Обновление проекта из GitHub Releases")
    p.add_argument("project", help="id проекта (часть тега до -v)")
    p.add_argument("--dir", default=".", help="папка установки (по умолчанию текущая)")
    p.add_argument("--repo", default=DEFAULT_REPO, help="owner/repo репозитория обновлений")
    p.add_argument("--manifest", help="URL или путь к manifest.json (вместо --repo)")
    p.add_argument("--asset", action="append", help="маска файлов релиза, можно несколько")
    p.add_argument("--check", action="store_true", help="только проверить")
    p.add_argument("--force", action="store_true", help="переустановить даже ту же версию")
    args = p.parse_args()

    target = Path(args.dir).resolve()
    project = args.project.lower()
    src = args.manifest or f"https://raw.githubusercontent.com/{args.repo}/main/manifest.json"

    try:
        info = load_manifest(src)["projects"].get(project)
        if not info:
            print(f"Проекта {project!r} нет в манифесте", file=sys.stderr)
            return 1

        state_path = target / STATE_FILE
        state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
        current = state.get(project, {}).get("version")
        latest = info["version"]

        if current and not args.force and version_key(current) >= version_key(latest):
            print(f"{project}: актуальная версия {current}")
            return 0
        if args.check:
            print(f"{project}: доступно обновление {current or '—'} -> {latest}")
            return 10

        assets = [a for a in info["assets"]
                  if not args.asset or any(fnmatch.fnmatch(a["name"], m) for m in args.asset)]
        if not assets:
            print("В релизе нет подходящих файлов", file=sys.stderr)
            return 1

        target.mkdir(parents=True, exist_ok=True)
        for a in assets:
            print(f"Скачиваю {a['name']} ({a['size'] / 1048576:.1f} МБ)")
            dest = target / a["name"]
            if a["name"].lower().endswith(".zip"):
                tmp = target / (".update-" + a["name"])
                try:
                    download(a["url"], tmp, a["sha256"])
                    extract_zip(tmp, target)
                finally:
                    tmp.unlink(missing_ok=True)
            else:
                download(a["url"], dest, a["sha256"])

        state[project] = {"version": latest, "updated": datetime.now(timezone.utc).isoformat()}
        state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{project}: обновлено до {latest}")
        return 0
    except Exception as e:
        print(f"Ошибка обновления: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
