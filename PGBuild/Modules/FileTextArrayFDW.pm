
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

package PGBuild::Modules::FileTextArrayFDW;

use PGBuild::Options;
use PGBuild::SCM;

use strict;

# strip required namespace from package name
(my $MODULE = __PACKAGE__ ) =~ s/PGBuild::Modules:://;

use vars qw($VERSION); $VERSION = 'REL_4.10';

my $hooks = {
    'checkout' => \&checkout,
    'setup-target' => \&setup_target,

    # 'need-run' => \&need_run,
    # 'configure' => \&configure,
    'build' => \&build,

    # 'check' => \&check,
    'install' => \&install,
    'installcheck' => \&installcheck,
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
        scmrepo => 'git://github.com/adunstan/file_text_array_fdw.git',
        git_reference => undef,
        git_keep_mirror => 'true',
        git_ignore_mirror_failure => 'true',
        build_root => $self->{buildroot},
    };

    $self->{scm} = new PGBuild::SCM $scmconf, 'file_text_array_fdw';
    my $where = $self->{scm}->get_build_path();
    $self->{where} = $where;

    # for each instance you create, do:
    main::register_module_hooks($self,$hooks);

}

sub checkout
{
    my $self = shift;
    my $savescmlog = shift; # array ref to the log lines

    print main::time_str(), "checking out $MODULE\n" if	$verbose;

    my $scmlog = $self->{scm}->checkout($self->{pgbranch});

    push(@$savescmlog,
        "------------- $MODULE checkout ----------------\n",@$scmlog);
}

sub setup_target
{
    my $self = shift;

    # copy the code or setup a vpath dir if supported as appropriate

    print main::time_str(), "copying source to  ...$self->{where}\n"
      if $verbose;

    $self->{scm}->copy_source(undef);

}

sub need_run
{
    my $self = shift;
    my $run_needed = shift; # ref to flag

    # to force a run do:
    # $$run_needed = 1;

    print main::time_str(), "checking if run needed by $MODULE\n"
      if	$verbose;

}

sub configure
{
    my $self = shift;

    print main::time_str(), "configuring $MODULE\n" if	$verbose;

}

sub build
{
    my $self = shift;

    print main::time_str(), "building $MODULE\n" if	$verbose;

    my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1";

    my @makeout = `cd $self->{where} && $cmd 2>&1`;

    my $status = $? >>8;
    main::writelog("$MODULE-build",\@makeout);
    print "======== make log ===========\n",@makeout if ($verbose > 1);
    main::send_result("$MODULE-build",$status,\@makeout) if $status;

}

sub install
{
    my $self = shift;

    print main::time_str(), "installing $MODULE\n" if	$verbose;

    my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1 install";

    my @log = `cd $self->{where} && $cmd 2>&1`;

    my $status = $? >>8;
    main::writelog("$MODULE-install",\@log);
    print "======== install log ===========\n",@log if ($verbose > 1);
    main::send_result("$MODULE-install",$status,\@log) if $status;

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

    print main::time_str(), "install-checking $MODULE\n" if	$verbose;

    my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1 installcheck";

    my @log = `cd $self->{where} && $cmd 2>&1`;

    my $status = $? >>8;
	my $installdir = "$self->{buildroot}/$self->{pgbranch}/inst";
    my @logfiles =
      ("$self->{where}/regression.diffs","$installdir/logfile");
    foreach my $logfile(@logfiles)
    {
		last unless $status;
        next unless (-e $logfile );
        push(@log,"\n\n================== $logfile ==================\n");
        my $handle;
        open($handle,$logfile);
        while(<$handle>)
        {
            push(@log,$_);
        }
        close($handle);
    }

    main::writelog("$MODULE-installcheck-$locale",\@log);
    print "======== installcheck ($locale) log ===========\n",@log
      if ($verbose > 1);
    main::send_result("$MODULE-installcheck-$locale",$status,\@log) if $status;

}

sub cleanup
{
    my $self = shift;

    print main::time_str(), "cleaning up $MODULE\n" if	$verbose > 1;

    system("rm -rf $self->{where}");
}

1;
