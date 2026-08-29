#!/usr/bin/env bash
# Aprovisiona la instancia de El Perico (POS) en el VPS compartido.
#
# Uso:  ./scripts/new-perico.sh <dominio>
# Ej.:  ./scripts/new-perico.sh perico.orwaygroup.com
#
# Diferencias contra new-ayalas-client.sh, a propósito:
#   1. Instancia ÚNICA, no una por cliente. Si ya existe, aborta en vez de
#      pisar la base de un negocio que está operando.
#   2. DOS roles de Postgres (owner + app), no uno. La app no puede alterar
#      estructura: es un sistema de dinero.
#   3. Cierra CONNECT a PUBLIC sobre perico_db. Ningún otro proyecto del VPS
#      puede siquiera abrir conexión contra esta base.
#   4. NO corre migraciones ni seed. Eso se hace explícito al final, para que
#      nadie siembre datos demo en un negocio real por accidente.
set -euo pipefail

DOMAIN="${1:?falta <dominio>  (ej: perico.orwaygroup.com)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/apps/perico"

DB="perico_db"
OWNER="perico_owner"
APPUSER="perico_app"

# Credenciales de superusuario del Postgres compartido.
set -a; source "$ROOT/.env"; set +a

compose_pg() {
  docker compose -f "$ROOT/docker-compose.yml" exec -T postgres "$@"
}

# --- Guarda: no repisar una instancia viva ---------------------------------
if compose_pg psql -U "$POSTGRES_USER" -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1; then
  echo "✗ La base '$DB' ya existe."
  echo "  Este script crea la instancia desde cero y NO es idempotente."
  echo "  Si quieres reinstalar, respalda y elimina la base a mano, con intención."
  exit 1
fi

if [ -f "$DIR/.env" ]; then
  echo "✗ Ya existe $DIR/.env — no lo sobrescribo."
  echo "  Contiene los secretos de una instancia que puede estar operando."
  exit 1
fi

OWNER_PASS="$(openssl rand -hex 24)"
APP_PASS="$(openssl rand -hex 24)"

# PIN de 4 digitos que el seed NO vaya a rechazar.
#
# El seed rechaza en produccion los PIN debiles: digitos repetidos, secuencias
# ascendentes o descendentes, y los sospechosos de siempre. `shuf` a secas puede
# sacar 1111 o 1234, y entonces el aprovisionamiento truena en el paso del seed
# —ya con la base creada y este script marcado como no idempotente—. Es raro
# (una de cada ~300) y por eso es peor: falla el dia que menos se espera, en
# casa del cliente.
pin_fuerte() {
  local pin
  while :; do
    pin="$(shuf -i 1000-9999 -n 1)"
    case "$pin" in
      0000|1111|2222|3333|4444|5555|6666|7777|8888|9999) continue ;;
      1234|2345|3456|4567|5678|6789|0123) continue ;;
      9876|8765|7654|6543|5432|4321|3210) continue ;;
      1212|2580|1004) continue ;;
    esac
    echo "$pin"
    return
  done
}

OWNER_PIN="$(pin_fuerte)"
ORWAY_PIN="$(pin_fuerte)"

echo "▶ Creando base '$DB' con roles '$OWNER' (dueño) y '$APPUSER' (runtime)…"
compose_pg psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE "$OWNER"   LOGIN PASSWORD '$OWNER_PASS';
CREATE ROLE "$APPUSER" LOGIN PASSWORD '$APP_PASS';
CREATE DATABASE "$DB" OWNER "$OWNER";

-- Aislamiento: por defecto Postgres deja que CUALQUIER rol se conecte a
-- CUALQUIER base. Aquí se cierra: solo estos dos roles entran.
REVOKE CONNECT ON DATABASE "$DB" FROM PUBLIC;
GRANT  CONNECT ON DATABASE "$DB" TO "$OWNER", "$APPUSER";
SQL

echo "▶ Aplicando privilegios de mínimo acceso dentro de '$DB'…"
compose_pg psql -U "$POSTGRES_USER" -d "$DB" -v ON_ERROR_STOP=1 <<SQL
ALTER SCHEMA public OWNER TO "$OWNER";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO "$APPUSER";

-- La app lee y escribe datos, pero no altera estructura.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO "$APPUSER";
GRANT USAGE, SELECT                 ON ALL SEQUENCES IN SCHEMA public TO "$APPUSER";

-- Y lo mismo para las tablas que creen las migraciones futuras, sin tener que
-- volver a correr GRANT cada vez.
ALTER DEFAULT PRIVILEGES FOR ROLE "$OWNER" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$APPUSER";
ALTER DEFAULT PRIVILEGES FOR ROLE "$OWNER" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO "$APPUSER";
SQL

echo "▶ Generando $DIR/.env…"
cat > "$DIR/.env" <<ENV
DOMAIN=$DOMAIN
DATABASE_URL=postgresql://$OWNER:$OWNER_PASS@postgres:5432/$DB?schema=public
DATABASE_URL_APP=postgresql://$APPUSER:$APP_PASS@postgres:5432/$DB?schema=public
SESSION_SECRET=$(openssl rand -base64 32)
PRINT_BRIDGE_KEY=$(openssl rand -hex 32)
TZ=America/Mexico_City
BUSINESS_NAME=El Perico
SEED_OWNER_NAME=Dueno
SEED_OWNER_PIN=$OWNER_PIN
SEED_ORWAY_NAME=Orway
SEED_ORWAY_PIN=$ORWAY_PIN
ENV
chmod 600 "$DIR/.env"

echo "▶ Levantando contenedor perico-pos…"
docker compose -p perico-pos --project-directory "$DIR" up -d

cat <<FIN

✓ Instancia creada. Falta, en este orden:

  1. Migraciones (con el rol dueño):
       docker compose -p perico-pos exec app npx prisma migrate deploy

  2. Catálogo real de El Perico (NO son datos demo, es su menú):
       docker compose -p perico-pos exec app npm run db:seed

  3. Entregar los PIN iniciales EN PERSONA y rotarlos en la primera sesión.
     Quedaron en $DIR/.env — que no salgan por chat.

  4. PrintBridge: copiar PRINT_BRIDGE_KEY al config.json de la PC de la caja.

  5. Verificar https://$DOMAIN con candado válido.

⚠ Backups: esta base guarda cortes de caja y pagos. Ver
  scripts/backup-all-dbs.sh — no dejes esto operando sin respaldo automático.

FIN
