"""Torch-free helpers to build + run lstm_runner against an installed prefix.
Shared by the live round-trip (test_lstm_roundtrip.py) and the consumer smoke."""
import os
import pathlib
import subprocess


def build_runner(here: pathlib.Path, prefix: pathlib.Path, build_dir: pathlib.Path) -> pathlib.Path:
    subprocess.run(["cmake", "-B", str(build_dir), "-S", str(here), "-G", "Ninja",
                    f"-DCMAKE_PREFIX_PATH={prefix}", f"-DETNP_PREFIX={prefix}"], check=True)
    subprocess.run(["cmake", "--build", str(build_dir), "--target", "lstm_runner"], check=True)
    return build_dir / "lstm_runner"


def run_runner(runner: pathlib.Path, model: pathlib.Path, inbin: pathlib.Path,
               outbin: pathlib.Path, dims: dict) -> None:
    env = {**os.environ,
           "LSTM_T": str(dims["T"]), "LSTM_B": str(dims["B"]),
           "LSTM_I": str(dims["I"]), "LSTM_H": str(dims["H"])}
    subprocess.run([str(runner), str(model), str(inbin), str(outbin)], check=True, env=env)
