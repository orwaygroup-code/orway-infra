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

# El id del contenedor de Postgres, para `docker cp`. Se resuelve una vez.
CONTENEDOR="$(docker compose -f "$ROOT/docker-compose.yml" ps -q postgres)"
if [ -z "$CONTENEDOR" ]; then
  echo "✗ El contenedor de Postgres no esta corriendo." >&2
  exit 1
fi

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
  TMP="/tmp/${DB}-${SELLO}.dump"   # dentro del contenedor
  echo "▶ $DB"

  # El volcado se escribe DENTRO del contenedor, no por tuberia.
  #
  # La primera version mandaba el volcado por stdout y lo verificaba con
  # `pg_restore --list /dev/stdin`. No funciona: un archivo en formato custom
  # se recorre hacia atras para leer su indice, y una tuberia no se puede
  # rebobinar. El efecto era el peor posible — descartaba respaldos BUENOS y
  # reportaba fallo. Un respaldo que miente sobre si mismo es peor que no
  # tenerlo, porque nadie va a buscar el problema hasta que haga falta.
  if ! compose_pg pg_dump -U "$POSTGRES_USER" -Fc -f "$TMP" "$DB"; then
    echo "  ✗ fallo el volcado de $DB" >&2
    compose_pg rm -f "$TMP" 2>/dev/null || true
    FALLOS=$((FALLOS + 1))
    continue
  fi

  # VERIFICACION, no opcional. Un pg_dump puede terminar en 0 y dejar un
  # archivo truncado si se acaba el disco a media escritura. `pg_restore -l`
  # lee el indice: si no lo puede listar, el respaldo no sirve, y es mejor
  # saberlo hoy que el dia que haya que restaurarlo. Ahora corre contra un
  # archivo real, que si se puede recorrer.
  if ! compose_pg pg_restore --list "$TMP" > /dev/null 2>&1; then
    echo "  ✗ el volcado de $DB no se puede leer: se descarta" >&2
    compose_pg rm -f "$TMP" 2>/dev/null || true
    FALLOS=$((FALLOS + 1))
    continue
  fi

  # Sale del contenedor con `docker cp`, no con `cat` por la tuberia de exec.
  # Un volcado es binario, y sacarlo por stdout depende de que nada en el
  # camino lo toque. `docker cp` esta hecho justamente para mover archivos.
  TAMANO_DENTRO="$(compose_pg stat -c %s "$TMP" | tr -d '')"

  if ! docker cp "$CONTENEDOR:$TMP" "$ARCHIVO" > /dev/null; then
    echo "  ✗ no se pudo sacar el volcado de $DB del contenedor" >&2
    rm -f "$ARCHIVO"
    compose_pg rm -f "$TMP" 2>/dev/null || true
    FALLOS=$((FALLOS + 1))
    continue
  fi
  compose_pg rm -f "$TMP" 2>/dev/null || true

  # Y que lo que llego al disco pese EXACTAMENTE lo que se verifico. Un byte
  # de diferencia significa que el archivo que guardamos no es el que pasó la
  # prueba, y entonces la prueba no vale.
  TAMANO_FUERA="$(stat -c %s "$ARCHIVO" 2>/dev/null || echo 0)"
  if [ "$TAMANO_DENTRO" != "$TAMANO_FUERA" ]; then
    echo "  ✗ $DB llego incompleto: $TAMANO_FUERA de $TAMANO_DENTRO bytes" >&2
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
