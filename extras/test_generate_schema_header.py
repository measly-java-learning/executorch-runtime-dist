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
    assert "namespace etnp {" in text and "namespace schema {" in text

def test_load_schema_roundtrip():
    sys.path.insert(0, str(HERE))
    from generate_schema_header import load_schema
    s = load_schema(HERE / "lstm" / "extra.yaml")
    assert s["qualified_name"] == "etnp::lstm"
    assert s["functional"].startswith("lstm(")
    assert s["out"].startswith("lstm.out(")
    assert s["variants"] == ["all"]

def test_header_has_backward_names():
    out = pathlib.Path(tempfile.mkdtemp()) / "etnp_lstm_schema.h"
    subprocess.run([sys.executable, str(HERE / "generate_schema_header.py"),
                    str(HERE / "lstm" / "extra.yaml"), str(out)], check=True)
    text = out.read_text()
    assert 'constexpr char kLstmBackwardName[] = "etnp::lstm_backward";' in text
    assert 'constexpr char kLstmBackwardOutName[] = "etnp::lstm_backward.out";' in text
    # The forward's two constants keep their historical spelling and values.
    assert 'constexpr char kLstmName[] = "etnp::lstm";' in text
    assert 'constexpr char kLstmOutName[] = "etnp::lstm.out";' in text


def test_load_schema_extra_ops():
    sys.path.insert(0, str(HERE))
    from generate_schema_header import load_schema
    s = load_schema(HERE / "lstm" / "extra.yaml")
    assert len(s["extra_ops"]) == 1
    e = s["extra_ops"][0]
    assert e["qualified_name"] == "etnp::lstm_backward"
    assert e["qualified_out_name"] == "etnp::lstm_backward.out"
    assert e["functional"].startswith("lstm_backward(")
    assert e["out"].startswith("lstm_backward.out(")


def test_forward_schema_unchanged():
    # Literals copied from load_schema() on main; the forward is frozen.
    sys.path.insert(0, str(HERE))
    from generate_schema_header import load_schema
    s = load_schema(HERE / "lstm" / "extra.yaml")
    assert s["functional"] == (
        "lstm(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh, "
        "Tensor? b_ih, Tensor? b_hh) -> (Tensor, Tensor, Tensor)")
    assert s["out"] == (
        "lstm.out(Tensor input, Tensor h0, Tensor c0, Tensor w_ih, Tensor w_hh, "
        "Tensor? b_ih, Tensor? b_hh, *, Tensor(a!) output, Tensor(b!) hn, "
        "Tensor(c!) cn) -> (Tensor(a!), Tensor(b!), Tensor(c!))")


def test_extra_ops_optional(tmp_path):
    import yaml
    sys.path.insert(0, str(HERE))
    from generate_schema_header import load_schema
    p = tmp_path / "extra.yaml"
    p.write_text(yaml.safe_dump({"namespace": "etnp", "op": "lstm",
                                 "variants": ["all"],
                                 "schema": {"functional": "lstm(Tensor x) -> (Tensor)",
                                            "out": "lstm.out(Tensor x, *, Tensor(a!) y) -> (Tensor(a!))"}}))
    assert load_schema(p)["extra_ops"] == []


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
