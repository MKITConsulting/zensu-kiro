#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec node "$ROOT/hooks/kiro/ai-work.js" hook-stop
