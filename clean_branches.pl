#!/usr/bin/perl

use strict;
use warnings;
use PGBuild::Options;
use LWP::Simple;
use File::Basename;
use File::Path qw(rmtree);
# process the command line
PGBuild::Options::fetch_options();
# no non-option args allowed here
die("$0: non-option arguments not permitted")
  if @ARGV;
use vars qw($branch);
$branch = 'global';

#
# process config file
#
require $buildconf;

(my $url = $PGBuild::conf{target}) =~s/cgi-bin.*/branches_of_interest.txt/;
 my $branches_of_interest = LWP::Simple::get($url);

die "getting branches of interest" unless $branches_of_interest;

my @branches = split(/\s+/,$branches_of_interest);
my $build_root=$PGBuild::conf{'build_root'};
my $animal=$PGBuild::conf{'animal'};
my %actual_branches= map {$_=>1} @branches;
my $now=time();

for my $dir (glob("$build_root/*")) {
	if (-f "$dir/$animal.last.status") {
	   # It is branch
	   my $d = basename($dir);
	   if (!exists($actual_branches{$d})) {
	   	  open my $f,"<", "$dir/$animal.last.status";
		  my $stamp = <$f>;
		  close $f;
		  if ($now-$stamp >  86400) {
		  	print "Cleaning up branch $d\n";
		  	rmtree($dir);
		  }
	   }
	}
} 
