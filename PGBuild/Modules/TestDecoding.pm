
package PGBuild::Modules::TestDecoding;

use PGBuild::Options;
use PGBuild::SCM;
use File::Basename;

use strict;

use vars qw($VERSION); $VERSION = 'REL_4.18';

my $hooks = {'check' => \&check,};

sub setup
{
    my $class = __PACKAGE__;

    my $buildroot = shift; # where we're building
    my $branch = shift; # The branch of Postgres that's being built.
    my $conf = shift;  # ref to the whole config object
    my $pgsql = shift; # postgres build dir

    # for now do nothing on MSVC
    return if $conf->{using_msvc};

    # only for supported branches
    return unless $branch eq 'HEAD' || $branch ge 'REL9_4_STABLE';

    my $self  = {
        buildroot => $buildroot,
        pgbranch=> $branch,
        bfconf => $conf,
        pgsql => $pgsql
    };
    bless($self, $class);

    main::register_module_hooks($self,$hooks);

}

sub check
{
    my $self = shift;

    return unless main::step_wanted('test-decoding-check');

    print main::time_str(), "checking test-decoding\n" if	$verbose;

    my $make = $self->{bfconf}->{make};

    my @checklog;

    if ($self->{bfconf}->{using_msvc})
    {

        #        chdir "$self->{pgsql}/src/tools/msvc";
        #        @checklog = `perl vcregress.pl upgradecheck 2>&1`;
        #        chdir "$self->{buildroot}/$self->{pgbranch}";
    }
    else
    {
        my $cmd = "cd $self->{pgsql}/contrib/test_decoding && $make check";
        @checklog = `$cmd 2>&1`;
    }

    my @logfiles = glob(
        "$self->{pgsql}/contrib/test_decoding/regression_output/log/*.log
		   $self->{pgsql}/contrib/test_decoding/regression_output/*.diffs
		   $self->{pgsql}/contrib/test_decoding/isolation_output/log/*.log
		   $self->{pgsql}/contrib/test_decoding/isolation_output/*.diffs"
    );
    foreach my $log (@logfiles)
    {
        my $fname = $log;
        $fname =~ s!.*/([^/]+/log/[^/]+log)$!$1!;
        $fname =~ s!.*/([^/]+/[^/]+diffs)$!$1!;
        local $/ = undef;
        my $handle;
        open($handle,$log);
        my $contents = <$handle>;
        close($handle);
        push(@checklog,
            "="x15 . " $fname " . "="x15 . "\n",$contents);
    }

    my $status = $? >>8;

    main::writelog("test-decoding-check",\@checklog);
    print "="x15 . " test-decoding check log " . "="x15 . "\n",@checklog
      if ($verbose > 1);
    main::send_result("test-decoding-check",$status,\@checklog) if $status;
    {
        no warnings 'once';
        $main::steps_completed .= " test-decoding-check";
    }

}

1;
