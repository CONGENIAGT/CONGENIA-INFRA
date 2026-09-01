#!/usr/bin/env bash
# =============================================================================
# Pruebas de salud atravesando el ALB, que es el unico punto de entrada.
#
# Comprueba CONTENIDO, no solo codigos HTTP: con las reglas de path mal
# aplicadas, MiniStack devuelve 200 sirviendo el frontend para todas las rutas,
# y un smoke test que solo mirara el codigo daria un falso verde.
# =============================================================================
set -uo pipefail

TFDIR="${1:-envs/local}"
GW="${MINISTACK_ENDPOINT:-http://localhost:4566}"

if [[ "$TFDIR" == *"/aws" || "$TFDIR" == "envs/aws" ]]; then
  base_url=$(cd "$TFDIR" && terraform output -raw public_url)
  host_header=""
  target_label="$base_url"
else
  alb=$(cd "$TFDIR" && terraform output -raw alb_name)
  host_header="${alb}.alb.localhost"
  base_url="$GW"
  target_label="${base_url} (Host: ${host_header})"
fi

fail=0
check() {
  local label="$1" path="$2" pattern="$3"
  local body code response attempt
  local attempts="${SMOKE_ATTEMPTS:-12}"
  local delay="${SMOKE_RETRY_DELAY_SECONDS:-5}"

  # ECS puede declarar el servicio antes de que la aplicacion acepte trafico.
  # Reintentar evita falsos negativos sin relajar la validacion de contenido.
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if [[ -n "$host_header" ]]; then
      response=$(curl -sS -m 15 -w $'\n%{http_code}' \
        -H "Host: ${host_header}" "${base_url}${path}")
    else
      response=$(curl -sS -m 15 -w $'\n%{http_code}' "${base_url}${path}")
    fi
    code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$code" =~ ^2[0-9][0-9]$ ]] && grep -qE "$pattern" <<<"$body"; then
      printf '  OK     %-22s %-18s %s\n' "$label" "$path" "$code"
      return
    fi

    if ((attempt < attempts)); then
      sleep "$delay"
    fi
  done

  printf '  FALLA  %-22s %-18s %s  (no coincide con /%s/ despues de %s intentos)\n' \
    "$label" "$path" "$code" "$pattern" "$attempts"
  fail=1
}

echo "Smoke test contra ${target_label}"
echo "  ruta                            path               http"
check "frontend (ficha)"  "/"                 'Ficha Genetica|<!doctype html>'
check "api + dependencias" "/health/ready"     '"status"[[:space:]]*:[[:space:]]*"ok"'
check "keycloak congenia"  "/realms/congenia"  '"realm"[[:space:]]*:[[:space:]]*"congenia"'

if [[ $fail -eq 0 ]]; then
  echo "Todo el trafico atraviesa la DMZ hacia la red privada correctamente."
else
  echo "Hay rutas que no llegan a su servicio."
fi
exit $fail
