#!/usr/bin/env bash
# Aprovisiona una instancia nueva de ORest para un restaurante.
# Uso:  ./scripts/new-orest-client.sh <cliente> <dominio>
# Ej.:  ./scripts/new-orest-client.sh sanluca sanluca.orwaygroup.com
#
# Hace: crea BD + usuario en el Postgres compartido, genera el .env del cliente
# con sus secretos, levanta el contenedor con Traefik y CORRE LAS MIGRACIONES.
#
# DIFERENCIAS CON new-ayalas-client.sh, y las dos importan:
#   1. ORest usa `prisma migrate deploy`, NUNCA `db push`. Lleva migraciones
#      desde el commit uno y su SQL escrito a mano no se regenera
#      (docs/producto.md, decisión 2). Un `db push` las borraría en silencio.
#   2. El primer usuario NO sale de este .env: lo crea una persona en
#      https://<dominio>/primer-uso con el SETUP_CODE que imprime este script.
set -euo pipefail

CLIENT="${1:?falta <cliente>}"
DOMAIN="${2:?falta <dominio>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/apps/orest/clients/$CLIENT"

if [ -e "$DIR" ]; then
  echo "✗ Ya existe $DIR. Si quieres rehacerlo, muévelo antes (lleva secretos)." >&2
  exit 1
fi

set -a; source "$ROOT/.env"; set +a
DB="orest_${CLIENT}_db"
DBUSER="orest_${CLIENT}"
DBPASS="$(openssl rand -hex 16)"
SETUP_CODE="$(openssl rand -hex 16)"

echo "▶ Creando BD '$DB' y usuario '$DBUSER'…"
docker compose -f "$ROOT/docker-compose.yml" exec -T postgres \
  psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE USER "$DBUSER" WITH PASSWORD '$DBPASS';
CREATE DATABASE "$DB" OWNER "$DBUSER";
-- Aislamiento entre bases del Postgres compartido: nadie más se conecta aquí.
REVOKE CONNECT ON DATABASE "$DB" FROM PUBLIC;
GRANT CONNECT ON DATABASE "$DB" TO "$DBUSER";
SQL

echo "▶ Generando .env del cliente en $DIR…"
mkdir -p "$DIR"
cp "$ROOT/apps/orest/docker-compose.yml" "$DIR/docker-compose.yml"
cat > "$DIR/.env" <<ENV
CLIENT=$CLIENT
DOMAIN=$DOMAIN
DATABASE_URL=postgresql://$DBUSER:$DBPASS@postgres:5432/$DB?schema=public&connection_limit=5
AUTH_SECRET=$(openssl rand -base64 48)
SETUP_CODE=$SETUP_CODE
ENV
chmod 600 "$DIR/.env"

echo "▶ Levantando contenedor orest-$CLIENT…"
docker compose -p "orest-$CLIENT" --project-directory "$DIR" up -d

echo "▶ Aplicando migraciones (migrate deploy, NUNCA db push)…"
docker compose -p "orest-$CLIENT" --project-directory "$DIR" exec -T app npx prisma migrate deploy

echo
echo "✓ Listo: https://$DOMAIN"
echo
echo "  SETUP_CODE = $SETUP_CODE"
echo "  Entrégaselo a quien pagó. Con él crea al primer MANAGER en"
echo "  https://$DOMAIN/primer-uso  —  deja de servir en cuanto exista cualquier Staff."
echo
echo "  Los secretos quedaron en $DIR/.env (chmod 600). GUÁRDALOS: el AUTH_SECRET"
echo "  no se puede regenerar sin tirar todas las sesiones."
echo
echo "  Antes de abrirlo al cliente, comprueba:"
echo "    docker compose -p orest-$CLIENT ps          # debe decir (healthy)"
echo "    curl -s https://$DOMAIN/api/health          # {\"ok\":true}"
