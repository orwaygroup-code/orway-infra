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
