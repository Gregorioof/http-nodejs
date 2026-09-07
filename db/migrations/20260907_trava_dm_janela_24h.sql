-- A trava era permanente: quem recebeu a DM uma vez nunca mais recebia daquela
-- automação. Isso resolve a rajada, mas deixa sem resposta quem volta a comentar
-- dias depois — num post de campanha que fica no ar vários dias, isso é lead perdido.
--
-- A trava passa a aceitar uma janela: dm_unica_janela_horas NULL mantém o
-- comportamento anterior (uma vez e pronto); com um número, a pessoa volta a poder
-- receber depois daquele tempo. A rajada continua barrada nos dois casos, porque
-- os comentários repetidos chegam dentro de segundos.
--
-- Ligado em 24h para todas as automações, a pedido.
--
-- Aplicado em: projeto Supabase "instadm" (tkvqphtluacmxlvqrwtk).

alter table public.automations
  add column if not exists dm_unica_janela_horas int;

comment on column public.automations.dm_unica_janela_horas is
  'NULL = uma DM por pessoa para sempre nesta automação. Com número (ex: 24), a pessoa volta a poder receber depois desse tempo. A rajada continua barrada nos dois casos.';

create or replace function public.trava_dm_unica()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ativa   boolean;
  v_escopo  text;
  v_janela  int;
  v_ja_teve boolean;
begin
  -- só interessa DM automática nascida de comentário/menção
  if not (new.kind = 'private_reply' or (new.kind = 'dm' and new.comment_id is not null)) then
    return new;
  end if;

  if new.contact_id is null or new.automation_id is null then
    return new;
  end if;

  select a.dm_unica_por_pessoa, a.dm_unica_escopo, a.dm_unica_janela_horas
    into v_ativa, v_escopo, v_janela
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
      and (v_janela is null or q.created_at > now() - make_interval(hours => v_janela))
      and case
            when v_escopo = 'conta'
              then q.conta_id is not distinct from new.conta_id
            else q.automation_id = new.automation_id
          end
  ) into v_ja_teve;

  if v_ja_teve then
    new.status := 'skipped';
    new.claimed_at := now();
    new.last_error := 'trava dm unica (' || v_escopo ||
                      case when v_janela is null then ', sem janela'
                           else ', janela ' || v_janela || 'h' end ||
                      '): contato ja recebeu a DM desta automacao';

    insert into public.events (kind, ig_user_id, conta_id, payload, note)
    values (
      'dm_bloqueada_trava',
      new.recipient_ig_id,
      new.conta_id,
      jsonb_build_object(
        'contact_id',    new.contact_id,
        'automation_id', new.automation_id,
        'comment_id',    new.comment_id,
        'escopo',        v_escopo,
        'janela_horas',  v_janela
      ),
      'DM nao enviada: pessoa ja foi respondida por DM'
    );
  end if;

  return new;
end;
$$;

revoke execute on function public.trava_dm_unica() from public, anon, authenticated;

update public.automations set dm_unica_janela_horas = 24 where dm_unica_por_pessoa;
