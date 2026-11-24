-- =====================================================================
-- GiLF Eventos — 002: tipos de bilhete, pagamentos e estatísticas de vendas
-- Só acrescenta (não apaga dados). Pode correr de novo.
-- =====================================================================

-- ---------- Definições de pagamento (editadas pelo administrador) ----------
create table if not exists definicoes (
  chave text primary key,
  valor jsonb not null default '{}'::jsonb,
  actualizado_em timestamptz not null default now()
);
alter table definicoes enable row level security;
drop policy if exists definicoes_ver on definicoes;
create policy definicoes_ver on definicoes for select using (true);
drop policy if exists definicoes_admin on definicoes;
create policy definicoes_admin on definicoes for all using (is_admin()) with check (is_admin());
revoke all on definicoes from anon, authenticated;
grant select on definicoes to anon, authenticated;
grant insert, update on definicoes to authenticated;
insert into definicoes (chave, valor) values ('pagamento', jsonb_build_object(
  'titular', '', 'banco', '', 'iban', '', 'mcx', '', 'whatsapp', '244922812224', 'prazo_horas', 48,
  'instrucoes', 'Depois de pagar, envie o comprovativo por WhatsApp com o código da reserva. O bilhete fica válido quando a organização confirmar o pagamento.'))
on conflict (chave) do nothing;

-- ---------- Bilhetes por evento e dados de pagamento por inscrição ----------
-- eventos.bilhetes = [{"id":"forum","nome":"Fórum","preco":15000 | null,"lotacao":200 | null,"descricao":"..."}]
-- preco null = "sob consulta" (a organização indica o valor ao confirmar o pagamento)
alter table eventos add column if not exists bilhetes jsonb not null default '[]'::jsonb;
alter table inscricoes add column if not exists tipo_bilhete text not null default '';
alter table inscricoes add column if not exists valor integer not null default 0;
alter table inscricoes add column if not exists pagamento text not null default 'gratis';
alter table inscricoes add column if not exists metodo text not null default '';
alter table inscricoes add column if not exists pago_em timestamptz;
alter table inscricoes add column if not exists expira_em timestamptz;
do $$ begin
  alter table inscricoes add constraint inscricoes_pagamento_chk check (pagamento in ('gratis', 'pendente', 'pago', 'reembolsado'));
exception when duplicate_object then null; end $$;
create index if not exists inscricoes_pago_idx on inscricoes (pagamento, pago_em);

-- ---------- Vista pública de eventos: + bilhetes e vendidos por tipo ----------
create or replace view v_eventos as
  select e.id, e.grupo_id, e.titulo, e.descricao, e.inicio, e.fim, e.formato, e.local, e.endereco, e.cidade, e.preco, e.preco_texto,
         e.vagas, e.certificado, e.oficial, e.link, e.estado, e.criado_em,
         (select count(*) from inscricoes i where i.evento_id = e.id and i.estado = 'confirmado')::int as n_confirmados,
         e.bilhetes,
         coalesce((select jsonb_object_agg(x.t, x.n) from (select i.tipo_bilhete as t, count(*) as n from inscricoes i
                    where i.evento_id = e.id and i.estado = 'confirmado' group by 1) x), '{}'::jsonb) as vendidos
  from eventos e join grupos g on g.id = e.grupo_id
  where e.estado in ('publicado', 'cancelado') and g.estado = 'aprovado';

-- ---------- Reservas não pagas expiram e o lugar passa à lista de espera ----------
create or replace function libertar_expiradas(p_evento text) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int; v_prazo int;
begin
  update inscricoes set estado = 'cancelado'
   where evento_id = p_evento and estado = 'confirmado' and pagamento = 'pendente' and expira_em is not null and expira_em < now();
  get diagnostics v_n = row_count;
  if v_n > 0 then
    select coalesce((valor->>'prazo_horas')::int, 48) into v_prazo from definicoes where chave = 'pagamento';
    update inscricoes set estado = 'confirmado',
           expira_em = case when pagamento = 'pendente' and valor > 0 then now() + make_interval(hours => coalesce(v_prazo, 48)) else null end
     where id in (select id from inscricoes where evento_id = p_evento and estado = 'espera' order by criado_em limit v_n);
  end if;
  return v_n;
end $$;

-- ---------- Comprar / reservar bilhete ----------
create or replace function comprar_bilhete(p_evento text, p_tipo text default '', p_objectivo text default '', p_b2b boolean default true)
returns table (r_estado text, r_codigo text, r_valor int, r_pagamento text, r_tipo text, r_expira timestamptz)
language plpgsql security definer set search_path = public as $$
declare v_e eventos; v_ja inscricoes; v_tipo jsonb; v_nome text := ''; v_preco int; v_lot int; v_n int; v_conf int;
        v_est text; v_pag text; v_prazo int; v_exp timestamptz;
begin
  if auth.uid() is null then raise exception 'Precisa de entrar na sua conta.'; end if;
  select e.* into v_e from eventos e join grupos g on g.id = e.grupo_id
   where e.id = p_evento and e.estado = 'publicado' and g.estado = 'aprovado' for update of e;
  if not found then raise exception 'Evento indisponível.'; end if;
  if coalesce(v_e.fim, v_e.inicio) < now() then raise exception 'Este evento já terminou.'; end if;
  perform libertar_expiradas(p_evento);

  select * into v_ja from inscricoes where evento_id = p_evento and perfil_id = auth.uid();
  if found and v_ja.estado <> 'cancelado' then
    return query select v_ja.estado, v_ja.codigo, v_ja.valor, v_ja.pagamento, v_ja.tipo_bilhete, v_ja.expira_em; return;
  end if;

  if jsonb_array_length(coalesce(v_e.bilhetes, '[]'::jsonb)) > 0 then
    select b into v_tipo from jsonb_array_elements(v_e.bilhetes) b where b->>'id' = p_tipo limit 1;
    if v_tipo is null then raise exception 'Escolha um tipo de bilhete.'; end if;
    v_nome := coalesce(v_tipo->>'nome', '');
    v_preco := nullif(v_tipo->>'preco', '')::int;
    v_lot := nullif(v_tipo->>'lotacao', '')::int;
    if v_lot is not null then
      select count(*) into v_n from inscricoes where evento_id = p_evento and estado = 'confirmado' and tipo_bilhete = v_nome;
      if v_n >= v_lot then raise exception 'O bilhete «%» está esgotado.', v_nome; end if;
    end if;
  else
    v_preco := v_e.preco;
  end if;

  select count(*) into v_conf from inscricoes where evento_id = p_evento and estado = 'confirmado';
  v_est := case when v_conf >= v_e.vagas then 'espera' else 'confirmado' end;
  v_pag := case when v_preco = 0 then 'gratis' else 'pendente' end;   -- preço > 0 ou "sob consulta"
  select coalesce((valor->>'prazo_horas')::int, 48) into v_prazo from definicoes where chave = 'pagamento';
  v_exp := case when v_pag = 'pendente' and coalesce(v_preco, 0) > 0 and v_est = 'confirmado' then now() + make_interval(hours => coalesce(v_prazo, 48)) else null end;

  insert into inscricoes (evento_id, perfil_id, codigo, estado, objectivo, quer_b2b, tipo_bilhete, valor, pagamento, metodo, pago_em, expira_em)
  values (p_evento, auth.uid(), 'GE-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)), v_est,
          coalesce(p_objectivo, ''), coalesce(p_b2b, true), v_nome, coalesce(v_preco, 0), v_pag, '', null, v_exp)
  on conflict (evento_id, perfil_id) do update
    set estado = excluded.estado, objectivo = excluded.objectivo, quer_b2b = excluded.quer_b2b, criado_em = now(), check_in_em = null,
        tipo_bilhete = excluded.tipo_bilhete, valor = excluded.valor, pagamento = excluded.pagamento, metodo = '', pago_em = null, expira_em = excluded.expira_em
    where inscricoes.estado = 'cancelado';
  insert into grupo_membros (grupo_id, perfil_id) values (v_e.grupo_id, auth.uid()) on conflict do nothing;
  return query select i.estado, i.codigo, i.valor, i.pagamento, i.tipo_bilhete, i.expira_em from inscricoes i where i.evento_id = p_evento and i.perfil_id = auth.uid();
end $$;

-- ---------- Organizador / admin: confirmar pagamento ----------
create or replace function confirmar_pagamento(p_inscricao uuid, p_pago boolean, p_metodo text default '', p_valor int default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_org((select e.grupo_id from inscricoes i join eventos e on e.id = i.evento_id where i.id = p_inscricao)) then raise exception 'Sem permissão.'; end if;
  update inscricoes set
    pagamento = case when p_pago then 'pago' else 'pendente' end,
    pago_em = case when p_pago then now() else null end,
    metodo = case when p_pago then coalesce(p_metodo, '') else '' end,
    valor = coalesce(p_valor, valor),
    expira_em = case when p_pago then null else now() + interval '48 hours' end
  where id = p_inscricao and pagamento in ('pendente', 'pago');
end $$;

-- ---------- Lista completa para organizadores (com bilhete e pagamento) ----------
create or replace function lista_bilhetes(p_evento text)
returns table (id uuid, nome text, telefone text, email text, cargo text, organizacao text, estado text, codigo text, objectivo text,
               quer_b2b boolean, check_in_em timestamptz, criado_em timestamptz, tipo_bilhete text, valor int, pagamento text,
               metodo text, pago_em timestamptz, expira_em timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not is_org((select grupo_id from eventos where eventos.id = p_evento)) then raise exception 'Sem permissão.'; end if;
  perform libertar_expiradas(p_evento);
  return query select i.id, p.nome, p.telefone, u.email::text, p.cargo, p.organizacao, i.estado, i.codigo, i.objectivo, i.quer_b2b,
      i.check_in_em, i.criado_em, i.tipo_bilhete, i.valor, i.pagamento, i.metodo, i.pago_em, i.expira_em
    from inscricoes i join perfis p on p.id = i.perfil_id join auth.users u on u.id = p.id
    where i.evento_id = p_evento and i.estado <> 'cancelado' order by i.estado, i.criado_em;
end $$;

-- ---------- Check-in: bilhete por pagar não entra ----------
create or replace function check_in(p_evento text, p_codigo text) returns json
language plpgsql security definer set search_path = public as $$
declare v inscricoes; v_nome text;
begin
  if not is_org((select grupo_id from eventos where id = p_evento)) then raise exception 'Sem permissão.'; end if;
  select * into v from inscricoes where evento_id = p_evento and codigo = upper(trim(split_part(p_codigo, '|', 1)));
  if not found then return json_build_object('ok', false, 'msg', 'Código não encontrado neste evento.'); end if;
  select nome into v_nome from perfis where id = v.perfil_id;
  if v.estado <> 'confirmado' then return json_build_object('ok', false, 'msg', v_nome || ' não tem lugar confirmado (' || v.estado || ').'); end if;
  if v.pagamento = 'pendente' then return json_build_object('ok', false, 'msg', v_nome || ' ainda não pagou o bilhete (' || v.valor || ' Kz).'); end if;
  if v.check_in_em is not null then return json_build_object('ok', true, 'ja', true, 'nome', v_nome, 'tipo', v.tipo_bilhete); end if;
  update inscricoes set check_in_em = now() where id = v.id;
  return json_build_object('ok', true, 'ja', false, 'nome', v_nome, 'tipo', v.tipo_bilhete);
end $$;

-- ---------- Estatísticas de vendas (administração) ----------
create or replace function admin_vendas() returns json
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Sem permissão.'; end if;
  return json_build_object(
    'receita', (select coalesce(sum(valor), 0) from inscricoes where pagamento = 'pago'),
    'pendente', (select coalesce(sum(valor), 0) from inscricoes where pagamento = 'pendente' and estado = 'confirmado'),
    'pagos', (select count(*) from inscricoes where pagamento = 'pago'),
    'por_pagar', (select count(*) from inscricoes where pagamento = 'pendente' and estado = 'confirmado'),
    'gratis', (select count(*) from inscricoes where pagamento = 'gratis' and estado = 'confirmado'),
    'espera', (select count(*) from inscricoes where estado = 'espera'),
    'presencas', (select count(*) from inscricoes where check_in_em is not null),
    'por_evento', coalesce((select json_agg(x order by x.inicio desc) from (
        select e.id, e.titulo, e.inicio, e.vagas,
          count(i.*) filter (where i.estado = 'confirmado') as vendidos,
          count(i.*) filter (where i.pagamento = 'pago') as pagos,
          count(i.*) filter (where i.pagamento = 'pendente' and i.estado = 'confirmado') as por_pagar,
          coalesce(sum(i.valor) filter (where i.pagamento = 'pago'), 0) as receita,
          coalesce(sum(i.valor) filter (where i.pagamento = 'pendente' and i.estado = 'confirmado'), 0) as pendente,
          count(i.*) filter (where i.check_in_em is not null) as presencas
        from eventos e left join inscricoes i on i.evento_id = e.id group by e.id) x), '[]'::json),
    'por_tipo', coalesce((select json_agg(x order by x.receita desc) from (
        select coalesce(nullif(i.tipo_bilhete, ''), 'Geral') as tipo, count(*) filter (where i.estado = 'confirmado') as vendidos,
          coalesce(sum(i.valor) filter (where i.pagamento = 'pago'), 0) as receita
        from inscricoes i group by 1) x), '[]'::json),
    'por_metodo', coalesce((select json_agg(x) from (
        select coalesce(nullif(metodo, ''), 'Não indicado') as metodo, count(*) as n, sum(valor) as receita
        from inscricoes where pagamento = 'pago' group by 1) x), '[]'::json),
    'por_dia', coalesce((select json_agg(x order by x.dia) from (
        select to_char(d, 'YYYY-MM-DD') as dia,
          coalesce((select sum(valor) from inscricoes where pagamento = 'pago' and pago_em::date = d), 0) as receita,
          (select count(*) from inscricoes where criado_em::date = d and estado <> 'cancelado') as reservas
        from generate_series(current_date - 29, current_date, interval '1 day') d) x), '[]'::json));
end $$;

-- ---------- Permissões ----------
revoke execute on function libertar_expiradas(text) from public, anon, authenticated;
revoke execute on function comprar_bilhete(text, text, text, boolean), confirmar_pagamento(uuid, boolean, text, int), lista_bilhetes(text), admin_vendas() from public, anon;
grant execute on function comprar_bilhete(text, text, text, boolean), confirmar_pagamento(uuid, boolean, text, int), lista_bilhetes(text), admin_vendas() to authenticated;
grant select on v_eventos to anon, authenticated;

-- ---------- Evento oficial: tipos de bilhete do fórum (preço a definir pela Comissão) ----------
update eventos set bilhetes = '[
  {"id":"forum","nome":"Fórum","preco":null,"lotacao":null,"descricao":"08h30 – 15h20 · Keynotes, painéis e networking"},
  {"id":"gala","nome":"Gala & Jantar","preco":null,"lotacao":null,"descricao":"19h00 – 23h00 · Gala Prémios Líderes Angola e jantar"},
  {"id":"completo","nome":"Fórum + Gala","preco":null,"lotacao":null,"descricao":"O dia completo"}
]'::jsonb, preco = null
where id = 'gilf-2026' and bilhetes = '[]'::jsonb;

-- Inscrições já existentes em eventos com preço: passam a "pendente" (não estavam pagas)
update inscricoes i set pagamento = 'pendente'
from eventos e where e.id = i.evento_id and i.pagamento = 'gratis' and (e.preco is null or e.preco > 0) and i.estado <> 'cancelado';
