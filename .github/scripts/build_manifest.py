#!/usr/bin/env python3
"""Собирает manifest.json из всех опубликованных релизов репозитория.

Тег релиза: <project>-v<version>, например genom-v1.2.0 или genom-db-v2024.10.1.
Для каждого проекта в манифест попадает только последняя (не draft, не prerelease) версия.
Подпись файла X берётся из файла X.sig того же релиза; без подписи клиенты файл не установят.

Запуск: GITHUB_TOKEN=... GITHUB_REPOSITORY=owner/repo python build_manifest.py manifest.json
"""
import hashlib
import json
import os
import re
import sys
import urllib.request

TAG_RE = re.compile(
    r"^(?P<project>[A-Za-z0-9][A-Za-z0-9._-]*?)-v(?P<version>\d+(?:\.\d+)*(?:-[0-9A-Za-z.-]+)?)$"
)
API = os.environ.get("GITHUB_API_URL", "https://api.github.com")


def version_key(v):
    main, _, pre = v.partition("-")
    nums = [int(x) for x in main.split(".")]
    while len(nums) > 1 and nums[-1] == 0:
        nums.pop()
    # релиз без суффикса старше prerelease с тем же номером
    return tuple(nums), pre == "", pre


def request(url, token, accept="application/vnd.github+json"):
    headers = {"Accept": accept, "User-Agent": "updates-manifest"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60)


def list_releases(repo, token):
    page = 1
    while True:
        with request(f"{API}/repos/{repo}/releases?per_page=100&page={page}", token) as r:
            batch = json.load(r)
        if not batch:
            return
        yield from batch
        page += 1


def download(url):
    # Репозиторий публичный: качаем без токена, иначе он уйдёт в редирект на хранилище файлов
    req = urllib.request.Request(url, headers={"User-Agent": "updates-manifest"})
    return urllib.request.urlopen(req, timeout=60)


def sha256_of(url):
    h = hashlib.sha256()
    with download(url) as r:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_signature(url):
    with download(url) as r:
        data = r.read(4096)
    return data.decode("ascii").strip()


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "manifest.json"
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ.get("GITHUB_TOKEN")

    # Старые хэши переиспользуем, чтобы не перекачивать файлы без поля digest
    known = {}
    if os.path.exists(out_path):
        with open(out_path, encoding="utf-8") as f:
            old = json.load(f)
        for proj in old.get("projects", {}).values():
            for a in proj.get("assets", []):
                known[(a["url"], a["size"])] = a["sha256"]

    latest = {}
    for rel in list_releases(repo, token):
        if rel["draft"] or rel["prerelease"]:
            continue
        m = TAG_RE.match(rel["tag_name"])
        if not m:
            print(f"skip: тег {rel['tag_name']!r} не в формате <project>-v<version>")
            continue
        project, version = m["project"].lower(), m["version"]
        cur = latest.get(project)
        if cur is None or version_key(version) > version_key(cur["version"]):
            latest[project] = {"version": version, "release": rel}

    projects = {}
    for project, item in sorted(latest.items()):
        rel = item["release"]
        sigs = {a["name"][:-4]: a for a in rel["assets"] if a["name"].endswith(".sig")}
        assets = []
        for a in sorted(rel["assets"], key=lambda a: a["name"]):
            if a["name"].endswith(".sig"):
                continue
            url, size = a["browser_download_url"], a["size"]
            digest = a.get("digest") or ""
            if digest.startswith("sha256:"):
                sha = digest.split(":", 1)[1]
            else:
                sha = known.get((url, size)) or sha256_of(url)
            sig = sigs.get(a["name"])
            if sig is None:
                print(f"warning: {rel['tag_name']}/{a['name']} без подписи — клиенты его не установят")
            assets.append({
                "name": a["name"], "url": url, "size": size, "sha256": sha,
                "signature": read_signature(sig["browser_download_url"]) if sig else None,
            })
        projects[project] = {
            "version": item["version"],
            "tag": rel["tag_name"],
            "published": rel["published_at"],
            "notes": rel["html_url"],
            "assets": assets,
        }
        print(f"{project}: {item['version']} ({len(assets)} файл(ов))")

    manifest = {"schema": 1, "repo": repo, "projects": projects}
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
