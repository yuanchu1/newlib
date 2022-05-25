-- start_matchsubs
--# psql 9 changes now shows username on connection. Ignore the added username.
--m/^You are now connected to database/
--s/ as user ".+"//
-- end_matchsubs

-- Ensure that our expectation of pg_statistic's schema is up-to-date
\d+ pg_statistic

--------------------------------------------------------------------------------
-- Scenario: Table without hll flag
--------------------------------------------------------------------------------

-- start_ignore
drop database if exists gpsd_db_without_hll;
-- end_ignore
create database gpsd_db_without_hll;
\c gpsd_db_without_hll

create table gpsd_foo(a int, s text) partition by range(a);
create table gpsd_foo_1 partition of gpsd_foo for values from (1) to (5);
insert into gpsd_foo values(1, 'something');
insert into gpsd_foo values(2, chr(1000));
insert into gpsd_foo values(3, chr(105));
insert into gpsd_foo values(4, 'a \ and a "');
analyze gpsd_foo;

-- arbitrarily populate stats data values having text (with quotes) in a slot
-- (without paying heed to the slot's stakind) to test dumpability
set allow_system_table_mods to on;
update pg_statistic set stavalues3='{"hello", "''world''"}'::text[] where starelid='gpsd_foo'::regclass and staattnum=2;

-- start_ignore
\! PYTHONIOENCODING=utf-8 gpsd gpsd_db_without_hll > data/gpsd-without-hll.sql
-- end_ignore

\c regression
drop database gpsd_db_without_hll;
create database gpsd_db_without_hll;

-- start_ignore
\! psql -f data/gpsd-without-hll.sql gpsd_db_without_hll
-- end_ignore
\c gpsd_db_without_hll

select
    staattnum,
    stainherit,
    stanullfrac,
    stawidth,
    stadistinct,
    stakind1,
    stakind2,
    stakind3,
    stakind4,
    stakind5,
    staop1,
    staop2,
    staop3,
    staop4,
    staop5,
    stacoll1,
    stacoll2,
    stacoll3,
    stacoll4,
    stacoll5,
    stanumbers1,
    stanumbers2,
    stanumbers3,
    stanumbers4,
    stanumbers5,
    stavalues1,
    stavalues2,
    stavalues3,
    stavalues4,
    stavalues5
from pg_statistic where starelid IN ('gpsd_foo'::regclass, 'gpsd_foo_1'::regclass);

--------------------------------------------------------------------------------
-- Scenario: Table with hll flag
--------------------------------------------------------------------------------

-- start_ignore
drop database if exists gpsd_db_with_hll;
-- end_ignore
create database gpsd_db_with_hll;
\c gpsd_db_with_hll

create table gpsd_foo(a int, s text) partition by range(a);
create table gpsd_foo_1 partition of gpsd_foo for values from (1) to (5);
insert into gpsd_foo values(1, 'something');
analyze gpsd_foo;

-- arbitrarily populate stats data values having text (with quotes) in a slot
-- (without paying heed to the slot's stakind) to test dumpability
set allow_system_table_mods to on;
update pg_statistic set stavalues3='{"hello", "''world''"}'::text[] where starelid='gpsd_foo'::regclass and staattnum=2;

-- start_ignore
\! PYTHONIOENCODING=utf-8 gpsd gpsd_db_with_hll --hll > data/gpsd-with-hll.sql
-- end_ignore

\c regression
drop database gpsd_db_with_hll;
create database gpsd_db_with_hll;

-- start_ignore
\! psql -f data/gpsd-with-hll.sql gpsd_db_with_hll
-- end_ignore
\c gpsd_db_with_hll

select
    staattnum,
    stainherit,
    stanullfrac,
    stawidth,
    stadistinct,
    stakind1,
    stakind2,
    stakind3,
    stakind4,
    stakind5,
    staop1,
    staop2,
    staop3,
    staop4,
    staop5,
    stacoll1,
    stacoll2,
    stacoll3,
    stacoll4,
    stacoll5,
    stanumbers1,
    stanumbers2,
    stanumbers3,
    stanumbers4,
    stanumbers5,
    stavalues1,
    stavalues2,
    stavalues3,
    stavalues4,
    stavalues5
from pg_statistic where starelid IN ('gpsd_foo'::regclass, 'gpsd_foo_1'::regclass);
