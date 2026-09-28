-- Reusable recap periods + Gem RNG Month Two anniversary.
--
-- Month One remains frozen in month_one_private and is only read as the
-- authoritative Sep 8 baseline. This migration is intentionally safe to
-- prepare before the event and does not deploy either the schema or Edge
-- Function by itself.
begin;
set local lock_timeout = '10s';

create schema if not exists recap_private;
revoke all on schema recap_private from public, anon, authenticated;

create table recap_private.periods (
  id text primary key,
  label text not null,
  begins_at timestamptz not null,
  statistics_cutoff timestamptz not null,
  publishes_at timestamptz not null,
  finalizes_at timestamptz not null,
  comparison_label text,
  configuration jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  check (begins_at < statistics_cutoff),
  check (statistics_cutoff <= publishes_at),
  check (publishes_at <= finalizes_at)
);

create table recap_private.period_reference_snapshots (
  period_id text primary key references recap_private.periods(id) on delete cascade,
  payload jsonb not null
);

create table recap_private.period_personal_baselines (
  period_id text not null references recap_private.periods(id) on delete cascade,
  player_id uuid not null,
  payload jsonb not null,
  primary key (period_id, player_id)
);

create table recap_private.period_snapshots (
  period_id text not null references recap_private.periods(id) on delete cascade,
  source text not null,
  key text not null,
  data jsonb not null,
  captured_at timestamptz not null default clock_timestamp(),
  primary key (period_id, source, key)
);

create table recap_private.period_record_candidates (
  period_id text not null references recap_private.periods(id) on delete cascade,
  player_id uuid not null,
  category text not null check (category in ('displayed','raw','value','weight','mutations','combo')),
  score numeric not null,
  rarity numeric not null,
  occurred_at timestamptz not null,
  source_id bigint not null,
  data jsonb not null,
  primary key (period_id, player_id, category)
);

create index period_record_candidates_global_order
  on recap_private.period_record_candidates
  (period_id, category, score desc, rarity desc, occurred_at desc, source_id desc);

create table recap_private.period_cache (
  period_id text primary key references recap_private.periods(id) on delete cascade,
  generated_at timestamptz not null,
  final boolean not null default false,
  payload jsonb not null
);

create table recap_private.anniversary_intro_views (
  period_id text not null references recap_private.periods(id) on delete cascade,
  player_id uuid not null,
  seen_at timestamptz not null default clock_timestamp(),
  primary key (period_id, player_id)
);

alter table recap_private.periods enable row level security;
alter table recap_private.period_reference_snapshots enable row level security;
alter table recap_private.period_personal_baselines enable row level security;
alter table recap_private.period_snapshots enable row level security;
alter table recap_private.period_record_candidates enable row level security;
alter table recap_private.period_cache enable row level security;
alter table recap_private.anniversary_intro_views enable row level security;

insert into recap_private.periods (
  id, label, begins_at, statistics_cutoff, publishes_at, finalizes_at,
  comparison_label, configuration
) values (
  'month-2', 'Month Two',
  '2026-09-07 16:00:00+00', '2026-10-07 16:00:00+00',
  '2026-10-07 16:00:00+00', '2026-10-08 16:00:00+00',
  'Month One',
  jsonb_build_object(
    'timezone', 'Asia/Singapore',
    'weightLabel', 'Heaviest Recorded Roll',
    'weightCoverageStartsAt', '2026-09-11T00:38:32.331827+00:00',
    'mutationTotalsComplete', false,
    'footer', 'TWO MONTHS DOWN. KEEP ROLLING.'
  )
)
on conflict (id) do nothing;

-- The frozen cache is the only truthful Sep 8 baseline. Do not reconstruct it
-- from today's players or operational history tables.
insert into recap_private.period_reference_snapshots(period_id, payload)
select 'month-2', payload->'global'
from month_one_private.cache
where singleton and final
on conflict (period_id) do nothing;

insert into recap_private.period_personal_baselines(period_id, player_id, payload)
select 'month-2', entry.key::uuid, entry.value
from month_one_private.cache c
cross join lateral jsonb_each(c.payload->'personal') entry
where c.singleton and c.final
on conflict (period_id, player_id) do nothing;

do $$
begin
  if not exists (select 1 from recap_private.period_reference_snapshots where period_id='month-2')
     or (select count(*) from recap_private.period_personal_baselines where period_id='month-2') <> 124 then
    raise exception 'The frozen Month One cache is missing or no longer contains its 124-player baseline.';
  end if;
end $$;

create function recap_private.record_candidates(h jsonb, weight_only boolean default false)
returns table(category text, score numeric, rarity numeric, occurred_at timestamptz, source_id bigint, data jsonb)
language sql immutable set search_path = '' as $$
  with parsed as (
    select coalesce((h->>'rarity')::numeric,(h->>'base_rarity')::numeric,0) as r,
      greatest(0.000001::numeric,coalesce((h->>'raw_luck')::numeric,1)) as luck,
      coalesce(nullif(h->'mutation_ids','null'::jsonb),'[]'::jsonb) as mutations,
      coalesce((h->>'effective_rarity')::numeric,
        coalesce((h->>'rarity')::numeric,(h->>'base_rarity')::numeric,0)) as effective_rarity
  )
  select candidate.category, candidate.score, parsed.r,
    (h->>'created_at')::timestamptz,
    coalesce((h->>'source_id')::bigint,(h->>'id')::bigint,(h->>'roll_number')::bigint,0),
    jsonb_build_object(
      'gem',h->>'gem_name','rarity',parsed.r,'luck',case when weight_only then null else parsed.luck end,
      'mutations',parsed.mutations,'value',nullif(h->>'value','')::numeric,
      'weight',nullif(h->>'final_weight','')::numeric,
      'rawRarity',greatest(1::numeric,parsed.r/parsed.luck),
      'at',h->>'created_at','recorded',true
    )
  from parsed
  cross join lateral (values
    ('displayed', parsed.r, not weight_only),
    ('raw', greatest(1::numeric,parsed.r/parsed.luck), not weight_only),
    ('value', coalesce(nullif(h->>'value','')::numeric,0), not weight_only),
    ('mutations', jsonb_array_length(parsed.mutations)::numeric, not weight_only),
    ('combo', coalesce(parsed.effective_rarity/nullif(parsed.r,0),1), not weight_only),
    ('weight', coalesce(nullif(h->>'final_weight','')::numeric,0), weight_only)
  ) candidate(category,score,enabled)
  where candidate.enabled
    and parsed.r > 0
    and h->>'gem_name' not in ('Enchant Relic','Ancient Relic')
    and (candidate.category not in ('mutations','combo') or jsonb_array_length(parsed.mutations)>0)
$$;

create function recap_private.upsert_candidate(
  p_period text, p_player uuid, p_history jsonb, p_weight_only boolean default false
) returns void
language sql volatile set search_path = '' as $$
  insert into recap_private.period_record_candidates(
    period_id,player_id,category,score,rarity,occurred_at,source_id,data
  )
  select p_period,p_player,c.category,c.score,c.rarity,c.occurred_at,c.source_id,c.data
  from recap_private.record_candidates(p_history,p_weight_only) c
  on conflict(period_id,player_id,category) do update set
    score=excluded.score,rarity=excluded.rarity,occurred_at=excluded.occurred_at,
    source_id=excluded.source_id,data=excluded.data
  where (excluded.score,excluded.rarity,excluded.occurred_at,excluded.source_id) >
    (period_record_candidates.score,period_record_candidates.rarity,
     period_record_candidates.occurred_at,period_record_candidates.source_id)
$$;

-- Called from the already-authoritative critical bookkeeping transaction.
-- This sees every accepted primary roll, including auto-sold/deposited rolls;
-- it does not depend on retained inventory or truncated leaderboard history.
create function recap_private.capture_roll(p_player uuid, p_payload jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  period_row recap_private.periods;
  captured_at timestamptz := clock_timestamp();
  history jsonb;
begin
  if coalesce(current_setting('request.jwt.claim.role',true),'') <> 'service_role' then
    raise exception 'service_role_required' using errcode='42501';
  end if;
  history := jsonb_build_object(
    'gem_name',p_payload->>'gemName','rarity',p_payload->>'rarity',
    'raw_luck',p_payload->>'rawLuck','effective_rarity',p_payload->>'effectiveRarity',
    'final_weight',p_payload->>'finalWeight','value',p_payload->>'value',
    'mutation_ids',coalesce(p_payload->'mutationIds','[]'::jsonb),
    'created_at',captured_at,'source_id',p_payload->>'rollNumber'
  );
  for period_row in
    select * from recap_private.periods
    where captured_at >= begins_at and captured_at < statistics_cutoff
    order by id
  loop
    perform pg_advisory_xact_lock_shared(7022026,hashtext(period_row.id));
    if clock_timestamp() < period_row.statistics_cutoff then
      perform recap_private.upsert_candidate(period_row.id,p_player,history,false);
      perform recap_private.upsert_candidate(period_row.id,p_player,history,true);
    end if;
  end loop;
end $$;

create function recap_private.capture_source() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  period_row recap_private.periods;
  row_data jsonb;
  row_key text;
  captured_at timestamptz := clock_timestamp();
begin
  row_data := case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  row_key := row_data->>tg_argv[0];
  for period_row in
    select * from recap_private.periods
    where captured_at < statistics_cutoff
    order by id
  loop
    perform pg_advisory_xact_lock_shared(7022026,hashtext(period_row.id));
    if clock_timestamp() < period_row.statistics_cutoff then
      if tg_op='DELETE' then
        delete from recap_private.period_snapshots
        where period_id=period_row.id and source=tg_table_name and key=row_key;
      else
        insert into recap_private.period_snapshots(period_id,source,key,data,captured_at)
        values(period_row.id,tg_table_name,row_key,row_data,clock_timestamp())
        on conflict(period_id,source,key) do update
          set data=excluded.data,captured_at=excluded.captured_at;
      end if;
    end if;
  end loop;
  return null;
end $$;

create function recap_private.seed_period(p_period text) returns void
language plpgsql set search_path = '' as $$
declare
  period_row recap_private.periods;
  source_row record;
begin
  select * into strict period_row from recap_private.periods where id=p_period;
  if clock_timestamp() >= period_row.statistics_cutoff then
    raise exception 'recap_period_already_closed';
  end if;
  perform pg_advisory_xact_lock(7022026,hashtext(period_row.id));
  for source_row in select * from (values
    ('players','id'),('bank_accounts','player_id'),
    ('system_account_exclusions','player_id'),('minigame_scores','run_id')
  ) v(table_name,key_name)
  loop
    execute format(
      'insert into recap_private.period_snapshots(period_id,source,key,data) '
      'select $1,%L,%I::text,to_jsonb(s) from public.%I s '
      'on conflict(period_id,source,key) do update set data=excluded.data,captured_at=clock_timestamp()',
      source_row.table_name,source_row.key_name,source_row.table_name
    ) using period_row.id;
  end loop;
end $$;

-- Install one reusable set of source triggers. New periods only need a period
-- row, baselines/reference snapshot, and seed_period(); no Month-N schema fork.
-- Take the same lock mode CREATE OR REPLACE TRIGGER needs up front. Do not use
-- DROP TRIGGER here: DROP upgrades this live-table lock to ACCESS EXCLUSIVE and
-- can deadlock with a roll transaction that has read players and is about to
-- write it.
lock table public.players, public.bank_accounts, public.system_account_exclusions,
  public.minigame_scores in share row exclusive mode;
select recap_private.seed_period('month-2');

create or replace trigger recap_period_capture after insert or update or delete on public.players
for each row execute function recap_private.capture_source('id');
create or replace trigger recap_period_capture after insert or update or delete on public.bank_accounts
for each row execute function recap_private.capture_source('player_id');
create or replace trigger recap_period_capture after insert or update or delete on public.system_account_exclusions
for each row execute function recap_private.capture_source('player_id');
create or replace trigger recap_period_capture after insert or update or delete on public.minigame_scores
for each row execute function recap_private.capture_source('run_id');

-- Best-effort historical candidate bootstrap. These operational tables are
-- explicitly not treated as complete roll ledgers; capture_roll is the durable
-- source from this migration onward.
do $$
declare h record;
begin
  for h in
    select to_jsonb(history) as data,history.player_id
    from public.best_roll_history history
    where history.created_at >= '2026-09-07 16:00:00+00'
      and history.created_at < '2026-10-07 16:00:00+00'
  loop
    perform recap_private.upsert_candidate('month-2',h.player_id,h.data,false);
  end loop;
  for h in
    select to_jsonb(history) as data,history.player_id
    from public.roll_weight_history history
    where history.created_at >= '2026-09-07 16:00:00+00'
      and history.created_at < '2026-10-07 16:00:00+00'
  loop
    perform recap_private.upsert_candidate('month-2',h.player_id,h.data,true);
  end loop;
end $$;

create function recap_private.build(p_period text) returns jsonb
language sql stable set search_path = '' as $$
with period as materialized (
  select * from recap_private.periods where id=p_period
), reference as materialized (
  select payload from recap_private.period_reference_snapshots where period_id=p_period
), eligible_base as materialized (
  select snapshot.key::uuid as id,snapshot.data->>'username' as username,
    (snapshot.data->>'created_at')::timestamptz as joined,
    coalesce((snapshot.data->>'total_rolls')::numeric,0) as lifetime_rolls,
    coalesce((snapshot.data->>'lifetime_earnings')::numeric,0) as lifetime_earned,
    coalesce((snapshot.data->>'lifetime_money_burned')::numeric,0) as lifetime_burned,
    coalesce((snapshot.data->>'money')::numeric,0) as money,
    baseline.payload as baseline,
    baseline.player_id is not null as has_baseline
  from recap_private.period_snapshots snapshot
  cross join period
  left join recap_private.period_personal_baselines baseline
    on baseline.period_id=p_period and baseline.player_id=snapshot.key::uuid
  where snapshot.period_id=p_period and snapshot.source='players'
    and snapshot.data->>'username' is not null
    and not coalesce((snapshot.data->>'leaderboard_hidden')::boolean,false)
    and (snapshot.data->>'created_at')::timestamptz < period.statistics_cutoff
    and not exists (
      select 1 from recap_private.period_snapshots excluded
      where excluded.period_id=p_period and excluded.source='system_account_exclusions'
        and excluded.key=snapshot.key
    )
), eligible as materialized (
  select *,
    greatest(0,lifetime_rolls-coalesce((baseline->>'rolls')::numeric,0)) as period_rolls,
    greatest(0,lifetime_earned-coalesce((baseline->>'earned')::numeric,0)) as period_earned,
    greatest(0,lifetime_burned-coalesce((baseline->>'burned')::numeric,0)) as period_burned,
    row_number() over(order by joined,id) as calculated_join_number
  from eligible_base
), ranked as materialized (
  select *,rank() over(order by period_rolls desc) as roll_rank,
    rank() over(order by period_earned desc) as earnings_rank,
    count(*) over() as population
  from eligible
), records as materialized (
  select candidate.*,eligible.username,
    candidate.data || jsonb_build_object('username',eligible.username,'score',candidate.score) as card
  from recap_private.period_record_candidates candidate
  join eligible on eligible.id=candidate.player_id
  where candidate.period_id=p_period
), games as materialized (
  select snapshot.data->>'game' as game,snapshot.data->>'player_id' as player_id,
    (snapshot.data->>'score')::numeric as score,(snapshot.data->>'tie1')::numeric as tie1,
    (snapshot.data->>'tie2')::numeric as tie2,
    (snapshot.data->>'achieved_at')::timestamptz as achieved_at,
    snapshot.key as run_id,eligible.username
  from recap_private.period_snapshots snapshot
  join eligible on eligible.id::text=snapshot.data->>'player_id'
  cross join period
  where snapshot.period_id=p_period and snapshot.source='minigame_scores'
    and (snapshot.data->>'achieved_at')::timestamptz >= period.begins_at
    and (snapshot.data->>'achieved_at')::timestamptz < period.statistics_cutoff
), game_bests as materialized (
  select distinct on(game,player_id) * from games
  order by game,player_id,score desc,tie1 desc,tie2 desc,achieved_at,run_id
), game_rankings as materialized (
  select *,row_number() over(partition by game order by score desc,tie1 desc,tie2 desc,achieved_at,run_id) as ranking,
    count(*) over(partition by game) as participants
  from game_bests
), totals as materialized (
  select count(*) as players,count(*) filter(where period_rolls>0) as active_players,
    count(*) filter(where joined >= (select begins_at from period)) as new_players,
    coalesce(sum(period_rolls),0) as rolls,coalesce(sum(period_earned),0) as earned,
    coalesce(sum(period_burned),0) as burned,
    coalesce(sum(lifetime_rolls),0) as lifetime_rolls,
    coalesce(sum(lifetime_earned),0) as lifetime_earned,
    coalesce(sum(lifetime_burned),0) as lifetime_burned,
    coalesce(percentile_cont(0.5) within group(order by period_rolls),0) as median_rolls,
    count(*) filter(where period_rolls>=1000) as rollers_1k,
    count(*) filter(where period_rolls>=10000) as rollers_10k,
    count(*) filter(where period_rolls>=100000) as rollers_100k
  from eligible
)
select jsonb_build_object(
  'period',jsonb_build_object(
    'id',period.id,'label',period.label,'beginsAt',period.begins_at,
    'statisticsCutoff',period.statistics_cutoff,'publishesAt',period.publishes_at,
    'finalizesAt',period.finalizes_at,'comparisonLabel',period.comparison_label,
    'configuration',period.configuration
  ),
  'global',jsonb_build_object(
    'totals',(select to_jsonb(t) from totals t),
    'monthOne',(select payload from reference),
    'topRollers',(select coalesce(jsonb_agg(jsonb_build_object(
      'username',username,'rolls',period_rolls,'rollRank',roll_rank) order by period_rolls desc,id),'[]'::jsonb)
      from (select * from ranked order by period_rolls desc,id limit 10) leaders),
    'topTenShare',(select coalesce(100*sum(period_rolls)/nullif((select rolls from totals),0),0)
      from (select period_rolls from eligible order by period_rolls desc,id limit 10) leaders),
    'records',(select coalesce(jsonb_object_agg(category,card),'{}'::jsonb) from (
      select distinct on(category) category,card from records
      order by category,score desc,rarity desc,occurred_at desc,source_id desc
    ) winners),
    'discoveries',(select coalesce(jsonb_agg(card order by score desc,rarity desc,occurred_at desc,source_id desc),'[]'::jsonb)
      from (select * from records where category='displayed' order by score desc,rarity desc,occurred_at desc,source_id desc limit 5) discoveries),
    'richest',(select jsonb_build_object('username',username,'money',money)
      from eligible order by money desc,id limit 1),
    'banked',(select coalesce(sum((snapshot.data->>'balance')::numeric),0)
      from recap_private.period_snapshots snapshot join eligible on eligible.id::text=snapshot.key
      where snapshot.period_id=p_period and snapshot.source='bank_accounts'),
    'minigameRuns',(select count(*) from games),
    'minigamePlayers',(select count(distinct player_id) from games),
    'minigames',(select coalesce(jsonb_agg(to_jsonb(summary) order by summary.runs desc,summary.game),'[]'::jsonb) from (
      select games.game,count(*) as runs,count(distinct games.player_id) as players,
        winner.username as best_player,winner.score as best_score,
        winner.tie1 as best_tie1,winner.tie2 as best_tie2
      from games
      left join lateral (
        select * from game_rankings ranked_game where ranked_game.game=games.game order by ranking limit 1
      ) winner on true
      group by games.game,winner.username,winner.score,winner.tie1,winner.tie2
    ) summary)
  ),
  'personal',(select coalesce(jsonb_object_agg(player.id::text,jsonb_build_object(
    'username',player.username,'joined',player.joined,
    'joinNumber',case when player.has_baseline then (player.baseline->>'joinNumber')::numeric else player.calculated_join_number end,
    'newPlayer',not player.has_baseline,
    'monthTwoRolls',player.period_rolls,'lifetimeRolls',player.lifetime_rolls,
    'monthTwoEarned',player.period_earned,'lifetimeEarned',player.lifetime_earned,
    'monthTwoBurned',player.period_burned,'lifetimeBurned',player.lifetime_burned,
    'population',player.population,'rollRank',player.roll_rank,'earningsRank',player.earnings_rank,
    'rollTopPercent',ceil(100.0*player.roll_rank/nullif(player.population,0)),
    'earningsTopPercent',ceil(100.0*player.earnings_rank/nullif(player.population,0)),
    'rollShare',coalesce(100*player.period_rolls/nullif((select rolls from totals),0),0),
    'monthOne',case when player.has_baseline then jsonb_build_object(
      'rolls',player.baseline->'rolls','earned',player.baseline->'earned','burned',player.baseline->'burned',
      'rollRank',player.baseline->'rollRank','earningsRank',player.baseline->'earningsRank',
      'records',coalesce(player.baseline->'records','{}'::jsonb)
    ) else null end,
    'highestDisplayed',(select card from records where player_id=player.id and category='displayed'),
    'rawRare',(select card from records where player_id=player.id and category='raw'),
    'records',(select coalesce(jsonb_object_agg(category,card),'{}'::jsonb) from records
      where player_id=player.id),
    'minigames',(select coalesce(jsonb_agg(to_jsonb(personal_game) order by personal_game.runs desc,personal_game.game),'[]'::jsonb) from (
      select game,count(*) as runs,
        (select score from game_rankings where game=played.game and player_id=player.id::text) as best_score,
        (select tie1 from game_rankings where game=played.game and player_id=player.id::text) as best_tie1,
        (select tie2 from game_rankings where game=played.game and player_id=player.id::text) as best_tie2,
        (select ranking from game_rankings where game=played.game and player_id=player.id::text) as rank,
        (select participants from game_rankings where game=played.game and player_id=player.id::text) as participants
      from games played where played.player_id=player.id::text group by game
    ) personal_game)
  )),'{}'::jsonb) from ranked player)
)
from period
$$;

create function public.get_recap_period(p_period text default 'month-2') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  period_row recap_private.periods;
  cached recap_private.period_cache;
  server_time timestamptz := clock_timestamp();
begin
  select * into period_row from recap_private.periods where id=p_period;
  if not found then raise exception 'unknown_recap_period'; end if;
  if server_time < period_row.publishes_at then
    return jsonb_build_object(
      'status','upcoming','serverTime',server_time,'period',jsonb_build_object(
        'id',period_row.id,'label',period_row.label,'beginsAt',period_row.begins_at,
        'statisticsCutoff',period_row.statistics_cutoff,'publishesAt',period_row.publishes_at,
        'finalizesAt',period_row.finalizes_at));
  end if;
  select * into cached from recap_private.period_cache where period_id=p_period;
  if cached.period_id is null or (not cached.final and
     (server_time >= period_row.finalizes_at or cached.generated_at <= server_time-interval '45 seconds')) then
    perform pg_advisory_xact_lock(7022026,hashtext(period_row.id));
    server_time := clock_timestamp();
    select * into cached from recap_private.period_cache where period_id=p_period;
    if cached.period_id is null or (not cached.final and
       (server_time >= period_row.finalizes_at or cached.generated_at <= server_time-interval '45 seconds')) then
      insert into recap_private.period_cache(period_id,generated_at,final,payload)
      values(period_row.id,server_time,server_time>=period_row.finalizes_at,recap_private.build(period_row.id))
      on conflict(period_id) do update set generated_at=excluded.generated_at,
        final=excluded.final,payload=excluded.payload
      where not recap_private.period_cache.final
      returning * into cached;
      if cached.period_id is null then
        select * into cached from recap_private.period_cache where period_id=p_period;
      end if;
    end if;
  end if;
  return jsonb_build_object(
    'status',case when cached.final then 'final' else 'finalizing' end,
    'serverTime',server_time,'asOf',least(cached.generated_at,period_row.statistics_cutoff),
    'refreshSeconds',case when cached.final then null else 45 end,
    'period',cached.payload->'period','global',cached.payload->'global',
    'personal',cached.payload->'personal'->(auth.uid()::text)
  );
end $$;

-- Atomic auto-play claim. Replay bypasses the one-time claim but never causes
-- the automatic presentation to reappear on another browser/device.
create function public.get_month_two_anniversary_intro(p_replay boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_player_id uuid := auth.uid();
  server_time timestamptz := clock_timestamp();
  period_row recap_private.periods;
  claimed uuid;
  active boolean;
  community_rolls numeric;
begin
  select * into period_row from recap_private.periods where id='month-2';
  active := server_time >= period_row.statistics_cutoff and server_time < period_row.finalizes_at;
  if v_player_id is null then
    return jsonb_build_object('show',false,'active',active,'serverTime',server_time);
  end if;
  if not coalesce(p_replay,false) then
    if not active then return jsonb_build_object('show',false,'active',false,'serverTime',server_time); end if;
    insert into recap_private.anniversary_intro_views(period_id,player_id)
    values('month-2',v_player_id) on conflict do nothing
    returning recap_private.anniversary_intro_views.player_id into claimed;
    if claimed is null then
      return jsonb_build_object('show',false,'active',true,'serverTime',server_time);
    end if;
  elsif server_time < period_row.statistics_cutoff then
    return jsonb_build_object('show',false,'active',false,'serverTime',server_time);
  end if;
  if active then
    select coalesce(sum(p.total_rolls),0) into community_rolls
    from public.players p
    where p.username is not null and not coalesce(p.leaderboard_hidden,false)
      and not exists(select 1 from public.system_account_exclusions e where e.player_id=p.id);
  else
    select coalesce((payload#>>'{global,totals,lifetime_rolls}')::numeric,4714512)
    into community_rolls from recap_private.period_cache where period_id='month-2';
    community_rolls := coalesce(community_rolls,4714512);
  end if;
  return jsonb_build_object(
    'show',true,'replay',coalesce(p_replay,false),'active',active,'serverTime',server_time,
    'monthOneRolls',4714512,'communityRolls',community_rolls,
    'recapPath','recap/month-2/'
  );
end $$;

-- Extend the deployed optimized bookkeeping function in place. The migration
-- refuses to guess if the expected current structure has changed.
do $migration$
declare
  function_oid regprocedure := 'public.roll_finish_bookkeeping(uuid,text,jsonb)'::regprocedure;
  definition text;
  rewritten text;
  needle constant text := E'    return jsonb_build_object(\n      \'lifetimeStats\', v_lifetime,';
  replacement constant text := E'    begin\n      perform recap_private.capture_roll(p_player_id,p_payload);\n    exception when others then v_errors := v_errors || jsonb_build_array(\'recap:\' || sqlstate); end;\n\n    return jsonb_build_object(\n      \'lifetimeStats\', v_lifetime,';
begin
  select pg_get_functiondef(function_oid) into definition;
  rewritten := replace(definition,needle,replacement);
  if rewritten=definition then
    raise exception 'Current optimized roll_finish_bookkeeping structure was not recognized; refusing to replace it.';
  end if;
  execute rewritten;
end
$migration$;

revoke all on function recap_private.capture_roll(uuid,jsonb) from public,anon,authenticated;
grant execute on function recap_private.capture_roll(uuid,jsonb) to service_role;
revoke all on function public.roll_finish_bookkeeping(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.roll_finish_bookkeeping(uuid,text,jsonb) to service_role;

-- Duolite is catalog-driven, so the optimized roll Edge Function continues to
-- use its current luck, weight and value formulas. Its Date is constructed on
-- the server; browser clocks never decide eligibility.
insert into public.private_feature_gems(
  name,title,rarity,base_weight,value_per_gram,description,metadata,
  hide_rarity_until_discovered,affected_by_luck,enabled,sort_order,
  starts_at,ends_at,availability_mode,availability_timezone,special_gem
) values (
  'Duolite','Duolite',2020026,202,2026,
  'Two crystal halves held in one formation. Available only during the second-month anniversary.',
  jsonb_build_object(
    'indexMarker','LIMITED • MONTH TWO 2026',
    'historicalAvailability','8 October 2026, 00:00–24:00 SGT',
    'anniversary','month-2','limited',true
  ),
  false,true,true,2026,
  '2026-10-07 16:00:00+00','2026-10-08 16:00:00+00',
  'date_range','Asia/Singapore',false
)
on conflict(name) do update set
  title=excluded.title,rarity=excluded.rarity,base_weight=excluded.base_weight,
  value_per_gram=excluded.value_per_gram,description=excluded.description,
  metadata=excluded.metadata,hide_rarity_until_discovered=excluded.hide_rarity_until_discovered,
  affected_by_luck=excluded.affected_by_luck,enabled=excluded.enabled,
  sort_order=excluded.sort_order,starts_at=excluded.starts_at,ends_at=excluded.ends_at,
  availability_mode=excluded.availability_mode,
  availability_timezone=excluded.availability_timezone,special_gem=excluded.special_gem,
  updated_at=clock_timestamp();

revoke all on all tables in schema recap_private from public,anon,authenticated;
revoke all on all functions in schema recap_private from public,anon,authenticated;
revoke all on function public.get_recap_period(text) from public;
grant execute on function public.get_recap_period(text) to anon,authenticated;
revoke all on function public.get_month_two_anniversary_intro(boolean) from public,anon;
grant execute on function public.get_month_two_anniversary_intro(boolean) to authenticated;

comment on schema recap_private is
  'Reusable server-authoritative recap periods. Private snapshots, baselines, candidates and immutable caches.';
comment on table recap_private.period_record_candidates is
  'Best candidate per player/category/period, ordered by score, rarity, occurred_at, then source_id.';

commit;
