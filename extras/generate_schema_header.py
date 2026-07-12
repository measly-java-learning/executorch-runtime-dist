#!/usr/bin/env python3
"""Emit the C++ op-name header from an extra.yaml (single source of truth).

Usage: generate_schema_header.py <extra.yaml> <out_header.h>
Also importable: load_schema(path) -> dict for the Python AOT face.
The generated header defines qualified op-name constants the C++ registrar uses,
so the name it registers cannot drift from the name the AOT/schema declares.
"""
import sys, pathlib, yaml


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
    return {
        "namespace": ns,
        "op": op,
        "variants": variants,
        "qualified_name": f"{ns}::{op}",
        "qualified_out_name": f"{ns}::{op}.out",
        "functional": " ".join(d["schema"]["functional"].split()),
        "out": " ".join(d["schema"]["out"].split()),
    }


def render_header(s: dict) -> str:
    guard_ns = s["namespace"]
    # TODO(op#2): the constant names kLstmName/kLstmOutName are lstm-specific. When a
    # second op is added, derive them from s["op"] (e.g. kGruName) or emit fixed
    # kOpName/kOpOutName — otherwise op #2 would get mis-named C++ constants.
    return (
        "// GENERATED from extras/{op}/extra.yaml — do not edit.\n"
        "#pragma once\n"
        "namespace {ns} {{\n"
        "namespace schema {{\n"
        '  inline constexpr char kLstmName[] = "{qn}";\n'
        '  inline constexpr char kLstmOutName[] = "{qon}";\n'
        "}}  // namespace schema\n"
        "}}  // namespace {ns}\n"
    ).format(op=s["op"], ns=guard_ns, qn=s["qualified_name"],
             qon=s["qualified_out_name"])


def main() -> int:
    extra_yaml, out_header = sys.argv[1], sys.argv[2]
    s = load_schema(extra_yaml)
    p = pathlib.Path(out_header)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(render_header(s))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
