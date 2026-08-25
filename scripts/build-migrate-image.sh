#!/usr/bin/env bash
# =============================================================================
# Construye y publica la imagen de migracion en ECR.
#
# Los .sql viven en el repo de la aplicacion (CONGENIA-M1-SERVER/db/init) y se
# copian aqui como contexto de build. No se versionan en este repositorio: la
# fuente de verdad del esquema sigue siendo el repo del servidor.
# =============================================================================
set -euo pipefail

TFDIR="${1:-envs/aws}"
ORCH_DIR="${2:-../ProjectUVG}"
TAG="${3:-latest}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGEN="${ORCH_DIR}/CONGENIA-M1-SERVER/db/init"
CONTEXTO="${HERE}/docker/migrate"

[[ -d "$ORIGEN" ]] || { echo "No encuentro los .sql en ${ORIGEN}" >&2; exit 1; }

rm -rf "${CONTEXTO}/sql"
mkdir -p "${CONTEXTO}/sql"
cp "${ORIGEN}"/*.sql "${CONTEXTO}/sql/"
echo "SQL horneado en la imagen:"
ls -1 "${CONTEXTO}/sql" | sed 's/^/  /'

repositorio=$(cd "$TFDIR" && terraform output -raw migrate_image_repository)
region=$(cd "$TFDIR" && terraform output -raw region)
registro="${repositorio%%/*}"

aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$registro"

# amd64 a proposito: los servicios de envs/aws declaran cpu_architecture
# X86_64 y la tarea de migracion corre en el mismo Fargate.
docker build --platform linux/amd64 -t "${repositorio}:${TAG}" "$CONTEXTO"
docker push "${repositorio}:${TAG}"

echo "Publicada ${repositorio}:${TAG}"
