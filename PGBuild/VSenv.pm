

package PGBuild::VSenv;

=comment

Copyright (c) 2003-2022, Andrew Dunstan

See accompanying License file for license details

=cut


use strict;
use warnings;

use Cwd;
use File::Find;

use vars qw($VERSION); $VERSION = 'REL_14';

sub getenv
{
	my $vsdir = shift;
	my $arg = shift || 'x64';

	my $here = getcwd();

	my @prelines = qx{set};

	my $preenv = env_from_lines(\@prelines);

	# File::Find doesn't provide a way to do find's -quit command. I could
	# use a goto to exit here but I prefer not to. With any luck traversing
	# the VS tree won't take too long. Looks like about 2s and not much
	# difference with or without -quit.
	my $where = '';
	my $wanted = sub { $where = $File::Find::dir if /^vcvarsall\.bat\z/s; };
	File::Find::find({ wanted => $wanted }, $vsdir);
	die "vcvarsall.bat not found" unless $where;

	chdir $where;

	my @lines = qx{.\\vcvarsall $arg && set};

	chdir $here;

	my $devenv = env_from_lines(\@lines);

	while (my ($k, $v) = each %$preenv)
	{
		delete $devenv->{$k} if $devenv->{$k} eq $v;
	}

	return $devenv;
}

sub env_from_lines
{
	my $lines = shift;

	chomp @$lines;
	do { s/\r$//; }
	  foreach @$lines;

	my $env = {};

	foreach my $line (@$lines)
	{
		next unless $line =~ /=/;
		my ($k, $v) = split(/=/, $line, 2);
		$env->{$k} = $v;
	}
	return $env;
}

1;
