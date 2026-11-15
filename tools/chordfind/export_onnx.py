"""Export a fine-tuned chord reader to ONNX for ScannerCore, with its character list.

usage: data/tools/trainenv/bin/python export_onnx.py RUN_DIR OUT_DIR
       (RUN_DIR holds best_accuracy.pdparams from train_chords.sh; OUT_DIR gets chord_rec.onnx and chord_rec_dict.txt)

Paddle 3.3 writes every linear layer with a bias as `linear_v2`, which paddle2onnx 2.1 cannot convert. For the
export only, `paddle.nn.functional.linear` is replaced with the same matmul + add (the form Paddle itself writes
outside PIR), so the ONNX model computes exactly what the Paddle model does.

The dictionary file has one character per line in model order; the model's class 0 is the CTC blank and the last
class is a space (use_space_char), neither of which is in the file.
"""

import os
import runpy
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
tools = os.path.join(here, "data", "tools")


def main():
    run, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    config = os.path.join(out, "config.yml")
    with open(os.path.join(here, "chord_rec.yml")) as f:
        text = f.read()
    text = text.replace("OUT", out).replace("WEIGHTS", os.path.join(tools, "weights", "PP-OCRv6_small_rec_pretrained"))
    with open(config, "w") as f:
        f.write(text.replace("DATA", os.path.join(here, "data", "unused")))

    import paddle

    def linear(x, weight, bias=None, name=None):
        y = paddle.matmul(x, weight)
        return y if bias is None else y + bias

    paddle.nn.functional.linear = linear
    paddle.nn.functional.common.linear = linear

    infer = os.path.join(out, "infer")
    paddleocr = os.path.join(tools, "PaddleOCR")
    os.chdir(paddleocr)
    sys.path.insert(0, paddleocr)
    sys.argv = ["export_model.py", "-c", config, "-o", f"Global.pretrained_model={run}/best_accuracy",
                f"Global.save_inference_dir={infer}"]
    runpy.run_path(os.path.join(paddleocr, "tools", "export_model.py"), run_name="__main__")

    import yaml

    with open(os.path.join(infer, "inference.yml")) as f:
        chars = yaml.safe_load(f)["PostProcess"]["character_dict"]
    with open(os.path.join(out, "chord_rec_dict.txt"), "w") as f:
        f.write("\n".join(chars) + "\n")
    # paddle2onnx in its own process: after a failed conversion it can hang instead of exiting
    subprocess.run([sys.executable, "-c",
                    "import paddle2onnx, sys; paddle2onnx.export(sys.argv[1], sys.argv[2], sys.argv[3], "
                    "opset_version=14, enable_onnx_checker=True)",
                    os.path.join(infer, "inference.json"), os.path.join(infer, "inference.pdiparams"),
                    os.path.join(out, "chord_rec.onnx")], check=True, stdin=subprocess.DEVNULL, timeout=600)
    print("wrote", os.path.join(out, "chord_rec.onnx"), len(chars), "characters")


if __name__ == "__main__":
    main()
