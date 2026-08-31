#!/bin/sh
# =============================================================================
# Aplica los .sql horneados en /sql contra la base que apunten las variables
# PG*. El password llega por PGPASSWORD, inyectado desde Secrets Manager por el
# bloque `secrets` de la task definition (nunca como environment en claro).
# =============================================================================
set -eu

: "${PGHOST:?falta PGHOST}"
: "${PGDATABASE:?falta PGDATABASE}"
: "${PGUSER:?falta PGUSER}"
: "${PGPASSWORD:?falta PGPASSWORD}"

echo "==> Migracion CONGENIA contra ${PGHOST}:${PGPORT:-5432}/${PGDATABASE}"

# RDS puede seguir arrancando cuando la tarea ya corre.
intentos=0
until pg_isready -q; do
  intentos=$((intentos + 1))
  if [ "$intentos" -ge 30 ]; then
    echo "!!! ${PGHOST} no acepta conexiones despues de 60s" >&2
    exit 1
  fi
  sleep 2
done

# El esquema no es idempotente: 23 CREATE TABLE sin IF NOT EXISTS. Correrlo dos
# veces aborta en la primera tabla. Se detecta por la presencia de "usuario",
# que es la primera que crea 01_schema.sql.
cargado=$(psql -tAc "SELECT to_regclass('public.usuario') IS NOT NULL")

if [ "$cargado" = "t" ] && [ "${MIGRATE_FORCE:-0}" != "1" ]; then
  echo "==> El esquema ya esta cargado (existe la tabla \"usuario\"). Nada que hacer."
  echo "    Para forzarlo: MIGRATE_FORCE=1 en la task definition (variable"
  echo "    \`force\` del modulo). Los CREATE TABLE fallaran si ya existen."
  exit 0
fi

for archivo in /sql/*.sql; do
  echo "==> Aplicando $(basename "$archivo")"
  psql -v ON_ERROR_STOP=1 -q -f "$archivo"
done

tablas=$(psql -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
echo "==> Listo. Tablas en el esquema public: ${tablas}"
