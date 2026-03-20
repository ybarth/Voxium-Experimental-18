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
    # Dedicated timing model (Parakeet CTC) — independent of main recognizer
    "timing_recognizer": None,
    "timing_loaded": False,
    "timing_loading": False,
    "timing_error": None,
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


def _find_speech_boundaries_ms(samples, sample_rate):
    """Find where speech starts and ends using adaptive energy detection.

    Uses the noise floor from the first 100ms to set a dynamic threshold,
    requires 3 consecutive windows above threshold to confirm speech onset,
    and adds a small safety margin.
    """
    window_ms = 20
    window_size = int(sample_rate * window_ms / 1000)
    total_ms = int(len(samples) / sample_rate * 1000)

    if len(samples) < window_size * 5:
        return 0, total_ms

    # Compute RMS for all windows
    n_windows = len(samples) // window_size
    rms_values = []
    for i in range(n_windows):
        chunk = samples[i * window_size : (i + 1) * window_size]
        rms_values.append(float(np.sqrt(np.mean(chunk ** 2))))

    # Estimate noise floor from first 100ms (5 windows at 20ms each)
    noise_windows = min(5, len(rms_values))
    noise_floor = np.median(rms_values[:noise_windows]) if noise_windows > 0 else 0.0

    # Threshold = 3x noise floor, with a minimum of 0.02 to avoid
    # triggering on very quiet recordings
    threshold = max(float(noise_floor) * 3.0, 0.02)

    # Require 3 consecutive windows above threshold to confirm speech
    consecutive_needed = 3

    # Find speech start
    speech_start = 0
    run = 0
    for i, rms in enumerate(rms_values):
        if rms > threshold:
            run += 1
            if run >= consecutive_needed:
                # Speech confirmed — start is where the run began
                start_window = i - consecutive_needed + 1
                speech_start = start_window * window_ms
                break
        else:
            run = 0

    # Find speech end (scan backwards)
    speech_end = total_ms
    run = 0
    for i in range(len(rms_values) - 1, -1, -1):
        if rms_values[i] > threshold:
            run += 1
            if run >= consecutive_needed:
                end_window = i + consecutive_needed
                speech_end = min(end_window * window_ms, total_ms)
                break
        else:
            run = 0

    return speech_start, speech_end

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

def _build_word_timestamps_from_ctc(result):
    """Build word-level timestamps from CTC/BPE tokens.

    Handles multiple token formats:
    - BPE subwords with leading-space word boundaries: ' the', 'ing', ' I'
    - SentencePiece ▁ prefix: '▁the', 'ing'
    - Character-level with space tokens
    """
    tokens = getattr(result, "tokens", None) or []
    timestamps = getattr(result, "timestamps", None) or []

    if not tokens or not timestamps or len(tokens) != len(timestamps):
        return []

    words = []
    current_text = ""
    word_start = None
    word_end = None

    for token, ts in zip(tokens, timestamps):
        # Detect word boundary: token starts with space or ▁
        is_boundary = token.startswith(" ") or token.startswith("\u2581")

        if is_boundary and current_text:
            # Flush the current word
            words.append({
                "word": current_text,
                "start_ms": int(word_start * 1000),
                "end_ms": int(word_end * 1000),
            })
            current_text = ""
            word_start = None

        # Strip the leading space/▁ to get the actual text
        piece = token.lstrip(" \u2581")

        # Skip empty tokens (standalone spaces, blanks)
        if not piece:
            continue

        if word_start is None:
            word_start = ts
        word_end = ts
        current_text += piece

    # Flush the last word
    if current_text and word_start is not None:
        words.append({
            "word": current_text,
            "start_ms": int(word_start * 1000),
            "end_ms": int((word_end or word_start) * 1000),
        })

    return words


def _build_synthetic_timestamps(text, duration_ms, speech_start_ms=0, speech_end_ms=None):
    """Build character-weighted synthetic timestamps from text.

    Uses speech_start_ms/speech_end_ms to place words only in the region
    where speech actually occurs, not from time 0.
    """
    words_list = text.split()
    if not words_list or duration_ms <= 0:
        return []

    if speech_end_ms is None:
        speech_end_ms = duration_ms

    speech_duration = speech_end_ms - speech_start_ms
    if speech_duration <= 0:
        speech_duration = duration_ms
        speech_start_ms = 0

    total_chars = sum(max(len(w), 1) for w in words_list)
    cursor = speech_start_ms
    result = []

    for i, word in enumerate(words_list):
        weight = max(len(word), 1) / total_chars
        span = int(speech_duration * weight)
        start = cursor
        end = speech_end_ms if i == len(words_list) - 1 else cursor + span
        cursor = end
        result.append({"word": word, "start_ms": start, "end_ms": end})

    return result


def transcribe_sherpa(bundle, samples, sample_rate):
    """Transcribe using sherpa-onnx recognizer."""
    recognizer = bundle["recognizer"]
    stream = recognizer.create_stream()
    stream.accept_waveform(sample_rate, samples.tolist())
    recognizer.decode_stream(stream)

    text = stream.result.text
    word_timestamps = _build_word_timestamps_from_ctc(stream.result)

    # Fall back to synthetic if CTC tokens weren't available
    if not word_timestamps and text.strip():
        duration_ms = int(len(samples) / sample_rate * 1000)
        start_ms, end_ms = _find_speech_boundaries_ms(samples, sample_rate)
        word_timestamps = _build_synthetic_timestamps(
            text.strip(), duration_ms, speech_start_ms=start_ms, speech_end_ms=end_ms
        )

    return {"text": text, "word_timestamps": word_timestamps}


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
        text = getattr(result, "text", str(result))

        # Build character-weighted timestamps using detected speech boundaries
        duration_ms = int(len(samples) / sample_rate * 1000)
        start_ms, end_ms = _find_speech_boundaries_ms(samples, sample_rate)
        word_timestamps = _build_synthetic_timestamps(
            text.strip(), duration_ms, speech_start_ms=start_ms, speech_end_ms=end_ms
        )

        return {"text": text, "word_timestamps": word_timestamps}
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
            "timing_loaded": server_state["timing_loaded"],
            "timing_loading": server_state["timing_loading"],
            "timing_error": server_state["timing_error"],
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
        result = transcribe_fn(bundle, samples, sample_rate)
        elapsed = time.time() - start

        text = result["text"] if isinstance(result, dict) else result
        word_timestamps = result.get("word_timestamps", []) if isinstance(result, dict) else []

        logger.info("Transcription in %.2fs (RTF %.2f): %s", elapsed, elapsed / max(duration, 0.01), text[:120])
        return jsonify({
            "text": text.strip(),
            "word_timestamps": word_timestamps,
            "duration": elapsed,
        })

    except Exception as e:
        logger.error("Transcription error: %s", e, exc_info=True)
        return jsonify({"error": str(e)}), 500


@app.route("/load_timing", methods=["POST"])
def load_timing_model():
    """Load Parakeet CTC as the dedicated timing model."""
    if server_state["timing_loaded"]:
        return jsonify({"status": "ok", "message": "Timing model already loaded"})

    try:
        server_state["timing_loading"] = True
        server_state["timing_error"] = None
        logger.info("Loading timing model (Parakeet CTC)...")
        bundle = load_parakeet_ctc()
        server_state["timing_recognizer"] = bundle
        server_state["timing_loaded"] = True
        server_state["timing_loading"] = False
        logger.info("Timing model ready.")
        return jsonify({"status": "ok"})
    except Exception as e:
        logger.error("Failed to load timing model: %s", e, exc_info=True)
        server_state["timing_loading"] = False
        server_state["timing_error"] = str(e)
        return jsonify({"error": str(e)}), 500


@app.route("/timing", methods=["POST"])
def analyze_timing():
    """Get CTC word-level timestamps from audio via the timing model."""
    data = request.json or {}
    audio_b64 = data.get("audio")
    sample_rate = data.get("sample_rate", 16000)

    if not audio_b64:
        return jsonify({"error": "No audio data provided"}), 400

    bundle = server_state["timing_recognizer"]
    if bundle is None:
        return jsonify({"error": "Timing model not loaded"}), 400

    try:
        samples = decode_audio(audio_b64)
        duration = len(samples) / sample_rate
        logger.info("Timing analysis: %.1fs of audio (%d samples)", duration, len(samples))

        start = time.time()
        recognizer = bundle["recognizer"]
        stream = recognizer.create_stream()
        stream.accept_waveform(sample_rate, samples.tolist())
        recognizer.decode_stream(stream)

        word_timestamps = _build_word_timestamps_from_ctc(stream.result)

        # Fall back to synthetic with speech detection if CTC tokens unavailable
        if not word_timestamps and stream.result.text.strip():
            duration_ms = int(len(samples) / sample_rate * 1000)
            start_ms, end_ms = _find_speech_boundaries_ms(samples, sample_rate)
            word_timestamps = _build_synthetic_timestamps(
                stream.result.text.strip(), duration_ms,
                speech_start_ms=start_ms, speech_end_ms=end_ms,
            )

        # Safety rail: verify CTC timestamps against energy-based speech onset.
        # If CTC says first word starts before detected speech, clamp forward.
        if word_timestamps:
            speech_start_ms, _ = _find_speech_boundaries_ms(samples, sample_rate)
            first_start = word_timestamps[0]["start_ms"]
            if first_start < speech_start_ms:
                shift = speech_start_ms - first_start
                logger.info("Clamping timestamps forward by %dms (CTC=%dms, energy=%dms)",
                            shift, first_start, speech_start_ms)
                for wt in word_timestamps:
                    wt["start_ms"] += shift
                    wt["end_ms"] += shift

        elapsed = time.time() - start

        logger.info("Timing analysis done in %.2fs (%d words, first_start=%dms)",
                     elapsed, len(word_timestamps),
                     word_timestamps[0]["start_ms"] if word_timestamps else 0)
        return jsonify({
            "word_timestamps": word_timestamps,
            "text": stream.result.text.strip(),
            "duration": elapsed,
        })

    except Exception as e:
        logger.error("Timing analysis error: %s", e, exc_info=True)
        return jsonify({"error": str(e)}), 500


@app.route("/unload", methods=["POST"])
def unload_model():
    server_state["recognizer"] = None
    server_state["model_loaded"] = None
    server_state["model_loading"] = False
    server_state["download_progress"] = 0.0
    server_state["timing_recognizer"] = None
    server_state["timing_loaded"] = False
    server_state["timing_loading"] = False
    server_state["timing_error"] = None
    logger.info("All models unloaded")
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
