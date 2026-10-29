# ORest Landing — el ápice `orest.com.mx`

La página comercial (el **punto de venta** de ORest). Vive en el ápice `orest.com.mx`; desde aquí la
gente conoce el producto y entra a contratar en `cloud.orest.com.mx`.

Es **un HTML estático y autocontenido** (`site/index.html`): todo el CSS, el JS y la fuente de marca van
en línea, no pide ningún recurso externo. Se sirve con `nginx` estándar, bind-monteado desde este repo.
No es un build de Next ni lleva secretos — por eso **no** sigue el patrón de imagen-construida de ORest y
Cloud (`docker save | ssh load`).

## DNS — el paso que se olvida

El comodín `A *` de `orest.com.mx` **no cubre el ápice pelado**. Antes de levantar nada:

```
A   @   → <IP del VPS>     # orest.com.mx  (ESTE es el que falta)
```

`www` y `cloud` ya los resuelve el comodín `*`. Comprueba el ápice desde fuera del VPS:

```bash
dig +short orest.com.mx
```

Debe devolver la IP del VPS. Si no, Traefik no recibe tráfico y ACME no emite el certificado.

## Levantar

Con el repo ya clonado en el VPS (`/opt/orway-infra`) y la red `web` creada (la misma de Traefik):

```bash
cd /opt/orway-infra
docker compose -f apps/orest-landing/docker-compose.yml up -d
```

Traefik toma las labels, enruta `orest.com.mx` y `www`→ápice, y pide el certificado. Verifica:

```bash
docker compose -f apps/orest-landing/docker-compose.yml ps
curl -I https://orest.com.mx
```

## Actualizar el contenido (texto, precios, lo que sea)

1. Edita `site/index.html` en el repo (en local), commitea y push.
2. En el VPS: `cd /opt/orway-infra && git pull`.
3. `docker compose -f apps/orest-landing/docker-compose.yml restart`.

nginx mantiene el archivo abierto en caché unos segundos; el `restart` lo fuerza a releer. Sin build, sin
`save|load`.

## De dónde sale `site/index.html`

Es la landing aprobada, exportada como **documento HTML completo** (con `<!doctype>`, `<meta charset>` y
metadatos OpenGraph para que el enlace se vea bien al compartirlo). El logo es el isotipo **vectorial**
oficial (robot-O + «Rest»); no depende de ninguna fuente. La tipografía de marca (Bauhaus Bugler) va
embebida como `data:` — ver la nota de licencia en el checklist de go-live antes de dejar la página
pública.

## Lo que este contenedor NO hace

- No tiene base de datos, no habla con Postgres, no está en la red por otra razón que alcanzar a Traefik.
- No recoge formularios ni datos: contratar ocurre en `cloud.orest.com.mx`, no aquí.
- No sirve ningún subdominio: cada restaurante y `cloud.` son sus propios routers.
