#!/usr/bin/env python3
"""Клиент обновлений: сверяет локальную версию проекта с manifest.json
в репозитории обновлений и ставит последний релиз (только stdlib).

    python updater.py genom --dir "C:\\Program Files\\Genom"
    python updater.py genom-db --dir data --asset "*.db"
    python updater.py genom --check        # код выхода 10, если есть обновление

Каждый файл проверяется по SHA-256 и по подписи RSA, сделанной закрытым ключом владельца.
Неподписанные или изменённые файлы не устанавливаются, даже если репозиторий взломан.

Коды выхода: 0 — всё актуально/обновлено, 10 — есть обновление (--check), 1 — ошибка.
"""
import argparse
import base64
import fnmatch
import hashlib
import hmac
import json
import os
import re
import shutil
import sys
import time
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_REPO = "LevRF/update"
STATE_FILE = ".update.json"

# Открытый ключ подписи (base64). Прописывается скриптом tools/New-SigningKey.ps1
PUBLIC_KEY_N = "rbl9jYLuJaLgQlnqwmAXeVLdjrP2uG3UrzcPIJtr7pLQf7wT4YJAu8tDPxv+Ou1MVVcCwEzgcgzw4cKol7GzQsEaMhfAlISYDzIGOAM1cXFAtu4kpaRqf1gb7f4qRBvZUvBb2GHnoSgkNoQoMIAwf0N1cNfEQfDC9qi3rDGajC0pJt5LIlQBO4ImQUER8qSDIsdpDki+C4OQ6CCtYumgwRR5OW0jtkBDF4wZMWM4F8+tznoSnAcBRHRQqoFP9omJnctyi1R8DjsBsLOqn9GFbSg8kIZl3djiurAKo78A4qJ+hVioJBeMODKfpe6bcHMzbbfJbc1pS9lrPCrsI76jh8z/3aJkaAtZTQAJm66HwFeLWfUOfXBMhlaBnGw7/QYc55V7U1XuPLoMM+0Ad/hJQWqERN+oozfCK8vaxAFv/B2GgXTe7b5SvlBrzgN9vIEl5qXfmGUlKg8U6dt4ZMvGuMIWVjToTinisU12EG+xoYElvcVcJ0shJssXvD4rVHQF"
PUBLIC_KEY_E = "AQAB"

SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
VERSION_RE = re.compile(r"^\d+(?:\.\d+)*(?:-[0-9A-Za-z.-]+)?$")


def version_key(v):
    main, _, pre = v.partition("-")
    nums = [int(x) for x in main.split(".")]
    while len(nums) > 1 and nums[-1] == 0:
        nums.pop()
    return tuple(nums), pre == "", pre


def signed_message(project, version, name, sha256):
    # формат должен совпадать с tools/Signing.ps1
    return f"update-sig-v1\n{project.lower()}\n{version}\n{name}\n{sha256.lower()}".encode("utf-8")


def verify_signature(message, sig_b64):
    """Проверка подписи RSASSA-PKCS1-v1_5 / SHA-256."""
    if not PUBLIC_KEY_N:
        raise RuntimeError("в клиент не прописан открытый ключ (tools/New-SigningKey.ps1)")
    n = int.from_bytes(base64.b64decode(PUBLIC_KEY_N), "big")
    e = int.from_bytes(base64.b64decode(PUBLIC_KEY_E), "big")
    k = (n.bit_length() + 7) // 8
    try:
        sig = base64.b64decode(sig_b64 or "", validate=True)
    except ValueError:
        sig = b""
    s = int.from_bytes(sig, "big")
    if len(sig) != k or s >= n:
        return False
    em = pow(s, e, n).to_bytes(k, "big")
    t = SHA256_DIGEST_INFO + hashlib.sha256(message).digest()
    expected = b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t
    return hmac.compare_digest(em, expected)


def open_url(url):
    req = urllib.request.Request(url, headers={"User-Agent": "updater"})
    return urllib.request.urlopen(req, timeout=60)


def load_manifest(src):
    if src.startswith("https://"):
        # raw.githubusercontent.com кэширует ~5 минут, параметр обходит кэш
        sep = "&" if "?" in src else "?"
        with open_url(f"{src}{sep}t={int(time.time())}") as r:
            return json.load(r)
    if src.startswith("http://"):
        raise RuntimeError("манифест только по https")
    return json.loads(Path(src).read_text(encoding="utf-8"))


def fetch_verified(asset, dest, project, version, url_prefix):
    """Скачивает файл в dest, только если совпали SHA-256 и подпись."""
    url = asset["url"]
    if url_prefix and not url.startswith(url_prefix):
        raise RuntimeError(f"{asset['name']}: недопустимый адрес {url}")
    part = dest.with_name(dest.name + ".part")
    h = hashlib.sha256()
    src = open_url(url) if url_prefix else open(url, "rb")
    try:
        with src, open(part, "wb") as out:
            for chunk in iter(lambda: src.read(1 << 20), b""):
                h.update(chunk)
                out.write(chunk)
        sha = h.hexdigest()
        if sha != asset["sha256"].lower():
            raise RuntimeError(f"{asset['name']}: контрольная сумма не совпала")
        if not verify_signature(signed_message(project, version, asset["name"], sha), asset.get("signature")):
            raise RuntimeError(f"{asset['name']}: подпись отсутствует или неверна, файл отклонён")
        os.replace(part, dest)
    finally:
        part.unlink(missing_ok=True)


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
    # файлы из сетевого манифеста — только из релизов своего репозитория
    url_prefix = f"https://github.com/{args.repo}/releases/download/" if src.startswith("https://") else None

    try:
        info = load_manifest(src)["projects"].get(project)
        if not info:
            print(f"Проекта {project!r} нет в манифесте", file=sys.stderr)
            return 1

        latest = info["version"]
        if not VERSION_RE.match(latest):
            raise RuntimeError(f"некорректная версия в манифесте: {latest!r}")

        state_path = target / STATE_FILE
        state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
        current = state.get(project, {}).get("version")

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
        for a in assets:
            if not NAME_RE.match(a["name"]):
                raise RuntimeError(f"недопустимое имя файла: {a['name']!r}")

        target.mkdir(parents=True, exist_ok=True)
        # сначала скачиваем и проверяем всё, ставим только если проверка прошла у всех файлов
        tmps = [target / (".update-" + a["name"]) for a in assets]
        try:
            for a, tmp in zip(assets, tmps):
                print(f"Скачиваю {a['name']} ({a['size'] / 1048576:.1f} МБ)")
                fetch_verified(a, tmp, project, latest, url_prefix)
            for a, tmp in zip(assets, tmps):
                if a["name"].lower().endswith(".zip"):
                    extract_zip(tmp, target)
                else:
                    os.replace(tmp, target / a["name"])
        finally:
            for tmp in tmps:
                tmp.unlink(missing_ok=True)

        state[project] = {"version": latest, "updated": datetime.now(timezone.utc).isoformat()}
        state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{project}: обновлено до {latest}")
        return 0
    except Exception as e:
        print(f"Ошибка обновления: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
