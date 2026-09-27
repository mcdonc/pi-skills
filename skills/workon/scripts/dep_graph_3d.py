#!/usr/bin/env python3
"""Self-contained 3D module-dependency page for a PR's head tree.

Reads two git trees (base and head) the same way
``structure_artifacts.py`` does — git ls-tree + show, so the working
tree stays untouched — builds the module-level import graph at head,
diffs the edges against base, and writes one HTML file with the
``3d-force-graph`` UMD bundle and the graph JSON inlined. One file,
opens offline in any WebGL browser, needs no server.

Delta rendering: edges the branch adds glow green with moving
particles, edges it removes render red, unchanged edges stay dim.
Nodes are colored by component (the first package segment under the
package root — the same grouping the Mermaid diagram uses) and sized
by the number of importers. Modules that only exist on removed
edges appear as ghosts so the severed relationships stay visible.

The ``3d-force-graph`` bundle is searched at ``--lib``, then next to
this script under ``assets/``, then ``~/.cache/pi-skills/`` (a copy
is downloaded from a CDN on first use). With no local copy the page
loads the library from a CDN at view time instead.

Exit status is 0 whether or not changes were found — this reports,
it does not gate.
"""

import argparse
import ast
import hashlib
import json
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import structure_artifacts as sa  # noqa: E402

LIB_NAME = "3d-force-graph.min.js"
CDN_URLS = [
    "https://unpkg.com/3d-force-graph/dist/3d-force-graph.min.js",
    "https://cdn.jsdelivr.net/npm/3d-force-graph/dist/3d-force-graph.min.js",
]

PAGE_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>__TITLE__</title>
<style>
  html, body { margin: 0; height: 100%; overflow: hidden; background: #0b0e1a;
               font-family: system-ui, sans-serif; }
  #graph { width: 100vw; height: 100vh; }
  #legend { position: absolute; top: 10px; left: 10px; padding: 8px 10px;
             background: rgba(10, 14, 30, 0.85); border-radius: 8px;
             font-size: 12px; color: #cdd3e8; max-width: 460px; }
  .lg { display: inline-flex; align-items: center; margin: 2px 8px 2px 0; }
  .lg i { display: inline-block; width: 10px; height: 10px; border-radius: 5px;
           margin-right: 4px; }
  #hint { position: absolute; bottom: 8px; left: 10px; font-size: 12px;
           color: #8890b0; }
</style>
</head>
<body>
<div id="legend"><b style="color:#fff">__TITLE__</b><br>__STATS__<br>__LEGEND__</div>
<div id="hint">drag = rotate &middot; scroll = zoom &middot; right-drag = pan &middot;
hover = module &middot; click = focus &middot; node size = importers &middot;
<span style="color:#39d353">green = edge added</span> &middot;
<span style="color:#f85149">red = edge removed</span></div>
<div id="graph"></div>
__LIB_TAG__
<script>
const graphData = __DATA__;
const Graph = ForceGraph3D()(document.getElementById("graph"))
  .graphData(graphData)
  .backgroundColor("#0b0e1a")
  .nodeLabel(n => `${n.id}  (${n.group}, imported by ${n.inDegree})`)
  .nodeColor(n => n.ghost ? "#5a5f78" : n.color)
  .nodeVal(n => 1 + (n.ghost ? 0 : n.inDegree) * 0.6)
  .nodeOpacity(0.9)
  .linkColor(l => l.state === "added" ? "#39d353"
              : l.state === "removed" ? "#f85149"
              : "rgba(140, 150, 190, 0.22)")
  .linkWidth(l => l.state === "removed" ? 0.8 : 0.4)
  .linkDirectionalParticles(l => l.state === "added" ? 2 : 0)
  .linkDirectionalParticleWidth(1.4)
  .linkDirectionalParticleSpeed(0.006)
  .onNodeClick(n => {
    const target = { x: n.x, y: n.y, z: n.z };
    Graph.cameraPosition(target, target, 900);
  });
</script>
</body>
</html>
"""


def component_color(name):
    """Stable distinct color per component (golden-angle hue)."""
    digest = hashlib.sha256(name.encode()).digest()
    hue = (digest[0] << 8 | digest[1]) * 137.508 % 360
    return f"hsl({hue:.0f}, 68%, 62%)"


def module_targets(prefix, parts, is_package, node):
    """Dotted absolute import targets of one statement, module level.

    ``from . import x`` lists only the submodule ``x``. Emitting the
    bare package target as well would draw a phantom edge back into
    the parent package — whose ``__init__`` re-exports the very
    children doing the importing — and show import cycles that do
    not exist at runtime.
    """
    if isinstance(node, ast.Import):
        return {alias.name for alias in node.names}
    pkg_parts = parts if is_package else parts[:-1]
    if node.level > len(pkg_parts):
        return set()  # relative import climbing past the root
    base = (
        pkg_parts[: len(pkg_parts) - (node.level - 1)] if node.level else ()
    )
    mod = tuple(node.module.split(".")) if node.module else ()
    targets = set()
    if mod:
        full = base + mod
        targets.add(".".join(full))
        for alias in node.names:
            if alias.name != "*":
                targets.add(".".join(full + (alias.name,)))
    else:
        for alias in node.names:
            if alias.name != "*":
                targets.add(".".join(base + (alias.name,)))
    return targets


def module_graph(repo, ref):
    """({(src, dst), ...}, {module: component}) for one tree."""
    files = sa.tree_py_files(repo, ref)
    packaged = sa.package_files(files)
    module_of = {".".join(parts): sa.component_of(prefix, parts)
                 for prefix, parts, _ in packaged.values()}
    module_of = {m: c for m, c in module_of.items() if c}
    edges = set()
    for path, (prefix, parts, is_package) in sorted(packaged.items()):
        src = ".".join(parts)
        if src not in module_of:
            continue
        try:
            tree = ast_parse(repo, ref, path)
        except (SyntaxError, ValueError):
            continue
        if tree is None:
            continue
        for node in walk_imports(tree):
            for target in module_targets(prefix, parts, is_package, node):
                dst = resolve(target, module_of)
                if dst and dst != src:
                    edges.add((src, dst))
    return edges, module_of


def ast_parse(repo, ref, path):
    try:
        source = sa.git_out(repo, "show", f"{ref}:{path}")
        return ast.parse(source, filename=path)
    except SystemExit:
        raise
    except (SyntaxError, ValueError):
        print(f"dep_graph_3d: skipping {path} (unparsable at {ref})",
              file=sys.stderr)
        return None


def walk_imports(tree):
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            yield node


def resolve(target, modules):
    """Longest module path covered by an import target string."""
    seg = target.split(".")
    for i in range(len(seg), 0, -1):
        cand = ".".join(seg[:i])
        if cand in modules:
            return cand
    return None


def find_lib(explicit):
    """Locate the 3d-force-graph UMD bundle, downloading it once."""
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    candidates.append(Path(__file__).resolve().parent / "assets" / LIB_NAME)
    candidates.append(Path.home() / ".cache" / "pi-skills" / LIB_NAME)
    for cand in candidates:
        if cand.is_file() and cand.stat().st_size > 100_000:
            return cand.read_text()
    cache = candidates[-1]
    for url in CDN_URLS:
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                data = resp.read().decode()
        except OSError as exc:
            print(f"dep_graph_3d: {url}: {exc}", file=sys.stderr)
            continue
        if len(data) > 100_000:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(data)
            return data
    return None


def build(repo, base, tree):
    base_edges, base_mods = module_graph(repo, base)
    head_edges, head_mods = module_graph(repo, tree)

    added = head_edges - base_edges
    removed = base_edges - head_edges
    new_mods = set(head_mods) - set(base_mods)
    ghosts = {m for pair in removed for m in pair} - set(head_mods)

    indeg = defaultdict(int)
    for src, dst in head_edges:
        indeg[dst] += 1

    comps = {c for c in head_mods.values()}
    comps |= {base_mods.get(m) or (m.split(".")[1:2] or [m])[0]
              for m in ghosts}
    colors = {c: component_color(c) for c in comps}

    nodes = []
    for m in sorted(set(head_mods) | ghosts):
        group = head_mods.get(m)
        ghost = group is None
        if ghost:
            group = (m.split(".")[1:2] or [m])[0]
        nodes.append({
            "id": m,
            "group": group,
            "color": colors[group],
            "inDegree": indeg.get(m, 0),
            "isNew": m in new_mods,
            "ghost": ghost,
        })
    links = [
        {"source": s, "target": t,
         "state": "added" if (s, t) in added else "same"}
        for s, t in sorted(head_edges)
    ] + [
        {"source": s, "target": t, "state": "removed"}
        for s, t in sorted(removed)
    ]
    return nodes, links, added, removed, new_mods, colors


def render(nodes, links, added, removed, new_mods, colors, title):
    stats = (f"{len(nodes)} modules, {len(links)} edges — "
             f"<span style='color:#39d353'>+{len(added)} added edges</span>, "
             f"<span style='color:#f85149'>-{len(removed)} removed</span>, "
             f"{len(new_mods)} new modules")
    ordered = sorted(colors.items(), key=lambda kv: kv[0])
    shown = ordered[:24]
    legend = "".join(
        f'<span class="lg"><i style="background:{c}"></i>{g}</span>'
        for g, c in shown
    )
    if len(ordered) > len(shown):
        legend += f'<span class="lg">+{len(ordered) - len(shown)} more</span>'
    html = (PAGE_TEMPLATE
            .replace("__TITLE__", title)
            .replace("__STATS__", stats)
            .replace("__LEGEND__", legend)
            .replace("__DATA__", json.dumps({"nodes": nodes, "links": links})))
    return html


def main():
    ap = argparse.ArgumentParser(
        description="Self-contained 3D module-dependency page for a PR head."
    )
    ap.add_argument("--base", default=None, help="base ref (default: origin/HEAD)")
    ap.add_argument("--tree", default="HEAD", help="head tree ref (default: HEAD)")
    ap.add_argument("--out", default="/tmp/dep-graph-3d.html",
                    help="output HTML path")
    ap.add_argument("--lib", default=None,
                    help="path to 3d-force-graph.min.js to inline")
    ap.add_argument("--title", default=None, help="page title")
    ap.add_argument("repo", nargs="?", default=".", help="repository path")
    args = ap.parse_args()

    base = args.base or sa.default_base(args.repo)
    merge_base = sa.git_out(args.repo, "merge-base", args.tree, base).strip()
    if not merge_base:
        sys.exit(f"dep_graph_3d: no merge base of {args.tree} and {base}")

    nodes, links, added, removed, new_mods, colors = build(
        args.repo, merge_base, args.tree
    )
    title = args.title or f"module dependency graph ({merge_base[:8]}…{args.tree})"

    lib = find_lib(args.lib)
    lib_tag = (f"<script>\n{lib}\n</script>" if lib
               else f'<script src="{CDN_URLS[0]}"></script>')
    html = render(nodes, links, added, removed, new_mods, colors, title)
    html = html.replace("__LIB_TAG__", lib_tag)
    Path(args.out).write_text(html)
    print(f"dep_graph_3d: {args.out} — {len(nodes)} modules, {len(links)} "
          f"edges (+{len(added)}/-{len(removed)}), "
          f"lib {'inlined' if lib else 'from CDN at view time'}")


if __name__ == "__main__":
    main()
