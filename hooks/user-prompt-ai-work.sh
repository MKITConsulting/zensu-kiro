#!/usr/bin/env bash
# Native identity permits idempotent initialization when agentSpawn is absent.
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
node "$ROOT/hooks/kiro/ai-work.js" hook-prompt
