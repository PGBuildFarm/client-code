
package PGBuild::Options;

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

# common options code for buildfarm scripts, so it stays in sync

use strict;
use warnings;
use Getopt::Long;

use vars qw(@option_list);

my $orig_verbose;

BEGIN
{
    @option_list =qw(
      $forcerun $buildconf $keepall $help
      $quiet $from_source $from_source_clean $testmode
      $test_mode $skip_steps $only_steps $find_typedefs
      $nosend $nostatus $verbose @config_set $schedule $tests
    );
}

use Exporter   ();
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

use vars qw($VERSION); $VERSION = 'REL_6';

@ISA         = qw(Exporter);
@EXPORT      = @option_list;
%EXPORT_TAGS = ();
@EXPORT_OK   = ();

our (
    $forcerun, $buildconf, $keepall,$help,
    $quiet, $from_source,$from_source_clean, $testmode,
    $test_mode, $skip_steps,$only_steps, $find_typedefs,
    $nosend, $nostatus, $verbose, @config_set,
    $schedule, $tests
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
    'only-steps=s' => \$only_steps,
    'config-set=s' => \@config_set,
    'schedule=s'   => \$schedule,
    'tests=s'      => \$tests,
);

$buildconf = "build-farm.conf"; # default value

# extra options can be used by a wrapper program, such as
# the one that will do the global lock and election, and it will
# still have acces to what it needs to do to invoke run_build.

sub fetch_options
{
    GetOptions(%standard_options, @_)
      || die "bad command line";

    # override GetOptions default for :i
	$orig_verbose = $verbose;
    $verbose = 1 if (defined($verbose) && $verbose==0);
    $verbose ||= 0; # stop complaints about undefined var in numeric comparison
}

sub standard_option_list
{
    my @result = ();
    foreach my $k ( keys %standard_options )
    {
        my $vref = $standard_options{$k};
		$vref = \$orig_force if $k eq 'verbose';
        next
          unless (ref $vref eq 'SCALAR' && defined($$vref))
          ||(ref $vref eq 'ARRAY' && @$vref);
        (my $nicekey = $k) =~ s/[=:].*//;
        if (ref $vref ne 'ARRAY')
        {
            push(@result, "--$nicekey");
            push(@result,$$vref) if $$vref && $k =~ /[:=]/;
        }
        else
        {
            foreach my $val (@$vref)
            {
                push(@result, "--$nicekey", $val);
            }
        }
    }
    return @result;
}

sub fixup_conf
{
    my $conf = shift;
    my $list = shift;
    foreach my $confset (@$list)
    {
        if ($confset =~ /^([A-Za-z_]+)(\.([A-Za-z_]+))?(\+?=)(.*)/)
        {
            my ($key, $subkey, $op, $val) = ($1, $3, $4, $5);

            if (   $key eq 'mail_events'
                || $key eq 'alerts'
                ||$key eq 'branches_to_build'
                || $key eq 'global_lock_dir')
            {
                die "unsupported setting via command line: $key";
            }
            elsif (!exists $conf->{$key})
            {
                die "Invalid config key: $key";
            }
            elsif (!ref $conf->{$key})
            {
                # scalars can;t have subkeys and we can't add to them
                if (defined $subkey || $op ne '=')
                {
                    die "invalid setting: $confset";
                }
                $conf->{$key} = $val;
            }
            elsif (ref $conf->{$key} eq 'ARRAY')
            {
                if ($op eq '+=')
                {
                    push @{$conf->{$key}}, $val;
                }
                else
                {
                    @{$conf->{$key}} = split(/,/,$val);
                }
            }
            elsif ($key =~ /_env$/)
            {
                if ($op ne '=')
                {
                    die "cannot append to $key.$subkey";
                }
                $conf->{$key}->{$subkey} = $val;
            }
            else
            {
                if ($key ne 'extra_config')
                {
                    die "missing logic for $key";
                }
                $conf->{$key}->{$subkey} ||= [];

                if ($op eq '+=')
                {
                    push @{$conf->{$key}->{$subkey}}, $val;
                }
                else
                {
                    @{$conf->{$key}->{$subkey}} = split(/,/,$val);
                }
            }
        }
        else
        {
            die "invalid conf_set argument: $confset";
        }
    }
}

1;
