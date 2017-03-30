
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

package PGBuild::Modules::TestSepgsql;

use PGBuild::Options;
use PGBuild::SCM;
use File::Find;

use Cwd;

use strict;

use vars qw($VERSION); $VERSION = 'REL_4.18';

my $hooks = {
    'build' => \&build,
    'install' => \&install,
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

    die "vpath testing not supported for SELinux tests"
      if $conf->{use_vpath};

    my $enforcing = `getenforce 2>&1`;
    chomp $enforcing;
    die "SELinux is not enforcing"
      unless $enforcing eq 'Enforcing';

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

# assumes the user has passwordless sudo privs
# location of selinux Makefile is also hardcoded,
# although it's fairly likely to be stable.

sub build
{
    my $self = shift;
    my $pgsql = $self->{pgsql};

    print main::time_str(), "building sepgsql policy module\n" if     $verbose;

    # the main build will set up sepgsql, what we need to do here is build
    # the policy module

    my $dir = cwd();

    chdir "$pgsql/contrib/sepgsql";

    my $make = $self->{bfconf}->{make};
    my @log = `$make -f /usr/share/selinux/devel/Makefile 2>&1`
      ; #  && sudo semodule -u sepgsql-regtest.pp 2>&1`;
    my $status = $? >>8;

    chdir $dir;

    main::writelog("sepgsql-policy-build",\@log);
    print "="x15 . " build sepgsql policy log " . "="x15 . "\n",@log
      if ($verbose > 1);
    main::send_result("sepgsql-policy-build",$status,\@log)
      if $status;
    {
        no warnings 'once';
        $main::steps_completed .= " sepgsql-policy-build";
    }
}

sub install
{
    my $self = shift;
    my $pgsql = $self->{pgsql};

    print main::time_str(), "installing sepgsql policy module\n"
      if     $verbose;

    # the main build will set up sepgsql, what we need to do here is install
    # the policy module

    my $dir = cwd();

    chdir "$pgsql/contrib/sepgsql";

    my $make = $self->{bfconf}->{make};
    my @log = `sudo semodule -u sepgsql-regtest.pp 2>&1`;
    my $status = $? >>8;

    $self->{module_installed} = $status == 0;

    chdir $dir;

    main::writelog("sepgsql-policy-install",\@log);
    print "="x15 . " install sepgsql policy log " . "="x15 . "\n",@log
      if ($verbose > 1);
    main::send_result("sepgsql-policy-install",$status,\@log)
      if $status;
    {
        no warnings 'once';
        $main::steps_completed .= " sepgsql-policy-install";
    }
}

sub locale_end
{
    my $self = shift;
    my $locale = shift;
    my $pgsql = $self->{pgsql};

    return unless $locale eq 'C';

    print main::time_str(), "testing sepgsql\n"
      if	$verbose;

    # set up a different data directory for selinux
    my @log = `cd inst && bin/initdb -U buildfarm --no-locale sepgsql 2>&1`;

    my $status = $? >>8;

    open(my $handle,">>inst/sepgsql/postgresql.conf");
    print $handle "shared_preload_libraries = 'sepgsql'\n";
    close $handle;

    my $sepgsql;
    my $wanted = sub {
        /^sepgsql\.sql\z/s && ($sepgsql = $File::Find::name);
    };
    File::Find::find($wanted, "inst/share");

    die "No sepgsql.sql found" unless $sepgsql;

    local %ENV = %ENV;
    $ENV{PGDATA} = cwd() . "/inst/sepgsql";
    $ENV{PATH} = cwd() . "/inst/bin:$ENV{PATH}";

    foreach my $db (qw(template0 template1 postgres))
    {
        last if $status;
        my $cmd = "inst/bin/postgres --single -F -c exit_on_error=true $db";
        my @nlog = `$cmd < $sepgsql 2>&1 1>/dev/null`;
        push(@log,
            "="x15 . " installing sepgsql in single user mode in $db " . "="x15 . "\n",
            @nlog);
        $status = $? >> 8;
    }

    if ($status)
    {
        main::writelog("sepgsql-test",\@log);
        print "="x15 . " test sepgsql setup " . "="x15 . "\n",@log
          if ($verbose > 1);
        main::send_result("test-sepgsql",$status,\@log);
    }

    my @startlog =
      `cd inst && bin/pg_ctl -D sepgsql -l sepgsql.log -w start 2>&1`;
    push(@log,"="x15 . " sepgsql start log\n",@startlog);
    $status = $? >>8;

    if ($status)
    {
        main::writelog("sepgsql-test",\@log);
        print "="x15 . " test sepgsql " . "="x15 . "\n",@log
          if ($verbose > 1);
        main::send_result("test-sepgsql",$status,\@log);
    }

    system("sudo setsebool sepgsql_regression_test_mode on");

    my @testlog = `cd $pgsql/contrib/sepgsql && ./test_sepgsql 2>&1`;
    push(@log,"="x15 . " sepgsql tests " . "="x15 . "\n",@testlog);
    $status = $? >>8;
    if ($status)
    {
        push(@log,"="x15 . " postgresql.log " . "="x15 . "\n");
        open(my $handle,"inst/sepgsql.log");
        push(@log,$_) while (<$handle>);
        close($handle);
    }

    my @stoplog = `cd inst && bin/pg_ctl -D sepgsql stop 2>&1`;
    push(@log,"="x15 . " sepgsql stop log\n",@stoplog);
    $status ||= $? >>8;
    main::writelog("sepgsql-test",\@log);

    if ($status)
    {
        print "="x15 . " test sepgsql " . "="x15 . "\n",@log
          if ($verbose > 1);
        main::send_result("test-sepgsql",$status,\@log);
    }

    {
        no warnings 'once';
        $main::steps_completed .= " sepgsql-test";
    }
}

sub cleanup
{
    my $self = shift;

    return unless $self->{module_installed};

    print main::time_str(), "cleaning up ",__PACKAGE__,"\n" if	$verbose > 1;

    system("sudo semodule -r sepgsql-regtest");
}

1;
