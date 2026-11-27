#!/usr/bin/env bash
# Smoke test for the built container image.
# Usage: .github/smoke-test.sh <image>
set -euo pipefail
IMAGE="${1:?usage: $0 <image>}"

echo "== binaries"
docker run --rm "$IMAGE" sh -c 'ffmpeg -hide_banner -version | head -1 && test -x /app/mediamtx && vainfo --help >/dev/null'

echo "== python imports + offline model inference"
# --network none: fails if the YOLO/EasyOCR models were not baked into the image
docker run --rm -i --network none "$IMAGE" python - <<'EOF'
import importlib, sys
mods = ["flask", "flask_cors", "requests", "yaml", "psutil", "onvif", "apprise",
        "paramiko", "cryptography", "pyhap", "qrcode", "torch", "torchvision",
        "cv2", "ultralytics", "easyocr", "skimage", "pyclipper", "scipy"]
for m in mods:
    importlib.import_module(m)
print("python", sys.version.split()[0], "- imports ok")

import numpy as np
img = np.zeros((640, 640, 3), dtype=np.uint8)

from ultralytics import YOLO
YOLO("yolov8n.pt")(img, verbose=False)  # relative to WORKDIR /app
print("yolo ok")

import easyocr
# download_enabled=False: raise instead of fetching missing models
easyocr.Reader(["en"], gpu=False, download_enabled=False, verbose=False).readtext(img)
print("easyocr ok")
EOF

echo "== smoke test passed"
