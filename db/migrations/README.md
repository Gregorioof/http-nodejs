# Migrações do InstaDM

SQL aplicado no projeto Supabase `instadm` (ref `tkvqphtluacmxlvqrwtk`), versionado aqui
porque o app está na Vercel sem repositório ligado.

| Arquivo | O que faz |
| --- | --- |
| `20260907_trava_dm_unica_por_pessoa.sql` | Uma DM automática por pessoa, mesmo que ela comente várias vezes no post. |

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

Reverter tudo:

```sql
drop trigger if exists trava_dm_unica_trg on public.queue;
drop function if exists public.trava_dm_unica();
```
