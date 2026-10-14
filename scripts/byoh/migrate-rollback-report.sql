-- What the packaged control plane did after the cutover, for the operator
-- to review before the development control plane starts again on its
-- database as it was at the cutover. scripts/byoh/migrate-from-dev.sh
-- rollback runs it as postgres on database ubicloud, with
-- -v cutover='<UTC timestamp of the copy>'. Strands have no creation
-- time; rollback compares their ids with the development database.

\set ON_ERROR_STOP 1
\pset footer off

\echo 'VMs created after the cutover (they do not exist in the development database; destroy them or record them):'
SELECT v.id, v.name, v.display_state, v.vm_host_id, v.created_at
FROM vm v WHERE v.created_at > :'cutover'::timestamptz ORDER BY v.created_at;

\echo 'Pages opened after the cutover:'
SELECT p.created_at, p.summary, p.resolved_at
FROM page p WHERE p.created_at > :'cutover'::timestamptz ORDER BY p.created_at;

\echo 'Hosts and the label of their strand now (compare with the development database below):'
SELECT h.id, h.allocation_state, s.label
FROM vm_host h LEFT JOIN strand s ON s.id = h.id ORDER BY h.id;
