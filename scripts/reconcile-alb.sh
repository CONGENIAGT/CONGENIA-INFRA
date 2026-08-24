#!/usr/bin/env bash
# Envoltorio de reconcile_alb.py. Solo aplica al entorno local (MiniStack).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/reconcile_alb.py" "${1:-envs/local}"
