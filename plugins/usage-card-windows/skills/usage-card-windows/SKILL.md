---
name: usage-card-windows
description: Help install, start, or troubleshoot the unofficial Codex Usage Card for Windows, including its separate launcher and sidebar display.
---

This plugin provides guidance; installing it does not add a sidebar widget or start a helper. The card uses an unofficial CDP connection and bundled `runtime/start.ps1` and `runtime/agent.cjs` in the plugin root. Read the repository README when available. On Windows, tell the user to save work and exit Codex before running the launcher. The launcher may ask the user to approve stopping verified background processes; do not kill processes or restart the active client on the user's behalf. Explain that the localhost debugging endpoint can be controlled by other local processes and must not be exposed to a network. If troubleshooting, inspect the launcher output and avoid requesting account or usage data. Do not claim a successful mount until verified.
