# orway-infra

Infraestructura compartida del VPS de Orway. **Fuente única de verdad** de cómo se
despliegan todos los proyectos (Sistema integral de Orway, Ayalas, y futuros CRMs/chatbots).

> Cualquier agente (Claude Code) o persona que vaya a tocar deploy/infra/n8n/dominios/BD:
> lee **[vps-infra.md](vps-infra.md)** antes. No improvises una infra distinta.

## Qué hay aquí
```
orway-infra/
├── vps-infra.md            ← arquitectura canónica (LÉEME)
├── docker-compose.yml      ← infra compartida: Traefik + Postgres + n8n
├── .env.example            ← secretos de la infra (copiar a .env)
├── apps/
│   └── ayalas/
│       ├── docker-compose.yml   ← template de UNA instancia de Ayalas (por cliente)
│       └── .env.example         ← env por cliente
└── scripts/
    └── new-ayalas-client.sh     ← aprovisiona un cliente nuevo (BD + .env + up)
```

## Modelo (resumen)
- **Docker + Traefik**: cada proyecto/cliente es un contenedor; Traefik enruta por dominio
  y emite TLS automático (Let's Encrypt). NO PM2.
- **Postgres compartido**: un servidor, **una BD por proyecto/cliente**.
- **n8n compartido**: un workflow por chatbot. Los tokens de Meta/OpenAI van como
  *Credentials de n8n*, nunca en el código.
- **Ayalas multi-cliente**: una sola imagen, distinto `.env` por cliente.

## Prerrequisitos
- VPS con Docker + Docker Compose v2.
- DNS de tus dominios/subdominios apuntando al IP del VPS
  (ej. `n8n.tudominio.com`, `ayalas.tudominio.com`, `orway.tudominio.com`).
- Imagen de cada app construida. **Ayalas necesita un `Dockerfile`** en su repo
  (Next.js standalone). Pendiente de agregar — pídelo y se hace.

## Deploy de la infra compartida (una sola vez)
```bash
cp .env.example .env      # y rellena ACME_EMAIL, POSTGRES_PASSWORD, N8N_HOST
docker compose up -d      # levanta traefik + postgres + n8n
```
n8n queda en `https://$N8N_HOST`. Postgres NO se expone a internet (solo red interna `web`).

## Agregar un cliente de Ayalas
```bash
# crea BD + usuario, genera apps/ayalas/<cliente>/.env y levanta el contenedor
./scripts/new-ayalas-client.sh <cliente> <dominio>
# ej: ./scripts/new-ayalas-client.sh ayalas ayalas.tudominio.com
```
Después, dentro del contenedor: `npm run db:push` + (opcional) `npm run db:seed`, y crear el
workflow en n8n apuntando a `https://<dominio>/api/bot/*` (contrato: ver el repo de Ayalas,
`docs/n8n-bot-api.md`).

## Si NO self-hospedas n8n o Postgres
- **n8n cloud**: borra el servicio `n8n` del `docker-compose.yml`; en los workflows usa la
  URL pública de tu n8n cloud.
- **BD administrada** (RDS, Neon, etc.): borra el servicio `postgres` y apunta `DATABASE_URL`
  de cada app a esa BD.

## Reglas duras
- **Backups** diarios de todas las BDs, fuera del VPS (ver nota en `vps-infra.md`).
- Secretos solo en `.env` / Credentials de n8n. Nunca en el repo.
- Token de Meta = **System User permanente**; Graph API v25.0.

> ⚠️ Los `docker-compose.yml` y scripts aquí son la **estructura propuesta**, aún **no
> probados en un VPS real**. Se validan en el primer deploy.
