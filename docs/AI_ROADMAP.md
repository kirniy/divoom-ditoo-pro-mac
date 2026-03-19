# AI Roadmap

This page tracks future AI features for the native Divoom Mac app. It stays separate from protocol parity notes so the product backlog does not get buried in reverse-engineering detail.

## Model Targets

- Gemini 2
- Gemini 3.1 Pro
- Gemini Flash
- other Gemini variants as they become useful for a specific task

## Principles

- Use the right model for the right job instead of one generic prompt path.
- Keep AI opt-in, explicit, and easy to disable.
- Cache results locally when possible so the app stays fast and resilient.
- Prefer actionable outputs over generic chat.
- Keep the native app useful even when AI is unavailable.

## Practical Features

- rotating top-card headlines and contextual status copy
- library tagging, auto-titles, and duplicate-detection hints
- natural-language animation search and library filtering
- cloud sync assistance for sorting, classification, and cleanup
- log summarization and failure explanation from the native app
- release-note and changelog drafting from real repo history
- animation curation suggestions based on favorites and recent sends
- quick help text for settings, install, and cloud-login flows

## Suggested Routing

- Gemini Flash for fast, low-latency copy, tagging, and helper text
- Gemini 2 for broader synthesis and library classification tasks
- Gemini 3.1 Pro for deeper analysis, multi-step reasoning, and content generation

## Product Guardrails

- never hide the current manual controls behind AI
- never make AI required for the core BLE or library flows
- never guess at protocol behavior just because an AI model suggested it
- surface model choice and source of truth in settings if AI features become active
