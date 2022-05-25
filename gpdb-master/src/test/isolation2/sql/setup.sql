create or replace language plpython3u;

-- Helper function, to call either __gp_aoseg, or gp_aocsseg, depending
-- on whether the table is row- or column-oriented. This allows us to
-- run the same test queries on both.
--
-- The Python utility that runs this doesn't know about dollar-quoting,
-- and thinks that a ';' at end of line ends the command. The /* in func */
-- comments at the end of each line thwarts that.
CREATE OR REPLACE FUNCTION gp_ao_or_aocs_seg(rel regclass,
  segment_id OUT integer,
  segno OUT integer,
  tupcount OUT bigint,
  modcount OUT bigint,
  formatversion OUT smallint,
  state OUT smallint)
RETURNS SETOF record as $$
declare
  amname_var text;	/* in func */
begin	/* in func */
  select amname into amname_var from pg_class c, pg_am am where c.relam = am.oid and c.oid = rel; /* in func */
  if amname_var = 'ao_column' then	/* in func */
    for segment_id, segno, tupcount, modcount, formatversion, state in SELECT DISTINCT x.segment_id, x.segno, x.tupcount, x.modcount, x.formatversion, x.state FROM gp_toolkit.__gp_aocsseg(rel) x loop	/* in func */
      return next;	/* in func */
    end loop;	/* in func */
  elsif amname_var = 'ao_row' then	/* in func */
    for segment_id, segno, tupcount, modcount, formatversion, state in SELECT x.segment_id, x.segno, x.tupcount, x.modcount, x.formatversion, x.state FROM gp_toolkit.__gp_aoseg(rel) x loop	/* in func */
      return next;	/* in func */
    end loop;	/* in func */
  else	/* in func */
    raise '% is not an AO_ROW or AO_COLUMN table', rel::text;	/* in func */
  end if;	/* in func */
end;	/* in func */
$$ LANGUAGE plpgsql;

-- Show locks in master and in segments. Because the number of segments
-- in the cluster depends on configuration, we print only summary information
-- of the locks in segments. If a relation is locked only on one segment,
-- we print that as a special case, but otherwise we just print "n segments",
-- meaning the relation is locked on more than one segment.
create or replace view locktest_master as
select coalesce(
  case when relname like 'pg_toast%index' then 'toast index'
       when relname like 'pg_toast%' then 'toast table'
       when relname like 'pg_aoseg%' then 'aoseg table'
       when relname like 'pg_aovisimap%index' then 'aovisimap index'
       when relname like 'pg_aovisimap%' then 'aovisimap table'
       else relname end, 'dropped table'),
  mode,
  locktype,
  'master'::text as node
from pg_locks l
left outer join pg_class c on ((l.locktype = 'append-only segment file' and l.relation = c.relfilenode) or (l.locktype != 'append-only segment file' and l.relation = c.oid)),
pg_database d
where relation is not null
and l.database = d.oid
and (relname <> 'gp_fault_strategy' and relname != 'locktest_master' or relname is NULL)
and d.datname = current_database()
and l.gp_segment_id = -1
group by l.gp_segment_id, relation, relname, locktype, mode
order by 1, 3, 2;

create or replace view locktest_segments_dist as
select relname,
  mode,
  locktype,
  l.gp_segment_id as node,
  relation
from pg_locks l
left outer join pg_class c on ((l.locktype = 'append-only segment file' and l.relation = c.relfilenode) or (l.locktype != 'append-only segment file' and l.relation = c.oid)),
pg_database d
where relation is not null
and l.database = d.oid
and (relname <> 'gp_fault_strategy' and relname != 'locktest_segments_dist' or relname is NULL)
and d.datname = current_database()
and l.gp_segment_id > -1
group by l.gp_segment_id, relation, relname, locktype, mode;

create or replace view locktest_segments as
SELECT coalesce(
  case when relname like 'pg_toast%index' then 'toast index'
       when relname like 'pg_toast%' then 'toast table'
       when relname like 'pg_aoseg%' then 'aoseg table'
       when relname like 'pg_aovisimap%index' then 'aovisimap index'
       when relname like 'pg_aovisimap%' then 'aovisimap table'
       else relname end, 'dropped table'),
  mode,
  locktype,
  case when count(*) = 1 then '1 segment'
       else 'n segments' end as node
  FROM gp_dist_random('locktest_segments_dist')
  group by relname, relation, mode, locktype;

-- Helper function
CREATE or REPLACE FUNCTION wait_until_waiting_for_required_lock (rel_name text, lmode text, segment_id integer) /*in func*/
RETURNS bool AS
$$
declare
retries int; /* in func */
begin /* in func */
  retries := 1200; /* in func */
  loop /* in func */
    if (select not granted from pg_locks l where granted='f' and l.relation::regclass = rel_name::regclass and l.mode=lmode and l.gp_segment_id=segment_id) then /* in func */
      return true; /* in func */
    end if; /* in func */
    if retries <= 0 then /* in func */
      return false; /* in func */
    end if; /* in func */
    perform pg_sleep(0.1); /* in func */
    retries := retries - 1; /* in func */
  end loop; /* in func */
end; /* in func */
$$ language plpgsql;


--
-- pg_ctl:
--   datadir: data directory of process to target with `pg_ctl`
--   command: commands valid for `pg_ctl`
--   command_mode: modes valid for `pg_ctl -m`  
--
create or replace function pg_ctl(datadir text, command text, command_mode text default 'immediate')
returns text as $$
    class PgCtlError(Exception):
        def __init__(self, errmsg):
            self.errmsg = errmsg
        def __str__(self):
            return repr(self.errmsg)

    import subprocess
    if command == 'promote':
        cmd = 'pg_ctl promote -D %s' % datadir
    elif command in ('stop', 'restart'):
        cmd = 'pg_ctl -l postmaster.log -D %s ' % datadir
        cmd = cmd + '-w -t 600 -m %s %s' % (command_mode, command)
    else:
        return 'Invalid command input'

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            shell=True)
    stdout, stderr = proc.communicate()

    if proc.returncode == 0:
        return 'OK'
    else:
        raise PgCtlError(stdout.decode()+'|'+stderr.decode())
$$ language plpython3u;

--
-- pg_ctl_start:
--
-- Start a specific greenplum segment
--
-- intentionally separate from pg_ctl() because it needs more information
--
--   datadir: data directory of process to target with `pg_ctl`
--   port: which port the server should start on
--
create or replace function pg_ctl_start(datadir text, port int)
returns text as $$
    import subprocess
    cmd = 'pg_ctl -l postmaster.log -D %s ' % datadir
    opts = '-p %d' % (port)
    opts = opts + ' -c gp_role=execute'
    cmd = cmd + '-o "%s" start' % opts
    return subprocess.check_output(cmd, stderr=subprocess.STDOUT, shell=True).decode().replace('.', '')
$$ language plpython3u;

--
-- restart_primary_segments_containing_data_for(table_name text):
--     table_name: the table containing data whose segment that needs a restart
--
-- Note: this does an immediate restart, which forces recovery
--
create or replace function restart_primary_segments_containing_data_for(table_name text) returns setof integer as $$
declare
	segment_id integer; /* in func */
begin
	for segment_id in select * from primary_segments_containing_data_for(table_name)
	loop
		perform pg_ctl(
      (select get_data_directory_for(segment_id)),
      'restart',
      'immediate'
    ); /* in func */
	end loop; /* in func */
end; /* in func */
$$ language plpgsql;

--
-- clean_restart_primary_segments_containing_data_for(table_name text):
--     table_name: the table containing data whose segment that needs a restart
--
-- Note: this does a fast restart, which does not require recovery
--
create or replace function clean_restart_primary_segments_containing_data_for(table_name text) returns setof integer as $$
declare
	segment_id integer; /* in func */
begin
	for segment_id in select * from primary_segments_containing_data_for(table_name)
	loop
		perform pg_ctl(
      (select get_data_directory_for(segment_id)),
      'restart',
      'fast'
    ); /* in func */
	end loop; /* in func */
end; /* in func */
$$ language plpgsql;

create or replace function primary_segments_containing_data_for(table_name text) returns setof integer as $$
begin
	return query execute 'select distinct gp_segment_id from ' || table_name; /* in func */
end; /* in func */
$$ language plpgsql;


create or replace function get_data_directory_for(segment_number int, segment_role text default 'p') returns text as $$
BEGIN
	return (
		select datadir 
		from gp_segment_configuration 
		where role=segment_role and 
		content=segment_number
	); /* in func */
END; /* in func */
$$ language plpgsql;

create or replace function master() returns setof gp_segment_configuration as $$
	select * from gp_segment_configuration where role='p' and content=-1; /* in func */
$$ language sql;

create or replace function wait_until_segment_synchronized(segment_number int) returns text as $$
begin
	for i in 1..1200 loop
		if (select count(*) = 0 from gp_segment_configuration where content = segment_number and mode != 's') then
			return 'OK'; /* in func */
		end if; /* in func */
		perform pg_sleep(0.1); /* in func */
		perform gp_request_fts_probe_scan(); /* in func */
	end loop; /* in func */
	return 'Fail'; /* in func */
end; /* in func */
$$ language plpgsql;

create or replace function wait_until_all_segments_synchronized() returns text as $$
begin
	/* no-op for a mirrorless cluster */
	if (select count(*) = 0 from gp_segment_configuration where role = 'm') then
		return 'OK'; /* in func */
	end if; /* in func */
	for i in 1..1200 loop
		if (select count(*) = 0 from gp_segment_configuration where content != -1 and mode != 's') then
			return 'OK'; /* in func */
		end if; /* in func */
		perform pg_sleep(0.1); /* in func */
		perform gp_request_fts_probe_scan(); /* in func */
 	end loop; /* in func */
	return 'Fail'; /* in func */
end; /* in func */
$$ language plpgsql;

create or replace function wait_for_replication_replay (segid int, retries int) returns bool as
$$
declare
	i int; /* in func */
	result bool; /* in func */
begin
	i := 0; /* in func */
	-- Wait until the mirror/standby has replayed up to flush location
	loop
		SELECT flush_lsn = replay_lsn INTO result from gp_stat_replication where gp_segment_id = segid; /* in func */
		if result then
			return true; /* in func */
		end if; /* in func */

		if i >= retries then
		   return false; /* in func */
		end if; /* in func */
		perform pg_sleep(0.1); /* in func */
		perform pg_stat_clear_snapshot(); /* in func */
		i := i + 1; /* in func */
	end loop; /* in func */
end; /* in func */
$$ language plpgsql;

create or replace function wait_until_standby_in_state(targetstate text)
returns text as $$
declare
   replstate text; /* in func */
   i int; /* in func */
begin
   i := 0; /* in func */
   while i < 1200 loop
      select state into replstate from pg_stat_replication; /* in func */
      if replstate = targetstate then
          return replstate; /* in func */
      end if; /* in func */
      perform pg_sleep(0.1); /* in func */
      perform pg_stat_clear_snapshot(); /* in func */
      i := i + 1; /* in func */
   end loop; /* in func */
   return replstate; /* in func */
end; /* in func */
$$ language plpgsql;

--
-- pg_basebackup:
--   host: host of the gpdb segment to back up
--   port: port of the gpdb segment to back up
--   slotname: desired slot name to create and associate with backup
--   datadir: destination data directory of the backup
--   forceoverwrite: overwrite the destination directory if it exists already
--   xlog_method: (stream/fetch) how to obtain XLOG segment files from source
--
-- usage: `select pg_basebackup('somehost', 12345, 'some_slot_name', '/some/destination/data/directory')`
--
create or replace function pg_basebackup(host text, dbid int, port int, create_slot boolean, slotname text, datadir text, force_overwrite boolean, xlog_method text) returns text as $$
    import subprocess
    import os
    cmd = 'pg_basebackup --no-sync --checkpoint=fast -h %s -p %d -R -D %s --target-gp-dbid %d' % (host, port, datadir, dbid)

    if create_slot:
        cmd += ' --create-slot'

    if slotname is not None:
        cmd += ' --slot %s' % (slotname)

    if force_overwrite:
        cmd += ' --force-overwrite'

    if xlog_method == 'stream':
        cmd += ' --wal-method stream'
    elif xlog_method == 'fetch':
        cmd += ' --wal-method fetch'
    else:
        plpy.error('invalid xlog method')

    # GPDB_12_MERGE_FIXME: avoid checking checksum for heap tables
    # till we code logic to skip/verify checksum for
    # appendoptimized tables. Enabling this results in basebackup
    # failures with appendoptimized tables.
    cmd += ' --no-verify-checksums'

    try:
        # Unset PGAPPNAME so that the pg_stat_replication.application_name is not affected
        if os.getenv('PGAPPNAME') is not None:
            os.environ.pop('PGAPPNAME')
        results = subprocess.check_output(cmd, stderr=subprocess.STDOUT, shell=True).replace(b'.', b'').decode()
    except subprocess.CalledProcessError as e:
        results = str(e) + "\ncommand output: " + e.output

    return results
$$ language plpython3u;

create or replace function count_of_items_in_directory(user_path text) returns text as $$
       import subprocess
       cmd = 'ls {user_path}'.format(user_path=user_path)
       results = subprocess.check_output(cmd, stderr=subprocess.STDOUT, shell=True).replace(b'.', b'').decode()
       return len([result for result in results.splitlines() if result != ''])
$$ language plpython3u;

create or replace function count_of_items_in_database_directory(user_path text, database_oid oid) returns int as $$
       import subprocess
       import os
       directory = os.path.join(user_path, str(database_oid))
       cmd = 'ls ' + directory
       results = subprocess.check_output(cmd, stderr=subprocess.STDOUT, shell=True).replace(b'.', b'').decode()
       return len([result for result in results.splitlines() if result != ''])
$$ language plpython3u;

create or replace function validate_tablespace_symlink(datadir text, tablespacedir text, dbid int, tablespace_oid oid) returns boolean as $$
    import os
    return os.readlink('%s/pg_tblspc/%d' % (datadir, tablespace_oid)) == ('%s/%d' % (tablespacedir, dbid))
$$ language plpython3u;

-- This function is used to loop until master shutsdown, to make sure
-- next command executed is only after restart and doesn't go through
-- while PANIC is still being processed by master, as master continues
-- to accept connections for a while despite undergoing PANIC.
CREATE OR REPLACE FUNCTION wait_till_master_shutsdown()
RETURNS void AS
$$
  DECLARE
    i int; /* in func */
  BEGIN
    i := 0; /* in func */
    while i < 120 loop
      i := i + 1; /* in func */
      PERFORM pg_sleep(.5); /* in func */
    end loop; /* in func */
  END; /* in func */
$$ LANGUAGE plpgsql;
