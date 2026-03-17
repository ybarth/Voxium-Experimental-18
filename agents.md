# Granite MLX Session Notes

Date: 2026-03-17
Project: OpenWhisper
Scope: Replace the Granite backend with Granite 4.0 1B Speech BF16 on Apple Silicon using MLX, then make the local inference server actually work in a real app environment.

## Outcome

The Granite path is no longer the old Python `transformers` / PyTorch server.
It now targets:

- Official model family: `ibm-granite/granite-4.0-1b-speech`
- MLX variant actually used by the app: `mlx-community/granite-4.0-1b-speech-bf16`

The local server was validated to:

- start successfully
- report health successfully
- load Granite successfully
- transcribe successfully after fixing a Granite-specific MLX weight-layout bug

## Source changes made

### 1. Granite backend migrated to MLX

Files:

- `OpenWhisper/Server/InferenceServerScript.swift`
- `OpenWhisper/Server/InferenceServerManager.swift`
- `OpenWhisper/Transcription/ModelManager.swift`
- `OpenWhisper/Views/SettingsTabView.swift`

What changed:

- Granite was switched from `transformers` + `torch` to `mlx-audio`.
- Granite now loads `mlx-community/granite-4.0-1b-speech-bf16`.
- Granite transcription uses the MLX Audio STT model instead of the old chat-template PyTorch path.
- UI text now reflects BF16 / MLX and the larger first-time download.
- Granite dependency installation changed from PyTorch packages to `mlx-audio`.

### 2. Python compatibility guard added

File:

- `OpenWhisper/Server/InferenceServerManager.swift`

What changed:

- Granite setup now explicitly requires Python `3.10+`.
- If the selected Python is too old, setup fails with a clear error instead of failing later during dependency install or model load.

### 3. Server reset flow added

Files:

- `OpenWhisper/Server/InferenceServerManager.swift`
- `OpenWhisper/AppState.swift`
- `OpenWhisper/Views/SettingsTabView.swift`

What changed:

- Added a `Reset Environment` action for server-backed models.
- Reset removes:
  - the server venv in `~/Library/Application Support/OpenWhisper/Server`
  - Granite HF cache for the MLX model
  - old IBM Granite cache entries that can confuse debugging

Why it matters:

- Granite state is not only in the app repo.
- Real runtime state lives in Application Support and Hugging Face cache.
- Rebuilds alone do not reset a broken inference environment.

### 4. Launch-time stale server handling added

Files:

- `OpenWhisper/Server/InferenceServerScript.swift`
- `OpenWhisper/Server/InferenceServerManager.swift`

What changed:

- Added `server_version` to `/health`.
- Added `/shutdown`.
- `InferenceServerManager.ensureRunning(...)` now:
  - checks for an already-running localhost server
  - reuses it if compatible
  - shuts it down if it is stale
  - then starts a fresh one if needed

Why it matters:

- Without this, app launch can fail or behave unpredictably if a previous inference server is still bound to port `8178`.

## Critical runtime issue found and fixed

### Problem

Granite loaded, but transcription failed with:

- `[conv] Expect the input channels in the input and weight array to match ...`

Observed in app logs during `/transcribe`.

### Root cause

The issue was not the OpenWhisper request format.
The issue was inside `mlx-audio`'s Granite Speech loader.

The BF16 community Granite checkpoint already stores its convolution weights in the layout MLX expects:

- `up_conv.weight` looked like `(4096, 1, 1024)`
- `down_conv.weight` looked like `(1024, 1, 2048)`
- `depth_conv.conv.weight` looked like `(2048, 15, 1)`

But `mlx-audio 0.4.1` was transposing those Granite conv weights during `sanitize()`.
That extra transpose produced the broken runtime layout and caused transcription to fail.

### Fix

File:

- `OpenWhisper/Server/InferenceServerScript.swift`

What changed:

- The Granite loader now monkey-patches `GraniteSpeechModel.sanitize` to skip the broken conv transpose and only drop `num_batches_tracked`.

Why this fix exists:

- It is a local compatibility patch against upstream `mlx-audio 0.4.1`.
- If `mlx-audio` fixes Granite sanitize in a later release, this patch should be revisited.

## Real-world configuration work required to make it actually function

This is the important installer section.

### Runtime prerequisites

- Apple Silicon Mac required
  - Granite MLX path explicitly requires `arm64`
- Python `3.10+` required
- Network required on first Granite setup
- Enough disk for the model download and cache
- Enough unified memory for runtime inference

### Python environment details

OpenWhisper creates and uses:

- `~/Library/Application Support/OpenWhisper/Server/venv`

This venv must contain at least:

- `flask`
- `numpy`
- `soundfile`
- `huggingface-hub`
- `mlx-audio`

Important:

- Existing older venvs can remain on disk across app runs.
- If the venv was created before Granite MLX support, the app may need to recreate it.
- The installer should either:
  - create this venv with the correct packages up front, or
  - force a clean rebuild of the server environment on first launch after install/update.

### Deployed server script location

The app does not run the repo file directly.
At runtime it writes and runs:

- `~/Library/Application Support/OpenWhisper/Server/inference_server.py`

Important:

- During debugging, this deployed script was stale and still pointed at the old Granite 3.3 / `transformers` implementation.
- The running app only picked up the new behavior after the deployed script was rewritten.

Installer implication:

- Updates must ensure the embedded server script in Application Support is refreshed.
- Do not assume the file already on disk is current.

### Actual Granite model cache location

Granite BF16 MLX model weights are not stored in `ServerModels`.
They are downloaded into Hugging Face cache:

- `~/.cache/huggingface/hub/models--mlx-community--granite-4.0-1b-speech-bf16`

Installer implication:

- If prewarming or cleaning Granite, this cache location matters.
- Reset/uninstall logic must account for HF cache, not just Application Support.

### Port behavior

The local inference server binds:

- `127.0.0.1:8178`

Installer / runtime implication:

- A stale server from an old app run can remain alive and block or confuse a new launch.
- The new version-handshake plus `/shutdown` logic is intended to solve this.

## Validation performed

Validated during this session:

- `swiftc -parse` passed for touched Swift files.
- The deployed server script parsed successfully after updates.
- Local server started on `127.0.0.1:8178`.
- `/health` returned expected data including `server_version`.
- `/shutdown` stopped the server cleanly.
- Granite BF16 MLX model loaded successfully.
- After the sanitize patch, Granite transcription succeeded.

Successful live transcription response:

- duration: about `2.32s`
- result text returned successfully from `/transcribe`

## Installer checklist

This should be folded into the installer or first-run bootstrap:

1. Ensure Apple Silicon-only Granite path is enforced.
2. Ensure Python `3.10+` is available and selected for the server environment.
3. Create or rebuild `~/Library/Application Support/OpenWhisper/Server/venv`.
4. Install Granite server dependencies, especially `mlx-audio`.
5. Refresh `~/Library/Application Support/OpenWhisper/Server/inference_server.py` from the current app bundle/source.
6. Handle stale localhost server replacement using version-aware health checks.
7. If shipping Granite by default, consider prewarming or at least documenting the Hugging Face cache location.
8. If shipping uninstall/reset tools, remove both:
   - Application Support server state
   - Hugging Face Granite cache
9. Preserve the Granite sanitize override unless and until upstream `mlx-audio` no longer needs it.

## Remaining caveats

- The Granite sanitize fix is currently a local runtime patch, not an upstream library fix.
- If `mlx-audio` changes Granite internals, this patch may need to be updated.
- Development builds on this machine still could not run full `xcodebuild` because `xcode-select` was pointing at Command Line Tools instead of full Xcode. That is a local dev environment issue, not a Granite runtime requirement for end users.
