#!/usr/bin/env python3
"""Real per-pixel depth from a monocular depth model, run locally.

Everything before this was authored depth: a Vision silhouette plus smooth
fields (a bulge for roundness, a linear tilt for a reaching limb). Those slide a
cutout around convincingly enough, but they do not correspond to the subject's
body, so a figure never reads as three-dimensional — his near arm has to sit
genuinely forward of his torso, with a real step between them.

This runs Depth Anything V2 on the machine. Nothing is uploaded; the model
weights come down once from Hugging Face and are then cached locally.

    tools/.venv/bin/python tools/depth_model.py \
        --in assets/Jordan_Dunk.jpg --out assets/depth_model.png

Output is 8-bit greyscale, **white = near**, matching the convention the rest of
the project uses.
"""
import argparse
import sys

MODELS = {
    # small is plenty at this resolution and downloads in seconds
    "small": "depth-anything/Depth-Anything-V2-Small-hf",
    "base": "depth-anything/Depth-Anything-V2-Base-hf",
    "large": "depth-anything/Depth-Anything-V2-Large-hf",
    # fallback if the installed transformers predates V2 support
    "v1-small": "LiheYoung/depth-anything-small-hf",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", required=True)
    ap.add_argument("--model", default="small", choices=list(MODELS))
    ap.add_argument("--invert", action="store_true",
                    help="flip if the model returns near-dark")
    ap.add_argument("--device", default="cpu", choices=["cpu", "mps"],
                    help="cpu by default: MPS has no bicubic upsample, which "
                         "DINOv2 position-embedding interpolation needs, and a "
                         "single still takes only seconds on CPU anyway")
    args = ap.parse_args()

    import numpy as np
    import torch
    from PIL import Image
    from transformers import AutoImageProcessor, AutoModelForDepthEstimation

    name = MODELS[args.model]
    print(f"loading {name} ...", flush=True)
    try:
        processor = AutoImageProcessor.from_pretrained(name)
        model = AutoModelForDepthEstimation.from_pretrained(name)
    except Exception as exc:                      # noqa: BLE001
        print(f"could not load {name}: {exc}", file=sys.stderr)
        print("try --model v1-small if this transformers is older than V2 support",
              file=sys.stderr)
        raise SystemExit(1)

    device = args.device
    if device == "mps" and not torch.backends.mps.is_available():
        device = "cpu"
    model = model.to(device).eval()
    print(f"device: {device}", flush=True)

    image = Image.open(args.src).convert("RGB")
    inputs = processor(images=image, return_tensors="pt").to(device)

    with torch.no_grad():
        predicted = model(**inputs).predicted_depth

    # back up to the source resolution
    depth = torch.nn.functional.interpolate(
        predicted.unsqueeze(1).float(),
        size=image.size[::-1],
        mode="bicubic",
        align_corners=False,
    ).squeeze()

    d = depth.cpu().numpy()
    lo, hi = float(d.min()), float(d.max())
    d = (d - lo) / max(hi - lo, 1e-8)
    if args.invert:
        d = 1.0 - d

    # Depth Anything predicts *disparity*: larger is nearer, which is already
    # the white-is-near convention used elsewhere in this project.
    out = (np.clip(d, 0, 1) * 255).astype("uint8")
    Image.fromarray(out, mode="L").save(args.dst)
    print(f"wrote {args.dst}  ({out.shape[1]}x{out.shape[0]}, raw range {lo:.2f}..{hi:.2f})")


if __name__ == "__main__":
    main()
