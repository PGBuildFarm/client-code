
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2022, Andrew Dunstan

See accompanying License file for license details

=cut

# NB: use of this module involves substantial persistent use of disk space.
# Don't even think about it unless you have a several GB of extra space
# you can devote to this module's storage.

# For now, only tests C locale upgrades.

package PGBuild::Modules::TestUpgradeXversion;

use PGBuild::Log;
use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $tmpdir $steps_completed);

use Cwd qw(abs_path);
use Fcntl qw(:flock :seek);
use File::Copy;
use File::Path;
use File::Basename;
use File::Temp qw(tempfile);

use strict;
use warnings;

our ($VERSION); $VERSION = 'REL_17';

my $hooks = {

	'need-run' => \&need_run,
	'locale-end' => \&installcheck,

};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch = shift;       # The branch of Postgres that's being built.
	my $conf = shift;         # ref to the whole config object
	my $pgsql = shift;        # postgres build dir

	return if $branch !~ /^(?:HEAD|REL_?\d+(?:_\d+)?_STABLE)$/;

	my $animal = $conf->{animal};
	my $upgrade_install_root =
	  $conf->{upgrade_install_root} || "$buildroot/upgrade.$animal";
	if (   !defined($conf->{upgrade_install_root})
		&& !-d $upgrade_install_root
		&& -d "$buildroot/upgrade/HEAD")
	{
		# support legacy use without animal name
		$upgrade_install_root = "$buildroot/upgrade";
	}

	mkdir $upgrade_install_root unless -d $upgrade_install_root;

	# we need to segregate from-source builds so they don't corrupt
	# non-from-source saves

	my $fs_upgrade_install_root = "$buildroot/fs-upgrade.$animal";

	mkdir $fs_upgrade_install_root
	  if $from_source && !-d $fs_upgrade_install_root;

	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql,
		upgrade_install_root => $upgrade_install_root,
		fs_upgrade_install_root => $fs_upgrade_install_root,
	};
	bless($self, $class);

	register_module_hooks($self, $hooks);
	return;
}

sub run_psql    ## no critic (Subroutines::ProhibitManyArgs)
{
	my ($psql, $flags, $sql, $database, $logfile, $append) = @_;
	my ($fh, $filename) = tempfile('bfsql-XXXX', UNLINK => 1, TMPDIR => 1);
	print $fh $sql;
	close $fh;
	my $rd = $append ? '>>' : '>';
	system(qq{"$psql" -X $flags -f "$filename" $database $rd "$logfile" 2>&1});
	return;    # callers can check $?
}

sub dbnames
{
	my $loc = shift;

	# collect names of databases.
	my $sql = 'select datname from pg_database';

	run_psql("psql", "-A -t", $sql, "postgres", "$loc-dbnames.data");
	my @dbnames = file_lines("$loc-dbnames.data");

	chomp @dbnames;
	my %dbnames;
	do { s/\r$//; $dbnames{$_} = 1; }
	  foreach @dbnames;
	return %dbnames;
}

sub get_lock
{
	my $self = shift;
	my $branch = shift;
	my $exclusive = shift;
	my $lockdir = $self->{upgrade_install_root};
	my $lockfile = "$lockdir/$branch.upgrade.LCK";
	open(my $ulock, ">", $lockfile)
	  || die "opening upgrade lock file $lockfile: $!";

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
	my $self = shift;
	my $need_run_ref = shift;
	my $upgrade_install_root = $self->{upgrade_install_root};
	my $upgrade_loc = "$upgrade_install_root/$self->{pgbranch}";
	$$need_run_ref = 1 unless -d $upgrade_loc;
	return;
}

sub setinstenv
{
	my $self = shift;
	my $installdir = shift;
	my $save_env = shift || {};

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

	if ($self->{bfconf}->{using_msvc} || $^O eq 'msys')
	{
		my $sep = $self->{bfconf}->{using_msvc} ? ';' : ':';
		$ENV{PATH} = "$installdir/bin$sep$ENV{PATH}";
		return;
	}
	else
	{
		$ENV{PATH} = "$installdir/bin:$ENV{PATH}";
	}
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
	return;
}

sub save_for_testing
{
	my $self = shift;
	my $save_env = shift;
	my $this_branch = shift;
	my $upgrade_install_root = shift;

	print time_str(), "saving files for cross-version upgrade check\n"
	  if $verbose;

	my $install_loc = "$self->{buildroot}/$this_branch/inst";
	my $upgrade_loc = "$upgrade_install_root/$this_branch";
	my $installdir = "$upgrade_loc/inst";

	mkdir $upgrade_install_root unless -d $upgrade_install_root;

	# rmtree chokes on these symlinks on Windows
	foreach my $f (qw(bin share lib include))
	{
		last unless $self->{bfconf}->{using_msvc};
		next unless -e "$upgrade_loc/inst/$f";
		system(qq{rmdir "$upgrade_loc/inst/$f"});
	}

	rmtree($upgrade_loc);

	mkdir $upgrade_loc;

	mkpath $installdir;

	copydir("$install_loc/data-C", "$installdir/data-C",
		"$upgrade_loc/save.log");

	return if $?;

	my $save_prefix = $from_source ? "fs-saves" : "saves";

	my $savebin = save_install($self->{buildroot}, $self->{pgbranch},
		$self->{pgsql}, "$upgrade_loc/save.log", $save_prefix);

	return if $?;

	my $can_symlink = eval { symlink "", ""; 1 };    # can fail on windows

	foreach my $idir (qw(bin lib include share))
	{
		if ($self->{bfconf}->{using_msvc} || !$can_symlink)
		{
			system(
				qq{cmd /c mklink /J "$installdir/$idir" "$savebin/$idir" >> "$upgrade_loc/save.log" 2>&1}
			);
		}
		else
		{
			symlink("$savebin/$idir", "$installdir/$idir");
		}
	}

	# at some stage we stopped installing regress.so
	if ($self->{bfconf}->{using_msvc})
	{
		# except on windows :-)
	}
	elsif ($^O eq 'msys')
	{
		copy "$self->{pgsql}/src/test/regress/regress.dll",
		  "$installdir/lib/postgresql/regress.dll"
		  unless (-e "$installdir/lib/postgresql/regress.dll");
	}
	else
	{
		copy "$self->{pgsql}/src/test/regress/regress.so",
		  "$installdir/lib/postgresql/regress.so"
		  unless (-e "$installdir/lib/postgresql/regress.so");
	}

	# keep a copy of installed database
	# to test it against, but we still need to move the regression
	# libraries.

	setinstenv($self, $installdir, $save_env);

	# start the server

	system( qq{"$installdir/bin/pg_ctl" -D "$installdir/data-C" -o -F }
		  . qq{-l "$upgrade_loc/db.log" -w start >"$upgrade_loc/ctl.log" 2>&1});

	return if $?;

	# fix the regression database so its functions point to $libdir rather than
	# the source directory, which won't persist past this build.

	my %dbnames = dbnames("$upgrade_loc/save");

	my $sql =
		'select distinct probin::text from pg_proc '
	  . 'where probin not like $$$libdir%$$';

	run_psql("psql", "-A -t", $sql, "regression",
		"$upgrade_loc/regresslibs.data");
	my @regresslibs = file_lines("$upgrade_loc/regresslibs.data");

	chomp @regresslibs;
	do { s/\r$// }
	  foreach @regresslibs;

	foreach my $lib (@regresslibs)
	{
		last if ($self->{bfconf}->{using_msvc});    # windows install adds these
		my $dest = "$installdir/lib/postgresql/" . basename($lib);
		copy($lib, $dest);
		die "cannot find $dest (from $lib)" unless -e $dest;
		chmod 0755, $dest;
	}

	$sql = q{
               update pg_proc set probin =
                  regexp_replace(probin,$$.*/$$,$$$libdir/$$)
               where probin not like $$$libdir/%$$
               returning current_database(), proname, probin;
             };
	$sql =~ s/\n//g;

	run_psql("$installdir/bin/psql", "-A -t -e", $sql, "regression",
		"$upgrade_loc/fix.log", 1);

	return if $?;

	my $dblink = (grep { /_dblink$/ } keys %dbnames)[0];

	if (($this_branch ge 'REL9_5' || $this_branch eq 'HEAD')
		&& $dblink)
	{
		run_psql("$installdir/bin/psql", "-A -t -e", $sql,
			$dblink, "$upgrade_loc/fix.log", 1);
		return if $?;
	}

	# use a different logfile here to get around windows sharing issue
	system( qq{"$installdir/bin/pg_ctl" -D "$installdir/data-C" -w stop }
		  . qq{>> "$upgrade_loc/ctl2.log" 2>&1});
	return if $?;

	open(my $ok, '>', "$upgrade_loc/save.ok") || return 1;
	print $ok "ok\n";
	close($ok);

	return 1;

}

sub test_upgrade    ## no critic (Subroutines::ProhibitManyArgs)
{
	my $self = shift;
	my $save_env = shift;
	my $this_branch = shift;
	my $upgrade_install_root = shift;
	my $dport = shift;
	my $other_branch = shift;

	my $upgrade_loc = "$upgrade_install_root/$this_branch";
	my $installdir = "$upgrade_loc/inst";
	my $oversion = basename $other_branch;
	my $upgrade_test = "upgrade_test-$this_branch";

	print time_str(), "checking upgrade from $oversion to $this_branch ...\n"
	  if $verbose;

	my $srcdir = $from_source || "$self->{buildroot}/$this_branch/pgsql";

	# load helper module from source tree
	unshift(@INC, "$srcdir/src/test/perl");
	require PostgreSQL::Test::AdjustUpgrade;
	PostgreSQL::Test::AdjustUpgrade->import;
	shift(@INC);

	# if $oversion isn't HEAD, convert it into a PostgreSQL::Version object
	my $old_version = $oversion;
	if ($old_version ne 'HEAD')
	{
		$old_version =~ s/REL_?(\d+(?:_\d+)?)_STABLE/$1/;
		$old_version =~ s/_/./;
		$old_version = PostgreSQL::Version->new($old_version);
	}

	rmtree "$other_branch/inst/$upgrade_test";
	copydir(
		"$other_branch/inst/data-C",
		"$other_branch/inst/$upgrade_test/",
		"$upgrade_loc/$oversion-copy.log"
	);
	return if $?;

	# is the old version using unix sockets or localhost?

	my $oldconf =
	  file_contents("$other_branch/inst/$upgrade_test/postgresql.conf");
	my $using_localhost = $oldconf =~ /^listen_addresses = 'localhost'/m;

	local $ENV{PGHOST} = $using_localhost ? "localhost" : $ENV{PGHOST};

	# The old version will have the unix sockets point to tmpdir from the
	# run in which it was set up, which will be gone by now, so we repoint
	# it to the current run's tmpdir.
	# listen_addresses will be set correctly and requires no adjustment.
	if (!$using_localhost)
	{
		my $tdir = $tmpdir;
		$tdir =~ s!\\!/!g;

		open(my $opgconf, ">>",
			"$other_branch/inst/$upgrade_test/postgresql.conf")
		  || die "opening $other_branch/inst/$upgrade_test/postgresql.conf: $!";
		my $param = "unix_socket_directories";
		$param = "unix_socket_directory"
		  if $oversion ne 'HEAD' && $oversion lt 'REL9_3_STABLE';
		print $opgconf "\n# Configuration added by buildfarm client\n\n";
		print $opgconf "$param = '$tdir'\n";
		close($opgconf);
	}

	setinstenv($self, "$other_branch/inst", $save_env);

	unlink "$other_branch/inst/dump-$this_branch.log";

	system( qq{"$other_branch/inst/bin/pg_ctl" -D }
		  . qq{"$other_branch/inst/$upgrade_test" -o -F -l }
		  . qq{"$other_branch/inst/dump-$this_branch.log" -w start }
		  . qq{>> "$upgrade_loc/$oversion-ctl.log" 2>&1});

	return if $?;

	run_psql("psql", "-A -t", "show port", "postgres",
		"$upgrade_loc/sport.dat");
	my $sport = file_contents("$upgrade_loc/sport.dat");
	$sport =~ s/\s+//msg;
	$sport = $sport + 0;

	# collect names of databases present in old installation.
	my %dbnames = dbnames("$upgrade_loc/$oversion");

	if ($oversion ne $this_branch)
	{
		# obtain and execute commands needed to make old database upgradable.
		my $adjust_cmds = adjust_database_contents($old_version, %dbnames);

		foreach my $updb (keys %$adjust_cmds)
		{
			my $upcmds = join(";\n", @{ $adjust_cmds->{$updb} });

			run_psql("$other_branch/inst/bin/psql", "-e -v ON_ERROR_STOP=1",
				$upcmds, $updb, "$upgrade_loc/$oversion-fix.log", 1);
			return if $?;
		}
	}

	# perform a dump from the old database for comparison purposes.
	my $extra_digits = "";

	if (   $oversion ne 'HEAD'
		&& $oversion le 'REL_11_STABLE'
		&& ($this_branch eq 'HEAD' || $this_branch gt 'REL_11_STABLE'))
	{
		$extra_digits = ' --extra-float-digits=0';
	}

	# use the NEW pg_dumpall so we're comparing apples with apples.
	setinstenv($self, "$installdir", $save_env);
	system( qq{"$installdir/bin/pg_dumpall" $extra_digits -p $sport -f }
		  . qq{"$upgrade_loc/origin-$oversion.sql" }
		  . qq{> "$upgrade_loc/$oversion-dump1.log" 2>&1});
	return if $?;
	setinstenv($self, "$other_branch/inst", $save_env);

	system( qq{"$other_branch/inst/bin/pg_ctl" -D }
		  . qq{"$other_branch/inst/$upgrade_test" -w stop }
		  . qq{>> "$upgrade_loc/$oversion-ctl2.log" 2>&1});
	return if $?;
	setinstenv($self, $installdir, $save_env);

	system( qq{initdb -A trust -U buildfarm --locale=C }
		  . qq{"$installdir/$oversion-upgrade" }
		  . qq{> "$upgrade_loc/$oversion-initdb.log" 2>&1});
	return if $?;

	unless ($using_localhost)
	{
		open(my $pgconf, ">>", "$installdir/$oversion-upgrade/postgresql.conf")
		  || die "opening $installdir/$oversion-upgrade/postgresql.conf: $!";
		my $tmp_param = "unix_socket_directories";
		$tmp_param = "unix_socket_directory"
		  if $this_branch ne 'HEAD' && $this_branch lt 'REL9_3_STABLE';
		print $pgconf "\n# Configuration added by buildfarm client\n\n";
		print $pgconf "listen_addresses = ''\n";
		print $pgconf "$tmp_param = '$tmpdir'\n";
		close($pgconf);
	}

	if ($oversion ge 'REL9_5_STABLE' || $oversion eq 'HEAD')
	{
		my $handle;
		open($handle, ">>", "$installdir/$oversion-upgrade/postgresql.conf")
		  || die "opening $installdir/$oversion-upgrade/postgresql.conf: $!";
		print $handle "\n# Configuration added by buildfarm client\n\n"
		  if ($self->{bfconf}->{using_msvc} || $^O eq 'msys');
		print $handle "shared_preload_libraries = 'dummy_seclabel'\n";
		close $handle;
	}

	# remove any vestigial scripts etc
	unlink(glob("$installdir/*.sql $installdir/*.sh $installdir/*.bat"));

	my $old_data = abs_path("$other_branch/inst/$upgrade_test");
	my $new_data = abs_path("$installdir/$oversion-upgrade");

	system( "cd $installdir && pg_upgrade -r "
		  . "--old-port=$sport "
		  . "--new-port=$dport "
		  . qq{--old-datadir="$old_data" }
		  . qq{--new-datadir="$new_data" }
		  . qq{--old-bindir="$other_branch/inst/bin" }
		  . qq{--new-bindir="$installdir/bin" }
		  . qq{>> "$upgrade_loc/$oversion-upgrade.log" 2>&1});

	foreach my $upgradelog (
		glob(
			"$installdir/pg_upgrade*
                                  $installdir/*.txt
                                  $new_data/pg_upgrade_output.d/*"
		)
	  )
	{
		my $bl = basename $upgradelog;
		rename $upgradelog, "$installdir/$oversion-$bl";
	}

	return if $?;

	system( qq{pg_ctl -D "$installdir/$oversion-upgrade" -l }
		  . qq{"$installdir/upgrade_log" -w start }
		  . qq{>> "$upgrade_loc/$oversion-ctl3.log" 2>&1});
	return if $?;

	if (-e "$installdir/analyze_new_cluster.sh")
	{
		system( "cd $installdir && sh ./analyze_new_cluster.sh "
			  . qq{> "$upgrade_loc/$oversion-analyse.log" 2>&1 });
		return if $?;
	}
	else
	{
		system( qq{"$installdir/bin/vacuumdb" --all --analyze-only }
			  . qq{> "$upgrade_loc/$oversion-analyse.log" 2>&1 });
		return if $?;
	}

	if (-e "$installdir/reindex_hash.sql")
	{
		system( qq{psql -X -e -f "$installdir/reindex_hash.sql" postgres }
			  . qq{> "$upgrade_loc/$oversion-reindex_hash.log" 2>&1 });
		return if $?;
	}

	system( "pg_dumpall $extra_digits -f "
			. qq{"$upgrade_loc/converted-$oversion-to-$this_branch.sql" }
			. qq{> "$upgrade_loc/converted-$oversion-$this_branch.log" 2>&1});
	return if $?;

	# run amcheck before updating extensions if any
	if ($this_branch ge 'REL_14_STABLE' || $this_branch eq 'HEAD')
	{
		# force amcheck extension update before running pg_amcheck
		if ($dbnames{contrib_regression_amcheck}
			&& ($this_branch ne $oversion))
		{
			local $ENV{PG_OPTIONS} = '--client-min-messages=warning';
			run_psql(
				"psql",
				"",
				"alter extension amcheck update",
				"contrib_regression_amcheck",
				"$upgrade_loc/amcheck-update.log"
			);
			return if $?;
		}
		system( "pg_amcheck --all --install-missing"
			  . qq{> "$upgrade_loc/$oversion-amcheck-1.log" 2>&1 });
		return if $?;
	}

	if (-e "$installdir/update_extensions.sql")
	{
		system( qq(psql -X -e -f "$installdir/update_extensions.sql" postgres)
			  . qq{> "$upgrade_loc/$oversion-update_extensions.log" 2>&1});
		return if $?;

		# rerun amcheck after updating extensions
		# but only for dbs where we updated the extensions
		if ($this_branch ge 'REL_14_STABLE' || $this_branch eq 'HEAD')
		{
			my @updates = grep { /\\connect/ }
			  file_lines("$installdir/update_extensions.sql");
			my @updatedbs;
			foreach my $upd (@updates)
			{
				if ($upd =~ /^\\connect (\w+)$/)
				{
					push @updatedbs, '-d', $1;
				}
				elsif ($upd =~ /^\\connect.*dbname='(.*)'"$/)
				{
					push @updatedbs, '-d', qq{"$1"};
				}
			}
			if (@updatedbs)
			{
				my $dbstr = join(' ', @updatedbs);
				system( "pg_amcheck $dbstr --install-missing"
					  . qq{> "$upgrade_loc/$oversion-amcheck-2.log" 2>&1 });
				return if $?;
			}
		}
	}

	system( qq{pg_ctl -D "$installdir/$oversion-upgrade" -w stop }
		  . qq{>> "$upgrade_loc/$oversion-ctl4.log" 2>&1});
	return if $?;

	if (-e "$installdir/delete_old_cluster.sh")
	{
		system("cd $installdir && sh ./delete_old_cluster.sh");
		return if $?;
	}
	elsif (-e "$installdir/delete_old_cluster.bat")
	{
		if ($^O eq 'msys')
		{
			system(qq{cd "$installdir" && cmd //c 'delete_old_cluster > nul'});
		}
		else
		{
			system(qq{cd "$installdir" && delete_old_cluster > nul});
		}
		return if $?;
	}

	# Slurp the pg_dump output files, and filter them if not same version.
	my $olddumpfile = "$upgrade_loc/origin-$oversion.sql";
	my $olddump = file_contents($olddumpfile);

	$olddump = adjust_old_dumpfile($old_version, $olddump)
	  if ($oversion ne $this_branch);

	my $newdumpfile = "$upgrade_loc/converted-$oversion-to-$this_branch.sql";
	my $newdump = file_contents($newdumpfile);

	$newdump = adjust_new_dumpfile($old_version, $newdump)
	  if ($oversion ne $this_branch);

	# Always write out the filtered files, to aid in diagnosing filter bugs.
	open(my $odh, '>', "$olddumpfile.fixed")
	  || die "opening $olddumpfile.fixed: $!";
	print $odh $olddump;
	close($odh);
	open(my $ndh, '>', "$newdumpfile.fixed")
	  || die "opening $newdumpfile.fixed: $!";
	print $ndh $newdump;
	close($ndh);

	# Are the results the same?
	if ($olddump ne $newdump)
	{
		# Trouble, so run diff to show the problem.
		system( qq{diff -u "$olddumpfile.fixed" "$newdumpfile.fixed" }
			  . qq{> "$upgrade_loc/dumpdiff-$oversion" 2>&1});

		return;
	}

	return 1;
}

sub installcheck
{
	# this is called after base installcheck has run, which in turn
	# is after both base install and base contrib install have run,
	# so we have everything we should need.

	my $self = shift;
	my $locale = shift;
	return unless $locale eq 'C';

	return unless step_wanted('pg_upgrade-xversion-check');

	# localize any environment changes so they don't leak to calling code.

	local %ENV = %ENV;

	my $tdir = $tmpdir;
	$tdir =~ s!\\!/!g;

	if ($ENV{PG_TEST_USE_UNIX_SOCKETS})
	{
		$ENV{PGHOST} = $tdir;
	}
	elsif ($self->{bfconf}->{using_msvc} || $^O eq 'msys')
	{
		$ENV{PGHOST} = 'localhost';
	}
	else
	{
		$ENV{PGHOST} = $tdir;
	}

	my $save_env = {};
	while (my ($env_key, $env_val) = each %ENV)
	{
		$save_env->{$env_key} = $env_val;
	}

	my $this_branch = $self->{pgbranch};

	my $upgrade_install_root =
		$from_source
	  ? $self->{fs_upgrade_install_root}
	  : $self->{upgrade_install_root};
	my $upgrade_loc = "$upgrade_install_root/$this_branch";
	my $installdir = "$upgrade_loc/inst";

	# for saving we need an exclusive lock.
	get_lock($self, $this_branch, 1);

	my $status =
	  save_for_testing($self, $save_env, $this_branch, $upgrade_install_root)
	  ? 0
	  : 1;

	release_lock($self);

	my @saveout;

	my $savelog = PGBuild::Log->new('xversion-upgrade-save');

	$savelog->add_log("$upgrade_loc/$_.log") foreach (qw( fix save db ctl ));
	push(@saveout, $savelog->log_string);

	writelog('xversion-upgrade-save', \@saveout);
	print "======== xversion upgrade save log ===========\n", @saveout
	  if ($verbose > 1);
	send_result('XversionUpgradeSave', $status, \@saveout) if $status;
	$steps_completed .= " XVersionUpgradeSave";

	# in saveonly mode our work is done
	return if $ENV{PG_UPGRADE_SAVE_ONLY};

	# ok, we now have the persistent copy of all branches we can use
	# to test upgrading from

	my $dport;
	{
		no warnings 'once';
		$dport = $main::buildport;
	}

	# for other branches ignore the from-source root if it's being used
	my $stable_root = $self->{upgrade_install_root};

	foreach my $other_branch (
		sort { $a =~ "HEAD" ? 999 : $b =~ "HEAD" ? -999 : $a cmp $b }
		glob("$stable_root/*"))
	{
		my $oversion = basename $other_branch;

		next unless -d $other_branch;    # will skip lockfiles

		# don't check unless there is a save.ok file for newer branches
		next unless -e "$other_branch/save.ok" ||
		  ($oversion ne "HEAD" && $oversion lt "REL_11_STABLE");

		# self-test from-source builds against the correct save.
		if ($from_source && $this_branch eq $oversion)
		{
			$other_branch = "$self->{fs_upgrade_install_root}/$this_branch";
		}

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
			$dport, $other_branch) ? 0 : 1;

		release_lock($self);

		rmtree("$installdir/$oversion-upgrade");

		my @testout;

		my $testlog =
		  PGBuild::Log->new("xversion-upgrade-$oversion-$this_branch");

		foreach my $log (
			glob("$upgrade_loc/*$oversion*"),
			glob("$installdir/${oversion}-pg_upgrade*"),
			glob("$installdir/${oversion}-20*T*.*/*"),
			glob("$installdir/${oversion}-20*T*.*/log/*")
		  )
		{
			next unless -f $log;
			next if $log =~ /\.custom$/;
			my $bn = basename $log;
			next if $bn =~ /^(origin|converted)/;
			$testlog->add_log($log) if (-s $log) || $bn =~ /dumpdiff/;
		}
		push(@testout, $testlog->log_string);

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
