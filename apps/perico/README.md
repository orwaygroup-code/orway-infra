# El Perico — POS

Lonchería en Jesús María, Ags. Punto de venta con kiosco de autoservicio,
caja con cortes de turno e impresión de comandas.

**Instancia única (single-tenant).** No es como Ayalas, que corre una imagen
compartida con N instancias por cliente: aquí hay un solo negocio. Si algún día
hay un segundo cliente de POS, esa es la conversación de extraer un producto,
no de copiar esta carpeta.

Código: repo `perico-pos`. Plan del proyecto: `Wiki/perico-pos/`.

---

## Asignación en el VPS

| Recurso | Valor | Por qué así |
|---|---|---|
| Proyecto Compose | `perico-pos` | Prefija contenedores y volúmenes. Único en el VPS. |
| Router de Traefik | `perico-pos` | Con nombre completo, no `perico` a secas: un cliente de Ayalas llamado "perico" no colisiona. |
| Dominio | `${DOMAIN}` | Se define al aprovisionar. |
| Puerto de contenedor | 3002 | Convención de la casa (3000 Orway, 3001 Ayalas). No hay colisión real —son puertos internos, aislados— pero se respeta para que los docs sigan siendo ciertos. |
| Base de datos | `perico_db` | Propia. Cerrada a `PUBLIC`. |
| Roles | `perico_owner`, `perico_app` | Dos, como Orway System. |
| n8n | **no se conecta** | No hay bot en Fase 1. Menos superficie. |

## Los dos roles de Postgres

`perico_owner` es dueño de la base y corre las migraciones. `perico_app` es el
runtime: lee y escribe datos, y **no puede alterar estructura**.

La razón es concreta: una inyección SQL en la app no puede `DROP TABLE` sobre
los cortes de caja ni los pagos. Cuesta unas líneas en el aprovisionamiento y
cierra la clase de incidente más cara que puede tener un sistema de dinero.

Está probado. En el entorno local, `perico_app` recibe
`ERROR: permission denied for schema public` al intentar crear una tabla, y
`ERROR: must be owner of table` al intentar borrarla, mientras que sus INSERT
y SELECT funcionan con normalidad.

## Aislamiento: qué queda cubierto y qué no

**Cubierto por esta configuración**

- Base propia con `CONNECT` revocado a `PUBLIC`: ningún rol de otro proyecto
  del VPS puede siquiera abrir conexión contra `perico_db`.
- La app no puede alterar su propio esquema.
- Límites de CPU y memoria: este POS no puede ser ahogado por otro proyecto
  desbocado, ni ahogarlo él.
- Rotación de logs: un contenedor sin rotar puede llenar el disco del VPS y
  tumbar **todos** los proyectos.
- `no-new-privileges` y `/tmp` en tmpfs.
- Rate limit propio en `/api/print-jobs/*`, que es el único endpoint que se
  golpea desde fuera cada 3 segundos.

**NO cubierto — huecos del VPS compartido, no de este proyecto**

1. **Los contenedores se ven entre sí en la red `web`.** Traefik la necesita
   para enrutar, pero el efecto es que la app de un cliente alcanza por HTTP la
   app de otro, y todas alcanzan `postgres:5432`. Arreglarlo pide una red por
   app con Traefik unido a todas: es un cambio al compose compartido que afecta
   a Ayalas y a Orway System, y se decide para todos, no desde aquí.

2. **Las bases que ya existen siguen abiertas a `PUBLIC`.** Ver
   `scripts/harden-postgres-isolation.sql`. Está escrito y comentado; hay que
   correrlo con intención, no automáticamente.

3. **No hay backups automatizados.** `Despliegue.md` lo marca como pendiente.
   Para un CRM es deuda; para un POS que guarda cortes de caja es
   descalificante. **Esto bloquea la salida a producción**, no la construcción.

## Aprovisionar

```bash
./scripts/new-perico.sh perico.orwaygroup.com
```

Crea la base y los dos roles, cierra `CONNECT` a `PUBLIC`, genera el `.env` con
secretos aleatorios en `chmod 600`, y levanta el contenedor. **No** corre
migraciones ni seed: eso se hace explícito después, para que nadie siembre datos
en un negocio real por accidente.

El script **aborta** si `perico_db` o el `.env` ya existen. No es idempotente a
propósito: reinstalar encima de una instancia que está operando destruiría los
cortes de caja del negocio.

## Después de aprovisionar

```bash
docker compose -p perico-pos exec app npx prisma migrate deploy
docker compose -p perico-pos exec app npm run db:seed
```

El seed carga el **menú real** de El Perico —19 familias, unas 86 combinaciones,
tomadas de su carta impresa—. No son datos demo: es su catálogo.

Los PIN iniciales quedan en `.env`. **Se entregan en persona y se rotan en la
primera sesión.** No salen por chat.

## Relacionado

- `../../vps-infra.md` · `../../DESPLIEGUE.md`
- `Wiki/orway-infra/00 - Overview/Arquitectura.md`
- `../../scripts/harden-postgres-isolation.sql`
