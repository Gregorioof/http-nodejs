-- Instagram DM: trava de resposta única por pessoa
--
-- Problema: o dedupe da fila era por comentário (dedupe_key = 'priv:<comment_id>'),
-- então quem comentava 10x no mesmo post recebia 10 DMs.
--
-- Solução: antes de inserir na fila, se a pessoa já tem uma DM automática
-- dessa automação (pending/sending/sent), o novo item entra como 'skipped'
-- em vez de 'pending'. O worker só consome 'pending', então nada é enviado.
-- A resposta pública no comentário continua acontecendo normalmente.
--
-- Aplicado em: projeto Supabase "instadm" (tkvqphtluacmxlvqrwtk).

alter table public.automations
  add column if not exists dm_unica_por_pessoa boolean not null default true,
  add column if not exists dm_unica_escopo text not null default 'automacao';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'automations_dm_unica_escopo_check'
  ) then
    alter table public.automations
      add constraint automations_dm_unica_escopo_check
      check (dm_unica_escopo in ('automacao', 'conta'));
  end if;
end $$;

comment on column public.automations.dm_unica_por_pessoa is
  'Quando true, a mesma pessoa só recebe a DM automática uma vez, mesmo comentando várias vezes. A resposta pública no comentário continua normal.';
comment on column public.automations.dm_unica_escopo is
  'automacao = uma DM por pessoa por automação (padrão). conta = uma DM por pessoa em toda a conta, somando todas as automações.';

create index if not exists queue_trava_dm_idx
  on public.queue (contact_id, automation_id, kind, status);

create index if not exists queue_trava_dm_conta_idx
  on public.queue (contact_id, conta_id, kind, status);

create or replace function public.trava_dm_unica()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ativa   boolean;
  v_escopo  text;
  v_ja_teve boolean;
begin
  -- só interessa DM automática nascida de comentário/menção
  if not (new.kind = 'private_reply' or (new.kind = 'dm' and new.comment_id is not null)) then
    return new;
  end if;

  if new.contact_id is null or new.automation_id is null then
    return new;
  end if;

  select a.dm_unica_por_pessoa, a.dm_unica_escopo
    into v_ativa, v_escopo
  from public.automations a
  where a.id = new.automation_id;

  if coalesce(v_ativa, false) is not true then
    return new;
  end if;

  v_escopo := coalesce(v_escopo, 'automacao');

  -- serializa comentários simultâneos da mesma pessoa: o 2º espera o 1º commitar
  perform pg_advisory_xact_lock(
    hashtext('dm_unica:' || v_escopo || ':' ||
             case when v_escopo = 'conta'
                  then coalesce(new.conta_id::text, '-')
                  else new.automation_id::text end ||
             ':' || new.contact_id::text)
  );

  select exists (
    select 1
    from public.queue q
    where q.contact_id = new.contact_id
      and (q.kind = 'private_reply' or (q.kind = 'dm' and q.comment_id is not null))
      and q.status in ('pending', 'sending', 'sent')
      and case
            when v_escopo = 'conta'
              then q.conta_id is not distinct from new.conta_id
            else q.automation_id = new.automation_id
          end
  ) into v_ja_teve;

  if v_ja_teve then
    new.status := 'skipped';
    new.claimed_at := now();
    new.last_error := 'trava dm unica (' || v_escopo || '): contato ja recebeu a DM desta automacao';

    insert into public.events (kind, ig_user_id, conta_id, payload, note)
    values (
      'dm_bloqueada_trava',
      new.recipient_ig_id,
      new.conta_id,
      jsonb_build_object(
        'contact_id',    new.contact_id,
        'automation_id', new.automation_id,
        'comment_id',    new.comment_id,
        'escopo',        v_escopo
      ),
      'DM nao enviada: pessoa ja foi respondida por DM'
    );
  end if;

  return new;
end;
$$;

comment on function public.trava_dm_unica() is
  'Marca como skipped a DM automática repetida para quem já foi respondido, mantendo o registro na fila para auditoria.';

-- a função só roda pelo trigger; ninguém precisa chamá-la pela API
revoke execute on function public.trava_dm_unica() from public, anon, authenticated;

drop trigger if exists trava_dm_unica_trg on public.queue;
create trigger trava_dm_unica_trg
  before insert on public.queue
  for each row execute function public.trava_dm_unica();
