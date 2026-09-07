-- O reconciliador estava varrendo 5 páginas de cada post a cada 5 minutos mesmo
-- com nada a recuperar: ~98 chamadas/hora à Graph API do Instagram, competindo
-- por rate limit com os envios do próprio app.
--
-- Agora só avança para a próxima página se a página atual trouxe algum comentário
-- órfão — como a API devolve do mais novo para o mais antigo, uma página inteira
-- já respondida indica que dali para trás está em dia. Uma vez por hora
-- (instadm-reconciliar-varredura) roda uma passagem profunda que pagina até o fim
-- da janela, cobrindo o caso raro de um buraco no meio do histórico.
--
-- Medido depois da mudança: rodada normal = 4 chamadas (uma página por post),
-- rodada profunda = 5. Antes eram 20 por rodada.
--
-- Aplicado em: projeto Supabase "instadm" (tkvqphtluacmxlvqrwtk).

alter table public.reconcilia_lote
  add column if not exists profundo boolean not null default false;

-- disparar() ganha o modo profundo; a assinatura sem argumento é substituída
create or replace function public.reconciliar_comentarios_disparar(p_profundo boolean default false)
returns int
language plpgsql
security definer
set search_path = public, extensions, net
as $$
declare
  r       record;
  v_token text;
  v_req   bigint;
  n       int := 0;
begin
  for r in
    select a.id as automation_id, a.conta_id, m.media_id
      from public.automations a
      cross join lateral unnest(a.media_ids) as m(media_id)
     where a.is_active
       and a.trigger_comment
       and a.arquivada_em is null
       and coalesce(m.media_id, '') <> ''
  loop
    select coalesce(c.ig_access_token, cfg.ig_access_token)
      into v_token
      from (select 1) z
      left join public.contas c   on c.id = r.conta_id
      left join public.config cfg on cfg.id = 1;

    continue when v_token is null;

    select net.http_get(
      url := 'https://graph.instagram.com/v21.0/' || r.media_id ||
             '/comments?limit=50&fields=' ||
             'id,text,timestamp,from%7Bid,username%7D,replies%7Bid,from%7Bid%7D%7D' ||
             '&access_token=' || v_token,
      timeout_milliseconds := 20000
    ) into v_req;

    insert into public.reconcilia_lote (automation_id, conta_id, media_id, request_id, profundo)
    values (r.automation_id, r.conta_id, r.media_id, v_req, p_profundo);

    n := n + 1;
  end loop;

  return n;
end;
$$;

drop function if exists public.reconciliar_comentarios_disparar();

-- coletar(): a decisão de paginar passa para depois do loop, condicionada a
-- ter achado órfão nesta página (ou o lote ser de varredura profunda)
create or replace function public.reconciliar_comentarios_coletar(
  p_max     int default 20,
  p_horas   int default 24,
  p_paginas int default 10
)
returns int
language plpgsql
security definer
set search_path = public, extensions, net
as $$
declare
  lote        record;
  a           record;
  cm          record;
  v_resp      record;
  v_json      jsonb;
  v_conta_ig  text;
  v_contact   uuid;
  v_texto_pub text;
  v_texto_dm  text;
  v_dm_status text;
  v_pub_ok    boolean;
  v_casou     boolean;
  v_simples   boolean;
  v_next      text;
  v_ts_min    timestamptz;
  v_req       bigint;
  v_na_pagina int;
  v_total     int := 0;
begin
  for lote in
    select * from public.reconcilia_lote
     where coletado_em is null
     order by criado_em
     limit 30
  loop
    select status_code, content into v_resp
      from net._http_response where id = lote.request_id;

    -- resposta ainda não chegou: fica para a próxima rodada
    continue when not found;

    update public.reconcilia_lote
       set coletado_em = now(), status_code = v_resp.status_code
     where id = lote.id;

    if v_resp.status_code <> 200 then
      update public.reconcilia_lote
         set erro = left(coalesce(v_resp.content, 'sem corpo'), 500)
       where id = lote.id;
      continue;
    end if;

    v_json := v_resp.content::jsonb;

    select * into a from public.automations where id = lote.automation_id;
    continue when not found or not a.is_active;

    select ig_user_id into v_conta_ig from public.contas where id = lote.conta_id;

    v_simples := a.quick_reply_label is null
             and coalesce(jsonb_array_length(a.opcoes), 0) = 0
             and a.captura is null
             and not a.pedir_follow;

    v_na_pagina := 0;

    for cm in
      with bruto as (
        select c->>'id'                       as cid,
               coalesce(c->>'text', '')       as texto,
               (c->>'timestamp')::timestamptz as ts,
               c->'from'->>'id'               as from_id,
               c->'from'->>'username'         as uname,
               coalesce(c->'replies'->'data', '[]'::jsonb) as replies
          from jsonb_array_elements(v_json->'data') c
      ),
      elegivel as (
        select b.*
          from bruto b
         where b.from_id is not null
           and b.from_id is distinct from v_conta_ig
           and b.ts > now() - make_interval(hours => p_horas)
           and not exists (select 1 from public.queue q where q.comment_id = b.cid)
           and not exists (
                 select 1 from jsonb_array_elements(b.replies) rr
                  where rr->'from'->>'id' = v_conta_ig
               )
      )
      select e.*, row_number() over (partition by e.from_id order by e.ts desc) as rn
        from elegivel e
       order by e.ts
    loop
      v_na_pagina := v_na_pagina + 1;
      exit when v_total >= p_max;

      v_casou := case
        when a.match_type = 'any' then true
        when coalesce(array_length(a.keywords, 1), 0) = 0 then a.match_type = 'any'
        when a.match_type = 'exact' then exists (
          select 1 from unnest(a.keywords) k where lower(btrim(k)) = lower(btrim(cm.texto)))
        else exists (
          select 1 from unnest(a.keywords) k
           where btrim(k) <> '' and position(lower(btrim(k)) in lower(cm.texto)) > 0)
      end;

      continue when not v_casou;

      insert into public.contacts (ig_user_id, username, conta_id, last_automation_id)
      values (cm.from_id, cm.uname, lote.conta_id, a.id)
      on conflict (conta_id, ig_user_id) do update
         set username   = coalesce(excluded.username, public.contacts.username),
             updated_at = now()
      returning id into v_contact;

      -- teto global: no máximo uma resposta pública por pessoa a cada 2h nesta automação
      v_pub_ok := cm.rn = 1 and not exists (
        select 1 from public.queue q
         where q.kind = 'public_reply'
           and q.contact_id = v_contact
           and q.automation_id = a.id
           and q.status in ('pending', 'sending', 'sent')
           and q.created_at > now() - interval '2 hours'
      );

      if coalesce(array_length(a.public_replies, 1), 0) > 0 then
        select a.public_replies[1 + floor(random() * array_length(a.public_replies, 1))::int]
          into v_texto_pub;

        insert into public.queue (kind, automation_id, contact_id, conta_id, comment_id,
                                  dedupe_key, payload, requires_window, status, last_error)
        values ('public_reply', a.id, v_contact, lote.conta_id, cm.cid,
                'pub:' || cm.cid,
                jsonb_build_object('text', v_texto_pub),
                false,
                case when v_pub_ok then 'pending' else 'skipped' end,
                case when v_pub_ok then null else 'reconciliador: rajada do mesmo contato' end)
        on conflict (dedupe_key) do nothing;
      end if;

      v_dm_status := null;
      if v_simples then
        v_texto_dm := case
          when coalesce(array_length(a.welcome_dm_variacoes, 1), 0) > 0
            then a.welcome_dm_variacoes[1 + floor(random() * array_length(a.welcome_dm_variacoes, 1))::int]
          else a.welcome_dm_text
        end;

        if coalesce(btrim(v_texto_dm), '') <> '' then
          insert into public.queue (kind, automation_id, contact_id, conta_id, comment_id,
                                    dedupe_key, payload, requires_window)
          values ('private_reply', a.id, v_contact, lote.conta_id, cm.cid,
                  'priv:' || cm.cid,
                  jsonb_build_object('text', v_texto_dm, 'type', 'text'),
                  false)
          on conflict (dedupe_key) do nothing
          returning status into v_dm_status;

          if v_dm_status = 'pending' then
            insert into public.queue (kind, automation_id, followup_id, contact_id, conta_id,
                                      dedupe_key, payload, requires_window, scheduled_at)
            select 'followup', a.id, f.id, v_contact, lote.conta_id,
                   'fu:' || v_contact || ':' || f.id,
                   f.payload, true, now() + make_interval(mins => f.delay_minutes)
              from public.followups f
             where f.automation_id = a.id
            on conflict (dedupe_key) do nothing;
          end if;
        end if;
      end if;

      insert into public.events (kind, ig_user_id, conta_id, payload, note)
      values ('comment.reconciliado', cm.from_id, lote.conta_id,
              jsonb_build_object(
                'comment_id',    cm.cid,
                'username',      cm.uname,
                'texto',         left(cm.texto, 200),
                'automation_id', a.id,
                'media_id',      lote.media_id,
                'pagina',        lote.pagina,
                'publica',       case when v_pub_ok then 'enfileirada' else 'rajada: ignorada' end,
                'dm',            coalesce(v_dm_status, case when v_simples then 'sem texto' else 'automacao com botao: nao remontada' end)
              ),
              'Comentário que o webhook não entregou, recuperado pelo reconciliador');

      v_total := v_total + 1;

      update public.reconcilia_lote
         set achados = achados + 1,
             enfileirados = enfileirados + case when v_pub_ok then 1 else 0 end
       where id = lote.id;
    end loop;

    -- só desce para a próxima página se esta trouxe órfão, ou na varredura profunda
    select min((c->>'timestamp')::timestamptz) into v_ts_min
      from jsonb_array_elements(v_json->'data') c;

    v_next := v_json->'paging'->>'next';
    if v_next is not null
       and lote.pagina < p_paginas
       and v_ts_min is not null
       and v_ts_min > now() - make_interval(hours => p_horas)
       and (lote.profundo or v_na_pagina > 0)
    then
      select net.http_get(url := v_next, timeout_milliseconds := 20000) into v_req;
      insert into public.reconcilia_lote (automation_id, conta_id, media_id, request_id, pagina, profundo)
      values (lote.automation_id, lote.conta_id, lote.media_id, v_req, lote.pagina + 1, lote.profundo);
    end if;

    exit when v_total >= p_max;
  end loop;

  return v_total;
end;
$$;

comment on function public.reconciliar_comentarios_disparar(boolean) is
  'Fase 1: pede à API do Instagram os comentários dos posts das automações ativas. profundo = pagina até o fim da janela mesmo sem órfãos.';

revoke execute on function public.reconciliar_comentarios_disparar(boolean)   from public, anon, authenticated;
revoke execute on function public.reconciliar_comentarios_coletar(int,int,int) from public, anon, authenticated;

select cron.unschedule('instadm-reconciliar-disparar');
select cron.schedule('instadm-reconciliar-disparar', '*/5 * * * *',
       $cron$select public.reconciliar_comentarios_disparar(false)$cron$);
select cron.schedule('instadm-reconciliar-varredura', '3 * * * *',
       $cron$select public.reconciliar_comentarios_disparar(true)$cron$);
