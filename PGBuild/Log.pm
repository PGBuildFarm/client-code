package PGBuild::Log;

=comment

Copyright (c) 2003-2020, Andrew Dunstan

See accompanying License file for license details

=cut

use strict;
use warnings;

# Log object for a step

# we do this mostly OO style, so almost nothing is exported

## no critic (ProhibitAutomaticExportation)
use Exporter qw(import);
our (@EXPORT, @EXPORT_OK, %EXPORT_TAGS);

@EXPORT      = qw(print_header_line);;
%EXPORT_TAGS = ();
@EXPORT_OK   = ();


use PGBuild::Utils;

sub print_header_line
{
	my $text = shift;
	my $l1 = int ((70 - length($text)) / 2);
	my $l2 = 70 - ($l1 + length($text));
	my $result = repeat('=',$l1) . " $text " . repeat('=',$l2) . "\n";
	return $result;
}

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
