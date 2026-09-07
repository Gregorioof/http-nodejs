-- Reconciliador de comentários que o webhook do Instagram não entrega.
--
-- Sintoma real: no post do 9.9, 23 comentários de seguidores ficaram sem
-- resposta nenhuma. Não havia evento, fila nem log — o webhook do Meta
-- simplesmente não entregou. Padrão: rajada da mesma pessoa (10+ comentários
-- em segundos); o Meta entrega os primeiros e para.
--
-- O sistema dependia 100% do webhook: o que não chegava, sumia para sempre.
-- Este job confere pela API do Instagram e enfileira o que faltou.
--
-- Duas fases porque pg_net é assíncrono:
--   1. reconciliar_comentarios_disparar()  -> pede os comentários dos posts das automações ativas
--   2. reconciliar_comentarios_coletar()   -> lê a resposta, pagina e enfileira o que faltou
--
-- Salvaguardas:
--   - resposta pública: no máximo uma por pessoa a cada 2h na mesma automação;
--     o resto da rajada entra como 'skipped' e não volta nas próximas rodadas
--   - DM: passa pela trava de DM única (20260907_trava_dm_unica_por_pessoa.sql)
--   - comentário já respondido pelo perfil (manual ou pelo app) é ignorado
--   - automação com botão, captura ou pedido de follow não tem a DM remontada
--     aqui: só a resposta pública sai, e o caso fica registrado em events
--
-- Aplicado em: projeto Supabase "instadm" (tkvqphtluacmxlvqrwtk).

create table if not exists public.reconcilia_lote (
  id            bigserial primary key,
  automation_id uuid not null references public.automations(id) on delete cascade,
  conta_id      uuid,
  media_id      text not null,
  request_id    bigint not null,
  pagina        int not null default 1,
  criado_em     timestamptz not null default now(),
  coletado_em   timestamptz,
  status_code   int,
  achados       int not null default 0,
  enfileirados  int not null default 0,
  erro          text
);

create index if not exists reconcilia_lote_pendente_idx
  on public.reconcilia_lote (criado_em) where coletado_em is null;

alter table public.reconcilia_lote enable row level security;

comment on table public.reconcilia_lote is
  'Uma linha por consulta de comentários feita à API do Instagram pelo reconciliador.';

-- ---------------------------------------------------------------- fase 1
create or replace function public.reconciliar_comentarios_disparar()
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

    insert into public.reconcilia_lote (automation_id, conta_id, media_id, request_id)
    values (r.automation_id, r.conta_id, r.media_id, v_req);

    n := n + 1;
  end loop;

  return n;
end;
$$;

-- ---------------------------------------------------------------- fase 2
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

    -- segue a paginação enquanto a página ainda estiver dentro da janela
    select min((c->>'timestamp')::timestamptz) into v_ts_min
      from jsonb_array_elements(v_json->'data') c;

    v_next := v_json->'paging'->>'next';
    if v_next is not null
       and lote.pagina < p_paginas
       and v_ts_min is not null
       and v_ts_min > now() - make_interval(hours => p_horas)
    then
      select net.http_get(url := v_next, timeout_milliseconds := 20000) into v_req;
      insert into public.reconcilia_lote (automation_id, conta_id, media_id, request_id, pagina)
      values (lote.automation_id, lote.conta_id, lote.media_id, v_req, lote.pagina + 1);
    end if;

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

    exit when v_total >= p_max;
  end loop;

  return v_total;
end;
$$;

comment on function public.reconciliar_comentarios_disparar() is
  'Fase 1: pede à API do Instagram os comentários dos posts das automações ativas.';
comment on function public.reconciliar_comentarios_coletar(int, int, int) is
  'Fase 2: lê as respostas da API, segue a paginação e enfileira os comentários que o webhook não entregou.';

-- as funções só rodam pelo pg_cron; ninguém precisa chamá-las pela API
revoke execute on function public.reconciliar_comentarios_disparar()       from public, anon, authenticated;
revoke execute on function public.reconciliar_comentarios_coletar(int,int,int) from public, anon, authenticated;

-- agendamento (o coletar corre 1 min depois do disparar, dando tempo à resposta)
select cron.schedule('instadm-reconciliar-disparar', '*/5 * * * *',
       $cron$select public.reconciliar_comentarios_disparar()$cron$);
select cron.schedule('instadm-reconciliar-coletar', '1-59/5 * * * *',
       $cron$select public.reconciliar_comentarios_coletar(20, 24, 10)$cron$);
select cron.schedule('instadm-reconciliar-faxina', '45 4 * * *',
       $cron$delete from public.reconcilia_lote where criado_em < now() - interval '7 days'$cron$);
