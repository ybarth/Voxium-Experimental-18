import Foundation

/// Embedded Python inference server script.
/// Written to ~/Library/Application Support/OpenWhisper/Server/ at runtime.
enum InferenceServerScript {
    static let content = #"""
#!/usr/bin/env python3
"""
OpenWhisper Local Inference Server
Supports Parakeet (via sherpa-onnx) and Granite (via MLX Audio) models.
"""
import os
import sys
import json
import base64
import logging
import time
from pathlib import Path

import numpy as np
from flask import Flask, request, jsonify

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("openwhisper-server")
SERVER_VERSION = "granite-mlx-v1"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
server_state = {
    "model_loaded": None,
    "model_loading": False,
    "download_progress": 0.0,
    "recognizer": None,
    "error": None,
    "start_time": time.time(),
}

MODELS_DIR = Path(
    os.environ.get(
        "MODELS_DIR",
        str(Path.home() / "Library" / "Application Support" / "OpenWhisper" / "ServerModels"),
    )
)

# ---------------------------------------------------------------------------
# Audio helpers
# ---------------------------------------------------------------------------

def decode_audio(base64_audio):
    """Decode base64-encoded float32 audio samples to numpy array."""
    audio_bytes = base64.b64decode(base64_audio)
    return np.frombuffer(audio_bytes, dtype=np.float32).copy()

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------

def _download_file_with_progress(url, dest_path, progress_start=0.0, progress_end=1.0):
    """Download a single file via HTTP with byte-level progress updates."""
    import urllib.request

    dest_path = Path(dest_path)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = str(dest_path) + ".tmp"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "OpenWhisper/1.0"})
        with urllib.request.urlopen(req, timeout=600) as resp:
            total = int(resp.headers.get("Content-Length", 0))
            downloaded = 0
            chunk_size = 256 * 1024  # 256 KB
            with open(tmp, "wb") as f:
                while True:
                    chunk = resp.read(chunk_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total > 0:
                        frac = downloaded / total
                        server_state["download_progress"] = (
                            progress_start + frac * (progress_end - progress_start)
                        )
        Path(tmp).rename(dest_path)
        size = dest_path.stat().st_size
        logger.info("Downloaded %s (%d MB)", dest_path.name, size // (1024 * 1024))
    except Exception:
        Path(tmp).unlink(missing_ok=True)
        raise


def _hf_download(repo_id, local_dir, required_files, progress_start=0.0, progress_end=1.0):
    """Download model files with real progress.

    Always downloads files individually via direct HTTPS so we can report
    byte-level progress to the health endpoint.
    """
    local_dir = Path(local_dir)
    local_dir.mkdir(parents=True, exist_ok=True)

    base_url = f"https://huggingface.co/{repo_id}/resolve/main"
    # Weight the progress by expected relative sizes
    files_to_get = [f for f in required_files if not (local_dir / f).exists()]
    if not files_to_get:
        server_state["download_progress"] = progress_end
        return

    per_file = (progress_end - progress_start) / len(files_to_get)
    for i, fname in enumerate(files_to_get):
        dest = local_dir / fname
        file_start = progress_start + i * per_file
        file_end = file_start + per_file
        logger.info("Downloading %s/%s (%d/%d)...", repo_id, fname, i + 1, len(files_to_get))
        _download_file_with_progress(f"{base_url}/{fname}", dest, file_start, file_end)

    server_state["download_progress"] = progress_end


# ---------------------------------------------------------------------------
# Model loaders
# ---------------------------------------------------------------------------

def load_parakeet_tdt():
    """Load Parakeet TDT-CTC 110M via sherpa-onnx (NeMo CTC decoder).

    Note: sherpa-onnx 1.12.x has a metadata bug in from_transducer() that
    crashes on recent Parakeet 0.6B models. We use the 110M CTC model
    instead, which works reliably and is very fast.
    """
    # Delegate to the same CTC loader — same model, same quality
    return load_parakeet_ctc()


def load_parakeet_ctc():
    """Load Parakeet TDT-CTC 110M (fast, small) via sherpa-onnx."""
    import sherpa_onnx

    model_dir = MODELS_DIR / "parakeet-tdt-ctc-110m"
    required = ["model.onnx", "tokens.txt"]

    missing = [f for f in required if not (model_dir / f).exists()]
    if missing:
        logger.info("Need to download Parakeet TDT-CTC 110M (missing: %s)", ", ".join(missing))
        server_state["download_progress"] = 0.0
        _hf_download(
            "csukuangfj/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000",
            model_dir,
            required,
        )
        server_state["download_progress"] = 1.0
        logger.info("Parakeet TDT-CTC 110M download complete.")
    else:
        logger.info("Parakeet TDT-CTC 110M model files already present.")

    logger.info("Creating sherpa-onnx NeMo CTC recognizer...")
    recognizer = sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
        model=str(model_dir / "model.onnx"),
        tokens=str(model_dir / "tokens.txt"),
        num_threads=4,
    )
    logger.info("Parakeet CTC recognizer created successfully.")
    return {"recognizer": recognizer, "type": "sherpa"}


def _monitor_hf_cache_progress(model_id, expected_bytes, progress_start, progress_end, stop_event):
    """Background thread: estimate download progress by watching HF cache size."""
    import glob
    cache_base = Path.home() / ".cache" / "huggingface" / "hub"
    slug = "models--" + model_id.replace("/", "--")
    cache_dir = cache_base / slug

    while not stop_event.is_set():
        try:
            total_size = sum(
                f.stat().st_size
                for f in cache_dir.rglob("*")
                if f.is_file()
            )
            frac = min(total_size / max(expected_bytes, 1), 0.99)
            server_state["download_progress"] = (
                progress_start + frac * (progress_end - progress_start)
            )
        except Exception:
            pass
        stop_event.wait(2)


def load_granite_speech():
    """Load Granite 4.0 1B Speech BF16 via MLX Audio on Apple Silicon."""
    import platform
    import threading
    from mlx_audio.stt.models.granite_speech.granite_speech import Model as GraniteSpeechModel
    from mlx_audio.stt.utils import load_model

    if platform.machine() != "arm64":
        raise RuntimeError("Granite MLX backend requires Apple Silicon (arm64).")

    # mlx-audio 0.4.1 transposes Granite Speech conv weights during sanitize(),
    # but the BF16 community checkpoint already stores them in the MLX layout.
    # Leaving them untouched avoids the conv channel mismatch seen at runtime.
    def _sanitize_granite_weights(weights):
        return {
            key: value
            for key, value in weights.items()
            if "num_batches_tracked" not in key
        }

    GraniteSpeechModel.sanitize = staticmethod(_sanitize_granite_weights)

    model_id = "mlx-community/granite-4.0-1b-speech-bf16"
    logger.info("Loading Granite 4.0 1B Speech BF16 via MLX Audio...")
    server_state["download_progress"] = 0.05

    logger.info("Downloading Granite MLX weights (~4.5 GB)...")
    server_state["download_progress"] = 0.15

    # Monitor cache directory growth in a background thread for progress
    stop_event = threading.Event()
    monitor = threading.Thread(
        target=_monitor_hf_cache_progress,
        args=(model_id, 4_800_000_000, 0.15, 0.95, stop_event),
        daemon=True,
    )
    monitor.start()

    try:
        model = load_model(model_id)
    finally:
        stop_event.set()
        monitor.join(timeout=3)

    server_state["download_progress"] = 1.0
    logger.info("Granite 4.0 1B Speech BF16 model loaded via MLX.")

    return {
        "model": model,
        "type": "granite",
    }


MODEL_LOADERS = {
    "parakeetTDT": load_parakeet_tdt,
    "parakeetCTC": load_parakeet_ctc,
    "graniteSpeech": load_granite_speech,
}

# ---------------------------------------------------------------------------
# Transcription backends
# ---------------------------------------------------------------------------

def transcribe_sherpa(bundle, samples, sample_rate):
    """Transcribe using sherpa-onnx recognizer."""
    recognizer = bundle["recognizer"]
    stream = recognizer.create_stream()
    stream.accept_waveform(sample_rate, samples.tolist())
    recognizer.decode_stream(stream)
    return stream.result.text


def transcribe_granite(bundle, samples, sample_rate):
    """Transcribe using Granite Speech via MLX Audio."""
    import os
    import tempfile
    import soundfile as sf

    model = bundle["model"]

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        temp_path = tmp.name

    try:
        sf.write(temp_path, samples, sample_rate)
        result = model.generate(temp_path, language="en")
        return getattr(result, "text", str(result))
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass


TRANSCRIBERS = {
    "sherpa": transcribe_sherpa,
    "granite": transcribe_granite,
}

# ---------------------------------------------------------------------------
# Flask routes
# ---------------------------------------------------------------------------

@app.route("/health")
def health():
    return jsonify(
        {
            "status": "ok",
            "server_version": SERVER_VERSION,
            "model_loaded": server_state["model_loaded"],
            "model_loading": server_state["model_loading"],
            "download_progress": server_state["download_progress"],
            "error": server_state["error"],
            "uptime": time.time() - server_state["start_time"],
        }
    )


@app.route("/load", methods=["POST"])
def load_model():
    data = request.json or {}
    model_name = data.get("model")

    if model_name not in MODEL_LOADERS:
        return jsonify({"error": f"Unknown model: {model_name}"}), 400

    try:
        server_state["model_loading"] = True
        server_state["error"] = None
        server_state["download_progress"] = 0.0

        logger.info("Loading model: %s", model_name)
        bundle = MODEL_LOADERS[model_name]()

        server_state["recognizer"] = bundle
        server_state["model_loaded"] = model_name
        server_state["model_loading"] = False

        logger.info("Model ready: %s", model_name)
        return jsonify({"status": "ok", "model": model_name})

    except Exception as e:
        logger.error("Failed to load model %s: %s", model_name, e, exc_info=True)
        server_state["model_loading"] = False
        server_state["error"] = str(e)
        return jsonify({"error": str(e)}), 500


@app.route("/transcribe", methods=["POST"])
def transcribe():
    data = request.json or {}
    audio_b64 = data.get("audio")
    sample_rate = data.get("sample_rate", 16000)

    if not audio_b64:
        return jsonify({"error": "No audio data provided"}), 400

    bundle = server_state["recognizer"]
    if bundle is None:
        return jsonify({"error": "No model loaded"}), 400

    try:
        samples = decode_audio(audio_b64)
        duration = len(samples) / sample_rate
        logger.info("Received %.1fs of audio (%d samples @ %dHz)", duration, len(samples), sample_rate)

        start = time.time()
        transcribe_fn = TRANSCRIBERS[bundle["type"]]
        text = transcribe_fn(bundle, samples, sample_rate)
        elapsed = time.time() - start

        logger.info("Transcription in %.2fs (RTF %.2f): %s", elapsed, elapsed / max(duration, 0.01), text[:120])
        return jsonify({"text": text.strip(), "duration": elapsed})

    except Exception as e:
        logger.error("Transcription error: %s", e, exc_info=True)
        return jsonify({"error": str(e)}), 500


@app.route("/unload", methods=["POST"])
def unload_model():
    server_state["recognizer"] = None
    server_state["model_loaded"] = None
    server_state["model_loading"] = False
    server_state["download_progress"] = 0.0
    logger.info("Model unloaded")
    return jsonify({"status": "ok"})


@app.route("/shutdown", methods=["POST"])
def shutdown_server():
    logger.info("Shutdown requested")
    shutdown = request.environ.get("werkzeug.server.shutdown")
    if shutdown is not None:
        shutdown()
        return jsonify({"status": "ok"})

    # Fallback when Werkzeug doesn't expose the shutdown hook.
    def _delayed_exit():
        time.sleep(0.2)
        os._exit(0)

    import threading
    threading.Thread(target=_delayed_exit, daemon=True).start()
    return jsonify({"status": "ok"})


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    port = int(os.environ.get("PORT", "8178"))
    logger.info("Starting OpenWhisper inference server on port %d", port)
    logger.info("Models directory: %s", MODELS_DIR)
    app.run(host="127.0.0.1", port=port, threaded=True)
"""#
}
