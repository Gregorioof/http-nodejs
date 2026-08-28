# FAQ Refund Worker (Cloudflare AI Gateway + cache)

Worker com rota `GET /faq/refund` que chama o Workers AI **via AI Gateway REST**,
usando cache com chave `faq:refund:v1` e TTL de 3600s. A resposta expõe o header
`cf-aig-cache-status` (`MISS` na primeira chamada, `HIT` nas seguintes — custo zero).

## Pré-requisitos

- Node.js
- Conta Cloudflare com créditos e um API Token com permissão **Workers AI: Read**
- Um gateway criado em **AI → AI Gateway** no dashboard da Cloudflare

## Setup

```bash
cd worker
npm install            # instala o wrangler (devDependency)
npx wrangler login
```

1. Preencha `CF_ACCOUNT_ID` e `CF_GATEWAY_ID` em `wrangler.jsonc`
   (Account ID aparece em Workers & Pages; o gateway ID é o nome do gateway criado).
2. Grave o token como segredo:

```bash
npx wrangler secret put CLOUDFLARE_API_TOKEN
```

## Deploy

```bash
npm run deploy
```

## Teste (MISS → HIT)

Chame a rota duas vezes e observe o header `cf-aig-cache-status`:

```bash
curl -si https://faq-refund-worker.<seu-subdominio>.workers.dev/faq/refund | grep -i cf-aig-cache-status
# cf-aig-cache-status: MISS

curl -si https://faq-refund-worker.<seu-subdominio>.workers.dev/faq/refund | grep -i cf-aig-cache-status
# cf-aig-cache-status: HIT   (resposta servida do cache, custo zero)
```

O corpo JSON também inclui `cacheStatus`, `cacheKey` e a resposta do modelo.

## Como funciona

O Worker faz `POST` para
`https://gateway.ai.cloudflare.com/v1/{ACCOUNT_ID}/{GATEWAY_ID}/workers-ai/{MODEL}`
enviando os headers de cache do AI Gateway:

- `cf-aig-cache-key: faq:refund:v1` — chave fixa, então toda chamada à rota reusa a mesma entrada
- `cf-aig-cache-ttl: 3600` — entrada expira em 1 hora

Docs: https://developers.cloudflare.com/ai-gateway/features/caching/
