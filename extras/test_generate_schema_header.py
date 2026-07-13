import subprocess, sys, pathlib, tempfile
HERE = pathlib.Path(__file__).parent

def test_header_has_qualified_op_names():
    out = pathlib.Path(tempfile.mkdtemp()) / "etnp_lstm_schema.h"
    subprocess.run([sys.executable, str(HERE / "generate_schema_header.py"),
                    str(HERE / "lstm" / "extra.yaml"), str(out)], check=True)
    text = out.read_text()
    assert 'constexpr char kLstmName[] = "etnp::lstm";' in text
    assert 'constexpr char kLstmOutName[] = "etnp::lstm.out";' in text
    assert "#pragma once" in text

def test_load_schema_roundtrip():
    sys.path.insert(0, str(HERE))
    from generate_schema_header import load_schema
    s = load_schema(HERE / "lstm" / "extra.yaml")
    assert s["qualified_name"] == "etnp::lstm"
    assert s["functional"].startswith("lstm(")
    assert s["out"].startswith("lstm.out(")
    assert s["variants"] == ["all"]


def test_non_all_variants_rejected(tmp_path):
    # Reserved-field guard: only [all] is implemented today, so anything else must
    # fail loudly at consumption rather than be silently ignored.
    import yaml, pytest
    sys.path.insert(0, str(HERE))
    from generate_schema_header import load_schema
    bad = tmp_path / "extra.yaml"
    bad.write_text(yaml.safe_dump({"namespace": "etnp", "op": "lstm",
                                   "variants": ["logging"]}))
    with pytest.raises(ValueError, match="variant gating is not yet implemented"):
        load_schema(bad)
