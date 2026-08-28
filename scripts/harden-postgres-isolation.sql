-- ===========================================================================
--  Aislamiento entre bases del Postgres compartido
-- ===========================================================================
--
--  QUÉ ARREGLA
--  Por defecto Postgres otorga CONNECT a PUBLIC sobre toda base nueva. Es decir:
--  el usuario `ayalas` puede abrir conexión contra `orway_integral`, y viceversa.
--  No puede LEER tablas ajenas (eso lo corta el nivel de tabla), pero sí conectar,
--  enumerar el esquema por pg_catalog, y quedar en posición de aprovechar
--  cualquier permiso mal puesto en el futuro.
--
--  Esto es exactamente el pendiente que anota Wiki/orway-infra/00 - Overview/
--  Arquitectura.md: "Endurecer el acceso cruzado entre BDs (REVOKE CONNECT …
--  FROM PUBLIC) es una mejora a discutir aquí, no por-repo."
--
--  Se vuelve urgente con El Perico porque es el primer proyecto del VPS que
--  guarda dinero: cortes de caja, pagos y referencias de tarjeta.
--
--  ---------------------------------------------------------------------------
--  ⚠ ESTE SCRIPT NO SE CORRE SOLO. Léelo, ajústalo a las bases y roles que
--    existan de verdad, y córrelo con intención en una ventana tranquila.
--    Un REVOKE mal puesto deja una app sin base y el negocio parado.
--  ---------------------------------------------------------------------------
--
--  ANTES DE CORRERLO
--    1. Respaldo fresco de TODAS las bases.
--    2. Confirma los nombres reales:
--         \l                                    -- bases
--         \du                                   -- roles
--    3. Confirma qué rol usa cada app, leyendo su .env (DATABASE_URL).
--       Si le quitas CONNECT a la base equivocada, esa app deja de funcionar
--       en el siguiente request, no al reiniciar.
--
--  CÓMO CORRERLO
--    docker compose -f docker-compose.yml exec -T postgres \
--      psql -U $POSTGRES_USER -d postgres -v ON_ERROR_STOP=1 \
--      < scripts/harden-postgres-isolation.sql
--
--  CÓMO REVERTIRLO (si algo se rompe)
--    GRANT CONNECT ON DATABASE <base> TO PUBLIC;
--
-- ===========================================================================


-- --- 1. Diagnóstico: quién puede conectarse hoy a qué -----------------------
-- Corre esto PRIMERO y guarda la salida. Es tu punto de retorno.

SELECT datname AS base,
       pg_catalog.pg_get_userbyid(datdba) AS dueno,
       datacl AS permisos_actuales
FROM pg_database
WHERE datistemplate = false
ORDER BY datname;


-- --- 2. Cerrar el acceso público, base por base -----------------------------
-- Descomenta y AJUSTA los nombres. Cada bloque es independiente: puedes
-- aplicar uno, verificar que la app sigue viva, y seguir con el siguiente.
-- Hacerlo de a una es más lento y es la forma correcta.

-- ---- Ayalas (un rol por cliente) ----
-- REVOKE CONNECT ON DATABASE ayalas_db FROM PUBLIC;
-- GRANT  CONNECT ON DATABASE ayalas_db TO ayalas;

-- ---- Orway System (dos roles: owner + app con RLS) ----
-- REVOKE CONNECT ON DATABASE orway_integral FROM PUBLIC;
-- GRANT  CONNECT ON DATABASE orway_integral TO orway_integral, orway_app;

-- ---- El Perico (ya lo deja cerrado scripts/new-perico.sh) ----
-- REVOKE CONNECT ON DATABASE perico_db FROM PUBLIC;
-- GRANT  CONNECT ON DATABASE perico_db TO perico_owner, perico_app;


-- --- 3. Que las bases FUTURAS nazcan cerradas -------------------------------
-- Sin esto, la próxima base creada vuelve a abrir CONNECT a PUBLIC y el
-- problema regresa calladamente. `template1` es la plantilla de la que
-- Postgres copia cada CREATE DATABASE.
--
-- REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
--
-- Nota: no rompe `createdb`, porque el creador recibe CONNECT como dueño.


-- --- 4. Verificación posterior ---------------------------------------------
-- Repite la consulta del paso 1: la columna de permisos debe mostrar solo los
-- roles esperados por base, sin la entrada de PUBLIC (`=Tc/`).
--
-- Prueba real, con un rol de otro proyecto:
--   PGPASSWORD=... psql -U ayalas -d perico_db -c "SELECT 1;"
--   -- Esperado: FATAL: permission denied for database "perico_db"
--
-- Si eso falla como debe, el aislamiento entre bases está puesto.


-- ===========================================================================
--  LO QUE ESTE SCRIPT NO ARREGLA
-- ===========================================================================
--
--  1. Los contenedores siguen viéndose entre sí en la red `web`. La app de un
--     cliente alcanza por HTTP la app de otro, y todas alcanzan postgres:5432.
--     Arreglarlo requiere una red por app con Traefik unido a todas, y es un
--     cambio al compose compartido que afecta a Ayalas y a Orway System.
--     No se hace desde un proyecto: se decide para todos.
--
--  2. Los backups siguen sin automatizar. Despliegue.md lo marca como "no
--     negociable, pendiente". Para un CRM es una deuda; para un POS con cortes
--     de caja es descalificante. Nada de esto sustituye a un respaldo.
--
-- ===========================================================================
