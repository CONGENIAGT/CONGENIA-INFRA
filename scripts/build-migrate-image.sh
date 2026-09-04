#!/usr/bin/env bash
# =============================================================================
# Construye y publica la imagen de migracion en ECR, desde una laptop.
#
# Es la valvula de escape: el camino normal es el workflow `publish-migrate`
# de CONGENIA-M1-SERVER, que hace lo mismo en cada merge que toca `db/`. Este
# script sigue aqui para publicar sin pasar por GitHub (una cuenta AWS nueva
# antes de configurar el pipeline, o una depuracion).
#
# El contexto de build vive en el repo del servidor, junto a los .sql que la
# imagen hornea. Antes el Dockerfile estaba en este repositorio y habia que
# copiar los .sql hasta aca; ahora no se copia nada.
# =============================================================================
set -euo pipefail

TFDIR="${1:-envs/aws}"
ORCH_DIR="${2:-../ProjectUVG}"
TAG="${3:-}"

CONTEXTO="${ORCH_DIR}/CONGENIA-M1-SERVER/db"
DOCKERFILE="${CONTEXTO}/migrate/Dockerfile"

[[ -f "$DOCKERFILE" ]] || { echo "No encuentro el Dockerfile en ${DOCKERFILE}" >&2; exit 1; }

# Sin tag explicito, se deriva del ultimo commit que toco los .sql. Asi el tag
# identifica el contenido: mismo esquema, mismo tag; esquema distinto, tag
# distinto. Hace falta porque ECR esta en modo inmutable y un `latest` fijo
# solo se podria publicar una vez.
#
# Es exactamente la misma regla que aplica el workflow, para que las dos vias
# de publicacion no puedan calcular tags distintos para el mismo esquema.
if [[ -z "$TAG" ]]; then
  sha=$(git -C "${ORCH_DIR}/CONGENIA-M1-SERVER" log -1 --format=%h -- db/init 2>/dev/null || true)
  TAG="schema-${sha:-sinrepo}"
  echo "Tag derivado del esquema: ${TAG}"
fi

echo "SQL que se hornea en la imagen:"
ls -1 "${CONTEXTO}/init" | sed 's/^/  /'

repositorio=$(cd "$TFDIR" && terraform output -raw migrate_image_repository)
region=$(cd "$TFDIR" && terraform output -raw region)
registro="${repositorio%%/*}"

aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$registro"

# amd64 a proposito: los servicios de envs/aws declaran cpu_architecture
# X86_64 y la tarea de migracion corre en el mismo Fargate.
docker build --platform linux/amd64 -f "$DOCKERFILE" -t "${repositorio}:${TAG}" "$CONTEXTO"
docker push "${repositorio}:${TAG}"

echo "Publicada ${repositorio}:${TAG}"
echo
echo "Agrega esta linea a ${TFDIR}/images.tfvars para que Terraform la use:"
echo "  \"migrate\" = \"${TAG}\""
