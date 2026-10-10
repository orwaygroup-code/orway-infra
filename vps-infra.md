# Infraestructura Orway — VPS compartido (arquitectura canónica)

> **Para cualquier agente (Claude Code) o persona que toque deploy/infra:** este es el
> documento de referencia de CÓMO se despliegan los proyectos de Orway. Léelo antes de
> configurar deploy, n8n, dominios o base de datos. No improvises una infra distinta.
> Si esta arquitectura cambia, se actualiza AQUÍ (fuente única de verdad).

## Idea central
Un **VPS** aloja **varios proyectos** de Orway (hoy: Sistema integral de Orway + Ayalas;
después: más CRMs/sistemas y chatbots). Todo corre en **Docker**, detrás de **Traefik**
como reverse proxy con TLS automático. La orquestación de chatbots es **n8n compartido**.

```
VPS (Docker host)
├── traefik            ← reverse proxy; enruta por dominio + Let's Encrypt automático
├── postgres (1)       ← compartido; UNA base de datos por proyecto/cliente
├── n8n (1)            ← orquesta TODOS los chatbots (1 workflow por bot/cliente)
├── orway-integral     ← Sistema integral de Orway (su contenedor)
├── ayalas-<cliente>   ← Ayalas por cliente (misma imagen, distinto .env)
└── (futuros CRMs / chatbots)
```

## Por qué Docker + Traefik (no PM2)
- **Docker:** proyectos de stacks distintos + varias instancias conviven aisladas; agregar
  uno = sumar un contenedor sin tocar los demás. PM2 mezclaría todo en el mismo SO.
- **Traefik:** detecta contenedores por *labels* y emite el dominio + certificado SSL solo.
  Sin editar config ni correr certbot a mano cada vez que agregas un cliente/bot.

## Componentes compartidos (una sola vez)
- **Traefik:** :80/:443, red Docker `web`; resuelve TLS con Let's Encrypt.
- **Postgres:** un contenedor, volumen persistente, **una BD por proyecto/cliente**
  (aislamiento lógico). Usuario por BD. No se expone el puerto a internet.
- **n8n:** un contenedor, volumen persistente; un workflow por chatbot/cliente. Aquí viven
  como *Credentials* los tokens de Meta y OpenAI (NUNCA en el código de las apps).

## Apps (por proyecto / por cliente)
- Cada app es un contenedor que se une a la red `web` y declara sus labels de Traefik
  (dominio/subdominio + TLS).
- **Ayalas es multi-cliente con UNA imagen:** cada gimnasio = mismo código, distinto `.env`
  (`DATABASE_URL` a su BD, dominio, `BOT_API_KEY`). Instancia por cliente, no multi-tenant.
- `DATABASE_URL` apunta al host **`postgres`** (nombre del servicio en la red interna), no a
  `localhost`.

## Cómo agregar un cliente / proyecto
1. Crear su **BD** + usuario en el Postgres compartido.
2. Crear su **`.env`** (dominio, `DATABASE_URL`, `BOT_API_KEY`, `SESSION_SECRET`).
3. Levantar el **contenedor** (imagen Ayalas para clientes de Ayalas; imagen propia para
   otros proyectos) con sus labels de Traefik. Ver `scripts/new-ayalas-client.sh`.
4. `prisma db push` (+ `db:seed` sin datos demo en prod) contra su BD.
5. Crear el **workflow en n8n** apuntando a `https://<dominio>/api/bot/*`
   (contrato: `docs/n8n-bot-api.md` en el repo de Ayalas).

## Reglas duras
- **Backups automáticos** de todas las BDs (diarios, fuera del VPS). No negociable.
- **Secretos** (Meta, OpenAI, `BOT_API_KEY`, DB) en `.env`/Credentials de n8n, nunca en el
  repo ni en el código.
- **Aislamiento / blast radius:** el Sistema integral de Orway (negocio propio) compartiendo
  VPS con CRMs de clientes y un n8n público es un riesgo. Para 2 sistemas es manejable; al
  crecer, evaluar mover el integral de Orway a **su propio VPS**. Clientes con datos
  sensibles (personales/médicos) también podrían ir aparte.

## Estado
- **Arquitectura: decidida** (Docker + Traefik, Postgres y n8n compartidos, app por cliente).
- **Configs:** este repo trae el scaffold (`docker-compose.yml`, template de app, script).
  **Aún no probados en un VPS real**; se validan en el primer deploy.

---

## Límites de memoria y swap (7 oct 2026)

**El VPS tiene 2 vCPU y 7.8 GB.** El **swap de 4 GB ya está aplicado** (9 oct 2026, ver abajo); antes
estaba en 0, y sin swap un servicio que se pasa de memoria no desacelera: el kernel elige una víctima
y la mata, y puede ser el POS de un restaurante en servicio.

**Los LÍMITES DE MEMORIA DE LA TABLA DE ABAJO SIGUEN SIN APLICARSE.** Solo `perico-pos` tiene uno; los
demás pueden comerse la caja entera. Mientras eso no cambie, los números de «Techo de capacidad»
describen una configuración que no existe todavía.

### Medición que sostiene los números (`docker stats`, 7 oct 2026)

| Contenedor | Medido | Límite |
|---|---|---|
| orway-app | 536 MB | 1 GB |
| n8n | 347 MB | 768 MB |
| perico-pos | 249 MB | 768 MB *(ya lo tenía)* |
| ayalas-app | 147 MB | 512 MB |
| postgres | 102 MB | **1.5 GB** |
| traefik | 32 MB | 256 MB |
| coturn | 11 MB | — *(no está en este repo, ver abajo)* |

Los límites son ~2× lo medido. **Postgres va holgado a propósito**: crece ~7 MB por conexión
y es la dependencia compartida de todas las apps — si a Postgres lo mata el OOM, se caen todas.

### Swap: 4 GB — APLICADO el 9 de octubre de 2026

No es para rendimiento. Es para que un pico **degrade en vez de matar**.

Comprobado en el VPS: `swapon --show` da `/swapfile file 4G`, `free -h` da 4.0Gi, la línea está en
`/etc/fstab` (así que sobrevive un reinicio) y `vm.swappiness = 10`. Los comandos que lo hicieron quedan
abajo como registro; **no se vuelven a correr**: `fallocate` sobre un swap activo falla con
«Text file busy», y eso es lo que tiene que pasar.

```bash
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
```

```bash
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

```bash
sysctl -w vm.swappiness=10 && echo 'vm.swappiness=10' >> /etc/sysctl.d/99-swap.conf
```

`swappiness=10`: que use swap solo bajo presión real, no por costumbre.

### APLICAR LOS LÍMITES NO ES SIN CORTE

Poner un límite **recrea el contenedor**. Reiniciar `postgres` tira la conexión de **todas** las
apps a la vez. Se hace **fuera de horario de servicio** (de madrugada, o lunes).

Orden: primero el swap (no requiere reiniciar nada) — **ya hecho, 9 oct** —, después los contenedores:
las apps antes que Postgres, y Postgres al final. **Esa segunda mitad es la que queda pendiente.**

### MEDIDO el 10 de octubre de 2026, con cinco instancias de ORest arriba

Durante el ensayo del agente hubo 5 instancias de ORest corriendo a la vez (4 desechables + `demo`),
más todo lo demás. `docker stats`:

| Contenedor | Medido | Límite |
|---|---|---|
| n8n | **462 MB** | 768 MB |
| orway-app | 277 MB | 1 GB |
| perico-pos | 245 MB | 768 MB |
| postgres | 225 MB | 1.5 GB |
| orest `demo` (meses de uso) | **167 MB** | 384 MB *(antes 768)* |
| ayalas-app | 145 MB | 512 MB |
| traefik | 120 MB | — |
| orest recién creada, en reposo | **83–92 MB** | 384 MB |
| orest-cloud-agent | 64 MB | — |
| coturn | 26 MB | — |

**`free -h`: 2.3 Gi usados de 7.8, 5.4 Gi disponibles, swap 0 B usados.** Con trece contenedores.

Dos cosas que esto corrigió:

1. **La cifra de ~250–335 MB por instancia de ORest estaba 3–4x de más.** Salía de medir
   **perico-pos**, no ORest. Por eso el límite por instancia bajó de **768M a 384M** (10 oct), lo que
   **duplica el techo por suma de límites: de 3 restaurantes a 7.**
2. **n8n es el mayor consumidor del VPS y no tiene límite.** El día que falte memoria, el kernel elige
   entre los que no tienen techo, y ése es el más grande de la lista.

**Lo medido es EN REPOSO.** Un restaurante en servicio consume más —`demo` ya está en 167 MB solo por
haber vivido— y Node no devuelve memoria con ganas. Antes de fijar el número del techo falta **medir una
instancia bajo carga real**.

### Techo de capacidad para ORest

Cada instancia de ORest cuesta ~300 MB (Perico, su equivalente, mide 249 en reposo) más ~35 MB
de Postgres por sus 5 conexiones: **~335 MB por restaurante**.

| Escenario | Clientes de ORest |
|---|---|
| Construyendo la imagen **en el VPS** (como hoy) | **6** |
| Construyendo fuera y subiendo la imagen | **12** |
| Más allá | topan las conexiones de Postgres: 16 |

`next build` pide 2–4 GB, y por eso **las imágenes se construyen en local y se suben**
(`docker save … | ssh … docker load`), nunca en el VPS. Con el swap puesto un pico ya degrada en vez de
matar, pero construir ahí sigue estando prohibido: degradar a seis restaurantes a media comida no es un
resultado aceptable, solo uno menos malo.

La cuenta completa de capacidad vive ahora en `orest-cloud/docs/capacidad.md`, con los tres criterios
(límites: 3 · medido: 12 · conexiones: 16). La tabla de abajo conserva un escenario de «6» que **ya no
aplica**: suponía construir la imagen en el VPS, y desde la ola C-2 el agente aprovisiona desde una
imagen precargada.

### Deriva conocida

**`coturn` corre en el VPS y NO está en este repo.** Lleva semanas arriba y es lo único que
consume CPU (3.6%). Si el VPS se reconstruyera desde aquí, no volvería, y nadie puede saber para
qué es. Hay que meterlo a este repo o quitarlo del VPS.

---

## ORest Cloud: el agente (ola C-2, 8 oct 2026; detalle en `orest-cloud/docs/agente.md`)

Cambia tres cosas de esta infra. **Ninguna está probada en el VPS todavía**: el ensayo con un cliente
desechable está en `orest-cloud/docs/agente.md` §9.

1. **Un contenedor privilegiado, `orest-cloud-agent`** (`apps/orest-cloud/docker-compose.yml`). Monta
   `/var/run/docker.sock`, lo que equivale a root del host, para crear, detener y actualizar instancias
   de ORest. Corre sin `ports:`, sin labels de Traefik (`exposedbydefault=false`) y sin HTTP. Está en
   `web` solo para llegar a Postgres. Monta `orway-infra` en la MISMA ruta que en el host. Es uno solo:
   lo hace cumplir un candado de Postgres.
2. **Roles de Postgres para Cloud** (`scripts/orest-cloud-roles.sql`, una vez; `scripts/orest-cloud-grants.sql`,
   después de cada migración de Cloud): dueño, web, agente y `orest_provisioner`, este último con
   `CREATEDB CREATEROLE` y **sin superusuario**. Ninguno con `DELETE` ni `TRUNCATE` en el registro.
3. **Una etiqueta de imagen por cliente de ORest.** `apps/orest/docker-compose.yml` usa
   `orest:${IMAGE_TAG:-latest}`, y `IMAGE_TAG` va en el `.env` de cada cliente. Sin `IMAGE_TAG` cae a
   `latest`: el alta manual de `scripts/new-orest-client.sh` sigue igual.

`apps/orest/clients/` (`.env` con secretos y sus copias apartadas) queda fuera de git (`.gitignore`).

## ORest Cloud: la mitad web (ola C-2c, 10 oct 2026; detalle en `orest-cloud/docs/despliegue.md`)

`apps/orest-cloud/docker-compose.yml` pasa de un servicio a tres. **Probado en local con el compose real** (Postgres 16
desechable, roles y grants de `scripts/`, red `web`); **no en el VPS todavía**.

1. **`web`** — imagen `orest-cloud-web:<WEB_TAG>`, la página de estado en **`https://cloud.orest.com.mx`** (router
   `orest-cloud`, puerto **3004**: 3000–3003 y 5678 ya estaban tomados). Rol `orest_cloud_web`. **Sin el socket de
   Docker** y sin el cliente en la imagen: la mitad expuesta no provisiona. Healthcheck en `/api/health`, que no toca la
   base. El DNS no se toca: el comodín `A *` ya cubre `cloud`. (El apex `orest.com.mx` **no** tiene registro A; es de
   C-7, no de aquí.)
2. **`notifier`** — el avisador de altas fallidas: la **misma imagen** que `web`, con `command` propio. Hace un POST a
   n8n por la red interna, y por eso **no** vive en el agente, que no habla HTTP con nadie. Rol `orest_cloud_web`: los
   grants de hoy le alcanzan (comprobado con el rol real).
3. **El proyecto se llama `orest-cloud`** (`name:` en el archivo). Antes era `-p orest-cloud-agent`: la primera vez,
   `docker compose -p orest-cloud-agent -f apps/orest-cloud/docker-compose.yml down` **antes** del `up -d`, o quedan dos
   agentes (el arrendamiento impide que trabajen los dos, pero el segundo se queda reiniciando).
4. **El agente tiene límite de memoria (256M)** y `pull_policy: never`. Era el único contenedor de Cloud sin límite, y
   un término sin límite vuelve falsa la cuenta del techo.

**Memoria:** límites `agent` 256M, `web` 256M, `notifier` 128M (medidos: 64, 58 y 18 MiB). Con ellos el techo de ORest
por suma de límites **baja de 7 a 5** — propuesta, no decisión: la cuenta está en `orest-cloud/docs/capacidad.md`, y el
número lo pone Paul en `ORESTCLOUD_MAX_INSTANCES`. La cuenta trae además la reserva del host (kernel, Docker y `coturn`,
~270 MiB medidos) y corrige una mezcla de unidades de la versión anterior.
