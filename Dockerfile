# Python version shared by both stages. The venv built in the builder stage
# links against the base image's interpreter, so both stages MUST use the same tag.
# 3.15: scikit-image 0.26 and pyclipper are compiled from source in the builder.
# 3.13: everything installs from prebuilt wheels (faster build).
ARG PYTHON_VERSION=3.15

# ---------------------------------------------------------------------------
# Stage 1: builder - compiler toolchain, Python venv, MediaMTX binary.
# Nothing from this stage ends up in the final image except /opt/venv and mediamtx.
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim AS builder

# gcc/g++ for packages without wheels for this Python version (scikit-image needs C, pyclipper needs C++)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Isolated venv so the runtime stage can copy all Python deps in one step
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install core Python dependencies
RUN pip install \
    flask \
    flask-cors \
    requests \
    pyyaml \
    psutil \
    onvif-zeep \
    apprise \
    paramiko \
    cryptography \
    "HAP-python[Camera]" \
    qrcode

# Install CPU-only PyTorch first (keeps the image small, ~200MB vs ~2GB for GPU)
RUN pip install \
    torch \
    torchvision \
    --index-url https://download.pytorch.org/whl/cpu

# Install AI dependencies (ultralytics / YOLO + headless OpenCV + EasyOCR for license plates)
RUN pip install \
    ultralytics \
    opencv-python-headless \
    easyocr

# Detect host architecture at build time and download the correct MediaMTX v1.21.3.
# Copied into /app in the runtime stage so MediaMTXManager skips downloading it at runtime.
WORKDIR /build
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then \
        MEDIAMTX_ARCH="amd64"; \
    elif [ "$ARCH" = "arm64" ]; then \
        MEDIAMTX_ARCH="arm64"; \
    elif [ "$ARCH" = "armhf" ]; then \
        MEDIAMTX_ARCH="armv7"; \
    else \
        MEDIAMTX_ARCH="amd64"; \
    fi && \
    curl -fL -o mediamtx.tar.gz "https://github.com/bluenviron/mediamtx/releases/download/v1.21.3/mediamtx_v1.21.3_linux_${MEDIAMTX_ARCH}.tar.gz" && \
    tar -xzf mediamtx.tar.gz mediamtx && \
    rm mediamtx.tar.gz && \
    chmod +x mediamtx

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim

# Install system dependencies needed for FFmpeg, macvlan creation, DHCP, and PyTorch (libgomp1)
RUN apt-get update && apt-get install -y \
    ffmpeg \
    iproute2 \
    isc-dhcp-client \
    procps \
    sudo \
    curl \
    libgomp1 \
    avahi-daemon \
    && rm -rf /var/lib/apt/lists/*

# VAAPI hardware video drivers for GridFusion encoding (issue #73): Intel (iHD for
# Broadwell and newer, i965 for older) and AMD (Mesa). vainfo is for troubleshooting.
# Enable non-free so intel-media-va-driver-non-free (full hardware encode/decode shaders
# on Gen8+ Intel GPUs) is installed when available, falling back to the free package.
# These are only used when the GPU is passed in (see docker-compose.yml "devices").
# Installed best-effort so ARM builds without these packages still succeed.
RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true && \
    apt-get update && \
    (apt-get install -y --no-install-recommends vainfo mesa-va-drivers || true) && \
    (apt-get install -y --no-install-recommends intel-media-va-driver-non-free || apt-get install -y --no-install-recommends intel-media-va-driver || true) && \
    (apt-get install -y --no-install-recommends i965-va-driver-shaders || apt-get install -y --no-install-recommends i965-va-driver || true) && \
    rm -rf /var/lib/apt/lists/*

# Python deps from the builder; prepend to PATH so `python` resolves to the venv
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app

COPY --from=builder /build/mediamtx /app/mediamtx

# Model pre-downloads run here, not in the builder: importing cv2 (pulled in by
# ultralytics/easyocr) needs libGL/glib, which only the runtime stage has (via ffmpeg deps).

# Pre-download the default YOLO model so it's available immediately at runtime
RUN python -c "from ultralytics import YOLO; YOLO('yolov8n.pt')"

# Pre-download the EasyOCR English models so license plate reading works offline
# and does not re-download them every time the container is recreated
RUN python -c "import easyocr; easyocr.Reader(['en'], gpu=False, verbose=False)"

# Copy the rest of the application
COPY . .

# Default Web UI port. Override at build/run time with the WEB_UI_PORT env var.
# (With network_mode: host this is informational; the app binds this port on the host.)
ENV WEB_UI_PORT=5552
EXPOSE ${WEB_UI_PORT}

# Run the app
CMD ["python", "run.py"]
