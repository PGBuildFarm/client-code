
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

package PGBuild::Modules::Pgbench;

use PGBuild::Options;
use PGBuild::SCM;

use strict;

use vars qw($VERSION); $VERSION = 'REL_4.11';

my $hooks = {
    'checkout' => \&checkout,
#    'setup-target' => \&setup_target,
#    'need-run' => \&need_run,
    'configure' => \&configure,
#    'build' => \&build,
#    'check' => \&check,
#    'install' => \&install,
    'installcheck' => \&installcheck,
#    'locale-end' => \&locale_end,
#    'cleanup' => \&cleanup,
};

sub setup
{
    my $class = __PACKAGE__;

    my $buildroot = shift; # where we're building
    my $branch = shift; # The branch of Postgres that's being built.
    my $conf = shift;  # ref to the whole config object
    my $pgsql = shift; # postgres build dir


	return unless $branch ge 'REL9_0_STABLE' || $branch eq 'HEAD';

	die "must not run bench tests with assert enabled builds"
	  if grep { /--enable-cassert/ } @{$conf->{config_opts}} ;

    # could even set up several of these (e.g. for different branches)
    my $self  = {
        buildroot => $buildroot,
        pgbranch=> $branch,
        bfconf => $conf,
        pgsql => $pgsql
    };
    bless($self, $class);

    my $scmconf ={
        scm => 'git',
        scmrepo => 'https://github.com/gregs1104/pgbench-tools.git',
        git_reference => undef,
        git_keep_mirror => 'true',
        git_ignore_mirror_failure => 'true',
        build_root => $self->{buildroot},
    };

    $self->{scm} = new PGBuild::SCM $scmconf, 'pgbench-tools';
    my $where = $self->{scm}->get_build_path();
    $self->{where} = $where;
    # for each instance you create, do:
    main::register_module_hooks($self,$hooks);

}

sub checkout
{
    my $self = shift;
    my $savescmlog = shift; # array ref to the log lines

    print main::time_str(), "checking out ",__PACKAGE__,"\n" if	$verbose;

    push(@$savescmlog,"pgbench-tools processed checkout\n");

    my $scmlog = $self->{scm}->checkout('master');

    push(@$savescmlog,
        "------------- pgbench-tools checkout ----------------\n",@$scmlog);
}

sub setup_target
{
    my $self = shift;

    # copy the code or setup a vpath dir if supported as appropriate

    print main::time_str(), "setting up ",__PACKAGE__,"\n" if	$verbose;

}

sub need_run
{
    my $self = shift;
    my $run_needed = shift; # ref to flag

    # to force a run do:
    # $$run_needed = 1;

    print main::time_str(), "checking if run needed by ",__PACKAGE__,"\n"
      if	$verbose;

}

sub configure
{
    my $self = shift;

    print main::time_str(), "configuring ",__PACKAGE__,"\n" if	$verbose;

	my $installdir = "$self->{buildroot}/$self->{pgbranch}/inst";
    (my $buildport = $ENV{EXTRA_REGRESS_OPTS}) =~ s/--port=//;

	chdir 'pgbench-tools';
	local $/ = undef;
	my $handle;
	open($handle,">>config");
	if (ref $self->{bfconf}->{pgbench_config} eq 'ARRAY')
	{
		foreach my $conf (@{ $self->{bfconf}->{pgbench_config}})
		{
			print $handle "$conf\n";
		}
	}

	print $handle "PGBENCHBIN=$installdir/bin/pgbench\n", 
	              "export PATH=$installdir/bin:\$PATH\n",
	              "TESTUSER=buildfarm\n",
				  "TESTPORT=$buildport\n",
	              "RESULTUSER=buildfarm\n",
				  "RESULTPORT=$buildport\n",
				  "MAX_WORKERS=4\n",
				  "TESTDB=bf_pgbench\n",
				  "RESULTDB=bf_pgbench_results\n";

	close($handle);

	open($handle,"runset");
	my $runset=<$handle>;
	close $handle;
	$runset =~ s!^([.]/webreport)!#$1!sm;
	open($handle,">runset");
	print $handle $runset;
	close $handle;
	

	chdir "..";
	
}

sub build
{
    my $self = shift;

    print main::time_str(), "building ",__PACKAGE__,"\n" if	$verbose;
}

sub install
{
    my $self = shift;

    print main::time_str(), "installing ",__PACKAGE__,"\n" if	$verbose;
}

sub check
{
    my $self = shift;

    print main::time_str(), "checking ",__PACKAGE__,"\n" if	$verbose;
}

sub installcheck
{
    my $self = shift;
    my $locale = shift;

	return unless $locale eq 'C';

    print main::time_str(), "installchecking ",__PACKAGE__,"\n"
      if	$verbose;

	my $installdir = "$self->{buildroot}/$self->{pgbranch}/inst";

    system("$installdir/bin/createdb bf_pgbench 2>&1");

	my $createstat = $? >> 8; 

	die "creating bf_pgbench: $createstat" if  $createstat;

    system("$installdir/bin/createdb bf_pgbench_results");

	$createstat = $? >> 8; 

	die "creating bf_pgbench_results: $createstat" if  $createstat;

	system("$installdir/bin/psql -d bf_pgbench_results -f pgbench-tools/init/resultdb.sql");

	$createstat = $? >> 8; 

	die "setting up bf_pgbench_results: $createstat" if  $createstat;

    local %ENV = %ENV;
    # delete $ENV{PGUSER};

    (my $buildport = $ENV{EXTRA_REGRESS_OPTS}) =~ s/--port=//;
    $ENV{PGPORT} = $buildport;

	my @logs = `cd pgbench-tools && ./runset 2>&1`;

	my $status = $? >> 8;

	main::writelog("pgbench",\@logs);
    print "======== pgbench log ===========\n",@logs
      if ($verbose > 1);
    main::send_result("pgbench",$status,\@logs) if $status;

	no warnings 'once';
	my ($animal, $branch, $snap) = 
	  ($self->{bfconf}->{animal},
	   $self->{pgbranch},
	   $main::now);

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($snap);
	$year += 1900; $mon +=1;
	my $snapshot=
	  sprintf("%d-%.2d-%.2d %.2d:%.2d:%.2d",$year,$mon,$mday,$hour,$min,$sec);

	print "snap = $snap, snapshot = $snapshot\n";

	my $copy = "copy (select '$animal', '$branch', '$snapshot', * from tests)" .
	           "to stdout csv";

	my @out= `$installdir/bin/psql -d bf_pgbench_results -c "$copy"`;

	main::writelog("pgbench_results.csv", \@out);

}

sub locale_end
{
    my $self = shift;
    my $locale = shift;

    print main::time_str(), "end of locale $locale processing",__PACKAGE__,"\n"
      if	$verbose;
}

sub cleanup
{
    my $self = shift;

    print main::time_str(), "cleaning up ",__PACKAGE__,"\n" if	$verbose > 1;

	system("cd pgbench-tools && git reset --hard && git clean -dfx");
}

1;
