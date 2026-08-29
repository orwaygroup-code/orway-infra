#!/usr/bin/env bash
# Respaldo de TODAS las bases del Postgres compartido de Orway.
#
# Se corre por cron en el VPS. Para El Perico no es una buena practica: es
# requisito para operar. Esa base guarda cortes de caja y pagos, y un respaldo
# que vive en el mismo disco que la base no es un respaldo — es una copia que
# se pierde con el mismo incidente.
#
# Uso:
#   ./scripts/backup-all-dbs.sh            # respalda y verifica
#   BACKUP_DEST=... ./scripts/backup-all-dbs.sh
#
# Cron sugerido (3:00, antes de que abra el local):
#   0 3 * * * /opt/orway-infra/scripts/backup-all-dbs.sh >> /var/log/orway-backup.log 2>&1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; source "$ROOT/.env"; set +a

DIR="${BACKUP_DIR:-/var/backups/orway}"
DIAS="${BACKUP_RETENTION_DAYS:-14}"
SELLO="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DIR"

compose_pg() {
  docker compose -f "$ROOT/docker-compose.yml" exec -T postgres "$@"
}

# Las bases reales, sin las plantillas de Postgres.
BASES="$(compose_pg psql -U "$POSTGRES_USER" -d postgres -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres'")"

if [ -z "$BASES" ]; then
  echo "✗ No se encontro ninguna base. ¿Esta arriba el contenedor de Postgres?" >&2
  exit 1
fi

FALLOS=0

for DB in $BASES; do
  ARCHIVO="$DIR/${DB}-${SELLO}.dump"
  echo "▶ $DB"

  # Formato custom (-Fc): comprimido y restaurable por tabla con pg_restore.
  if ! compose_pg pg_dump -U "$POSTGRES_USER" -Fc "$DB" > "$ARCHIVO"; then
    echo "  ✗ fallo el volcado de $DB" >&2
    rm -f "$ARCHIVO"
    FALLOS=$((FALLOS + 1))
    continue
  fi

  # VERIFICACION, no opcional. Un pg_dump puede terminar en 0 y dejar un
  # archivo truncado si se acaba el disco a media escritura. `pg_restore -l`
  # lee el indice del volcado: si no lo puede listar, el respaldo no sirve y
  # es mejor saberlo hoy que el dia que haya que restaurarlo.
  if ! compose_pg pg_restore --list /dev/stdin < "$ARCHIVO" > /dev/null 2>&1; then
    echo "  ✗ el volcado de $DB no se puede leer: se descarta" >&2
    rm -f "$ARCHIVO"
    FALLOS=$((FALLOS + 1))
    continue
  fi

  echo "  ✓ $(du -h "$ARCHIVO" | cut -f1)  $ARCHIVO"
done

# ---------------------------------------------------------------------------
#  Copia FUERA del servidor
# ---------------------------------------------------------------------------
# Sin esto, el respaldo protege contra un DROP TABLE pero NO contra perder el
# VPS, que es el escenario que de verdad cierra un negocio. Configura UNO de
# estos en el .env de la infra y descomenta el bloque que corresponda.
#
#   BACKUP_DEST=rclone   BACKUP_REMOTE=orway-drive:respaldos
#   BACKUP_DEST=s3       BACKUP_BUCKET=orway-respaldos  S3_ENDPOINT=https://...
#   BACKUP_DEST=scp      BACKUP_HOST=usuario@maquina    BACKUP_PATH=/respaldos
#
case "${BACKUP_DEST:-ninguno}" in
  rclone)
    rclone copy "$DIR" "${BACKUP_REMOTE:?falta BACKUP_REMOTE}" \
      --include "*-${SELLO}.dump" --transfers 2
    echo "✓ copiado a $BACKUP_REMOTE"
    ;;
  s3)
    for f in "$DIR"/*-"${SELLO}".dump; do
      aws s3 cp "$f" "s3://${BACKUP_BUCKET:?falta BACKUP_BUCKET}/" \
        ${S3_ENDPOINT:+--endpoint-url "$S3_ENDPOINT"}
    done
    echo "✓ copiado a s3://$BACKUP_BUCKET"
    ;;
  scp)
    scp "$DIR"/*-"${SELLO}".dump \
      "${BACKUP_HOST:?falta BACKUP_HOST}:${BACKUP_PATH:?falta BACKUP_PATH}/"
    echo "✓ copiado a $BACKUP_HOST"
    ;;
  ninguno)
    echo "⚠ BACKUP_DEST no esta configurado: el respaldo vive SOLO en este VPS."
    echo "  Si se pierde el servidor, se pierde con el. Configuralo antes de"
    echo "  poner El Perico a cobrar dinero real."
    ;;
  *)
    echo "✗ BACKUP_DEST desconocido: ${BACKUP_DEST}" >&2
    FALLOS=$((FALLOS + 1))
    ;;
esac

# Rotacion local. La copia de afuera se rota donde viva.
find "$DIR" -name '*.dump' -mtime "+$DIAS" -delete

if [ "$FALLOS" -gt 0 ]; then
  echo "✗ Termino con $FALLOS fallo(s)." >&2
  exit 1
fi

echo "✓ Respaldo completo: $SELLO"
