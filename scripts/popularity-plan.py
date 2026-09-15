#!/usr/bin/env python3
"""Rank Homebrew demand and plan Nanobrew packaging; does not claim install success."""
import argparse
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "formula-analytics": "analytics/install-on-request/30d.json",
    "cask-analytics": "analytics/cask-install/30d.json",
    "formulae": "formula.json", "casks": "cask.json",
}
INTEL_TAGS = {"tahoe", "sequoia", "sonoma", "ventura", "monterey", "big_sur", "all"}


def canonical(token):
    token = token.split()[0]
    for prefix in ("homebrew/core/", "homebrew/cask/"):
        if token.startswith(prefix):
            return token[len(prefix):]
    return token


def ranked(data, kind, top):
    counts = defaultdict(int)
    for row in data["items"]:
        count = int(str(row["count"]).replace(",", ""))
        if count < 0 or not row[kind].strip():
            raise ValueError("Invalid analytics row")
        counts[canonical(row[kind])] += count
    if sum(counts.values()) != data["total_count"]:
        raise ValueError("Analytics row counts do not reconcile to total_count")
    return [{"rank": i + 1, "token": token, "events_30d": count}
            for i, (token, count) in enumerate(sorted(counts.items(), key=lambda x: (-x[1], x[0]))[:top])]


def intel_tags(metadata):
    return sorted(INTEL_TAGS.intersection(metadata.get("bottle", {}).get("stable", {}).get("files", {})))


def assess(row, kind, record, meta):
    result = dict(row)
    resolved = (record or {}).get("resolved", {})
    assets = resolved.get("assets", {})
    upstream = (record or {}).get("upstream", {}).get("type")
    live_version = (meta.get("versions", {}).get("stable") if kind == "formula" else meta.get("version")) if meta else None
    stale = (resolved.get("version") != live_version) if live_version and resolved.get("version") else None
    if kind == "formula" and stale is False:
        stale = (resolved.get("revision", 0) != meta.get("revision", 0)
                 or resolved.get("rebuild", 0) != meta.get("bottle", {}).get("stable", {}).get("rebuild", 0))
    tags = intel_tags(meta or {}) if kind == "formula" else None
    if not meta:
        action = "review tap metadata"
    elif kind == "cask":
        action = "review cask artifacts" if not record else ("review cask pin" if stale or "macos-x86_64" not in assets else "test install")
    elif upstream == "github_release":
        action = "review upstream pin" if stale or "macos-x86_64" not in assets else "test install"
    elif not tags:
        action = "source build candidate"
    elif not record:
        action = "seed current bottle"
    elif stale or "macos-x86_64" not in assets:
        action = "review bottle pin"
    else:
        action = "test install"
    result.update(registry_entry=record is not None, upstream_type=upstream,
                  pinned_version=resolved.get("version"), live_version=live_version,
                  pin_differs_from_live=stale,
                  pinned_platforms=sorted(assets), live_intel_bottle_tags=tags,
                  action=action, runtime_validation="not tested by this report")
    return result


def dependency_closure(name, metadata):
    seen, missing = set(), set()
    pending = [name]
    while pending:
        token = pending.pop()
        if token in seen:
            continue
        seen.add(token)
        if token not in metadata:
            missing.add(token)
        else:
            pending.extend(metadata[token].get("dependencies", []))
    return seen, missing


def build_plan(inputs, registry, top):
    records = {(r["kind"], r["token"]): r for r in registry["records"]}
    if len(records) != len(registry["records"]):
        raise ValueError("Duplicate registry kind/token keys")
    metadata = {}
    for kind, key in (("formula", "formulae"), ("cask", "casks")):
        index = {}
        for item in inputs[key]:
            name = item["name"] if kind == "formula" else item["token"]
            index[name] = item
            for alias in item.get("aliases", []):
                index.setdefault(alias, item)
        metadata[kind] = index
    report = {"generated_at": datetime.now(timezone.utc).isoformat(), "top": top,
              "definition": "30-day reported install-on-request formula events; cask install events. Options aggregated by package; stable-version metadata assessed.",
              "caveats": ["Events are not unique users or exact downloads, and are not Intel-specific demand.",
                          "Registry entries and available bottles are not proof of installation success.",
                          "Dependency priority uses current metadata dependencies, not a host-resolved dependency graph.",
                          "Pinned older Intel bottles may remain usable when the latest version has no Intel bottle.",
                          "A differing pin may be newer than Homebrew metadata; never automatically downgrade it.",
                          "Cask platform availability is reported from pins only; runtime and OS requirements need tests."],
              "summary": {}}
    for kind in ("formula", "cask"):
        analytics = inputs[kind + "-analytics"]
        rows = [assess(row, kind, records.get((kind, row["token"])), metadata[kind].get(row["token"]))
                for row in ranked(analytics, kind, top)]
        events = sum(r["events_30d"] for r in rows)
        summary = {"start_date": analytics["start_date"], "end_date": analytics["end_date"],
                   "packages": len(rows), "events": events,
                   "registry_entries": sum(r["registry_entry"] for r in rows),
                   "intel_pins": sum("macos-x86_64" in r["pinned_platforms"] for r in rows),
                   "pins_differing_from_live": sum(r["pin_differs_from_live"] is True for r in rows),
                   "actions": dict(sorted((action, sum(r["action"] == action for r in rows)) for action in {r["action"] for r in rows}))}
        report[kind] = rows
        report["summary"][kind] = summary
    priority = defaultdict(lambda: {"affected_packages": [], "affected_events": 0})
    unknown = set()
    for row in report["formula"]:
        closure, missing = dependency_closure(row["token"], metadata["formula"])
        unknown.update(missing)
        for name in closure - missing:
            meta = metadata["formula"][name]
            record = records.get(("formula", name), {})
            if intel_tags(meta) or record.get("upstream", {}).get("type") == "github_release":
                continue
            priority[name]["affected_packages"].append(row["token"])
            priority[name]["affected_events"] += row["events_30d"]
    report["intel_source_priority"] = sorted(
        ({"token": name, **values} for name, values in priority.items()),
        key=lambda x: (-x["affected_events"], x["token"]))
    report["unresolved_dependency_metadata"] = sorted(unknown)
    return report


def markdown(report):
    lines = ["# Homebrew popularity → Nanobrew packaging plan", "", report["definition"], "",
             "Availability below is metadata, not an install-success claim.", ""]
    for kind in ("formula", "cask"):
        s = report["summary"][kind]
        lines += [f"## {kind.title()} top {s['packages']}", "",
                  f"Period: {s['start_date']} to {s['end_date']}. Registry entries: {s['registry_entries']}; Intel pins: {s['intel_pins']}; pins differing from live metadata: {s['pins_differing_from_live']}.", "",
                  "| Rank | Package | Events | Pinned version | Current version | Next action |",
                  "|---:|---|---:|---|---|---|"]
        for r in report[kind]:
            lines.append(f"| {r['rank']} | {r['token']} | {r['events_30d']:,} | {r['pinned_version'] or '—'} | {r['live_version'] or 'unknown'} | {r['action']} |")
        lines.append("")
    lines += ["## Intel source-build priorities", "", "Ranked by summed demand for top formulas whose metadata dependency graph reaches each package. These totals overlap across packages and must not be added together.", "",
              "| Package | Affected top formulas | Associated events |", "|---|---:|---:|"]
    for r in report["intel_source_priority"][:20]:
        lines.append(f"| {r['token']} | {len(r['affected_packages'])} | {r['affected_events']:,} |")
    lines += ["", "## Limits", ""] + ["- " + c for c in report["caveats"]]
    lines += ["", "## Sources", ""]
    for s in report.get("sources", []):
        lines.append(f"- [{s['name']}]({s['url']}); snapshot SHA256 `{s['sha256']}`")
    return "\n".join(lines) + "\n"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--inputs", type=Path, help="Use saved JSON snapshots instead of fetching")
    p.add_argument("--output", type=Path, default=ROOT / "dist/popularity")
    p.add_argument("--registry", type=Path, default=ROOT / "registry/upstream.json")
    p.add_argument("--top", type=int, default=100)
    args = p.parse_args()
    if args.top < 1:
        p.error("--top must be positive")
    args.output.mkdir(parents=True, exist_ok=True)

    def load(item):
        name, path = item
        url = "https://formulae.brew.sh/api/" + path
        if args.inputs:
            data = (args.inputs / (name + ".json")).read_bytes()
        else:
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read()
            (args.output / (name + ".json")).write_bytes(data)
        return name, json.loads(data), {"name": name, "url": url, "sha256": hashlib.sha256(data).hexdigest()}

    with ThreadPoolExecutor(max_workers=4) as pool:
        loaded = list(pool.map(load, SOURCES.items()))
    registry_bytes = args.registry.read_bytes()
    report = build_plan({name: data for name, data, _ in loaded}, json.loads(registry_bytes), args.top)
    report["sources"] = [source for _, _, source in loaded]
    report["registry_sha256"] = hashlib.sha256(registry_bytes).hexdigest()
    (args.output / "plan.json").write_text(json.dumps(report, indent=2) + "\n")
    (args.output / "plan.md").write_text(markdown(report))
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    main()
