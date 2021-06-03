

package PGBuild::VSenv;

use strict;
use warnings;

use Cwd;

use vars qw($VERSION); $VERSION = 'REL_12';

sub getenv
{
	my $vsdir = shift;
	my $arg = shift || 'x64';

	my $here = getcwd();

	my @prelines = qx{set};

	my $preenv = env_from_lines(\@prelines);

	chdir "$vsdir/BuildTools/VC/Auxiliary/Build";

	my @lines = qx{.\\vcvarsall $arg && set};

	chdir $here;

	my $devenv = env_from_lines(\@lines);

	while (my ($k,$v) = each %$preenv)
			{
				delete $devenv->{$k} if $devenv->{$k} eq $v;
			}

	return $devenv;
}

sub env_from_lines
{
	my $lines = shift;

	chomp @$lines;
	do { s/\r$//; } foreach @$lines;

	my $env = {};

	foreach my $line (@$lines)
			{
				next unless $line =~ /=/;
				my ($k,$v) = split(/=/, $line, 2);
				$env->{$k} = $v;
			}
	return $env;
}

1;
