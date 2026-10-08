-- ORest Cloud: los roles de Postgres (ola C-2, orest-cloud/docs/agente.md §6). Se corre UNA vez, como
-- superusuario del Postgres compartido, ANTES del primer `prisma migrate deploy` de Cloud:
--
--   OREST_CLOUD_OWNER_PASSWORD=… OREST_CLOUD_WEB_PASSWORD=… OREST_CLOUD_AGENT_PASSWORD=… \
--   OREST_PROVISIONER_PASSWORD=… \
--   docker compose exec -T -e OREST_CLOUD_OWNER_PASSWORD -e OREST_CLOUD_WEB_PASSWORD \
--     -e OREST_CLOUD_AGENT_PASSWORD -e OREST_PROVISIONER_PASSWORD \
--     postgres psql -U "$POSTGRES_USER" -d postgres -f - < scripts/orest-cloud-roles.sql
--
-- Las contraseñas entran por variables de entorno (\getenv), no por argumentos: los argumentos se ven
-- en la lista de procesos.
--
-- Por qué cuatro roles:
--   orest_cloud_owner  dueño de las tablas del registro. SOLO migra. Es el único que podría
--                      desactivar un trigger, y ninguna app se conecta con él.
--   orest_cloud_web    la web (expuesta): da de alta instancias y PIDE Jobs. Sin DELETE ni TRUNCATE.
--   orest_cloud_agent  el agente, en el registro: reclama y mueve Jobs. Sin DELETE ni TRUNCATE.
--   orest_provisioner  el agente, en el clúster: CREATEDB y CREATEROLE, SIN superusuario. Crea la base y
--                      el rol de cada restaurante y solo puede tocar lo que él creó (probado contra
--                      Postgres 16.14). No puede desactivar los triggers del registro: no es su dueño.

\set ON_ERROR_STOP on
\getenv owner_pass OREST_CLOUD_OWNER_PASSWORD
\getenv web_pass OREST_CLOUD_WEB_PASSWORD
\getenv agent_pass OREST_CLOUD_AGENT_PASSWORD
\getenv prov_pass OREST_PROVISIONER_PASSWORD
\if :{?owner_pass}
\else
  \echo 'falta OREST_CLOUD_OWNER_PASSWORD'
  \quit
\endif
\if :{?web_pass}
\else
  \echo 'falta OREST_CLOUD_WEB_PASSWORD'
  \quit
\endif
\if :{?agent_pass}
\else
  \echo 'falta OREST_CLOUD_AGENT_PASSWORD'
  \quit
\endif
\if :{?prov_pass}
\else
  \echo 'falta OREST_PROVISIONER_PASSWORD'
  \quit
\endif

CREATE ROLE orest_cloud_owner LOGIN PASSWORD :'owner_pass';
CREATE ROLE orest_cloud_web   LOGIN PASSWORD :'web_pass';
CREATE ROLE orest_cloud_agent LOGIN PASSWORD :'agent_pass';
CREATE ROLE orest_provisioner LOGIN CREATEDB CREATEROLE PASSWORD :'prov_pass';

CREATE DATABASE orest_cloud OWNER orest_cloud_owner;
REVOKE CONNECT ON DATABASE orest_cloud FROM PUBLIC;
GRANT CONNECT ON DATABASE orest_cloud TO orest_cloud_web, orest_cloud_agent;
