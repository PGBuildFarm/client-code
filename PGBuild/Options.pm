
package PGBuild::Options;

=comment

Copyright (c) 2003-2010, Andrew Dunstan

See accompanying License file for license details

=cut 

# common options code for buildfarm scripts, so it stays in sync

use strict;
use warnings;
use Getopt::Long;

use vars qw(@option_list);

BEGIN
{
    @option_list =qw(
      $forcerun $buildconf $keepall $help
      $quiet $from_source $from_source_clean $testmode
      $test_mode $skip_steps $find_typedefs
      $nosend $nostatus $verbose
    );
}

use Exporter   ();
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

use vars qw($VERSION); $VERSION = 'REL_4.7';

@ISA         = qw(Exporter);
@EXPORT      = @option_list;
%EXPORT_TAGS = ();
@EXPORT_OK   = ();

our (
    $forcerun, $buildconf, $keepall,
    $help, $quiet, $from_source,
    $from_source_clean, $testmode,$test_mode, $skip_steps,
    $find_typedefs,$nosend, $nostatus, $verbose,
);

my (%standard_options);

%standard_options =(
    'nosend' => \$nosend,
    'config=s' => \$buildconf,
    'from-source=s' => \$from_source,
    'from-source-clean=s' => \$from_source_clean,
    'force' => \$forcerun,
    'find-typedefs' => \$find_typedefs,
    'keepall' => \$keepall,
    'verbose:i' => \$verbose,
    'nostatus' => \$nostatus,
    'test' => \$testmode,
    'help' => \$help,
    'quiet' => \$quiet,
    'skip-steps=s' => \$skip_steps,
);

$buildconf = "build-farm.conf"; # default value

# extra options can be used by a wrapper program, such as
# the one that will do the global lock and election, and it will
# still have acces to what it needs to do to invoke run_build.

sub fetch_options
{
    GetOptions(%standard_options, @_)
      || die "bad command line";

}

sub standard_option_list
{
    my @result = ();
    foreach my $k ( keys %standard_options )
    {
        my $vref = $standard_options{$k};
        next unless defined($$vref);
        (my $nicekey = $k) =~ s/[=:].*//;
        push(@result, "--$nicekey");
        push(@result,$$vref) if $$vref && $k =~ /[:=]/;
    }
    return @result;
}

1;
