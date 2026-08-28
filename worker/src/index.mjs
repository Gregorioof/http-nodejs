const CACHE_KEY = 'faq:refund:v1';
const CACHE_TTL_SECONDS = '3600';

const FAQ_QUESTION =
  'Explique de forma curta e objetiva a política de reembolso: prazo de 7 dias, ' +
  'produto sem uso, estorno no mesmo meio de pagamento em até 5 dias úteis.';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method !== 'GET' || url.pathname !== '/faq/refund') {
      return Response.json({ error: 'Not found' }, { status: 404 });
    }

    if (!env.CF_ACCOUNT_ID || !env.CF_GATEWAY_ID || !env.CLOUDFLARE_API_TOKEN) {
      return Response.json(
        {
          error:
            'Configure CF_ACCOUNT_ID e CF_GATEWAY_ID em wrangler.jsonc e rode ' +
            '`npx wrangler secret put CLOUDFLARE_API_TOKEN`.',
        },
        { status: 500 },
      );
    }

    const gatewayUrl =
      `https://gateway.ai.cloudflare.com/v1/${env.CF_ACCOUNT_ID}` +
      `/${env.CF_GATEWAY_ID}/workers-ai/${env.CF_AI_MODEL}`;

    const upstream = await fetch(gatewayUrl, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.CLOUDFLARE_API_TOKEN}`,
        'Content-Type': 'application/json',
        'cf-aig-cache-key': CACHE_KEY,
        'cf-aig-cache-ttl': CACHE_TTL_SECONDS,
      },
      body: JSON.stringify({
        messages: [
          {
            role: 'system',
            content: 'Você é um assistente de FAQ. Responda em português, em até 3 frases.',
          },
          { role: 'user', content: FAQ_QUESTION },
        ],
      }),
    });

    const cacheStatus = upstream.headers.get('cf-aig-cache-status') ?? 'UNKNOWN';

    if (!upstream.ok) {
      const detail = await upstream.text();
      return Response.json(
        { error: 'AI Gateway request failed', status: upstream.status, detail },
        { status: 502, headers: { 'cf-aig-cache-status': cacheStatus } },
      );
    }

    const data = await upstream.json();
    const answer = data?.result?.response ?? data;

    return Response.json(
      { question: FAQ_QUESTION, answer, cacheKey: CACHE_KEY, cacheStatus },
      { headers: { 'cf-aig-cache-status': cacheStatus } },
    );
  },
};
