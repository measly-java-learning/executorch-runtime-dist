import pathlib
import sys

import numpy as np

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]   # extras/lstm/test/ -> repo root
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))
from extras.lstm.test import consumer_smoke  # noqa: E402


def test_parse_shape_roundtrip(tmp_path):
    (tmp_path / "shape").write_text("LSTM_T=5\nLSTM_B=2\nLSTM_I=4\nLSTM_H=3\n")
    assert consumer_smoke.parse_shape(tmp_path / "shape") == {"T": 5, "B": 2, "I": 4, "H": 3}


def test_within_tol():
    a = np.array([1.0, 2.0, 3.0], dtype=np.float32)
    assert consumer_smoke.within_tol(a, a + 1e-6)
    assert not consumer_smoke.within_tol(a, a + 1e-2)
    assert not consumer_smoke.within_tol(a, a[:2])   # shape mismatch
