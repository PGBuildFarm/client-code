
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

package PGBuild::Modules::Skeleton;

use PGBuild::Options;
use PGBuild::SCM;

use strict;

use vars qw($VERSION); $VERSION = 'REL_4.19';

my $hooks = {
    'checkout' => \&checkout,
    'setup-target' => \&setup_target,
    'need-run' => \&need_run,
    'configure' => \&configure,
    'build' => \&build,
    'check' => \&check,
    'install' => \&install,
    'installcheck' => \&installcheck,
    'locale-end' => \&locale_end,
    'cleanup' => \&cleanup,
};

sub setup
{
    my $class = __PACKAGE__;

    my $buildroot = shift; # where we're building
    my $branch = shift; # The branch of Postgres that's being built.
    my $conf = shift;  # ref to the whole config object
    my $pgsql = shift; # postgres build dir

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

sub checkout
{
    my $self = shift;
    my $savescmlog = shift; # array ref to the log lines

    print main::time_str(), "checking out ",__PACKAGE__,"\n" if	$verbose;

    push(@$savescmlog,"Skeleton processed checkout\n");
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

    print main::time_str(), "installchecking $locale",__PACKAGE__,"\n"
      if	$verbose;
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
}

1;
