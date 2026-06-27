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
