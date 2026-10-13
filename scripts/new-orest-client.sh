#!/usr/bin/env bash
# Aprovisiona una instancia nueva de ORest para un restaurante.
# Uso:  ./scripts/new-orest-client.sh <cliente> <dominio> <etiqueta-de-imagen>
# Ej.:  ./scripts/new-orest-client.sh sanluca sanluca.orest.com.mx 952bf8e
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
#   3. LA ETIQUETA DE IMAGEN ES OBLIGATORIA, y falla cerrado si no se da. Antes
#      este script no escribia IMAGE_TAG, asi que el compose caia a `latest` y
#      cada cliente quedaba atado a lo ultimo que alguien hubiera subido con ese
#      nombre -que no corresponde a ningun commit-. La regla la dejo el ensayo
#      del 10 oct: una etiqueta de imagen tiene que corresponder a un commit.
#      Si se omite, el script lista las imagenes que SI hay en este host.
set -euo pipefail

CLIENT="${1:?falta <cliente>}"
DOMAIN="${2:?falta <dominio>}"
if [ -z "${3:-}" ]; then
  echo "✗ Falta <etiqueta-de-imagen>. No se cae a 'latest': una etiqueta tiene que" >&2
  echo "  corresponder a un commit. Imagenes de ORest en este host:" >&2
  docker image ls --format '    orest:{{.Tag}}  ({{.Size}}, {{.CreatedSince}})' orest >&2 || true
  exit 1
fi
IMAGE_TAG="$3"
if ! docker image inspect "orest:$IMAGE_TAG" >/dev/null 2>&1; then
  echo "✗ No existe la imagen orest:$IMAGE_TAG en este host. Subela antes:" >&2
  echo "    docker save orest:$IMAGE_TAG | ssh orway docker load" >&2
  exit 1
fi
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
IMAGE_TAG=$IMAGE_TAG
ENV
chmod 600 "$DIR/.env"

echo "▶ Levantando contenedor orest-$CLIENT con orest:$IMAGE_TAG…"
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
