
=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

##########################################################################
#
# SCM Class and subclasses for specific SCMs (currently CVS and git).
#
#########################################################################

package PGBuild::SCM;

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_7';

# factory function to return the right subclass
sub new
{
	my $class  = shift;
	my $conf   = shift;
	my $target = shift || 'pgsql';
	if (defined($conf->{scm}) && $conf->{scm} =~ /^git$/i)
	{
		$conf->{scm} = 'git';
		return PGBuild::SCM::Git->new($conf, $target);
	}
	elsif ((defined($conf->{scm}) && $conf->{scm} =~ /^cvs$/i)
		|| $conf->{csvrepo}
		|| $conf->{cvsmethod})
	{
		$conf->{scm} = 'cvs';
		return PGBuild::SCM::CVS->new($conf, $target);
	}
	die "only CVS and Git currently supported";
}

# common routine use for copying the source, called by the
# SCM objects (directly, not as class methods)
sub copy_source
{
	my $using_msvc = shift;
	my $target     = shift;
	my $build_path = shift;

	# annoyingly, there isn't a standard perl module to do a recursive copy
	# and I don't want to require use of the non-standard File::Copy::Recursive
	if ($using_msvc)
	{
		system("xcopy /I /Q /E $target $build_path 2>&1");
	}
	else
	{
		system("cp -R -p $target $build_path 2>&1");
	}
	my $status = $? >> 8;
	die "copying directories: $status" if $status;
	return;
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
# log_id()
# rm_worktree()

##################################
#
# SCM for CVS
#
##################################

package PGBuild::SCM::CVS;    ## no critic (ProhibitMultiplePackages)

use strict;
use warnings;

use File::Find;
use File::Basename;
use PGBuild::Options;
use PGBuild::Utils;

sub new
{
	my $class  = shift;
	my $conf   = shift;
	my $target = shift;
	my $self   = {};
	$self->{cvsrepo} =
	     $conf->{cvsrepo}
	  || $conf->{scmrepo}
	  || ":pserver:anoncvs\@anoncvs.postgresql.org:/projects/cvsroot";
	$self->{cvsmethod}         = $conf->{cvsmethod} || 'update';
	$self->{use_git_cvsserver} = $conf->{use_git_cvsserver};
	$self->{ignore_files}      = {};
	$self->{target}            = $target;

	die "can't use export cvs method with git-cvsserver"
	  if $self->{use_git_cvsserver} && ($self->{cvsmethod} eq 'export');

	return bless $self, $class;
}

sub copy_source_required
{
	my $self = shift;
	return $self->{cvsmethod} ne 'export';
}

sub copy_source
{
	my $self       = shift;
	my $using_msvc = shift;
	my $target     = $self->{target};
	my $build_path = $self->{build_path};
	die "no build path" unless $build_path;
	PGBuild::SCM::copy_source($using_msvc, $target, $build_path);
	return;
}

sub check_access
{
	my $self       = shift;
	my $using_msvc = shift;

	return unless ($self->{cvsrepo} =~ /^:pserver:/ && !$using_msvc);

	# we can't do this when using cvsnt (for msvc) because it
	# stores the passwords in the registry, damn it

	# this is NOT a perfect check, because we don't want to
	# catch the  port which might or might not be there
	# but it will warn most people if necessary, and it's not
	# worth any extra work.
	my $cvspass;
	my $loginfound = 0;
	my $srvr;
	(undef,, undef, $srvr, undef) = split(/:/, $self->{cvsrepo});
	my $qsrvr = quotemeta($srvr);
	if (open($cvspass, '<', glob("~/.cvspass")))
	{

		while (my $line = <$cvspass>)
		{
			if ($line =~ /:pserver:$qsrvr:/)
			{
				$loginfound = 1;
				last;
			}

		}
		close($cvspass);
	}
	die "Need to login to :pserver:$srvr first"
	  unless $loginfound;
	return;
}

sub get_build_path
{
	my $self      = shift;
	my $use_vpath = shift;
	my $target    = $self->{target};
	$self->{build_path} =
	  ($self->{cvsmethod} eq 'export' && (!$use_vpath))
	  ? "$target"
	  : "$target.build";
	return $self->{build_path};
}

sub log_id
{

	# CVS doesn't have a concept of a tree id.
	return;
}

sub checkout
{
	my $self   = shift;
	my $branch = shift;
	$self->{branch} = $branch;
	my $cvsmethod = $self->{cvsmethod};
	my $cvsserver = $self->{cvsrepo};
	my $target    = $self->{target};

	my @cvslog;

	if ($self->{use_git_cvsserver})
	{

		# git-cvsserver treats a branch as a module, so we have to do things
		# a bit differently from the old CVS server
		my $module = $branch eq 'HEAD' ? 'master' : $branch;

		if (-d $target)
		{
			chdir $target;
			@cvslog = `cvs -d $cvsserver update -d 2>&1`;
			chdir '..';
			find_ignore($self);
		}
		else
		{
			@cvslog = `cvs -d $cvsserver co -d $target $module 2>&1`;
			find_ignore($self);
		}
	}
	else
	{

		# old style CVS repo where the module name is 'pgsql' and we
		# check out branches

		# cvs occasionally does weird things when given an explicit HEAD
		# especially on checkout or update.
		# since it's the default anyway, we omit it.
		my $rtag = $branch eq 'HEAD' ? "" : "-r $branch";

		if ($cvsmethod eq 'export')
		{

			# but you have to have a tag for export
			@cvslog = `cvs -d  $cvsserver export -r $branch $target 2>&1`;
		}
		elsif (-d $target)
		{
			chdir $target;
			@cvslog = `cvs -d $cvsserver update -d $rtag 2>&1`;
			chdir '..';
			find_ignore($self);
		}
		else
		{
			@cvslog = `cvs -d $cvsserver co $rtag $target 2>&1`;
			find_ignore($self);
		}
	}
	my $status = $? >> 8;
	print "======== cvs $cvsmethod log ===========\n", @cvslog
	  if ($verbose > 1);

	# can't call writelog here because we call cleanlogs after the
	# scm stage, since we only clear out the logs if we find we need to
	# do a build run.
	# consequence - we don't save the cvs log if we don't do a run
	# doesn't matter too much because if CVS fails we exit anyway.

	my $merge_conflicts = grep { /^C/ } @cvslog;
	my $mod_files       = grep { /^M/ } @cvslog;
	my $unknown_files   = grep { /^\?/ } @cvslog;
	my @bad_ignore      = ();
	foreach my $ignore (keys %{ $self->{ignore_files} })
	{
		push(@bad_ignore, "X $ignore\n")
		  if -e $ignore;
	}

	if (   $cvsmethod ne 'export'
		&& $unknown_files
		&& !($nosend && $nostatus))
	{
		sleep 20;
		my @statout = `cd $target && cvs -d $cvsserver status 2>&1`;
		$unknown_files = grep { /^\?/ } @statout;
	}

	send_result("$target-CVS", $status, \@cvslog) if ($status);
	send_result("$target-CVS-Merge", $merge_conflicts, \@cvslog)
	  if ($merge_conflicts);
	unless ($nosend && $nostatus)
	{
		send_result("$target-CVS-Dirty", $mod_files, \@cvslog)
		  if ($mod_files);
		send_result("$target-CVS-Extraneous-Files", $unknown_files, \@cvslog)
		  if ($unknown_files);
		send_result("$target-CVS-Extraneous-Ignore",
			scalar(@bad_ignore), \@bad_ignore)
		  if (@bad_ignore);
	}

	# if we were successful, however, we return the info so that
	# we can put it in the newly cleaned logdir  later on.
	return \@cvslog;
}

sub cleanup
{
	my $self = shift;
	unlink keys %{ $self->{ignore_files} };
	return;
}

sub rm_worktree
{
	# noop for cvs
}

# find_ignore is now a private method of the subclass.
sub find_ignore
{

	my $self        = shift;
	my $target      = $self->{target};
	my $ignore_file = $self->{ignore_files};
	my $cvsmethod   = $self->{cvsmethod};

	my $wanted = sub {

		# skip CVS dirs if using update
		if ($cvsmethod eq 'update' && $_ eq 'CVS' && -d $_)
		{
			$File::Find::prune = 1;
		}
		elsif (-f $_ && $_ eq '.cvsignore')
		{
			my $fh;
			open($fh, '<', $_)
			  || die "cannot open $File::Find::name for reading";
			my @names = (<$fh>);
			close($fh);
			chomp @names;
			my $found_dir = $File::Find::dir;
			do { s!^!$found_dir/!; }
			  foreach @names;
			@{$ignore_file}{@names} = (1) x @names;
		}
	};

	File::Find::find({ wanted => $wanted }, $target);
	return;
}

sub find_changed ## no critic (Subroutines::ProhibitManyArgs)
{
	my $self                  = shift;
	my $current_snap          = shift;
	my $last_run_snap         = shift;
	my $last_success_snap     = shift;
	my $changed_files         = shift;
	my $changed_since_success = shift;
	my $cvsmethod             = $self->{cvsmethod};
	my $target                = $self->{target};

	my $wanted = sub {

		# skip CVS dirs if using update
		if ($cvsmethod eq 'update' && $_ eq 'CVS' && -d $_)
		{
			$File::Find::prune = 1;
		}
		else
		{
			my (
				$dev,   $ino,     $mode, $nlink, $uid,
				$gid,   $rdev,    $size, $atime, $mtime,
				$ctime, $blksize, $blocks
			) = lstat($_);

			if (-f _ )
			{
				$$current_snap = $mtime if ($mtime > $$current_snap);

				my $sname = $File::Find::name;
				if ($last_run_snap && ($mtime > $last_run_snap))
				{
					$sname =~ s!^$target/!!;
					push(@$changed_files, $sname);
				}
				elsif ($last_success_snap && ($mtime > $last_success_snap))
				{
					$sname =~ s!^$target/!!;
					push(@$changed_since_success, $sname);
				}
			}
		}
	};

	File::Find::find({ wanted => $wanted }, $target);
	return;
}

sub get_versions
{
	my $self = shift;
	return if $self->{cvsmethod} eq "export";

	my $flist = shift;
	return unless @$flist;

	my $target = $self->{target};
	my @cvs_status;

	# some shells (e.g cygwin::bash ) choke on very long command lines
	# so do this in batches.
	while (@$flist)
	{
		my @chunk = splice(@$flist, 0, 200);
		my @res = `cd $target && cvs status @chunk 2>&1`;
		push(@cvs_status, @res);
		my $status = $? >> 8;
		print "======== $target-cvs status log ===========\n", @cvs_status
		  if ($verbose > 1);
		send_result("$target-CVS-status", $status, \@cvs_status)
		  if ($status);
	}
	my @fchunks = split(/File:/, join("", @cvs_status));
	my @repolines;
	foreach (@fchunks)
	{
		## no critic (RegularExpressions::ProhibitComplexRegexes)

		# we need to report the working revision rather than the
		# repository revision version in case the file has been
		# updated between the time we did the checkout/update and now.

		my $module = $target;    # XXX is it??
		$module = ($self->{branch} eq 'HEAD' ? 'master' : $self->{branch})
		  if $self->{use_git_cvsserver};
		next
		  unless m!
			Working\srevision:\s+
			(\d+(\.\d+)+)
			.*Repository.revision:.
			(\d+(\.\d+)+)
			.*
			/($module/.*)
			,v
			!sx;

		push(@repolines, "$5 $1");
	}
	@$flist = (@repolines);
	return;
}

##################################
#
# SCM for git
#
##################################

package PGBuild::SCM::Git;    ## no critic (ProhibitMultiplePackages)

use strict;
use warnings;

use Cwd qw(getcwd abs_path);
use File::Copy;
use File::Path;
use Fcntl qw(:flock);

use File::Find;
use File::Basename;

use PGBuild::Utils;
use PGBuild::Options;

sub new
{
	my $class  = shift;
	my $conf   = shift;
	my $target = shift;
	my $self   = {};
	$self->{gitrepo} = $conf->{scmrepo}
	  || "https://git.postgresql.org/git/postgresql.git";
	$self->{reference} = $conf->{git_reference}
	  if defined($conf->{git_reference});

	# need to use abs_path here to avoid some idiocy in msysGit.
	$self->{mirror} = (
		$target eq 'pgsql'
		? abs_path("$conf->{build_root}") . "/pgmirror.git"
		: abs_path("$conf->{build_root}") . "/$target-mirror.git"
	) if $conf->{git_keep_mirror};
	$self->{ignore_mirror_failure} = $conf->{git_ignore_mirror_failure};
	$self->{use_workdirs}          = $conf->{git_use_workdirs};
	$self->{build_root}            = $conf->{build_root};
	$self->{gchours} = 7 * 24;    # default 1 week.
	if (exists($conf->{git_gc_hours}))
	{
		$self->{gchours} = $conf->{git_gc_hours};
	}
	$self->{target} = $target;
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
	my $self       = shift;
	my $using_msvc = shift;
	my $target     = $self->{target};
	my $build_path = $self->{build_path};
	die "no build path" unless $build_path;

	# we don't want to copy the (very large) .git directory
	# so we just move it out of the way during the copy
	# there might be better ways of doing this, but this should do for now

	move "$target/.git", "./git-save";
	PGBuild::SCM::copy_source($using_msvc, $target, $build_path);
	move "./git-save", "$target/.git";
	return;
}

sub get_build_path
{
	my $self      = shift;
	my $use_vpath = shift;             # irrelevant for git
	my $target    = $self->{target};
	$self->{build_path} = "$target.build";
	return $self->{build_path};
}

sub check_access
{
	# no login required?
	return;
}

sub log_id
{
	my $self = shift;
	writelog('githead', [ $self->{headref} ])
	  if $self->{headref};
	return;
}

sub checkout
{

	my $self      = shift;
	my $branch    = shift;
	my $gitserver = $self->{gitrepo};
	my $target    = $self->{target};
	my $status;

	# Msysgit does some horrible things, especially when it expects a drive
	# spec and doesn't get one.  So we extract it if it exists and use it
	# where necessary.

	my $drive = "";
	my $cwd   = getcwd();
	$drive = substr($cwd, 0, 2) if $cwd =~ /^[A-Z]:/;

	# we are currently in the branch directory.
	# If we're using git_use_workdirs, open a file and wait for a lock on it
	# in the HEAD directory

	my $lockfile;

	if (   $self->{use_workdirs}
		&& !defined($self->{reference})
		&& $^O ne "MSWin32"
		&& $^O ne "msys"
		&& -d '../HEAD/')
	{
		open($lockfile, ">", "../HEAD/checkout.LCK")
		  || die "opening checkout lockfile: $!";

		# no LOCK_NB here so we wait for the lock
		die "acquiring lock on $self->{build_root}/HEAD/checkout.LCK"
		  unless flock($lockfile, LOCK_EX);
	}

	my @gitlog;
	if ($self->{mirror})
	{

		if (-d $self->{mirror})
		{
			@gitlog = run_log(qq{git --git-dir="$self->{mirror}" fetch});
			$status = $self->{ignore_mirror_failure} ? 0 : $? >> 8;

			my $last_gc = find_last("$target.mirror.gc") || 0;
			if (  !$status
				&& $branch eq 'HEAD'
				&& $self->{gchours}
				&& time - $last_gc > $self->{gchours} * 3600)
			{
				my @gclog = run_log(qq{git --git-dir="$self->{mirror}" gc});
				push(@gitlog, "----- mirror garbage collection -----\n",
					@gclog);
				set_last("$target.mirror.gc");
				$status = $? >> 8;
			}
		}
		else
		{
			my $char1 = substr($gitserver, 0, 1);
			$gitserver = "$drive$gitserver"
			  if ($char1 eq '/' or $char1 eq '\\');

			# this will fail on older git versions
			# workaround is to do this manually in the buildroot:
			#   git clone --bare $gitserver pgmirror.git
			#   (cd pgmirror.git && git remote add --mirror origin $gitserver)
			# or equivalent for other targets
			@gitlog = run_log("git clone --mirror $gitserver $self->{mirror}");
			$status = $? >> 8;
		}
		if ($status)
		{
			unshift(@gitlog, "Git mirror failure:\n");
			print @gitlog if ($verbose);
			send_result('Git-mirror', $status, \@gitlog);
		}
	}

	if (-d $target)
	{
		chdir $target;
		my @branches = `git branch`;    # too trivial for run_log
		unless (grep { /^\* bf_$branch$/ } @branches)
		{
			if (-l ".git/config" && -f ".git/config")
			{
				# if it's a symlinked workdir, and the config link isn't into
				# thin air, it's likely that the HEAD has been refreshed, so
				# we'll just check out the branch again
				# this shouldn't happen on HEAD/master, so we don't need
				# special branch name logic
				my @ncolog =
				  run_log("git checkout -b bf_$branch --track origin/$branch");
				push(@gitlog, @ncolog);
			}
			else
			{
				# otherwise we expect the branch to be there, and it's a failure
				# if it's not there

				chdir '..';
				print "Missing checked out branch bf_$branch:\n", @branches
				  if ($verbose);
				unshift @branches, "Missing checked out branch bf_$branch:\n";
				send_result("$target-Git", $status, \@branches);
			}
		}

		# do a checkout in case the work tree has been removed
		# this is harmless if it hasn't
		my @colog   = run_log("git checkout . ");
		my @pulllog = run_log("git pull");
		push(@gitlog, @colog, @pulllog);
		chdir '..';

		# run gc from the parent so we find and set the status file correctly
		if (!-l "$target/.git/config" && $self->{gchours})
		{
			my $last_gc = find_last("$target.gc") || 0;
			if (time - $last_gc > $self->{gchours} * 3600)
			{
				my @gclog = run_log("git --git-dir=$target/.git gc");
				push(@gitlog, "----- garbage collection -----\n", @gclog);
				set_last("$target.gc");
			}
		}
	}
	elsif ($branch ne 'HEAD'
		&& $self->{use_workdirs}
		&& !defined($self->{reference})
		&& $^O ne "MSWin32"
		&& $^O ne "msys")
	{

		# exclude Windows for now - need to make sure how to do symlinks
		# portably there
		# early versions don't have mklink

		# not sure how this plays with --reference, so for now I'm excluding
		# that, too
		# currently the following 4 members use --reference:
		#     castoroides protosciurus mastodon narwhal

		my $head = $self->{build_root} . '/HEAD';
		unless (-d "$head/$target/.git")
		{
			# clone HEAD even if not (yet) needed for a run, as it will be the
			# non-symlinked repo linkd to by all the others.

			my $base = $self->{mirror} || $gitserver;

			my $char1 = substr($base, 0, 1);
			$base = "$drive$base"
			  if ($char1 eq '/' or $char1 eq '\\');

			mkdir $head;

			my @clonelog = run_log(qq{git clone -q $base "$head/$target"});
			push(@gitlog, @clonelog);
			$status = $? >> 8;
			if (!$status)
			{
				my $savedir = getcwd();
				chdir "$head/$target";

				# make sure we don't name the new branch HEAD
				my @colog =
				  run_log("git checkout -b bf_HEAD --track origin/master");
				push(@gitlog, @colog);
				chdir $savedir;
			}
		}

		# now we can set up the git dir symlinks like git-new-workdir does

		mkdir $target;
		chdir $target;
		mkdir ".git";
		mkdir ".git/logs";
		my @links = qw (config refs logs/refs objects info hooks
		  packed-refs remotes rr-cache svn);
		foreach my $link (@links)
		{
			system(qq{ln -s "$head/$target/.git/$link" ".git/$link"});
		}
		copy("$head/$target/.git/HEAD", ".git/HEAD");

		my @branches = `git branch`;
		chomp @branches;
		my @colog;
		if (grep { /\bbf_$branch\b/ } @branches)
		{
			# Don't try to create an existing branch
			# the target dir only might have been wiped away,
			# so we need to handle this case.
			@colog = run_log("git checkout -f bf_$branch");
		}
		else
		{
			@colog =
			  run_log("git checkout -f -b bf_$branch --track origin/$branch");
		}

		# Make sure the branch we just checked out is up to date.
		my @pull_log = run_log("git pull");
		push(@gitlog, @colog, @pull_log);

		chdir "..";
	}
	else
	{
		my $reference =
		  defined($self->{reference}) ? "--reference $self->{reference}" : "";

		my $base = $self->{mirror} || $gitserver;

		my $char1 = substr($base, 0, 1);
		$base = "$drive$base"
		  if ($char1 eq '/' or $char1 eq '\\');

		my @clonelog = run_log("git clone -q $reference $base $target");
		push(@gitlog, @clonelog);
		$status = $? >> 8;
		if (!$status)
		{
			chdir $target;

			# make sure we don't name the new branch HEAD
			# also, safer to checkout origin/master than origin/HEAD, I think
			my $rbranch = $branch eq 'HEAD' ? 'master' : $branch;
			my @colog =
			  run_log("git checkout -b bf_$branch --track origin/$rbranch");
			push(@gitlog, @colog);
			chdir "..";
		}
	}
	$status = $? >> 8;
	print "================== git log =====================\n", @gitlog
	  if ($verbose > 1);

	close($lockfile) if $lockfile;

	# can't call writelog here because we call cleanlogs after the
	# checkout stage, since we only clear out the logs if we find we need to
	# do a build run.
	# consequence - we don't save the git log if we don't do a run
	# doesn't matter too much because if git fails we exit anyway.

	# Don't call git clean here. If the user has left stuff lying around it
	# might be important to them, so instead of blowing it away just bitch
	# loudly.

	chdir "$target";
	my @gitstat = `git status --porcelain`;    # too trivial for run_log
	my $headref = `git show-ref --heads -- bf_$branch 2>&1`;    # ditto
	$self->{headref} = (split(/\s+/, $headref))[0];
	chdir "..";

	send_result("$target-Git", $status, \@gitlog) if ($status);
	unless ($nosend && $nostatus)
	{
		push(@gitlog, "===========", @gitstat);
		send_result("$target-Git-Dirty", 99, \@gitlog)
		  if (@gitstat);
	}

	# if we were successful, however, we return the info so that
	# we can put it in the newly cleaned logdir  later on.
	return \@gitlog;
}

sub cleanup
{
	my $self   = shift;
	my $target = $self->{target};
	chdir $target;
	system("git clean -dfxq");
	chdir "..";
	return;
}

sub rm_worktree
{
	my $self   = shift;
	my $target = $self->{target};
	chdir $target;
	foreach my $f (glob(".[a-z]* *"))
	{
		next if $f eq '.git';
		if (-d $f)
		{
			rmtree($f);
		}
		else
		{
			unlink $f;
		}
	}
	chdir "..";
	return;
}

# private Class level routine for getting changed file data
sub parse_log
{
	my $cmd = shift;

	# don't use run_log here in case it has dates
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
			$line =~ s/\s+$//;    # make sure all trailing space is trimmed
			$list->{$line} ||= $commit;    # keep most recent commit
		}
	}
	return $list;
}

sub find_changed
{
	my $self                  = shift;
	my $target                = $self->{target};
	my $current_snap          = shift;
	my $last_run_snap         = shift;
	my $last_success_snap     = shift || 0;
	my $changed_files         = shift;
	my $changed_since_success = shift;

	# too trivial to use run_log
	my $cmd = qq{git --git-dir=$target/.git log -n 1 "--pretty=format:%ct"};
	$$current_snap = `$cmd` + 0;

	# get the list of changed files and stash the commit data

	if ($last_run_snap)
	{
		if ($last_success_snap > 0 && $last_success_snap < $last_run_snap)
		{
			$last_success_snap++;
			my $lrsscmd = "git  --git-dir=$target/.git log --name-only "
			  . "--since=$last_success_snap --until=$last_run_snap";
			$self->{changed_since_success} = parse_log($lrsscmd);
		}
		else
		{
			$self->{changed_since_success} = {};
		}
		$last_run_snap++;
		my $lrscmd = "git  --git-dir=$target/.git log --name-only "
		  . "--since=$last_run_snap";
		$self->{changed_since_last_run} = parse_log($lrscmd);
		foreach my $file (keys %{ $self->{changed_since_last_run} })
		{
			delete $self->{changed_since_success}->{$file};
		}
	}
	else
	{
		$self->{changed_since_last_run} = {};
	}

	@$changed_files         = sort keys %{ $self->{changed_since_last_run} };
	@$changed_since_success = sort keys %{ $self->{changed_since_success} };
	return;
}

sub get_versions
{
	my $self  = shift;
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
			push(@repoversions, "$file $commit");
		}
		elsif (exists $self->{changed_since_success}->{$file})
		{
			my $commit = $self->{changed_since_success}->{$file};
			push(@repoversions, "$file $commit");
		}
	}
	@$flist = @repoversions;
	return;
}

1;
