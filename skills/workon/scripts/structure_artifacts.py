#!/usr/bin/env python3
"""Component-level structure delta between two git trees.

Emits one Markdown blob for a PR comment:

  - new and removed import edges between components; a component is
    the first package segment under the package root (a subpackage
    such as ``msks.server`` or a loose root module such as
    ``msks.identity`` — both are "msks.server" and "identity" here)
  - added and removed public API surface: module-level functions,
    classes, and constants, with function signatures
  - a Mermaid diagram of the touched components plus one hop of
    neighbors, at head state, with import-site counts as edge labels

Both trees are read through git (ls-tree + show), so the working
tree stays untouched and the base can be any ref. Packages are
auto-detected from __init__.py chains; test trees (directories
named tests, test, or test_*) and loose files beside the package
(tests, scripts) sit outside the graph. Stdlib only, Python 3.9+.

Exit status is 0 whether or not changes were found — this reports,
it does not gate.
"""

import argparse
import ast
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import PurePosixPath

EXCLUDE_PARTS = {
    ".git",
    ".devenv",
    ".worktrees",
    ".venv",
    "venv",
    "node_modules",
    "dist",
    "build",
}


def is_test_dir(part):
    return part == "tests" or part == "test" or part.startswith("test_")

MAX_SITES_SHOWN = 5
MAX_DIAGRAM_NODES = 24


def git_out(repo, *args):
    proc = subprocess.run(
        ["git", "-C", repo, *args], capture_output=True, text=True
    )
    if proc.returncode != 0:
        sys.exit(
            f"structure_artifacts: git {' '.join(args[:2])} failed:"
            f" {proc.stderr.strip()}"
        )
    return proc.stdout


def tree_py_files(repo, ref):
    lines = git_out(repo, "ls-tree", "-r", "--name-only", ref).splitlines()
    return [
        f
        for f in lines
        if f.endswith(".py")
        and not any(
            p in EXCLUDE_PARTS or is_test_dir(p)
            for p in PurePosixPath(f).parts[:-1]
        )
    ]


def package_files(files):
    """Map packaged .py files to (prefix, module_parts, is_package).

    A file is packaged when its directory chain holds __init__.py
    files up to a topmost package directory; the prefix is that
    directory's name. Files not under such a chain (tests, scripts
    sitting beside the package) are left out — they are not part of
    the component graph.
    """
    pkg_dirs = {
        str(PurePosixPath(f).parent)
        for f in files
        if PurePosixPath(f).name == "__init__.py"
    }
    out = {}
    for f in files:
        top = None
        cur = str(PurePosixPath(f).parent)
        while cur in pkg_dirs:
            top = cur
            parent = str(PurePosixPath(cur).parent)
            if parent == cur:
                break
            cur = parent
        if top is None:
            continue
        rel = PurePosixPath(f).relative_to(top)
        stem_parts = rel.with_suffix("").parts
        if stem_parts[-1] == "__init__":
            stem_parts = stem_parts[:-1]
        parts = (PurePosixPath(top).name,) + stem_parts
        out[f] = (PurePosixPath(top).name, parts, len(stem_parts) < len(rel.parts))
    return out


def component_of(prefix, parts):
    """Component for a module path: the first segment under the
    package root. Underscore segments (dunders, private helper
    modules) belong to the package root itself."""
    if not parts or parts[0] != prefix:
        return None
    if len(parts) > 1:
        return prefix if parts[1].startswith("_") else parts[1]
    return prefix


def import_targets(prefix, parts, is_package, node):
    """Dotted absolute targets of one import statement."""
    pkg_parts = parts if is_package else parts[:-1]
    targets = set()
    if isinstance(node, ast.Import):
        for alias in node.names:
            targets.add(alias.name)
        return targets
    if node.level > len(pkg_parts):
        return targets  # relative import climbing past the root
    base = (
        pkg_parts[: len(pkg_parts) - (node.level - 1)] if node.level else ()
    )
    mod = base + (tuple(node.module.split(".")) if node.module else ())
    if mod:
        targets.add(".".join(mod))
        for alias in node.names:
            if alias.name != "*":
                targets.add(".".join(mod + (alias.name,)))
    else:
        for alias in node.names:
            if alias.name != "*":
                targets.add(alias.name)
    return targets


def public_surface(body, comp, module):
    """(component, module, kind, name, signature) for module-level defs."""
    out = set()
    for node in body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if not node.name.startswith("_"):
                args = [
                    a.arg
                    for a in (
                        node.args.posonlyargs
                        + node.args.args
                        + node.args.kwonlyargs
                    )
                ]
                out.add(
                    (comp, module, "def", node.name, f"({', '.join(args)})")
                )
        elif isinstance(node, ast.ClassDef):
            if not node.name.startswith("_"):
                out.add((comp, module, "class", node.name, ""))
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and not target.id.startswith("_"):
                    out.add((comp, module, "const", target.id, ""))
        elif isinstance(node, ast.AnnAssign):
            if (
                isinstance(node.target, ast.Name)
                and not node.target.id.startswith("_")
            ):
                out.add((comp, module, "const", node.target.id, ""))
    return out


def collect(repo, ref):
    files = tree_py_files(repo, ref)
    packaged = package_files(files)
    prefixes = {prefix for prefix, _, _ in packaged.values()}
    edges = defaultdict(list)  # (src_component, dst_component) -> sites
    api = set()
    for path, (prefix, parts, is_package) in sorted(packaged.items()):
        comp = component_of(prefix, parts)
        if comp is None:
            continue
        try:
            source = git_out(repo, "show", f"{ref}:{path}")
            tree = ast.parse(source, filename=path)
        except (SyntaxError, ValueError):
            print(
                f"structure_artifacts: skipping {path} (unparsable at {ref})",
                file=sys.stderr,
            )
            continue
        for node in ast.walk(tree):
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                dsts = set()
                for target in import_targets(
                    prefix, parts, is_package, node
                ):
                    seg = tuple(target.split("."))
                    if seg[0] in prefixes:
                        dst = component_of(seg[0], seg)
                        if dst != comp:
                            dsts.add(dst)
                for dst in dsts:
                    edges[(comp, dst)].append((path, node.lineno))
        api |= public_surface(tree.body, comp, ".".join(parts))
    return edges, api, packaged


def default_base(repo):
    proc = subprocess.run(
        ["git", "-C", repo, "rev-parse", "--verify", "origin/HEAD"],
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0:
        return "origin/HEAD"
    sys.exit(
        "structure_artifacts: no --base given and origin/HEAD does not"
        " resolve; pass --base <ref> (e.g. --base origin/main)"
    )


def mermaid_id(name):
    return re.sub(r"\W", "_", name)


def render(
    base,
    tree,
    new_edges,
    removed_edges,
    api_added,
    api_removed,
    head_edges,
    changed_comps,
):
    lines = []
    lines.append(f"## Structure delta (`{base}`…`{tree}`)")
    lines.append("")

    if new_edges:
        lines.append(f"### New component edges ({len(new_edges)})")
        lines.append("")
        for (src, dst) in sorted(new_edges):
            sites = sorted(set(head_edges[(src, dst)]))
            shown = ", ".join(f"`{p}:{n}`" for p, n in sites[:MAX_SITES_SHOWN])
            extra = (
                f" (+{len(sites) - MAX_SITES_SHOWN} more)"
                if len(sites) > MAX_SITES_SHOWN
                else ""
            )
            lines.append(f"- `{src}` → `{dst}` — {len(sites)} site(s): {shown}{extra}")
        lines.append("")

    if removed_edges:
        lines.append(f"### Removed component edges ({len(removed_edges)})")
        lines.append("")
        for src, dst in sorted(removed_edges):
            lines.append(f"- `{src}` → `{dst}`")
        lines.append("")

    if api_added or api_removed:
        for label, entries in (
            ("Added public API", api_added),
            ("Removed public API", api_removed),
        ):
            if not entries:
                continue
            lines.append(f"### {label} ({len(entries)})")
            lines.append("")
            by_comp = defaultdict(list)
            for comp, module, kind, name, sig in entries:
                by_comp[comp].append((module, kind, name, sig))
            for comp in sorted(by_comp):
                lines.append(f"**{comp}**")
                lines.append("")
                for module, kind, name, sig in sorted(by_comp[comp]):
                    lines.append(f"- `{module}`: {kind} `{name}`{sig}")
                lines.append("")

    relevant = set(changed_comps)
    relevant |= {c for pair in list(new_edges) + list(removed_edges) for c in pair}
    if relevant:
        one_hop = set(relevant)
        for src, dst in head_edges:
            if src in relevant:
                one_hop.add(dst)
            if dst in relevant:
                one_hop.add(src)
        nodes = one_hop if len(one_hop) <= MAX_DIAGRAM_NODES else relevant
        lines.append("### Component diagram (touched + one hop, head state)")
        lines.append("")
        lines.append("```mermaid")
        lines.append("flowchart LR")
        for src, dst in sorted(head_edges):
            if src in nodes and dst in nodes:
                lines.append(
                    f"  {mermaid_id(src)} -->|{len(head_edges[(src, dst)])}|"
                    f" {mermaid_id(dst)}"
                )
        lines.append("```")

    if len(lines) <= 2:
        return (
            f"No component-level structural changes between `{base}`"
            f" and `{tree}`."
        )
    return "\n".join(lines).rstrip() + "\n"


def main():
    ap = argparse.ArgumentParser(
        description="Component-level structure delta between two git trees."
    )
    ap.add_argument("--base", default=None, help="base ref (default: origin/HEAD)")
    ap.add_argument("--tree", default="HEAD", help="head tree ref (default: HEAD)")
    ap.add_argument("repo", nargs="?", default=".", help="repository path")
    args = ap.parse_args()

    base = args.base or default_base(args.repo)
    merge_base = git_out(args.repo, "merge-base", args.tree, base).strip()
    if not merge_base:
        sys.exit(f"structure_artifacts: no merge base of {args.tree} and {base}")

    base_edges, base_api, _ = collect(args.repo, merge_base)
    head_edges, head_api, head_packaged = collect(args.repo, args.tree)

    new_edges = {k for k in head_edges if k not in base_edges}
    removed_edges = {k for k in base_edges if k not in head_edges}
    api_added = head_api - base_api
    api_removed = base_api - head_api

    # Components whose files changed, for the diagram's seed set.
    diff = git_out(
        args.repo,
        "diff",
        "--name-only",
        "--diff-filter=ACMR",
        merge_base,
        args.tree,
    ).splitlines()
    base_packaged = package_files(tree_py_files(args.repo, merge_base))
    changed_comps = set()
    for f in diff:
        if f in head_packaged:
            changed_comps.add(
                component_of(head_packaged[f][0], head_packaged[f][1])
            )
        elif f in base_packaged:
            changed_comps.add(
                component_of(base_packaged[f][0], base_packaged[f][1])
            )

    print(
        render(
            merge_base[:12],
            args.tree,
            new_edges,
            removed_edges,
            api_added,
            api_removed,
            head_edges,
            changed_comps,
        )
    )


if __name__ == "__main__":
    main()
