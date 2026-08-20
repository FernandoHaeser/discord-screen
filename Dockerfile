# Imagem do servidor da Sala de Tela.
#
# Duas etapas de propósito. A primeira monta o site — o que exige o vite e o
# código do cliente inteiro; a segunda leva só o que roda: servidor, shared,
# client/dist e as dependências de produção. O que compila não precisa viajar
# junto, e a imagem final fica com uma fração do tamanho.

# ------------------------------------------------------------------ build

FROM node:22-slim AS build

WORKDIR /app

# Os package.json antes do resto do código: enquanto as dependências não
# mudarem, o Docker reaproveita esta camada e o deploy pula o npm ci inteiro.
# Os três arquivos porque isto é um workspace — sem os dois de baixo, o npm
# recusa a instalação.
COPY package.json package-lock.json ./
COPY client/package.json client/
COPY server/package.json server/

RUN npm ci

COPY . .

RUN npm run build

# Baixa o cloudflared aqui — ainda root, com rede liberada no build — e não no
# runtime: lá o processo roda como `node`, sem permissão de escrita em /app
# para criar .cache/, e sem garantia de saída para a internet em toda máquina
# de deploy. O binário sai pronto no .cache/, só falta copiar.
RUN node -e "import('./scripts/cloudflared.mjs').then(m => m.garantirCloudflared()).catch(e => { console.error(e); process.exit(1); })"

# ---------------------------------------------------------------- runtime

FROM node:22-slim

# Antes do npm ci: com NODE_ENV=production o npm já pula as devDependencies
# sozinho, e o servidor lê esta mesma variável para exigir o SESSION_SECRET.
ENV NODE_ENV=production

# node:22-slim não vem com CA raiz nenhuma — o Node embute a sua própria e não
# sente falta, mas o cloudflared é um binário Go que confia no /etc/ssl/certs
# do sistema, e sem isto todo POST para trycloudflare.com morre com
# "certificate signed by unknown authority", como se a rede estivesse quebrada.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
COPY client/package.json client/
COPY server/package.json server/

RUN npm ci --omit=dev && npm cache clean --force

COPY server/ server/
COPY shared/ shared/
COPY scripts/ scripts/
COPY --from=build /app/client/dist client/dist
# --chown: dono vira `node`. Não é só leitura do binário — a cada subida o
# túnel descartável escreve um config neutro (tunel-rapido.yml) aqui dentro
# (ver configNeutro() em scripts/tunel.mjs), e sem isso o processo, já como
# `node`, tropeça num EACCES antes mesmo de tentar abrir o túnel.
COPY --from=build --chown=node:node /app/.cache .cache

# Usuário sem privilégio, já existente na imagem oficial.
USER node

# Só o Traefik do Dokploy fala com esta porta; ela não fica exposta na rede.
EXPOSE 3001

# O health serve ao Docker e ao Dokploy: um container que responde 200 aqui
# está com servidor, salas e build no lugar.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3001)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# start-docker.mjs: abre um túnel Cloudflare descartável (endereço novo a cada
# subida — sem domínio próprio pra fixar) e só então sobe o servidor, já
# apontado pro endereço que acabou de nascer. Ver o próprio script pro porquê
# de não gravar .env aqui.
CMD ["node", "scripts/start-docker.mjs"]
