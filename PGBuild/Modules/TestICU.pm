
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

package PGBuild::Modules::TestICU;

use PGBuild::Options;
use PGBuild::SCM;

use Fcntl qw(:seek);

use strict;

use vars qw($VERSION); $VERSION = 'REL_4.18';

my $hooks = {
    'installcheck' => \&installcheck,
};

sub setup
{
    my $class = __PACKAGE__;

    my $buildroot = shift; # where we're building
    my $branch = shift; # The branch of Postgres that's being built.
    my $conf = shift;  # ref to the whole config object
    my $pgsql = shift; # postgres build dir

    return unless grep {$_ eq '--with-icu' } @{$conf->{config_opts}},

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

    return unless $locale =~ /utf8/i;

    my $pgsql = $self->{pgsql};
    my $branch = $self->{pgbranch};
    my $buildroot = "$self->{buildroot}/$branch";
    my $binswitch = 'bindir';
    my $installdir = "$buildroot/inst";

    return unless $locale =~ /utf8$/i;

    return unless main::step_wanted("installcheck-icu");

    print main::time_str(), "installchecking ICU-$locale\n"
      if	$verbose;

    (my $buildport = $ENV{EXTRA_REGRESS_OPTS}) =~ s/--port=//;

    my $inputdir = "";
    if ($self->{bfconf}->{use_vpath})
    {
        $inputdir = "--inputdir=$buildroot/pgsql/src/test/regress";
    }

    my $logpos = -s "$installdir/logfile" || 0;

    my @checklog;
    my $cmd ="./pg_regress --$binswitch=$installdir/bin --dlpath=. "
      ."$inputdir --port=$buildport collate.icu.utf8";
    @checklog = `cd $pgsql/src/test/regress && $cmd 2>&1`;

    my $status = $? >>8;
    my @logfiles =
      ("$pgsql/src/test/regress/regression.diffs","$installdir/logfile");
    foreach my $logfile(@logfiles)
    {
        next unless (-e $logfile );
        push(@checklog,"\n\n================== $logfile ==================\n");
        my $handle;
        open($handle,$logfile);
        seek($handle, $logpos, SEEK_SET) if $logfile =~ m!/logfile$!;
        while(<$handle>)
        {
            push(@checklog,$_);
        }
        close($handle);
    }
    if ($status)
    {
        my @trace =
          main::get_stack_trace("$installdir/bin","$installdir/data-$locale");
        push(@checklog,@trace);
    }
    main::writelog("install-check-ICU-$locale",\@checklog);
    print "======== make installcheck -ICU-$locale log ========\n",@checklog
      if ($verbose > 1);
    main::send_result("InstallCheck-ICU-$locale",$status,\@checklog)
      if $status;
    {
        no warnings 'once';
        $main::steps_completed .= " InstallCheck-ICU-$locale";
    }

}

1;
