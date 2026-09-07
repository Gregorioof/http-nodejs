# Migrações do InstaDM

SQL aplicado no projeto Supabase `instadm` (ref `tkvqphtluacmxlvqrwtk`), versionado aqui
porque o app está na Vercel sem repositório ligado.

| Arquivo | O que faz |
| --- | --- |
| `20260907_trava_dm_unica_por_pessoa.sql` | Uma DM automática por pessoa, mesmo que ela comente várias vezes no post. |
| `20260907_reconciliador_comentarios.sql` | Recupera comentários que o webhook do Instagram não entrega. |

## Trava de DM única

Liga/desliga por automação:

```sql
-- desligar em uma automação
update automations set dm_unica_por_pessoa = false where id = '<automation_id>';

-- trava global: uma DM por pessoa somando todas as automações da conta
update automations set dm_unica_escopo = 'conta' where id = '<automation_id>';
```

Ver o que a trava barrou:

```sql
select created_at, payload
from events
where kind = 'dm_bloqueada_trava'
order by created_at desc;
```

Reverter:

```sql
drop trigger if exists trava_dm_unica_trg on public.queue;
drop function if exists public.trava_dm_unica();
```

## Reconciliador de comentários

Roda a cada 5 minutos (`instadm-reconciliar-disparar` + `instadm-reconciliar-coletar`),
confere pela API do Instagram os posts das automações ativas e enfileira o que o
webhook não entregou.

Ver o que foi recuperado:

```sql
select created_at, payload->>'username' as autor, payload->>'texto' as texto,
       payload->>'publica' as publica, payload->>'dm' as dm
from events
where kind = 'comment.reconciliado'
order by created_at desc;
```

Saúde das consultas à API:

```sql
select criado_em, media_id, pagina, status_code, achados, enfileirados, erro
from reconcilia_lote
order by criado_em desc limit 20;
```

Rodar na mão:

```sql
select public.reconciliar_comentarios_disparar();
select public.reconciliar_comentarios_coletar(20, 24, 10);  -- max, horas, páginas
```

Reverter:

```sql
select cron.unschedule('instadm-reconciliar-disparar');
select cron.unschedule('instadm-reconciliar-coletar');
select cron.unschedule('instadm-reconciliar-faxina');
drop function if exists public.reconciliar_comentarios_coletar(int, int, int);
drop function if exists public.reconciliar_comentarios_disparar();
drop table if exists public.reconcilia_lote;
```
