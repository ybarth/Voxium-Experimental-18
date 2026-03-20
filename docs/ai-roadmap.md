# AI Intelligence Layer — Roadmap

> Established 2026-03-20. This document captures the full vision and build order for integrating AI intelligence across OpenWhisper.

## Overview

The app is evolving from a voice-to-text tool into an AI-enhanced dictation system. This roadmap covers: a custom dictionary feature, integration of open-source and commercial LLMs, an LLM Council for multi-model collaboration, and AI-powered enhancements to transcription, history, and UI.

## Build Order

Each layer depends on the one before it. Each sub-project gets its own design spec → implementation plan → build cycle.

### Layer 1: AI Provider Infrastructure

**Sub-project A: Local LLM Management**
- MLX as primary local runtime (best Apple Silicon / M4 performance via Metal GPU)
- 8 curated models: Llama 3.1 70B, Qwen 2.5 72B, Kimi-Dev-72B, GLM-4.6, DeepSeek-R1 32B, Gemma 2 27B, Phi-4 14B, Mixtral 8x22B
- Ollama as optional convenience integration (auto-detects local install)
- Model download from HuggingFace with pause/resume, health checks, load/unload lifecycle

**Sub-project B: Commercial API Integration (BYOK)**
- Bring-your-own-key management for Claude, GPT, Gemini, Grok
- Key format validation per service (intelligent field validation)
- Connection testing with diagnostic error explanations
- Secure key storage via macOS Keychain

**Sub-project C: Unified AI Provider Abstraction**
- Common protocol wrapping both local and commercial models
- Task routing — user configures which model(s) handle which tasks
- Configuration UI in Settings

> A, B, and C are tightly coupled and should be specced/built together.

### Layer 2: LLM Council

**Sub-project D: Council System**
- Based on [Karpathy's LLM Council](https://github.com/karpathy/llm-council)
- Three stages:
  1. Individual model responses to a query
  2. Anonymized peer review (models critique each other without knowing identities)
  3. Chairman LLM synthesizes the final response
- User configures which models participate and which serves as chairman
- Can include both local (Ollama) and commercial (BYOK) models

### Layer 3: Feature Integration (parallelizable)

**Sub-project E: Custom Dictionary**
- Word dictionary with pronunciation recordings and phonetic annotations (Regular/NATO/IPA verbal spelling)
- Tiered activation engine (Tier 1: always active top ~100 by frequency, Tier 2: context-activated by app/recency, Tier 3: post-processing phonetic correction only)
- Document scanning (PDF, DOCX, RTF, Markdown) to discover unknown words
- Three configurable add-word modes: Quick Pop-up, Full Dictionary Window, Inline Overlay
- Contextual descriptions per entry for AI-enhanced activation
- Integration with all transcription backends (whisper.cpp, Parakeet, Granite, future Claude)
- Architecture: semi-independent `DictionaryManager` subsystem with two narrow integration points to `AppState` (prompt injection before transcription, correction after transcription)

**Sub-project F: Transcription Post-Processing**
- AI-powered cleanup, editing, polishing, context-aware formatting
- Configurable intensity: Off / On / Intensify / Diminish
- Modeled after Wispr Flow capabilities

**Sub-project G: History Intelligence**
- AI-generated titles for transcription entries
- Editorial suggestions on history entries
- Content assessment — flag nonsensical transcribed words
- Easily dismissible queries for quick user edits

**Sub-project H: Visual Generation**
- AI-generated colors and textures by text description
- Applied to history window entries and bars

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Dictionary architecture | Semi-independent `DictionaryManager` | Keeps `AppState` from growing; narrow integration points |
| Dictionary storage | Local JSON + audio files, sync-ready abstraction | Local-first but can add cloud sync later |
| Add-word default mode | Full Dictionary Window | Most complete; all three modes available |
| Tier system | 3 tiers with auto-promotion | Keeps initial prompt lean (~100-200 words) while full dictionary participates in post-processing |
| Post-processing matching | Soundex + Metaphone with confidence threshold | Fast O(1) lookups; won't replace real English words |
| AI provider pattern | Unified protocol over local + commercial | Any feature can use any model without coupling |
| AI per-task config | User chooses single model OR council per task | Flexibility without forcing complexity |
