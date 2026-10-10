-- ORest Cloud: qué puede cada rol en las tablas del registro (ola C-2, orest-cloud/docs/agente.md §6).
-- Se corre como orest_cloud_owner DESPUÉS de cada `prisma migrate deploy` de Cloud (una migración que
-- agregue una tabla necesita sus permisos aquí). Es idempotente.
--
--   docker compose exec -T postgres psql -U orest_cloud_owner -d orest_cloud -f - < scripts/orest-cloud-grants.sql
--
-- Ninguno tiene DELETE ni TRUNCATE: «nada se borra» deja de depender solo de los triggers. Y ninguno
-- es dueño, así que ninguno puede `ALTER TABLE … DISABLE TRIGGER`.
--
-- Los triggers corren con el rol de quien dispara: pedir un Job hace `SELECT … FOR UPDATE` sobre su
-- Instance (pide UPDATE), y mover un Job escribe el estado de la Instance (también UPDATE). Por eso los
-- dos tienen UPDATE sobre Instance; escribir `state` o `imageTag` a mano lo sigue rechazando la base
-- (INSTANCE_ONLY_BY_JOB).

\set ON_ERROR_STOP on

GRANT USAGE ON SCHEMA public TO orest_cloud_web, orest_cloud_agent;

-- La web: da de alta y pide. No mueve Jobs.
GRANT SELECT, INSERT, UPDATE ON "Instance" TO orest_cloud_web;
GRANT SELECT, INSERT ON "Job" TO orest_cloud_web;
GRANT USAGE ON SEQUENCE "Instance_id_seq", "Job_id_seq" TO orest_cloud_web;

-- El agente: lee y mueve. No da de alta ni pide.
GRANT SELECT, UPDATE ON "Instance" TO orest_cloud_agent;
GRANT SELECT, UPDATE ON "Job" TO orest_cloud_agent;

-- ─────────────────────────────────────────────────────────────────────────────────────────────────
-- Las tablas que llegaron después de la C-2. Este archivo ya advertía arriba que una migración con
-- tabla nueva necesita sus permisos aquí, y aun así se olvidó DOS veces: ni `Notice` (C-6) ni
-- `AgentLease` (C-2b) los tenían. Sin ellos el proceso que las usa no arranca, y el error no dice
-- «falta un GRANT».
-- (La columna `statusToken` de la C-5 no necesitó nada: es una columna de `Instance`, no una tabla.)
-- ─────────────────────────────────────────────────────────────────────────────────────────────────

-- `Notice` (ola C-6): el aviso de que un alta falló. Lo escribe el avisador, que es de la mitad WEB de
-- Cloud y usa su rol. SELECT para no avisar dos veces del mismo Job; INSERT para anotar el entregado.
-- Su trigger consulta `Job` para exigir que esté en FAILED, y los triggers corren con el rol de quien
-- dispara: `orest_cloud_web` ya tiene SELECT sobre `Job`, así que alcanza.
GRANT SELECT, INSERT ON "Notice" TO orest_cloud_web;
GRANT USAGE ON SEQUENCE "Notice_id_seq" TO orest_cloud_web;
-- Comprobado en la ola C-2c con el rol real, desde el servicio `notifier`: lee los Jobs FAILED (con su Instance) e
-- inserta su Notice con solo lo de aquí arriba. La web (página de estado) solo lee Instance y Job: también alcanza.

-- `AgentLease` (ola C-2b): el arrendamiento del agente único. SIN ESTO EL AGENTE NUEVO NO ARRANCA.
-- INSERT para tomarlo la primera vez, UPDATE para tomarlo cuando venció y para renovarlo, SELECT para
-- ver el plazo que vio. No necesita permiso de secuencia: el `id` es 1 por omisión, no es serial.
GRANT SELECT, INSERT, UPDATE ON "AgentLease" TO orest_cloud_agent;
