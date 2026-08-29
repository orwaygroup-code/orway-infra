#!/usr/bin/env bash
# Aprovisiona una instancia nueva de Ayalas para un cliente.
# Uso:  ./scripts/new-ayalas-client.sh <cliente> <dominio>
# Ej.:  ./scripts/new-ayalas-client.sh ayalas ayalas.tudominio.com
#
# Hace: crea BD + usuario en el Postgres compartido, genera el .env del cliente
# (con secretos), y levanta el contenedor con Traefik. NO corre db:push/seed (eso
# se hace después, ver el final).
set -euo pipefail

CLIENT="${1:?falta <cliente>}"
DOMAIN="${2:?falta <dominio>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/apps/ayalas/clients/$CLIENT"

# Postgres: usa las credenciales de superusuario del .env de la infra.
set -a; source "$ROOT/.env"; set +a
DB="${CLIENT}_db"
DBUSER="$CLIENT"
DBPASS="$(openssl rand -hex 16)"

echo "▶ Creando BD '$DB' y usuario '$DBUSER'…"
docker compose -f "$ROOT/docker-compose.yml" exec -T postgres \
  psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE USER "$DBUSER" WITH PASSWORD '$DBPASS';
CREATE DATABASE "$DB" OWNER "$DBUSER";
SQL

echo "▶ Generando .env del cliente en $DIR…"
mkdir -p "$DIR"
cp "$ROOT/apps/ayalas/docker-compose.yml" "$DIR/docker-compose.yml"
cat > "$DIR/.env" <<ENV
CLIENT=$CLIENT
DOMAIN=$DOMAIN
DATABASE_URL=postgresql://$DBUSER:$DBPASS@postgres:5432/$DB?schema=public
SESSION_SECRET=$(openssl rand -base64 32)
ADMIN_EMAIL=admin@$CLIENT.mx
ADMIN_PASSWORD=$(openssl rand -hex 8)
ADMIN_NAME=Administrador
BOT_API_KEY=$(openssl rand -hex 16)
META_GRAPH_VERSION=v25.0
GYM_TIMEZONE=America/Mexico_City
ENV

echo "▶ Levantando contenedor ayalas-$CLIENT…"
docker compose -p "ayalas-$CLIENT" --project-directory "$DIR" up -d

echo "✓ Listo. Falta (una vez):"
echo "   docker compose -p ayalas-$CLIENT exec app npm run db:push"
echo "   docker compose -p ayalas-$CLIENT exec app npm run db:seed   # opcional, sin demo en prod"
echo "   y crear el workflow en n8n -> https://$DOMAIN/api/bot/*"
echo "   Credenciales/secretos quedaron en $DIR/.env (guárdalos)."
