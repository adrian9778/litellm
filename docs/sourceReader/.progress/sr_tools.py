"""sourceReader 定位与校验工具。

四个子命令（规范见同目录 UPDATE-SPEC.md）：
  locate  SYM...           全库定位符号定义（两遍扫描：先生产树，未命中再扫 tests/scripts）
  outline FILE [--top N]   输出文件符号骨架 + docstring 首行
  offset  FILE SYM         符号定义行号（用于算函数内偏移）
  verify  DOC... [--symbols]  校验文档引用；--symbols 追加符号级校验（引用的符号是否真在该文件里）

用法：python3 -I docs/sourceReader/.progress/sr_tools.py <subcommand> ...
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]

PROD_ROOTS: tuple[str, ...] = ("litellm", "gateway", "backend", "enterprise", "litellm_cli", "litellm-proxy-extras")
FALLBACK_ROOTS: tuple[str, ...] = ("tests", "scripts", "ci_cd", "db_scripts", "migrations", "ui/litellm-dashboard")
SKIP_DIRS: frozenset[str] = frozenset({".git", "node_modules", "__pycache__", ".venv", "venv", ".zcode", "dist", "build", ".mypy_cache", ".pytest_cache"})

DEF_RE = re.compile(r"^\s*(?:class|def|async def)\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
ASGN_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=\n]+)?=", re.M)

CITED_SPAN_RE = re.compile(r"`([^`\n]+)`")
PATH_TOKEN_RE = re.compile(r"(?<![A-Za-z0-9_./-])([A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:tsx|py|yaml|yml|json|prisma|toml|md|sql|txt|pem))(?![A-Za-z0-9_./-])")
NEGATION_WORDS: tuple[str, ...] = ("不存在", "已删除", "被删", "已清空", "不再", "已改名", "已迁移", "示例", "占位", "your_", "test_x")
RUNTIME_CONFIG_HINTS: frozenset[str] = frozenset({"config.yaml", "my-config.yaml", "proxy_config.yaml", "dev_config.yaml", "model_config.yaml", ".env", "public_key.pem"})


def iter_py_files(roots: tuple[str, ...]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        base = REPO_ROOT / root
        if base.is_file():
            files.append(base)
            continue
        if not base.is_dir():
            continue
        for path in base.rglob("*.py"):
            if not any(part in SKIP_DIRS for part in path.parts):
                files.append(path)
    for py in REPO_ROOT.glob("*.py"):
        files.append(py)
    return files


def scan_symbols(files: list[Path]) -> dict[str, list[tuple[Path, int]]]:
    found: dict[str, list[tuple[Path, int]]] = {}
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for match in DEF_RE.finditer(text):
            found.setdefault(match.group(1), []).append((path, text[: match.start()].count("\n") + 1))
        for match in ASGN_RE.finditer(text):
            found.setdefault(match.group(1), []).append((path, text[: match.start()].count("\n") + 1))
    return found


def cmd_locate(symbols: list[str]) -> int:
    prod = scan_symbols(iter_py_files(PROD_ROOTS))
    fallback = scan_symbols(iter_py_files(FALLBACK_ROOTS))
    missing: list[str] = []
    for sym in symbols:
        hits = prod.get(sym, []) or fallback.get(sym, [])
        if not hits:
            missing.append(sym)
            continue
        for path, line in hits[:6]:
            print(f"{path.relative_to(REPO_ROOT)}:{line}")
    for sym in missing:
        print(f"NOT FOUND: {sym}", file=sys.stderr)
    return 1 if missing else 0


def cmd_outline(file: str, top: int | None) -> int:
    path = REPO_ROOT / file if not Path(file).is_absolute() else Path(file)
    if not path.exists():
        print(f"no such file: {path}", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    count = 0
    for index, line in enumerate(lines, start=1):
        match = re.match(r"^(?:class|def|async def)\s+([A-Za-z_][A-Za-z0-9_]*)", line.strip())
        if match is None:
            continue
        doc = ""
        for candidate in lines[index : index + 2]:
            stripped = candidate.strip()
            if stripped.startswith('"""') or stripped.startswith("'''"):
                doc = stripped.strip('"\'')
                break
        print(f"{index:5d}  {line.strip()[:110]}  {doc[:60]}")
        count += 1
        if top is not None and count >= top:
            break
    return 0


def cmd_offset(file: str, symbol: str) -> int:
    path = REPO_ROOT / file if not Path(file).is_absolute() else Path(file)
    if not path.exists():
        print(f"no such file: {path}", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8", errors="replace")
    pattern = re.compile(rf"^\s*(?:class|def|async def)\s+{re.escape(symbol)}\b", re.M)
    match = pattern.search(text)
    if match is None:
        asgn = re.compile(rf"^\s*{re.escape(symbol)}\s*(?::[^=\n]+)?=", re.M).search(text)
        if asgn is None:
            print(f"NOT FOUND: {symbol} in {file}", file=sys.stderr)
            return 1
        print(text[: asgn.start()].count("\n") + 1)
        return 0
    print(text[: match.start()].count("\n") + 1)
    return 0


def resolve_candidate(candidate: str, doc_dir: Path) -> Path | None:
    bases: list[Path] = [REPO_ROOT, *doc_dir.parents, doc_dir]
    for base in bases:
        resolved = (base / candidate).resolve()
        if resolved.exists():
            return resolved
    resolved = (REPO_ROOT / candidate).resolve()
    return resolved if resolved.exists() else None


_KNOWN_FILES_CACHE: dict[tuple[str, ...], list[Path]] = {}


def iter_known_files(roots: tuple[str, ...]) -> list[Path]:
    cached = _KNOWN_FILES_CACHE.get(roots)
    if cached is not None:
        return cached
    files: list[Path] = []
    for root in roots:
        base = REPO_ROOT / root
        if not base.is_dir():
            continue
        for pattern in ("*.py", "*.ts", "*.tsx", "*.yaml", "*.yml", "*.json", "*.prisma", "*.toml", "*.sql", "*.md"):
            for path in base.rglob(pattern):
                if not any(part in SKIP_DIRS for part in path.parts):
                    files.append(path)
    _KNOWN_FILES_CACHE[roots] = files
    return files


_SUFFIX_INDEX_CACHE: dict[str, list[str]] = {}


def suffix_matches(candidate: str) -> list[str]:
    hit = _SUFFIX_INDEX_CACHE.get(candidate)
    if hit is not None:
        return hit
    hit = [str(p.relative_to(REPO_ROOT)) for p in iter_known_files(PROD_ROOTS + FALLBACK_ROOTS) if str(p.relative_to(REPO_ROOT)).endswith(candidate)]
    _SUFFIX_INDEX_CACHE[candidate] = hit
    return hit


PLACEHOLDER_RE = re.compile(r"NNN|(^|[/_.])Foo([/_.]|$)|test_x|your_")


def basename_index() -> dict[str, set[str]]:
    index: dict[str, set[str]] = {}
    for path in iter_known_files(PROD_ROOTS + FALLBACK_ROOTS):
        index.setdefault(path.name, set()).add(str(path.relative_to(REPO_ROOT)))
    return index


def classify_candidate(candidate: str, context: str, doc_dir: Path, basenames: dict[str, set[str]]) -> str:
    if resolve_candidate(candidate, doc_dir) is not None:
        return "ok"
    if any(word in context for word in NEGATION_WORDS) or PLACEHOLDER_RE.search(candidate):
        return "· 说明性/占位引用"
    if "/" not in candidate and candidate in basenames:
        count = len(basenames[candidate])
        return f"· 裸名缩写({count}处同名)" if count > 1 else "· 裸名缩写"
    if "/" in candidate:
        suffix_hits = suffix_matches(candidate)
        if suffix_hits:
            return f"· 尾段缩写({len(suffix_hits)}处)"
    if not candidate.startswith(".") and candidate.count("/") == 0 and candidate.endswith((".json", ".yaml", ".yml", ".toml", ".sql", ".pem", ".txt", ".env")):
        return "· 运行期/说明性文件名"
    return "✗ 疑似失效"


def cited_paths(text: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    lines_with_pos: list[tuple[int, str]] = []
    offset = 0
    for line in text.splitlines():
        lines_with_pos.append((offset, line))
        offset += len(line) + 1

    def line_for(pos: int) -> str:
        for start, line in lines_with_pos:
            if start <= pos < start + len(line) + 1:
                return line
        return ""

    for span_match in CITED_SPAN_RE.finditer(text):
        span = span_match.group(1)
        context = line_for(span_match.start())
        if " :: " in span:
            first = span.split(" :: ", 1)[0].strip()
            if PATH_TOKEN_RE.fullmatch(first):
                out.append((first, context))
                continue
        for token_match in PATH_TOKEN_RE.finditer(span):
            out.append((token_match.group(1), context))
    return out


def resolve_loose(candidate: str, doc_dir: Path, basenames: dict[str, set[str]] | None = None) -> Path | None:
    resolved = resolve_candidate(candidate, doc_dir)
    if resolved is not None:
        return resolved
    if "/" not in candidate and basenames and candidate in basenames:
        unique = sorted(basenames[candidate])
        if len(unique) == 1:
            return REPO_ROOT / unique[0]
    if "/" in candidate:
        hits = suffix_matches(candidate)
        if len(hits) == 1:
            return REPO_ROOT / hits[0]
    return None


def cmd_verify(docs: list[str], check_symbols: bool) -> int:
    problems = 0
    basenames = basename_index()
    for doc in docs:
        path = Path(doc)
        if not path.is_absolute():
            path = (REPO_ROOT / doc).resolve()
        text = path.read_text(encoding="utf-8", errors="replace")
        doc_dir = path.parent
        at_refs = re.findall(r"@#?\d+", text)
        bad: list[tuple[str, str]] = []
        for candidate, context in cited_paths(text):
            verdict = classify_candidate(candidate, context, doc_dir, basenames)
            if verdict != "ok":
                bad.append((candidate, verdict))
        symbols_problems = 0
        if check_symbols:
            symbols_problems = verify_symbols(text, doc_dir)
        hard = sum(1 for _, c in bad if c.startswith("✗")) + len(at_refs) + symbols_problems
        status = "OK" if hard == 0 else "FAIL"
        print(f"{path}: {status}  (硬伤={hard}, @行号={len(at_refs)}, 疑似失效={sum(1 for _, c in bad if c.startswith('✗'))}, 分类豁免={sum(1 for _, c in bad if not c.startswith('✗'))}, 符号级问题={symbols_problems})")
        for candidate, verdict in bad:
            print(f"  {verdict}: {candidate}")
        problems += hard
    return 1 if problems else 0


def verify_symbols(text: str, doc_dir: Path) -> int:
    problems = 0
    basenames = basename_index()
    for span_match in CITED_SPAN_RE.finditer(text):
        span = span_match.group(1)
        if " :: " not in span:
            continue
        parts = [p.strip() for p in span.split(" :: ")]
        path_part = parts[0]
        if not PATH_TOKEN_RE.fullmatch(path_part):
            continue
        resolved = resolve_loose(path_part, doc_dir, basenames)
        if resolved is None or resolved.suffix != ".py":
            continue
        try:
            body = resolved.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        defined = {m for m in DEF_RE.findall(body)} | {m for m in ASGN_RE.findall(body)}
        for symbol_part in parts[1:]:
            if "+" in symbol_part or "行" in symbol_part:
                continue
            name = symbol_part.strip("()").replace("async ", "").replace("def ", "").replace("class ", "")
            name = name.split("（")[0].strip()
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", name):
                continue
            leaf = name.split(".")[-1]
            if leaf not in defined and name not in defined:
                print(f"  符号未归属: {path_part} :: {symbol_part}（原文片段）")
                problems += 1
    return problems


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    command, rest = args[0], args[1:]
    if command == "locate":
        return cmd_locate(rest)
    if command == "outline":
        top = None
        if "--top" in rest:
            index = rest.index("--top")
            top = int(rest[index + 1])
            rest = rest[:index] + rest[index + 2 :]
        return cmd_outline(rest[0], top)
    if command == "offset":
        return cmd_offset(rest[0], rest[1])
    if command == "verify":
        check = "--symbols" in rest
        docs = [a for a in rest if not a.startswith("--")]
        return cmd_verify(docs, check)
    print(f"unknown subcommand: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
