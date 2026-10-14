-- Prints "table<TAB>rows" for every ordinary table in schema public
-- (partitions included, partitioned parents not, so no row counts
-- twice), sorted. scripts/byoh/migrate-from-dev.sh copy-db runs it as
-- postgres on the development database right after pg_dump and on the
-- restored copy before its pending migrations, and compares the two.

\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
\pset fieldsep '\t'

SELECT coalesce(string_agg(format('SELECT %L AS t, count(*) AS n FROM public.%I', c.relname, c.relname), ' UNION ALL ' ORDER BY c.relname),
  'SELECT NULL::text AS t, NULL::bigint AS n WHERE false') AS q
FROM pg_class c
WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' \gset

SELECT t, n FROM (:q) s ORDER BY t;
