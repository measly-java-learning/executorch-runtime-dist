import pathlib
import sys

import numpy as np
import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]   # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.test import consumer_smoke  # noqa: E402


def test_parse_shape_roundtrip(tmp_path):
    (tmp_path / "shape").write_text("LSTM_T=5\nLSTM_B=2\nLSTM_I=4\nLSTM_H=3\n")
    assert consumer_smoke.parse_shape(tmp_path / "shape") == {"T": 5, "B": 2, "I": 4, "H": 3}


def test_parse_train_shape(tmp_path):
    (tmp_path / "train_shape").write_text(
        "TRAIN_T=8\nTRAIN_B=2\nTRAIN_I=4\nTRAIN_H=16\nTRAIN_O=1\nTRAIN_NOUT=18\n")
    assert consumer_smoke.parse_train_shape(tmp_path / "train_shape") == {
        "T": 8, "B": 2, "I": 4, "H": 16, "O": 1}


def test_train_check_skips_without_fixture(tmp_path):
    # Empty fixtures dir: the check must SKIP without attempting a build (the
    # prefix path here does not exist, so a build attempt would raise).
    got = consumer_smoke.train_check(tmp_path, tmp_path / "no-prefix", tmp_path)
    assert got == "skip"


def test_train_check_partial_fixture_fails_by_name(tmp_path, capsys):
    # A published package with only some training members is broken, not old:
    # fail with the missing names instead of a bare FileNotFoundError (or a skip).
    (tmp_path / "train.pte").write_bytes(b"PTE")
    with pytest.raises(SystemExit) as exc:
        consumer_smoke.train_check(tmp_path, tmp_path / "no-prefix", tmp_path)
    assert exc.value.code == 1
    err = capsys.readouterr().err
    assert "partial training fixture set" in err
    for m in ("train.ptd", "train_in.bin", "train_out.bin", "train_shape"):
        assert m in err


def test_within_tol():
    a = np.array([1.0, 2.0, 3.0], dtype=np.float32)
    assert consumer_smoke.within_tol(a, a + 1e-6)
    assert not consumer_smoke.within_tol(a, a + 1e-2)
    assert not consumer_smoke.within_tol(a, a[:2])   # shape mismatch
