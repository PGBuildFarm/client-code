
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

# NB: use of this module involves substantial persistent use of disk space.
# Don't even think about it unless you have a several GB of extra space
# you can devote to this module's storage.

# For now, only tests C locale upgrades.

package PGBuild::Modules::TestUpgradeXversion;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $tmpdir $steps_completed);

use Fcntl qw(:flock :seek);
use File::Copy;
use File::Path;
use File::Basename;

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_9';

my $hooks = {

	'need-run'   => \&need_run,
	'locale-end' => \&installcheck,

};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch    = shift;    # The branch of Postgres that's being built.
	my $conf      = shift;    # ref to the whole config object
	my $pgsql     = shift;    # postgres build dir

	return if $from_source;
	return if $conf->{using_msvc};    # disable on MSVC for now

	my $animal = $conf->{animal};
	my $upgrade_install_root =
	  $conf->{upgrade_install_root} || "$buildroot/upgrade.$animal";
	if (! defined($conf->{upgrade_install_root})
		&& ! -d $upgrade_install_root && -d "$buildroot/upgrade/HEAD")
	{
		# support legacy use without animal name
		$upgrade_install_root = "$buildroot/upgrade";
	}

	my $self = {
		buildroot            => $buildroot,
		pgbranch             => $branch,
		bfconf               => $conf,
		pgsql                => $pgsql,
		upgrade_install_root => $upgrade_install_root,
	};
	bless($self, $class);

	register_module_hooks($self, $hooks);
	return;
}

sub get_lock
{
	my $self      = shift;
	my $branch    = shift;
	my $exclusive = shift;
	my $lockdir   = $self->{upgrade_install_root};
	my $lockfile  = "$lockdir/$branch.upgrade.LCK";
	open(my $ulock, ">", $lockfile)
	  || die "opening upgrade lock file";

	# wait if necessary for the lock
	if (!flock($ulock, $exclusive ? LOCK_EX : LOCK_SH))
	{
		print STDERR "Unable to get upgrade lock. Exiting.\n";
		exit(1);
	}
	$self->{lockfile} = $ulock;
	return;
}

sub release_lock
{
	my $self = shift;
	close($self->{lockfile});
	delete $self->{lockfile};
	return;
}

sub need_run
{
	my $self                 = shift;
	my $need_run_ref         = shift;
	my $upgrade_install_root = $self->{upgrade_install_root};
	my $upgrade_loc          = "$upgrade_install_root/$self->{pgbranch}";
	$$need_run_ref = 1 unless -d $upgrade_loc;
	return;
}

sub setinstenv
{
	my $self       = shift;
	my $installdir = shift;
	my $save_env   = shift || {};

	# first restore environment from what was saved

	if (exists $save_env->{LD_LIBRARY_PATH})
	{
		$ENV{LD_LIBRARY_PATH} = $save_env->{LD_LIBRARY_PATH};
	}
	else
	{
		delete $ENV{LD_LIBRARY_PATH};
	}
	if (exists $save_env->{DYLD_LIBRARY_PATH})
	{
		$ENV{DYLD_LIBRARY_PATH} = $save_env->{DYLD_LIBRARY_PATH};
	}
	else
	{
		delete $ENV{DYLD_LIBRARY_PATH};
	}
	if (exists $save_env->{PATH})
	{
		$ENV{PATH} = $save_env->{PATH};
	}

	# now adjust it to point to new dir

	if (my $ldpath = $ENV{LD_LIBRARY_PATH})
	{
		$ENV{LD_LIBRARY_PATH} = "$installdir/lib:$ldpath";
	}
	else
	{
		$ENV{LD_LIBRARY_PATH} = "$installdir/lib";
	}
	if (my $ldpath = $ENV{DYLD_LIBRARY_PATH})
	{
		$ENV{DYLD_LIBRARY_PATH} = "$installdir/lib:$ldpath";
	}
	else
	{
		$ENV{DYLD_LIBRARY_PATH} = "$installdir/lib";
	}
	if ($self->{pgconf}->{using_msvc})
	{
		$ENV{PATH} = "$installdir/bin;$ENV{PATH}";
	}
	else
	{
		$ENV{PATH} = "$installdir/bin:$ENV{PATH}";
	}
	return;
}

sub save_for_testing
{
	my $self                 = shift;
	my $save_env             = shift;
	my $this_branch          = shift;
	my $upgrade_install_root = shift;

	print time_str(), "saving files for cross-version upgrade check\n"
	  if $verbose;

	my $install_loc = "$self->{buildroot}/$this_branch/inst";
	my $upgrade_loc = "$upgrade_install_root/$this_branch";
	my $installdir  = "$upgrade_loc/inst";

	mkdir $upgrade_install_root unless -d $upgrade_install_root;

	rmtree($upgrade_loc);

	mkdir $upgrade_loc;

	my $cp;
	if ($self->{bfconf}->{using_msvc})
	{
		$cp = "xcopy /I /Q /E";
	}
	else
	{
		$cp = "cp -r";
	}
	system(qq{$cp "$install_loc" "$installdir" >"$upgrade_loc/save.log" 2>&1});

	return if $?;

	# at some stage we stopped installing regress.so
	copy "$install_loc/../pgsql.build/src/test/regress/regress.so",
	  "$installdir/lib/postgresql/regress.so"
	  unless (-e "$installdir/lib/postgresql/regress.so");

	# keep a copy of installed database
	# to test it against, but we still need to move the regression
	# libraries.

	setinstenv($self, $installdir, $save_env);

	# start the server

	system( qq{$installdir/bin/pg_ctl -D $installdir/data-C -o -F }
		  . qq{-l "$upgrade_loc/db.log" -w start >"$upgrade_loc/ctl.log" 2>&1});

	return if $?;

	# fix the regression database so its functions point to $libdir rather than
	# the source directory, which won't persist past this build.

	my $sql =
	  'select probin::text from pg_proc where probin not like $$$libdir%$$';

	my @regresslibs = `psql -A -X -t -c '$sql' regression`;

	chomp @regresslibs;

	my %regresslibs = map { $_ => 1 } @regresslibs;

	foreach my $lib (keys %regresslibs)
	{
		my $dest = "$installdir/lib/postgresql/" . basename($lib);
		copy($lib, $dest);
		die "cannot find $dest (from $lib)" unless -e $dest;
		chmod 0755, $dest;
	}

	$sql = q{
               update pg_proc set probin =
                  regexp_replace(probin,$$.*/$$,$$$libdir/$$)
               where probin not like $$$libdir/%$$ returning proname,probin;
             };

	$sql =~ s/\n//g;

	system( "$installdir/bin/psql -A -X -t -c '$sql' regression "
		  . ">> '$upgrade_loc/fix.log' 2>&1");

	return if $?;

	system( "$installdir/bin/psql -A -X -t -c '$sql' contrib_regression "
		  . ">> '$upgrade_loc/fix.log' 2>&1");

	return if $?;

	if ($this_branch ge 'REL9_5' || $self->{pgbranch} eq 'HEAD')
	{
		system(
			"$installdir/bin/psql -A -X -t -c '$sql' contrib_regression_dblink "
			  . ">> '$upgrade_loc/fix.log' 2>&1");
		return if $?;
	}

	my $opsql;
	if ($this_branch ne 'HEAD' && $this_branch le 'REL9_4_STABLE')
	{
		$opsql = 'drop operator if exists public.=> (bigint, NONE)';

		# syntax is illegal in 9.5 and later, and it shouldn't
		# be possible for it to exist there anyway.
		# quoting the operator can also fail,  so it's left unquoted.
		system( "$installdir/bin/psql -A -X -t -c '$opsql' regression "
			  . ">> '$upgrade_loc/fix.log' 2>&1");
		return if $?;
	}

	# disable modules known to cause pg_upgrade to fail

	foreach my $bad_module ("test_ddl_deparse")
	{
		system( "$installdir/bin/psql -X -e "
			  . "-c 'drop database if exists contrib_regression_$bad_module' postgres"
			  . ">> '$upgrade_loc/fix.log' 2>&1");
		return if $?;
	}

	system( "pg_ctl -D $installdir/data-C -w stop "
		  . ">> '$upgrade_loc/ctl.log' 2>&1");
	return if $?;

	return 1;

}

sub test_upgrade    ## no critic (Subroutines::ProhibitManyArgs)
{
	my $self                 = shift;
	my $save_env             = shift;
	my $this_branch          = shift;
	my $upgrade_install_root = shift;
	my $dport                = shift;
	my $install_loc          = shift;
	my $other_branch         = shift;

	my $upgrade_loc  = "$upgrade_install_root/$this_branch";
	my $installdir   = "$upgrade_loc/inst";
	my $oversion     = basename $other_branch;
	my $upgrade_test = "upgrade_test-$this_branch";

	print time_str(), "checking upgrade from $oversion to $this_branch ...\n"
	  if $verbose;

	rmtree "$other_branch/inst/$upgrade_test";
	my $testcmd = qq{
          cp -r "$other_branch/inst/data-C"
                "$other_branch/inst/$upgrade_test"
          > '$upgrade_loc/$oversion-copy.log' 2>&1
    };
	$testcmd =~ s/\n//g;
	system $testcmd;

	return if $?;

	# The old version will have the unix sockets point to tmpdir from the
	# run in which it was set up, which will be gone by now, so we repoint
	# it to the current run's tmpdir.
	# listen_addresses will be set correctly and requires no adjustment.
	open(my $opgconf, ">>", "$other_branch/inst/$upgrade_test/postgresql.conf")
	  || die "opening $other_branch/inst/$upgrade_test/postgresql.conf: $!";
	my $param = "unix_socket_directories";
	$param = "unix_socket_directory" if $oversion ne 'HEAD' && $oversion lt 'REL9_3_STABLE';
	print $opgconf "$param = '$tmpdir'\n";
	close($opgconf);

	setinstenv($self, "$other_branch/inst", $save_env);

	my $sconfig = `$other_branch/inst/bin/pg_config --configure`;
	my $sport = $sconfig =~ /--with-pgport=(\d+)/ ? $1 : 5432;

	system( "$other_branch/inst/bin/pg_ctl -D "
		  . "$other_branch/inst/$upgrade_test -o '-F' -l "
		  . "$other_branch/inst/dump-$this_branch.log -w start "
		  . ">> '$upgrade_loc/$oversion-ctl.log' 2>&1");

	return if $?;

	if ($this_branch gt 'REL9_6_STABLE' || $this_branch eq 'HEAD')
	{
		system( "$other_branch/inst/bin/psql -X -e "
			  . " -c 'drop database if exists contrib_regression_tsearch2' "
			  . "postgres "
			  . ">> '$upgrade_loc/$oversion-copy.log' 2>&1");
		return if $?;

		system( "$other_branch/inst/bin/psql -X -e "
			  . " -c 'drop function if exists oldstyle_length(integer, text)' "
			  . "regression "
			  . ">> '$upgrade_loc/$oversion-copy.log' 2>&1");
		return if $?;
	}

	# some regression functions gone from release 11 on
	if (($this_branch ge 'REL_11_STABLE' || $this_branch eq 'HEAD') &&
	   ($oversion lt 'REL_11_STABLE' && $oversion ne 'HEAD'))
	{
		my $missing_funcs = q{drop function if exists public.boxarea(box);
                              drop function if exists public.funny_dup17();
                            };
		$missing_funcs =~ s/\n//g;

		system( "$other_branch/inst/bin/psql -X -e "
			  . " -c '$missing_funcs' "
			  . "regression "
			  . ">> '$upgrade_loc/$oversion-copy.log' 2>&1");
		return if $?;
	}

	# user table OIDS are gone from release 12 on
	if (($this_branch gt 'REL_11_STABLE' || $this_branch eq 'HEAD') &&
	   ($oversion le 'REL_11_STABLE' && $oversion ne 'HEAD'))
	{
		my $nooid_stmt = q{
           DO $stmt$
           DECLARE
              rec text;
           BEGIN
              FOR rec in
                 select oid::regclass::text
                 from pg_class
                 where relname !~ '^pg_'
                    and relhasoids
                    and relkind in ('r','m')
              LOOP
                 execute 'ALTER TABLE ' || rec || ' SET WITHOUT OIDS';
                 RAISE NOTICE 'removing oids from table %', rec;
              END LOOP;
           END; $stmt$;
        };
		open(my $nooid,">",'nooid.sql') || die "opening nooid.sql: $!";
        print $nooid $nooid_stmt;
		close($nooid);
		foreach my $oiddb ("regression","contrib_regression_btree_gist")
		{
			system( "$other_branch/inst/bin/psql -X -e "
					. " -f nooid.sql "
					. "$oiddb "
					. ">> '$upgrade_loc/$oversion-copy.log' 2>&1");
			return if $?;
		}

		if ($oversion ge 'REL_10_STABLE')
		{
			system( "$other_branch/inst/bin/psql -X -e "
					. " -c 'drop foreign table if exists ft_pg_type' "
					. "contrib_regression_postgres_fdw "
					. ">> '$upgrade_loc/$oversion-copy.log' 2>&1");
			return if $?;
		}
	}

	# use the NEW pg_dumpall so we're comparing apples with apples.
	setinstenv($self, "$installdir", $save_env);
	system( "$installdir/bin/pg_dumpall -p $sport -f "
		  . "$upgrade_loc/origin-$oversion.sql "
		  . ">'$upgrade_loc/$oversion-dump1.log' 2>&1");
	return if $?;
	setinstenv($self, "$other_branch/inst", $save_env);

	system( "$other_branch/inst/bin/pg_ctl -D "
		  . "$other_branch/inst/$upgrade_test -w stop "
		  . ">> '$upgrade_loc/$oversion-ctl.log' 2>&1");
	return if $?;
	setinstenv($self, $installdir, $save_env);

	system( "initdb -U buildfarm --locale=C "
		  . "$installdir/$oversion-upgrade "
		  . "> '$upgrade_loc/$oversion-initdb.log' 2>&1");
	return if $?;

	open(my $pgconf, ">>", "$installdir/$oversion-upgrade/postgresql.conf")
	  || die "opening $installdir/$oversion-upgrade/postgresql.conf: $!";
	my $tmp_param = "unix_socket_directories";
	$tmp_param = "unix_socket_directory" if $this_branch ne 'HEAD' && $this_branch lt 'REL9_3_STABLE';
	print $pgconf "listen_addresses = ''\n";
	print $pgconf "$tmp_param = '$tmpdir'\n";
	close($pgconf);

	if ($oversion ge 'REL9_5_STABLE' || $oversion eq 'HEAD')
	{
		my $handle;
		open($handle, ">>", "$installdir/$oversion-upgrade/postgresql.conf")
		  || die "opening $installdir/$oversion-upgrade/postgresql.conf: $!";
		print $handle "shared_preload_libraries = 'dummy_seclabel'\n";
		close $handle;
	}

	system( "cd $installdir && pg_upgrade "
		  . "--old-port=$sport "
		  . "--new-port=$dport "
		  . "--old-datadir=$other_branch/inst/$upgrade_test "
		  . "--new-datadir=$installdir/$oversion-upgrade "
		  . "--old-bindir=$other_branch/inst/bin "
		  . "--new-bindir=$installdir/bin "
		  . ">> '$upgrade_loc/$oversion-upgrade.log' 2>&1");

	foreach my $upgradelog (glob("$installdir/pg_upgrade*"))
	{
		my $bl = basename $upgradelog;
		rename $upgradelog, "$installdir/$oversion-$bl";
	}

	return if $?;

	system( "pg_ctl -D $installdir/$oversion-upgrade -l "
		  . "$installdir/upgrade_log -w start "
		  . ">> '$upgrade_loc/$oversion-ctl.log' 2>&1");
	return if $?;

	if (-e "$installdir/analyze_new_cluster.sh")
	{
		system( "cd $installdir && sh ./analyze_new_cluster.sh "
			  . "> '$upgrade_loc/$oversion-analyse.log' 2>&1 ");
		return if $?;
	}

	if (-e "$installdir/reindex_hash.sh")
	{
		system( qq{psql -X -e -f "$installdir/reindex_hash.sql" postgres >}
			  . "> '$upgrade_loc/$oversion-reindex_hash.log' 2>&1 ");
		return if $?;
	}

	system( "pg_dumpall -f "
		  . "$upgrade_loc/converted-$oversion-to-$this_branch.sql");
	return if $?;

	system( "pg_ctl -D $installdir/$oversion-upgrade -w stop "
		  . ">> '$upgrade_loc/$oversion-ctl.log'");
	return if $?;

	if (-e "$installdir/delete_old_cluster.sh")
	{
		system("cd $installdir && sh ./delete_old_cluster.sh");
		return if $?;
	}

	system( "diff -I '^-- ' -u $upgrade_loc/origin-$oversion.sql "
		  . "$upgrade_loc/converted-$oversion-to-$this_branch.sql "
		  . "> $upgrade_loc/dumpdiff-$oversion 2>&1");

	# diff exits with status 1 if files differ
	return if $? >> 8 > 1;

	my $difflines = `wc -l < $upgrade_loc/dumpdiff-$oversion`;
	chomp($difflines);

	# If the versions match we expect a possible handful of diffs,
	# generally from reordering of larg object output.
	# If not we heuristically allow up to 2000 lines of diffs

	if (   ($oversion ne $this_branch && $difflines < 2000)
		|| ($oversion eq $this_branch) && $difflines < 50)
	{
		return 1;
	}
	else
	{
		return;
	}
}

sub installcheck
{

	# this is called after base installcheck has run, which in turn
	# is after both base install and base contrib install have run,
	# so we have everything we should need.

	my $self   = shift;
	my $locale = shift;
	return unless $locale eq 'C';

	return unless step_wanted('pg_upgrade-xversion-check');

	# localize any environment changes so they don't leak to calling code.

	local %ENV = %ENV;

	$ENV{PGHOST} = $tmpdir;

	my $save_env = {};
	while (my ($env_key, $env_val) = each %ENV)
	{
		$save_env->{$env_key} = $env_val;
	}

	my $this_branch = $self->{pgbranch};

	my $upgrade_install_root = $self->{upgrade_install_root};
	my $install_loc          = "$self->{buildroot}/$this_branch/inst";
	my $upgrade_loc          = "$upgrade_install_root/$this_branch";
	my $installdir           = "$upgrade_loc/inst";

	# for saving we need an exclusive lock.
	get_lock($self, $this_branch, 1);

	my $status =
	  save_for_testing($self, $save_env, $this_branch, $upgrade_install_root)
	  ? 0
	  : 1;

	release_lock($self);

	my @saveout;

	foreach my $log (qw( fix save db ctl ))
	{
		next unless -e "$upgrade_loc/$log.log";
		my @lines = file_lines("$upgrade_loc/$log.log");
		push(@saveout,
			"===================== $log.log ==============\n", @lines)
		  if @lines;
	}

	writelog('xversion-upgrade-save', \@saveout);
	print "======== xversion upgrade save log ===========\n", @saveout
	  if ($verbose > 1);
	send_result('XversionUpgradeSave', $status, \@saveout) if $status;
	$steps_completed .= " XVersionUpgradeSave";

	# ok, we now have the persistent copy of all branches we can use
	# to test upgrading from

	my $dconfig = `$installdir/bin/pg_config --configure`;
	my $dport = $dconfig =~ /--with-pgport=(\d+)/ ? $1 : 5432;

	foreach my $other_branch (
		sort { $a =~ "HEAD" ? 999 : $b =~ "HEAD" ? -999 : $a cmp $b }
		glob("$upgrade_install_root/*"))
	{
		my $oversion = basename $other_branch;

		next unless -d $other_branch;    # will skip lockfiles

		next
		  unless (($this_branch eq 'HEAD')
			|| ($oversion ne 'HEAD' && $oversion le $this_branch));

		# for testing a shared lock should do, since each each upgrade will
		# be sourced in a directory named with this branch, so it's no
		# longer shared with other branch tests. This lock will prevent the
		# other branch from being removed or changed under us.
		get_lock($self, $oversion, 0);

		$status =
		  test_upgrade($self, $save_env, $this_branch, $upgrade_install_root,
			$dport, $install_loc, $other_branch) ? 0 : 1;

		release_lock($self);

		rmtree("$installdir/$oversion-upgrade");

		my @testout;

		foreach my $log (glob("$upgrade_loc/*$oversion*"),
			glob("$installdir/${oversion}_pg_upgrade*"))
		{
			next unless -e "$log";
			my $bn = basename $log;
			next if $bn =~ /^(origin|converted)/;
			my @lines = file_lines($log);
			push(@testout, "===================== $bn ==============\n", @lines)
			  if (@lines || $bn =~ /dumpdiff/);
		}

		writelog("xversion-upgrade-$oversion-$this_branch", \@testout);
		print "====== xversion upgrade $oversion to $this_branch =======\n",
		  @testout
		  if ($verbose > 1);
		send_result("XversionUpgrade-$oversion-$this_branch",
			$status, \@testout)
		  if $status;
		$steps_completed .= " XVersionUpgrade-$oversion-$this_branch";
	}
	return;
}

1;
