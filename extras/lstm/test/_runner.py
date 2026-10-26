"""Torch-free helpers to build + run the LSTM C++ runners against an installed
prefix. Shared by the live round-trips (test_lstm_roundtrip.py) and the consumer
smoke."""
import os
import pathlib
import subprocess


def build_runner(here: pathlib.Path, prefix: pathlib.Path, build_dir: pathlib.Path,
                 target: str = "lstm_runner") -> pathlib.Path:
    subprocess.run(["cmake", "-B", str(build_dir), "-S", str(here), "-G", "Ninja",
                    f"-DCMAKE_PREFIX_PATH={prefix}", f"-DETNP_PREFIX={prefix}"], check=True)
    subprocess.run(["cmake", "--build", str(build_dir), "--target", target], check=True)
    return build_dir / target


def run_runner(runner: pathlib.Path, model: pathlib.Path, inbin: pathlib.Path,
               outbin: pathlib.Path, dims: dict) -> None:
    env = {**os.environ,
           "LSTM_T": str(dims["T"]), "LSTM_B": str(dims["B"]),
           "LSTM_I": str(dims["I"]), "LSTM_H": str(dims["H"])}
    subprocess.run([str(runner), str(model), str(inbin), str(outbin)], check=True, env=env)


def run_train_runner(runner: pathlib.Path, pte: pathlib.Path, ptd: pathlib.Path,
                     inbin: pathlib.Path, outbin: pathlib.Path, dims: dict) -> None:
    env = {**os.environ,
           "TRAIN_T": str(dims["T"]), "TRAIN_B": str(dims["B"]),
           "TRAIN_I": str(dims["I"]), "TRAIN_O": str(dims["O"])}
    subprocess.run([str(runner), str(pte), str(ptd), str(inbin), str(outbin)],
                   check=True, env=env)
