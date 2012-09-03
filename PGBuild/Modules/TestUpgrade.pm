
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

package PGBuild::Modules::TestUpgrade;

use PGBuild::Options;
use PGBuild::SCM;

use strict;

use vars qw($VERSION); $VERSION = 'REL_4.7';

my $hooks = {
#    'checkout' => \&checkout,
#    'setup-target' => \&setup_target,
#    'need-run' => \&need_run,
#    'configure' => \&configure,
#    'build' => \&build,
#    'install' => \&install,
    'installcheck' => \&installcheck,
#    'cleanup' => \&cleanup,
};

sub setup
{
    my $class = __PACKAGE__;

    my $buildroot = shift; # where we're building
    my $branch = shift; # The branch of Postgres that's being built.
    my $conf = shift;  # ref to the whole config object
    my $pgsql = shift; # postgres build dir

	return unless ($branch eq 'HEAD' or $branch ge 'REL9_2');
	return if $conf->{using_msvc};

    # could even set up several of these (e.g. for different branches)
    my $self  = {
        buildroot => $buildroot,
        pgbranch=> $branch,
        bfconf => $conf,
        pgsql => $pgsql
    };
    bless($self, $class);

    # for each instance you create, do:
    main::register_module_hooks($self,$hooks);

}

sub installcheck
{
    my $self = shift;
    my $locale = shift;

	return if $locale ne 'C';

    print main::time_str(), "checking pg_upgrade\n" if	$verbose;

	my @checklog;
	my $cmd = "cd $self->{pgsql}/contrib/pg_upgrade && make check";
	@checklog = `$cmd 2>&1`;

	my $status = $? >>8;

    main::writelog("check-pg_upgrade",\@checklog);
    print "======== pg_upgrade check log ===========\n",@checklog
      if ($verbose > 1);
    main::send_result("pg_upgradeCheck",$status,\@checklog) if $status;
  {
	  no warnings 'once';
	  $main::steps_completed .= " pg_upgradeCheck";
  }


}


1;
