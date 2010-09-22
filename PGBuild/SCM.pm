use strict;
##########################################################################
#
# SCM Class and subclasses for specific SCMs (currently CVS and git).
#
#########################################################################

package PGBuild::SCM;

# factory function to return the right subclass
sub new
{
	my $class = shift;
    my $conf = shift;
	if (defined($conf->{scm}) &&  $conf->{scm} =~ /^git$/i)
	{
		$conf->{scm} = 'git';
		return new PGBuild::SCM::Git $conf;
	}
    elsif ((defined($conf->{scm}) &&  $conf->{scm} =~ /^cvs$/i ) || 
		$conf->{csvrepo} || 
		$conf->{cvsmethod})
    {
		$conf->{scm} = 'cvs';;
		return new PGBuild::SCM::CVS $conf;
    }
    die "only CVS and Git currently supported";
}

# required operations in each subclass:
# new()
# copy_source_required()
# copy_source()
# check_access()
# get_build_path()
# checkout()
# cleanup()
# find_changed()
# get_versions()



##################################
#
# SCM for CVS
#
##################################

package PGBuild::SCM::CVS;


sub new
{                
    my $class = shift;
    my $conf = shift;
    my $self = {};
    $self->{cvsrepo} = 
	$conf->{cvsrepo} || 
	$conf->{scmrepo} || 
	":pserver:anoncvs\@anoncvs.postgresql.org:/projects/cvsroot";
    $self->{cvsmethod} = $conf->{cvsmethod} || 'export';
	$self->{ignore_files} = {};
    return bless $self, $class;
}

sub copy_source_required
{
	my $self = shift;
	return $self->{cvsmethod} ne 'export';
}

sub copy_source
{
	main::copy_source();
}

sub check_access 
{
    my $self = shift;
    my $using_msvc = shift;

    return unless ($self->{cvsrepo} =~ /^:pserver:/ && ! $using_msvc);

	# we can't do this when using cvsnt (for msvc) because it
	# stores the passwords in the registry, damn it
	
	# this is NOT a perfect check, because we don't want to
	# catch the  port which might or might not be there
	# but it will warn most people if necessary, and it's not
	# worth any extra work.
	my $cvspass;
	my $loginfound = 0;
	my $srvr;
	(undef,,undef,$srvr,undef) = split(/:/,$self->{cvsrepo});
	my $qsrvr = quotemeta($srvr);
	if (open($cvspass,glob("~/.cvspass")))
	{
		while (my $line = <$cvspass>)
		{
			if ($line =~ /:pserver:$qsrvr:/)
			{
				$loginfound=1;
				last;
			}

		}
		close($cvspass);
	}
	die "Need to login to :pserver:$srvr first" 
		unless $loginfound;
}

sub get_build_path
{
	my $self = shift;
    my $use_vpath = shift;
    return 
	  ($self->{cvsmethod} eq 'export' && not $use_vpath) ? 
		"pgsql" : 
		  "pgsql.$$";
}

sub checkout
{
	my $self = shift;
	my $branch = shift;
	my $cvsmethod = $self->{cvsmethod};
	my $cvsserver = $self->{cvsrepo};

	my @cvslog;
	# cvs occasionally does weird things when given an explicit HEAD
	# especially on checkout or update.
	# since it's the default anyway, we omit it.
	my $rtag = $branch eq 'HEAD' ? "" : "-r $branch";
	if ($cvsmethod eq 'export')
	{
		# but you have to have a tag for export
		@cvslog = `cvs -d  $cvsserver export -r $branch pgsql 2>&1`;
	}
	elsif (-d 'pgsql')
	{
		chdir 'pgsql';
		@cvslog = `cvs -d $cvsserver update -d $rtag 2>&1`;
		chdir '..';
		find_ignore($self);
	}
	else
	{
		@cvslog = `cvs -d $cvsserver co $rtag pgsql 2>&1`;
		find_ignore($self);
	}
	my $status = $? >>8;
	print "======== cvs $cvsmethod log ===========\n",@cvslog
		if ($main::verbose > 1);
	# can't call writelog here because we call cleanlogs after the
	# scm stage, since we only clear out the logs if we find we need to
	# do a build run.
	# consequence - we don't save the cvs log if we don't do a run
	# doesn't matter too much because if CVS fails we exit anyway.

	my $merge_conflicts = grep {/^C/} @cvslog;
	my $mod_files = grep { /^M/ } @cvslog;
	my $unknown_files = grep {/^\?/ } @cvslog;
	my @bad_ignore = ();
	foreach my $ignore (keys %{$self->{ignore_files}})
	{
		push (@bad_ignore,"X $ignore\n") 
			if -e $ignore;
	}

	if ( $cvsmethod ne 'export' && $unknown_files && 
		! ($main::nosend && $main::nostatus ) )
	{
		sleep 20;
		my @statout = `cd pgsql && cvs -d $cvsserver status 2>&1`;
		$unknown_files = grep { /^\?/ } @statout;
	}
		
	
	main::send_result('CVS',$status,\@cvslog)	if ($status);
	main::send_result('CVS-Merge',$merge_conflicts,\@cvslog) 
		if ($merge_conflicts);
	unless ($main::nosend && $main::nostatus)
	{
		main::send_result('CVS-Dirty',$mod_files,\@cvslog) 
			if ($mod_files);
		main::send_result('CVS-Extraneous-Files',$unknown_files,\@cvslog)
			if ($unknown_files);
		main::send_result('CVS-Extraneous-Ignore',
						  scalar(@bad_ignore),\@bad_ignore)
			if (@bad_ignore);
	}

	# if we were successful, however, we return the info so that 
	# we can put it in the newly cleaned logdir  later on.
	return \@cvslog;
}

sub cleanup
{
	my $self = shift;
	unlink keys %{$self->{ignore_files}};
}

# find_ignore is now a private method of the subclass.
sub find_ignore
{

	my $self = shift;
	my $ignore_file =  $self->{ignore_files};
	my $cvsmethod = $self->{cvsmethod};

	my $wanted = sub 
	{
		# skip CVS dirs if using update
		if ($cvsmethod eq 'update' && $_ eq 'CVS' && -d $_)
		{
			$File::Find::prune = 1;
		}
		elsif (-f $_ && $_ eq '.cvsignore')
		{
			my $fh;
			open($fh,$_) || die "cannot open $File::Find::name for reading";
			my @names = (<$fh>);
			close($fh);
			chomp @names;
			map { s!^!$File::Find::dir/!; } @names;
			@{$ignore_file}{@names} = (1) x @names;
		}
	};

	File::Find::find({wanted => $wanted}, 'pgsql') ;
}

sub find_changed {
	my $self = shift;
	my $current_snap = shift;
	my $last_run_snap = shift;
	my $last_success_snap = shift;
	my $changed_files = shift;
	my $changed_since_success = shift;
	my $cvsmethod = $self->{cvsmethod};

	my $wanted = sub
	{
		# skip CVS dirs if using update
		if ($cvsmethod eq 'update' && $_ eq 'CVS' && -d $_)
		{
			$File::Find::prune = 1;
		}
		else
		{
			my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,
				$size,$atime,$mtime,$ctime,$blksize,$blocks) = lstat($_);
			
			if (-f _ )
			{
				$$current_snap = $mtime  if ($mtime > $$current_snap);
				
				my $sname = $File::Find::name;
				if ($last_run_snap && ($mtime > $last_run_snap))
				{
					$sname =~ s!^pgsql/!!;
					push(@$changed_files,$sname);
				}
				elsif ($last_success_snap && ($mtime > $last_success_snap))
				{
					$sname =~ s!^pgsql/!!;
					push(@$changed_since_success,$sname);
				}
			}
		}
	};

	File::Find::find({wanted => $wanted}, 'pgsql') ;
}


sub get_versions
{
	my $self = shift;
	return if $self->{cvsmethod} eq "export";

	my $flist = shift;
	return unless @$flist;
	my @cvs_status;
	# some shells (e.g cygwin::bash ) choke on very long command lines
	# so do this in batches.
	while (@$flist)
	{
		my @chunk = splice(@$flist,0,200);
		my @res = `cd pgsql && cvs status @chunk 2>&1` ;
		push(@cvs_status,@res);
		my $status = $? >>8;
		print "======== cvs status log ===========\n",@cvs_status
			if ($main::verbose > 1);
		main::send_result('CVS-status',$status,\@cvs_status)	if ($status);
	}
	my @fchunks = split(/File:/,join("",@cvs_status));
	my @repolines;
	foreach (@fchunks)
	{
		# we need to report the working revision rather than the
		# repository revision version in case the file has been
		# updated between the time we did the checkout/update and now.
		next unless 
			m!
			Working\srevision:\s+
			(\d+(\.\d+)+)
			.*Repository.revision:.
			(\d+(\.\d+)+)
			.*
			/(pgsql/.*)
			,v
			!sx ;

		push(@repolines,"$5 $1");
	}
	@$flist = (@repolines);
}

##################################
#
# SCM for git
#
##################################

package PGBuild::SCM::Git;

use File::Copy;

sub new
{                
    my $class = shift;
    my $conf = shift;
    my $self = {};
    $self->{gitrepo} = 
	  $conf->{scmrepo} || "git://git.postgresql.org/git/postgresql.git";
	$self->{reference} = $conf->{git_reference} 
	  if defined ($conf->{git_reference});
    return bless $self, $class;
}

sub copy_source_required
{
	my $self = shift;
	# always copy git
	return 1;
}

sub copy_source
{
	# we don't want to copy the (very large) .git directory
	# so we just move it out of the way during the copy
	# there might be better ways of doing this, but this should do for now

	move "pgsql/.git", "./git-save";
	main::copy_source();
	move "./git-save","pgsql/.git";
}

sub get_build_path
{
	my $self = shift;
    my $use_vpath = shift;
    return "pgsql.$$";
}


sub check_access 
{
	# no login required?
	return;
}

sub checkout
{

	my $self = shift;
	my $branch = shift;
	my $gitserver = $self->{gitrepo};
	my $status;

	my @gitlog;
	if (-d 'pgsql')
	{
		chdir 'pgsql';
		my @branches = `git branch 2>&1`;
		unless (grep {/^\* bf_$branch$/} @branches)
		{
			print "Missing checked out branch bf_$branch:\n",@branches 
			  if ($main::verbose);
			push @branches,"Missing checked out branch bf_$branch:\n";
			main::send_result('Git',$status,\@branches)
		}
		@gitlog = `git pull 2>&1`;
		chdir '..';
	}
	else
	{
		my $reference = defined($self->{reference}) ?
		  "--reference $self->{reference}" : "";
		@gitlog = `git clone -q $reference $gitserver pgsql 2>&1`;
		$status = $? >>8;
		if (!$status)
		{
			chdir "pgsql";
			# make sure we don't name the new branch HEAD
			# also, safer to checkout origin/master than origin/HEAD, I think
			my $rbranch = $branch eq 'HEAD' ? 'master' : $branch;
			my @colog = 
			  `git checkout -b bf_$branch --track origin/$rbranch 2>&1`;
			push(@gitlog,@colog);
			chdir "..";
		}
	}
	$status = $? >>8;
	print "================== git log =====================\n",@gitlog
		if ($main::verbose > 1);
	# can't call writelog here because we call cleanlogs after the
	# checkout stage, since we only clear out the logs if we find we need to
	# do a build run.
	# consequence - we don't save the git log if we don't do a run
	# doesn't matter too much because if git fails we exit anyway.

	# Don't call git clean here. If the user has left stuff lying around it
	# might be important to them, so instead of blowing it away just bitch
	# loudly.

	chdir "pgsql";
	my @gitstat = `git status 2>&1`;
	chdir "..";

	@gitstat = grep 
	{not /Already.up-to-date|On branch bf_$branch|nothing to commit .working directory clean./}
	  @gitstat;


	main::send_result('Git',$status,\@gitlog)	if ($status);
	unless ($main::nosend && $main::nostatus)
	{
		push(@gitlog,"===========",@gitstat);
		main::send_result('Git-Dirty',99,\@gitlog) 
			if (@gitstat);
	}

	# if we were successful, however, we return the info so that 
	# we can put it in the newly cleaned logdir  later on.
	return \@gitlog;
}


sub cleanup
{
	my $self = shift;
	chdir "pgsql";
	system("git clean -dfxq");
	chdir "..";
}

# private Class level routine for getting changed file data
sub parse_log
{
	my $cmd = shift;
	my @lines = `$cmd`;
	chomp(@lines);
	my $commit;
	my $list = {};
	foreach my $line (@lines)
	{
		next if $line =~ /^(Author:|Date:|\s)/;
		next unless $line;
		if ($line =~ /^commit ([0-9a-zA-Z]+)/)
		{
			$commit = $1;
		}
		else
		{
			# anything else should be a file name
			$line =~ s/\s+$//; # make sure all trailing space is trimmed
			$list->{$line} ||= $commit; # keep most recent commit
		}
	}
	return $list;
}

sub find_changed
{
	my $self = shift;
	my $current_snap = shift;
	my $last_run_snap = shift;
	my $last_success_snap = shift || 0;
	my $changed_files = shift;
	my $changed_since_success = shift;

	my $cmd = 'git --git-dir=pgsql/.git log -n 1 --pretty=format:%ct';
	$$current_snap = `$cmd` +0;

	# get the list of changed files and stash the commit data

	if ($last_run_snap)
	{
		if ($last_success_snap > 0 && $last_success_snap < $last_run_snap)
		{
			$last_success_snap++;
			my $lrsscmd = 
			  "git  --git-dir=pgsql/.git log --name-only " . 
				"--since=$last_success_snap --until=$last_run_snap";
			$self->{changed_since_success} = parse_log($lrsscmd);
		}
		else
		{
			$self->{changed_since_success} = {};
		}
		$last_run_snap++;
		my $lrscmd = 
		  "git  --git-dir=pgsql/.git log --name-only " . 
			"--since=$last_run_snap";
		$self->{changed_since_last_run} = parse_log($lrscmd);
		foreach my $file (keys %{$self->{changed_since_last_run}})
		{
			delete $self->{changed_since_success}->{$file};
		}
	}
	else
	{
		$self->{changed_since_last_run} = {};
	}

	@$changed_files = sort keys %{$self->{changed_since_last_run}};
	@$changed_since_success = sort keys %{$self->{changed_since_success}};
}

sub get_versions
{
	my $self = shift;
	my $flist = shift;
	return unless @$flist;
	my @repoversions;

	# for git we have already collected and stashed the info, so we just 
	# extract it from the stash.

	foreach my $file (@$flist)
	{
		if (exists $self->{changed_since_last_run}->{$file})
		{
			my $commit = $self->{changed_since_last_run}->{$file};
			push(@repoversions,"$file $commit");
		}
		elsif (exists $self->{changed_since_success}->{$file})
		{
			my $commit = $self->{changed_since_success}->{$file};
			push(@repoversions,"$file $commit");
		}
	}
	@$flist = @repoversions;
}

1;
