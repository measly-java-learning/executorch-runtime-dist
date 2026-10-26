import importlib.util
import pathlib
import sys

import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]   # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.aot import emit_fixtures  # noqa: E402


def test_shape_text_format():
    txt = emit_fixtures.shape_text({"T": 5, "B": 2, "I": 4, "H": 3})
    assert txt == "LSTM_T=5\nLSTM_B=2\nLSTM_I=4\nLSTM_H=3\n"


def test_train_shape_text_format():
    txt = emit_fixtures.train_shape_text(
        {"T": 8, "B": 2, "I": 4, "H": 16, "O": 1}, 42)
    assert txt == ("TRAIN_T=8\nTRAIN_B=2\nTRAIN_I=4\nTRAIN_H=16\nTRAIN_O=1\n"
                   "TRAIN_NOUT=42\n")


@pytest.mark.skipif(importlib.util.find_spec("torch") is None,
                    reason="torch not installed in this env")
def test_emit_writes_all_members(tmp_path):
    emit_fixtures.main(tmp_path)
    for m in ("lstm.pte", "in.bin", "out.bin", "shape",
              "train.pte", "train.ptd", "train_in.bin", "train_out.bin",
              "train_shape"):
        assert (tmp_path / m).stat().st_size > 0, m
