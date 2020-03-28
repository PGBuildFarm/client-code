package PGBuild::Log;

=comment

Copyright (c) 2003-2020, Andrew Dunstan

See accompanying License file for license details

=cut

use strict;
use warnings;

# Log object for a step

# we do this OO style, so nothing is exported

use PGBuild::Utils;

sub new
{
	my $class = shift;
	my $step = shift;
	my $self = {
		step => $step,
		files => [],
	};
	bless($self,$class);
	return $self;
}

sub add_log
{
	my $self = shift;
	my $logfile = shift;
	my $filepos = shift;
	return unless -e $logfile;
	my $contents = file_contents($logfile,$filepos);
	my $list = $self->{files};
	my $fobj = {name=> $logfile, contents => $contents};
	push(@$list, $fobj);
	return;
}

sub add_log_lines
{
	my $self = shift;
	my $logfile = shift;
	my $contents = shift; # can be scalar string or arrayref of strings
	$contents = join("",@$contents) if ref $contents eq 'ARRAY';
	my $list = $self->{files};
	my $fobj = {name=> $logfile, contents => $contents};
	push(@$list, $fobj);
	return;
}

sub log_string
{
	my $self = shift;
	my $str = "log files for step $self->{step}:\n";
	my $list = $self->{files};
	foreach my $file (@$list)
	{
		$str .= "$log_file_marker $file->{name} $log_file_marker\n";
		$str .= $file->{contents};
		$str .= "\n" unless substr($str,-1) eq "\n";
	}
	return $str;
}

1;
