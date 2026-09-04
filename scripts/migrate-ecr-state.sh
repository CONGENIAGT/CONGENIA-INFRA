#!/usr/bin/env bash
# =============================================================================
# Mueve los repositorios ECR del estado de envs/aws al de envs/shared.
#
# Se corre UNA VEZ, al adoptar la separacion de estados. Despues de esto,
# `make destroy ENV=aws` deja de borrar las imagenes.
#
# Por que hace falta un script y no basta con editar el codigo: los cinco
# repositorios ya existen en AWS y estan registrados en el estado de envs/aws.
# Al sacarlos de la configuracion, `terraform plan` los da por eliminados. Si
# alguien aplica ese plan, se pierden las imagenes publicadas.
#
# El orden correcto es importar primero y soltar despues:
#
#   1. `terraform import` los registra en envs/shared (no toca AWS).
#   2. Se comprueba que las imagenes siguen ahi.
#   3. `terraform state rm` los saca de envs/aws SIN destruirlos.
#
# Hacerlo al reves —soltar antes de importar— deja cinco repositorios que
# ningun estado administra, y volver a adoptarlos es el mismo trabajo.
#
# Uso:
#   ./scripts/migrate-ecr-state.sh            # muestra que haria
#   ./scripts/migrate-ecr-state.sh --aplicar  # lo hace
# =============================================================================
set -euo pipefail

APLICAR=0
[[ "${1:-}" == "--aplicar" ]] && APLICAR=1

REGION="${AWS_REGION:-us-east-1}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

REPOS=(
  congenia/api
  congenia/frontend
  congenia/pdf-worker
  congenia/keycloak
  congenia/migrate
)

if [[ "$APLICAR" -eq 0 ]]; then
  echo "MODO SIMULACION. Nada se modifica. Para ejecutarlo: --aplicar"
  echo ""
fi

# Un entorno inicializado con `-backend=false` (lo hace la verificacion de
# formato y el workflow terraform-check) apunta a un estado local vacio. Ahi
# `state list` no devuelve nada, y este script concluiria que ya esta todo
# migrado cuando en realidad no leyo el estado real. Se comprueba antes de
# tomar cualquier decision.
exigir_backend_remoto() {
  local entorno="$1" backend
  backend=$(python3 - "$entorno" <<'PY'
import json, sys, pathlib
ruta = pathlib.Path(sys.argv[1]) / ".terraform" / "terraform.tfstate"
try:
    print(json.loads(ruta.read_text()).get("backend", {}).get("type", "ninguno"))
except Exception:
    print("ninguno")
PY
)
  if [[ "$backend" != "s3" ]]; then
    echo "" >&2
    echo "${entorno} no esta apuntando al estado remoto (backend: ${backend})." >&2
    echo "Seguramente se inicializo con -backend=false. Corregilo con:" >&2
    echo "" >&2
    echo "  terraform -chdir=${entorno} init -reconfigure" >&2
    echo "" >&2
    echo "Sin esto el script leeria un estado vacio y creeria que no hay nada" >&2
    echo "que migrar." >&2
    exit 1
  fi
}

# ── 0. Estado de partida ────────────────────────────────────────────────────
echo "══ Imagenes publicadas hoy ══"
faltantes=0
for repo in "${REPOS[@]}"; do
  n=$(aws ecr describe-images --region "$REGION" --repository-name "$repo" \
        --query 'length(imageDetails)' --output text 2>/dev/null || echo "sin-repo")
  printf "  %-22s %s imagen(es)\n" "$repo" "$n"
  [[ "$n" == "sin-repo" ]] && faltantes=1
done

if [[ "$faltantes" -eq 1 ]]; then
  echo ""
  echo "Falta algun repositorio en ECR. Esta migracion adopta repositorios que" >&2
  echo "ya existen; si no existen, lo que corresponde es aplicar envs/shared." >&2
  exit 1
fi

echo ""
echo "══ 1. Importar en envs/shared ══"
terraform -chdir=envs/shared init -input=false >/dev/null
exigir_backend_remoto envs/shared

# Se lee una sola vez: `terraform ... | grep -q` devolveria 141 por SIGPIPE
# con pipefail activo, y la condicion diria lo contrario de lo que ve.
estado_shared=$(terraform -chdir=envs/shared state list 2>/dev/null || true)

for repo in "${REPOS[@]}"; do
  direccion="module.registry.aws_ecr_repository.this[\"${repo}\"]"

  if grep -qxF "$direccion" <<<"$estado_shared"; then
    printf "  ya importado  %s\n" "$repo"
    continue
  fi

  if [[ "$APLICAR" -eq 0 ]]; then
    printf "  importaria    %s\n" "$repo"
  else
    printf "  importando    %s\n" "$repo"
    terraform -chdir=envs/shared import -input=false "$direccion" "$repo" >/dev/null
  fi
done

# ── 2. Comprobar antes de soltar nada ───────────────────────────────────────
echo ""
echo "══ 2. Comprobar el import ══"

if [[ "$APLICAR" -eq 1 ]]; then
  importados=$(terraform -chdir=envs/shared state list | grep -c 'aws_ecr_repository' || true)
  echo "  repositorios en el estado de envs/shared: ${importados}/5"

  if [[ "$importados" -ne 5 ]]; then
    echo "" >&2
    echo "El import no quedo completo. NO se suelta nada de envs/aws: mientras" >&2
    echo "sigan ahi, estan administrados y protegidos." >&2
    exit 1
  fi
else
  echo "  (en modo simulacion no hay nada que comprobar todavia)"
fi

# ── 3. Soltar de envs/aws ───────────────────────────────────────────────────
echo ""
echo "══ 3. Soltar de envs/aws (sin destruir) ══"
terraform -chdir=envs/aws init -input=false >/dev/null
exigir_backend_remoto envs/aws

# Si el estado de envs/aws esta vacio, no es que ya se migro: es que no se
# esta leyendo el estado correcto.
if [[ "$(terraform -chdir=envs/aws state list | wc -l | tr -d ' ')" -eq 0 ]]; then
  echo "El estado de envs/aws esta vacio. Revisar el backend antes de seguir." >&2
  exit 1
fi

estado_aws=$(terraform -chdir=envs/aws state list)

for repo in "${REPOS[@]}"; do
  direccion="module.platform.aws_ecr_repository.this[\"${repo}\"]"

  if ! grep -qxF "$direccion" <<<"$estado_aws"; then
    printf "  ya soltado    %s\n" "$repo"
    continue
  fi

  if [[ "$APLICAR" -eq 0 ]]; then
    printf "  soltaria      %s\n" "$repo"
  else
    printf "  soltando      %s\n" "$repo"
    terraform -chdir=envs/aws state rm "$direccion" >/dev/null
  fi
done

echo ""
if [[ "$APLICAR" -eq 0 ]]; then
  echo "Simulacion terminada. Para ejecutarlo:"
  echo "  ./scripts/migrate-ecr-state.sh --aplicar"
  exit 0
fi

# ── 4. Confirmar que ningun plan quiere destruir ECR ────────────────────────
echo "══ 4. Comprobar que ningun plan destruye ECR ══"

if terraform -chdir=envs/aws plan -lock=false -input=false \
     -var-file=images.tfvars -var=manage_dns=false -no-color 2>/dev/null \
   | grep -q 'aws_ecr_repository.*will be destroyed'; then
  echo "  TODAVIA aparece una destruccion de ECR en el plan de envs/aws." >&2
  echo "  No aplicar nada hasta entender por que." >&2
  exit 1
fi

echo "  ok: el plan de envs/aws ya no toca los repositorios."
echo ""
echo "Las imagenes siguen en ECR y ahora las administra envs/shared."
echo "Siguiente paso: 'make create ENV=shared' para crear el resto del stack"
echo "compartido (lifecycle policies, rol de CI, zona DNS)."
