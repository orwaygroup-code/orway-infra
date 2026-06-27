# Despliegue paso a paso — VPS compartido de Orway

> Runbook operativo. Lo sigue una persona que maneja el VPS. Acompaña a
> `vps-infra.md` (el "qué/por qué"); esto es el "cómo, en orden".
> **Estado: primer despliegue (infra aún no probada en un VPS real).**

Datos de este despliegue:
- **VPS (Hostinger, Ubuntu, Docker 29 preinstalado):** IP **real** del servidor =
  **`2.24.217.100`** (eth0). ⚠️ `2.57.91.91` es un **edge/CDN de Hostinger**, NO el
  VPS — el DNS debe apuntar a `2.24.217.100`.
- **Dominio:** `orwaygroup.com`. El apex (+ www) sirve **Orway System**. DNS apex/www
  y `n8n` → `2.24.217.100`.
- **ACME (Let's Encrypt):** `ORWAYGROUP@gmail.com`.

> ### ⚠️ Lecciones del primer deploy real (2026-06-27) — Hostinger
> 1. **No uses `2.57.91.91` (CDN) en el DNS.** Pasa por el CDN de Hostinger
>    (`Server: hcdn`) y rompe el challenge ACME (`tls: no application protocol`).
>    La IP real del VPS sale con `ip -4 addr show scope global` (eth0). Apunta el
>    DNS ahí.
> 2. **Traefik debe ser `traefik:v3`** (no `v3.1`): Docker Engine 29 exige API
>    >= 1.40 y v3.1 se queda en 1.24 (ignora `DOCKER_API_VERSION`). Ya está en el
>    `docker-compose.yml`.
> 3. **Challenge ACME = HTTP-01** (no TLS-ALPN). Ya está en el compose.
> 4. **Cuidado con el rate-limit de Let's Encrypt:** 5 autorizaciones fallidas por
>    hora por dominio. Si quemas el límite probando, espera ~1 h. (El `429` por
>    rate-limit NO suma fallos; los fallos son del challenge.)
> 5. Desplegamos los repos en **`/opt/orway-system`** y **`/opt/orway-infra`**
>    (no en `~`). Ajusta las rutas de abajo si usas `/opt`.
> 6. `orway-system` es **privado** → en el VPS se clona con una **deploy key SSH**
>    de solo lectura (`ssh-keygen` + agregarla en GitHub → Settings → Deploy keys).

---

## Parte A — Lo que ya hicimos (en los repos, antes del VPS)

1. **Repo `orway-system`** quedó listo para Docker:
   - `Dockerfile` (Next 16, node:22-slim; conserva node_modules para correr
     migraciones/seed dentro del contenedor).
   - `.dockerignore`, `docs/INFRA.md` (puntero a esta infra).
   - `.env.example` en forma de despliegue (host `postgres`, dos roles RLS).
   - Se retiró el `DEPLOY.md` viejo de PM2. `npm run build` y `docker build` validados.
   - `scripts/deploy.sh` — actualizar/desplegar (idempotente, master-only).
2. **Repo `orway-infra`** (este): se agregó `apps/orway/` (compose + `.env.example`)
   y este runbook.

> Orway usa **dos roles** de Postgres (RLS): `DATABASE_URL` (owner, migraciones) y
> `DATABASE_URL_APP` (`orway_app`, runtime de mínimo privilegio). Por eso su
> provisión es distinta a la de Ayalas (que usa un solo usuario).

---

## Parte B — DNS (antes de levantar nada)

Traefik emite el TLS por challenge: el dominio debe resolver al VPS **antes** de
arrancar el contenedor. Registros necesarios (todos → `2.57.91.91`):

| Tipo | Nombre | Contenido | Notas |
|------|--------|-----------|-------|
| A | `@` | `2.24.217.100` | IP **real** del VPS (NO el CDN `2.57.91.91`) |
| CNAME | `www` | `orwaygroup.com` | sigue al apex |
| A | `n8n` | `2.24.217.100` | para n8n |

> Si no agregas `n8n` ahora, todo lo demás funciona; solo n8n quedará reintentando
> su certificado hasta que el DNS exista.

---

## Parte C — Bootstrap del VPS (una sola vez)

Entra por SSH como root (o con sudo) y prepara el servidor.

```bash
ssh root@2.57.91.91

# 1. Actualizar el sistema
apt update && apt -y upgrade

# 2. Firewall: solo SSH + HTTP/HTTPS (Traefik usa 80/443)
apt install -y ufw
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw --force enable

# 3. Docker + Compose (script oficial)
curl -fsSL https://get.docker.com | sh
docker --version && docker compose version

# 4. Usuarios de despliegue (uno por persona; en el grupo docker, sin root).
#    Repite para tu compañero. Sube SU llave pública a su authorized_keys.
adduser paul
usermod -aG docker paul
#   (para tu compañero: adduser companero ; usermod -aG docker companero)
```

A partir de aquí, trabaja como tu usuario (`su - paul`), no como root.

---

## Parte D — Infra compartida: Traefik + Postgres + n8n (una sola vez)

```bash
# Como tu usuario:
cd ~
git clone https://github.com/orwaygroup-code/orway-infra.git
cd orway-infra

# Crea el .env de la infra (NO se commitea)
cp .env.example .env
nano .env
```

Rellena `~/orway-infra/.env`:
```dotenv
ACME_EMAIL=ORWAYGROUP@gmail.com
POSTGRES_USER=orway
POSTGRES_PASSWORD=<genera uno fuerte: openssl rand -hex 24>
N8N_HOST=n8n.orwaygroup.com
```

Levanta la infra:
```bash
docker compose up -d
docker compose ps          # traefik, postgres, n8n en estado "running"
docker compose logs -f traefik   # mira que emita los certificados (Ctrl+C para salir)
```

n8n queda en `https://n8n.orwaygroup.com`. **Postgres NO se expone** a internet
(sin `ports:`); las apps lo alcanzan por la red interna con host `postgres`.

---

## Parte E — Base de datos de Orway (dos roles + BD)

Orway necesita **owner** (`orway_integral`) + **app** (`orway_app`) en el Postgres
compartido. Genera dos contraseñas y guárdalas (van también en el `.env` de Orway):

```bash
OWNER_PASS=$(openssl rand -hex 16); echo "OWNER_PASS=$OWNER_PASS"
APP_PASS=$(openssl rand -hex 16);   echo "APP_PASS=$APP_PASS"

# Crea roles + BD (como superusuario, dentro del contenedor de Postgres).
# Sustituye 'orway' si tu POSTGRES_USER es otro.
docker compose -f ~/orway-infra/docker-compose.yml exec -T postgres \
  psql -U orway -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE orway_integral LOGIN PASSWORD '$OWNER_PASS' CREATEROLE;
CREATE ROLE orway_app      LOGIN PASSWORD '$APP_PASS';
CREATE DATABASE orway_integral_db OWNER orway_integral;
SQL
```

> El owner lleva `CREATEROLE` para poder ser dueño de las tablas y aplicar `rls.sql`.
> Pre-creamos `orway_app` con contraseña fuerte; `rls.sql` lo detecta (`if not
> exists`) y solo le pone los grants y las políticas.

---

## Parte F — Construir y levantar Orway

```bash
cd ~
git clone https://github.com/orwaygroup-code/orway-system.git
cd orway-system

# .env de la instancia de Orway (vive junto al compose de la app, en la infra)
cp ~/orway-infra/apps/orway/.env.example ~/orway-infra/apps/orway/.env
nano ~/orway-infra/apps/orway/.env
```

Rellena `~/orway-infra/apps/orway/.env` con los valores reales:
```dotenv
DOMAIN=orwaygroup.com
DATABASE_URL=postgresql://orway_integral:<OWNER_PASS>@postgres:5432/orway_integral_db
DATABASE_URL_APP=postgresql://orway_app:<APP_PASS>@postgres:5432/orway_integral_db
SESSION_SECRET=<openssl rand -base64 48>
STORAGE_DIR=/data/storage
BOT_API_KEY=<openssl rand -hex 16>
NODE_ENV=production
```

Construye la imagen y levanta el contenedor:
```bash
cd ~/orway-system
docker build -t orway-system:latest .
docker compose -p orway --project-directory ~/orway-infra/apps/orway up -d
docker compose -p orway --project-directory ~/orway-infra/apps/orway logs -f app
```

Traefik detecta el contenedor por sus labels y emite el certificado de
`orwaygroup.com` + `www`. La primera vez puede tardar ~1 min.

---

## Parte G — Provisión de datos (una sola vez)

Migraciones, RLS y usuarios iniciales, **dentro** del contenedor de Orway:

```bash
APP=~/orway-infra/apps/orway
docker compose -p orway --project-directory $APP exec app sh -c '
  npx prisma migrate deploy &&
  npx prisma db execute --file prisma/sql/rls.sql &&
  npx prisma db execute --file prisma/sql/notifications.sql &&
  npm run db:seed
'
```

Login admin del seed: **admin@orway.com / OrwayTemp2026** → cámbiala al primer
ingreso (el sistema lo exige).

---

## Parte H — Verificar

1. `https://orwaygroup.com` → el sitio público de Orway (reemplaza la landing vieja).
2. `https://orwaygroup.com/login` → entra con el admin del seed.
3. Candado de HTTPS válido (Let's Encrypt). Si falla el cert: revisa
   `docker compose -f ~/orway-infra/docker-compose.yml logs traefik` y que el DNS
   resuelva al VPS.

---

## Parte I — Actualizaciones (el día a día)

Cuando haya cambios en `master` (ver el plan de colaboración):

```bash
cd ~/orway-system && ./scripts/deploy.sh
```

Hace: `git pull` (master) → `docker build` → `up -d` → migraciones + RLS
(idempotente). **No** corre el seed (es de una sola vez).

---

## Notas y trampas

- **Reemplazo del apex:** al levantar Orway con `Host(orwaygroup.com)`, Traefik sirve
  Orway en el dominio principal; la landing anterior deja de verse ahí.
- **Backups (no negociable):** `pg_dump` de cada BD + el volumen `orway_storage`
  (Orway Cloud), diarios y **fuera del VPS**. Pendiente de automatizar con cron.
- **Secretos:** solo en los `.env` del VPS (`chmod 600`) y en Credentials de n8n.
  Nunca en el repo.
- **Aislamiento:** una BD por proyecto. Endurecer el acceso cruzado entre BDs
  (`REVOKE CONNECT ... FROM PUBLIC`) es una posible mejora a discutir en esta infra,
  no por-repo.
