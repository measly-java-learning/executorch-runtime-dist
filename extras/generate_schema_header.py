#!/usr/bin/env python3
"""Emit the C++ op-name header from an extra.yaml (single source of truth).

Usage: generate_schema_header.py <extra.yaml> <out_header.h>
Also importable: load_schema(path) -> dict for the Python AOT face.
The generated header defines qualified op-name constants the C++ registrar uses,
so the name it registers cannot drift from the name the AOT/schema declares.
"""
import sys, pathlib, yaml


def _camel(op: str) -> str:
    """lstm -> Lstm, lstm_backward -> LstmBackward (C++ constant stem)."""
    return "".join(p[:1].upper() + p[1:] for p in op.split("_") if p)


def _schema_entry(namespace: str, op, schema, where: str) -> dict:
    if not isinstance(op, str) or not op.isidentifier():
        raise ValueError(f"{where}: op must be a simple identifier, got {op!r}")
    if not isinstance(schema, dict):
        raise ValueError(f"{where}: 'schema' must be a mapping")
    fields = {}
    for k in ("functional", "out"):
        text = schema.get(k)
        if not isinstance(text, str) or not text.strip():
            raise ValueError(f"{where}: schema.{k} must be a non-empty string")
        fields[k] = " ".join(text.split())
    # The declared text must actually name this op; a typo here would register a
    # kernel the AOT never emits (or vice versa), which fails only at model load.
    if not fields["functional"].startswith(f"{op}("):
        raise ValueError(f"{where}: functional must start with '{op}('")
    if not fields["out"].startswith(f"{op}.out("):
        raise ValueError(f"{where}: out must start with '{op}.out('")
    return {
        "op": op,
        "qualified_name": f"{namespace}::{op}",
        "qualified_out_name": f"{namespace}::{op}.out",
        "functional": fields["functional"],
        "out": fields["out"],
    }


def load_schema(extra_yaml) -> dict:
    d = yaml.safe_load(pathlib.Path(extra_yaml).read_text())
    ns, op = d["namespace"], d["op"]
    variants = d.get("variants", ["all"])
    # `variants` is reserved for future per-op variant gating. Only [all] is
    # implemented today (the op is always-on in every tarball variant); validate
    # here — the single consumption point both faces call — so an unexpected value
    # fails loudly instead of being silently ignored. Replace when gating lands.
    if variants != ["all"]:
        raise ValueError(
            f"extra.yaml variants={variants!r}: per-op variant gating is not yet "
            "implemented; only [all] is supported.")
    fwd = _schema_entry(ns, op, d["schema"], "extra.yaml")
    extra_ops, seen = [], {op}
    for i, entry in enumerate(d.get("extra_ops") or []):
        if not isinstance(entry, dict):
            raise ValueError(f"extra_ops[{i}]: each entry must be a mapping")
        e = _schema_entry(ns, entry.get("op"), entry.get("schema"),
                          f"extra_ops[{i}]")
        if e["op"] in seen:
            raise ValueError(f"extra_ops[{i}]: duplicate op name {e['op']!r}")
        seen.add(e["op"])
        extra_ops.append(e)
    return {
        "namespace": ns,
        "op": op,
        "variants": variants,
        "qualified_name": fwd["qualified_name"],
        "qualified_out_name": fwd["qualified_out_name"],
        "functional": fwd["functional"],
        "out": fwd["out"],
        "extra_ops": extra_ops,
    }


def render_header(s: dict) -> str:
    guard_ns = s["namespace"]
    entries = [(s["op"], s["qualified_name"], s["qualified_out_name"])]
    entries += [(e["op"], e["qualified_name"], e["qualified_out_name"])
                for e in s["extra_ops"]]
    consts = "".join(
        f'  inline constexpr char k{_camel(op)}Name[] = "{qn}";\n'
        f'  inline constexpr char k{_camel(op)}OutName[] = "{qon}";\n'
        for op, qn, qon in entries)
    return (
        f"// GENERATED from extras/{s['op']}/extra.yaml — do not edit.\n"
        "#pragma once\n"
        f"namespace {guard_ns} {{\n"
        "namespace schema {\n"
        f"{consts}"
        "}  // namespace schema\n"
        f"}}  // namespace {guard_ns}\n"
    )


def main() -> int:
    extra_yaml, out_header = sys.argv[1], sys.argv[2]
    s = load_schema(extra_yaml)
    p = pathlib.Path(out_header)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(render_header(s))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
