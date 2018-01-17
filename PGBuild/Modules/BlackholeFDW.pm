# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

package PGBuild::Modules::BlackholeFDW;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils;

use Fcntl qw(:seek);

use strict;

# strip required namespace from package name
(my $MODULE = __PACKAGE__ ) =~ s/PGBuild::Modules:://;

use vars qw($VERSION); $VERSION = 'REL_6.1';

my $hooks = {
    'checkout' => \&checkout,
    'setup-target' => \&setup_target,

    # 'need-run' => \&need_run,
    # 'configure' => \&configure,
    'build' => \&build,

    # 'check' => \&check,
    'install' => \&install,

    # 'installcheck' => \&installcheck,
    'cleanup' => \&cleanup,
};

sub setup
{
    my $class = __PACKAGE__;

    my $buildroot = shift; # where we're building
    my $branch = shift; # The branch of Postgres that's being built.
    my $conf = shift;  # ref to the whole config object
    my $pgsql = shift; # postgres build dir

    return unless $branch ge 'REL9_1_STABLE' || $branch eq 'HEAD';

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
        scmrepo => 'https://bitbucket.org/adunstan/blackhole_fdw.git',
        git_reference => undef,
        git_keep_mirror => 'true',
        git_ignore_mirror_failure => 'true',
        build_root => $self->{buildroot},
    };

    $self->{scm} = new PGBuild::SCM $scmconf, 'blackhole_fdw';
    my $where = $self->{scm}->get_build_path();
    $self->{where} = $where;

    # for each instance you create, do:
    register_module_hooks($self,$hooks);

}

sub checkout
{
    my $self = shift;
    my $savescmlog = shift; # array ref to the log lines

    print time_str(), "checking out $MODULE\n" if	$verbose;

    my $scmlog = $self->{scm}->checkout('HEAD');

    push(@$savescmlog,
        "------------- $MODULE checkout ----------------\n",@$scmlog);
}

sub setup_target
{
    my $self = shift;

    # copy the code or setup a vpath dir if supported as appropriate

    print time_str(), "copying source to  ...$self->{where}\n"
      if $verbose;

    $self->{scm}->copy_source(undef);

}

sub build
{
    my $self = shift;

    print time_str(), "building $MODULE\n" if	$verbose;

    my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1";

    my @makeout = `cd $self->{where} && $cmd 2>&1`;

    my $status = $? >>8;
    writelog("$MODULE-build",\@makeout);
    print "======== make log ===========\n",@makeout if ($verbose > 1);
	$status ||= check_make_log_warnings("$MODULE-build", $verbose)
	  if $check_warnings;
    send_result("$MODULE-build",$status,\@makeout) if $status;

}

sub install
{
    my $self = shift;

    print time_str(), "installing $MODULE\n" if	$verbose;

    my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1 install";

    my @log = `cd $self->{where} && $cmd 2>&1`;

    my $status = $? >>8;
    writelog("$MODULE-install",\@log);
    print "======== install log ===========\n",@log if ($verbose > 1);
    send_result("$MODULE-install",$status,\@log) if $status;

}

sub cleanup
{
    my $self = shift;

    print time_str(), "cleaning up $MODULE\n" if	$verbose > 1;

    system("rm -rf $self->{where}");
}

1;
