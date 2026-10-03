# Economy cash-ledger compaction

`public.economy_cash_ledger` reached roughly 8.1 million rows and 3.26 GB on
2026-10-03. More than 99% of the rows were gem-sale balance events. Migration
`20261003005215_compact_economy_cash_ledger.sql` keeps the audit trail while
making the operational table bounded.

## What is preserved

- The newest eight complete days remain as ordinary ledger rows. This covers
  the longest anti-cheat window (168 hours) with an additional partial-day
  margin.
- Every older gem-sale row is stored in an ordered, checksummed JSONB archive
  chunk. The archive contains every original column and uses PostgreSQL TOAST
  compression.
- Per-player/day rollups retain amount, credited/debited totals, event count,
  first/last IDs, and first/last timestamps for efficient All-time reports.
- Reviewed correction rows and every non-gem-sale category remain individually
  addressable in the original ledger.
- `admin_get_economy_breakdown('All')` and All-time lottery ratios combine the
  rollups with the remaining raw rows, so their totals and event counts do not
  change.

The archive is private, RLS-protected, and unavailable to `anon`,
`authenticated`, and `service_role`, like the original private accounting
tables.

## Deployment and catch-up

Deploy the migration yourself. It does not archive millions of rows inside the
migration transaction. Instead, its named `pg_cron` job archives up to 10,000
rows per minute in an atomic batch. At the measured backlog of about 4.86
million eligible rows, catch-up should take roughly eight hours; live load can
change that estimate.

Monitor progress in the SQL editor:

```sql
select
  (select count(*) from public.economy_cash_ledger) as raw_rows,
  (select coalesce(sum(event_count), 0)
     from economy_private.cash_ledger_archive_chunks) as archived_rows,
  (select count(*) from economy_private.cash_ledger_daily_rollups) as rollup_rows,
  (select min(created_at) from public.economy_cash_ledger
     where category = 'gem_sales' and player_id is not null) as oldest_raw_gem_sale;
```

The job is caught up when `oldest_raw_gem_sale` is within the retained window.
The function can also be run manually; concurrent attempts return `busy` and
do not duplicate data:

```sql
select economy_private.compact_cash_ledger_batch();
```

## Reclaiming disk space

Batch deletion makes old heap and index pages reusable, but PostgreSQL does not
immediately return them to the filesystem. After catch-up, run the following in
a quiet maintenance window:

```sql
vacuum (full, analyze) public.economy_cash_ledger;
```

`VACUUM FULL` takes an exclusive table lock and temporarily needs extra disk
space. Do not run it during active gameplay. Regular autovacuum is sufficient
if reusable space is acceptable and an immediate decrease in the dashboard's
reported relation size is not required.

## Exact archive inspection

Database owners can recover a bounded ID range without expanding the entire
archive:

```sql
select *
from economy_private.read_archived_cash_ledger(100000, 101000, 1000);
```

The returned columns match `public.economy_cash_ledger`. Archive chunk
integrity is enforced by row count and payload checksum constraints.
