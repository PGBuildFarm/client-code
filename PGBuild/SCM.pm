
=comment

Copyright (c) 2003-2022, Andrew Dunstan

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

use vars qw($VERSION); $VERSION = 'REL_14';

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
# get_branches()

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

sub find_changed    ## no critic (Subroutines::ProhibitManyArgs)
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

sub get_branches
{
	# noop for cvs
	return ();
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

use PGBuild::Utils qw(:DEFAULT $devnull);
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
	$self->{skip_git_default_check} = $conf->{skip_git_default_check} || 0;
	if (!$self->{skip_git_default_check})
	{
		# check if we can run "git ls-remote --symref" If not, we can't run
		# the default branch name update code.
		# try to test against a known local git repo.
		my $repo = $self->{gitrepo};
		if (exists $self->{mirror} && -d $self->{mirror})
		{
			$repo = $self->{mirror};
		}
		elsif (-d "$self->{build_root}/HEAD/pgsql/.git")
		{
			$repo = "$self->{build_root}/HEAD/pgsql";
		}
		system(qq{git ls-remote --symref "$repo" HEAD > $devnull 2>&1});
		if ($?)
		{
			my $gversion = `git --version`;
			chomp $gversion;
			print "$gversion too old for automatic default branch update\n"
			  if $verbose;
			$self->{skip_git_default_check} = "detected by SCM module";
		}
	}
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


# test if symlinks are available:
# For directories we could use junctions via "mklink /j"
# (c.f. TextUpgradeXVersion.pm) but there is no equivalent for plain files
# which we need here. Windows currently forbids using non-junction mklink
# except by administrative users, which is both stupid and sad.

# It can be fixed by setting a security policy for the user.
# Local Group Policy Editor: Launch gpedit.msc, navigate to
#   Computer Configuration - Windows Settings - Security Settings -
#   Local Policies - User Rights Assignment
# and add the account(s) to the list named Create symbolic links.
# See https://github.com/git-for-windows/git/wiki/Symbolic-Links

sub have_symlink
{
	my $self = shift;
	$self->{have_symlink} = 1 unless $^O eq 'msys' || $^O eq 'MSWin32';
	return $self->{have_symlink} if exists $self->{have_symlink};
	if ($^O eq 'msys')
	{
		my $symlink_exists = eval { symlink("", ""); 1 };
		unless ($symlink_exists)
		{
			$self->{have_symlink} = 0;
			return 0;
		}
		open(my $tg, ">", "tg.txt") || die "opening tg.txt: $1";
		print $tg "boo!\n";
		close $tg;
		unless (symlink "tg.txt", "lnk.txt")
		{
			unlink "lnk.txt", "tg.txt";
			$self->{have_symlink} = 0;
			return 0;
		}
		my $ok = -l "lnk.txt" && -f "lnk.txt";
		my $txt = $ok ? file_contents("lnk.txt") : "";
		$ok &&= $txt eq "boo!\n";
		unlink "lnk.txt", "tg.txt";
		$self->{have_symlink} = $ok;
		return $ok;
	}
	else
	{
		# MSWin32
		open(my $tg, ">", "tg.txt") || return 0;
		print $tg "boo!\n";
		close $tg;
		system(qq{mklink "lnk.txt" "tg.txt" >nul 2>&1});
		my $txt = -e "lnk.txt" ? file_contents("lnk.txt") : "" ;
		my $ok  = $txt eq "boo!\n";
		unlink "lnk.txt", "tg.txt";
		$self->{have_symlink} = $ok;
		return $ok;
	}
	return 0;    # keep perl critic happy
}


# the argument here should be a symbolic link and point to a plain file
# returns:
#    nosuchfile - link is missing
#    notsym     - it's not a symlink
#    dangling   - pointed to file is missing or not a plain file
#    ok         - all good
sub _test_file_symlink
{
	my $file = shift;
	return 'nosuchfile' unless -e $file;
	if ($^O eq 'MSWin32')
	{
		$file =~ s!/!\\!g;    # `dir` doesn't like forward slash paths
		my $dirout = `dir "$file"`;
		return 'notsym' unless $dirout =~ /<SYMLINK>.*\[(.*)\]/;
		$file = $1;
	}
	else
	{
		return 'notsym' unless -l $file;
	}
	return 'dangling' unless -f $file;
	return 'ok';
}

sub _make_symlink
{
	# assumes we have a working symlink (see above)
	# note: unix and windows do link/target in the opposite order
	my $target = shift;
	my $link   = shift;
	if ($^O eq 'MSWin32')
	{
		my $dirswitch = -d $target ? "/d" : "";
		system(qq{mklink $dirswitch "$link" "$target" >nul 2>&1});
	}
	else
	{
		# msys2 perl is smart enough to check if the target is a directory
		# and set up the right type of symlink
		symlink $target, $link;
	}
	return;
}

sub _check_default_branch
{
	my $self   = shift;
	my $target = shift;

	return if $self->{skip_git_default_check};

	my $upstream = $self->{mirror} || $self->{gitrepo};

	my @remote = `git ls-remote --symref $upstream HEAD`;
	chomp(@remote);
	my $remote_def = (grep { /^ref:/ } @remote)[0];
	die "no remote default: @remote" unless $remote_def;
	$remote_def =~ s!.*/([a-zA-Z0-9_-]+)\s.*!$1!;

	my $local = `git symbolic-ref refs/remotes/origin/HEAD`;
	chomp $local;

	return () if $local eq "refs/remotes/origin/$remote_def";

	$local =~ s!.*/!!;
	my $this_branch = `git rev-parse --abbrev-ref HEAD`;
	chomp $this_branch;

	# ok, here we go
	my (@lines, @log);

	# check out the local idea of the upstream default
	@lines = run_log("git checkout $local");
	push(@log, @lines);
	return @log if $?;

	# bring it up to date
	@lines = run_log("git merge -q --ff-only origin/$local");
	push(@log, @lines);
	return @log if $?;

	# delete the bf_HEAD branch if it exists
	my ($hasbfhead) = grep { /bf_HEAD/ } split(/\n/, `git branch`);
	if ($hasbfhead)
	{
		my $here = getcwd();

		# clean out the bf_HEAD working files before we mangle things
		chdir "../../HEAD";
		$self->rm_worktree($target);
		chdir $here;
		@lines = run_log("git branch -d bf_HEAD");
		push(@log, @lines);
		return @log if $?;
	}

	# rename the branch to align with upstream
	@lines = run_log("git branch -m $remote_def");
	push(@log, @lines);
	return @log if $?;

	# fetch the upstream
	@lines = run_log("git fetch");
	push(@log, @lines);
	return @log if $?;

	# realign the branch to fetch from the right upstream branch
	@lines = run_log("git branch --unset-upstream");
	push(@log, @lines);
	return @log if $?;
	@lines = run_log("git branch -u origin/$remote_def");
	push(@log, @lines);
	return @log if $?;

	# bring it up to date
	@lines = run_log("git merge -q --ff-only origin/$remote_def");
	push(@log, @lines);
	return @log if $?;

	# realign the local version of the remote HEAD ref
	@lines = run_log("git symbolic-ref refs/remotes/origin/HEAD "
		  . "refs/remotes/origin/$remote_def");
	push(@log, @lines);
	return @log if $?;

	# now run a pruning fetch, which will remove the last vestiges of the
	# old branch name
	@lines = run_log("git fetch -p");
	push(@log, @lines);
	return @log if $?;

	# recreate the bf_HEAD branch if we deleted it above
	if ($hasbfhead)
	{
		my $here = getcwd;
		chdir "../../HEAD/$target";
		@lines = run_log("git checkout -b bf_HEAD --track origin/$remote_def");
		push(@log, @lines);
		return @log if $?;

		# fix the git index for bf_HEAD
		@lines = run_log("git reset --hard origin/$remote_def");
		push(@log, @lines);
		return @log if $?;
		chdir $here;
	}

	# go back to the branch we were on if we're not on it already
	unless ($this_branch eq 'bf_HEAD')
	{
		@lines = run_log("git checkout $this_branch");
		push(@log, @lines);
		return @log if $?;
	}

	return @log;
}

sub _create_or_update_mirror
{
	my $self   = shift;
	my $target = shift;
	my $branch = shift;

	my $gitserver = $self->{gitrepo};

	my $skip_default_name_check = $self->{skip_git_default_check};

	my @gitlog;
	my $status;
	if (-d $self->{mirror})
	{
		# do we need --prune-tags here? I'm not sure. Only very modern versions
		# of git have --prune-tags, so for now we'll leave it out.
		# see https://git-scm.com/docs/git-fetch/2.25.1 for a discussion
		# of different ways of saying it
		@gitlog = run_log(qq{git --git-dir="$self->{mirror}" fetch --prune});
		if ($self->{ignore_mirror_failure})
		{
			print "Git  mirror failure (ignored)\n", @gitlog if $? && $verbose;
			$status = 0;
		}
		else
		{
			$status = $? >> 8;
		}

		if (!$status && !$skip_default_name_check)
		{
			# make sure we have the same idea of the default branch name
			# as upstream
			my @remote_def = run_log(
				qq{git --git-dir="$self->{mirror}" ls-remote --symref origin HEAD}
			);
			$status = $? >> 8;
			if (!$status)
			{
				my $ref = (grep { m!ref: .*\s+HEAD! } @remote_def)[0];
				$ref =~ s/.*?ref: //;
				$ref =~ s/\s+HEAD.*//;
				system(
					qq{git --git-dir="$self->{mirror}" symbolic-ref HEAD $ref});

				# failure here is local, thus not an ignore-mirror-failure
				$status = $? >> 8;
			}
			elsif ($self->{ignore_mirror_failure})
			{
				print "Git  mirror ls-remote failure (ignored)\n", @remote_def
				  if $verbose;
				$status = 0;
			}
		}

		my $last_gc = find_last("$target.mirror.gc") || 0;
		if (  !$status
			&& $branch eq 'HEAD'
			&& $self->{gchours}
			&& time - $last_gc > $self->{gchours} * 3600)
		{
			my @gclog = run_log(qq{git --git-dir="$self->{mirror}" gc});
			push(@gitlog, "----- mirror garbage collection -----\n", @gclog);
			set_last("$target.mirror.gc");

			# this is also local, so not covered by ignore-mirror-failure
			$status = $? >> 8;
		}
	}
	else    # mirror does not exist
	{
		$gitserver = abs_path($gitserver) if $gitserver =~ m!^[/\\]!;

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

	return @gitlog;
}

sub _setup_new_head
{
	# only called when HEAD has disappeared from under a workdir (or it never
	# existed)

	my $self   = shift;
	my $target = shift;

	my $gitserver = $self->{gitrepo};
	my $base      = $self->{mirror} || $gitserver;
	my $head      = $self->{build_root} . '/HEAD';

	my @gitlog;
	my $status;

	$base = abs_path($base) if $base =~ m!^[/\\]!;

	mkdir $head;

	print "running ", qq{git clone -q $base "$head/$target"}, "\n";
	my @clonelog = run_log(qq{git clone -q $base "$head/$target"});
	push(@gitlog, @clonelog);
	$status = $? >> 8;
	if (!$status)
	{
		my $savedir = getcwd();
		chdir "$head/$target";

		# we're on a fresh clone so the current branch should be the
		# upstream default
		my $defbranch = `git rev-parse --abbrev-ref HEAD`;
		chomp($defbranch);

		# make sure we don't name the new branch HEAD
		my @colog =
		  run_log("git checkout -b bf_HEAD --track origin/$defbranch");
		push(@gitlog, @colog);
		chdir $savedir;
	}
	else
	{
		die "clone status: $status";
	}

	return @gitlog;
}

sub _setup_new_workdir
{
	my $self   = shift;
	my $target = shift;
	my $branch = shift;

	my @gitlog;

	my $head = $self->{build_root} . '/HEAD';
	unless (-d "$head/$target/.git")
	{
		# clone HEAD even if not (yet) needed for a run, as it will be the
		# non-symlinked repo linkd to by all the others.
		@gitlog = $self->_setup_new_head($target);
	}

	# now we can set up the git dir symlinks like git-new-workdir does

	mkdir $target;
	chdir $target;
	mkdir ".git";
	mkdir ".git/logs";

	# skip qw(remotes rr-cache svn). They shouldn't exist on the linked-to
	# directory, regardless of what git-new-workdir thinks
	my @links = qw (config refs logs/refs objects info hooks packed-refs);
	foreach my $link (@links)
	{
		_make_symlink("$head/$target/.git/$link", ".git/$link");
	}
	copy("$head/$target/.git/HEAD", ".git/HEAD");

	my @checklog = $self->_check_default_branch($target);

	# run git fetch in case there are new branches the local repo
	# doesn't yet know about
	my @fetchlog = run_log('git fetch --prune');

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
	push(@gitlog, @checklog, @fetchlog, @colog, @pull_log);

	chdir "..";

	return;
}

sub _setup_new_basedir
{
	my $self   = shift;
	my $target = shift;
	my $branch = shift;

	my $gitserver = $self->{gitrepo};

	my @gitlog;
	my $status;

	my $reference =
	  defined($self->{reference}) ? "--reference $self->{reference}" : "";

	my $base = $self->{mirror} || $gitserver;

	$base = abs_path($base) if $base =~ m!^[/\\]!;

	my @clonelog = run_log("git clone -q $reference $base $target");
	push(@gitlog, @clonelog);
	$status = $? >> 8;
	if (!$status)
	{
		chdir $target;

		my $rbranch = $branch;

		if ($branch eq 'HEAD')
		{
			$rbranch = `git rev-parse --abbrev-ref HEAD`;
			chomp $rbranch;
		}

		my @colog =
		  run_log("git checkout -b bf_$branch --track origin/$rbranch");
		push(@gitlog, @colog);
		chdir "..";
	}

	return @gitlog;
}

sub _update_target
{
	my $self   = shift;
	my $target = shift;
	my $branch = shift;

	my @gitlog;

	# If a run crashed during copy_source(), repair.
	if (-d "./git-save" && !-d "$target/.git")
	{
		move "./git-save", "$target/.git";
	}

	chdir $target;
	my @branches = `git branch 2>&1`;    # too trivial for run_log
	unless (grep { /^\* bf_$branch$/ } @branches)
	{
		if (_test_file_symlink(".git/config") eq 'ok')
		{
			# if it's a symlinked workdir, and the config link isn't into
			# thin air, it's likely that the HEAD has been refreshed, so
			# we'll just check out the branch again
			# this shouldn't happen on HEAD/default, so we don't need
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
			send_result("$target-Git", 1, \@branches);
		}
	}

	# do a checkout if the work tree has apparently been removed
	# If not, don't overwrite anything the user has left there
	my @colog = ();
	@colog = run_log("git checkout . ")
	  unless (grep { $_ ne ".git" } glob(".[a-z]* *"));
	my @gitstat = `git status --porcelain --ignored`;  # too trivial for run_log
	     # make sure it's clean before we try to update it
	if (@gitstat)
	{
		print "Repo is not clean:\n", @gitstat
		  if ($verbose);
		chdir '..';
		push(@gitlog, "===========\n") if @gitlog;
		push(@gitlog, @gitstat);
		send_result("$target-Git-Dirty", 99, \@gitlog);
	}

	my @checklog = $self->_check_default_branch($target);

	# we do this instead of 'git pull' in case the upstream repo
	# has been rebased

	my $rbranch = $branch;

	if ($branch eq 'HEAD')
	{
		# bf_HEAD should map to the upstream default.
		$rbranch = `git symbolic-ref refs/remotes/origin/HEAD`;
		chomp $rbranch;
		$rbranch =~ s!.*/!!;
	}

	my @pulllog = run_log("git fetch --prune");
	my @pull2 = $? ? () : run_log("git reset --hard origin/$rbranch");
	push(@gitlog, @checklog, @colog, @pulllog, @pull2);

	chdir "..";

	# run gc from the parent so we find and set the status file correctly
	if (_test_file_symlink("$target/.git/config") !~ /ok|dangling/
		&& $self->{gchours})
	{
		my $last_gc = find_last("$target.gc") || 0;
		if (time - $last_gc > $self->{gchours} * 3600)
		{
			my @gclog = run_log("git --git-dir=$target/.git gc");
			push(@gitlog, "----- garbage collection -----\n", @gclog);
			set_last("$target.gc");
		}
	}

	return @gitlog;
}

sub checkout
{
	my $self   = shift;
	my $branch = shift;
	my $target = $self->{target};
	my $status;

	# we are currently in the branch directory.
	# If we're using git_use_workdirs, open a file and wait for a lock on it
	# in the HEAD directory

	my $lockfile;

	if (   $self->{use_workdirs}
		&& !defined($self->{reference})
		&& -d '../HEAD/'
		&& $self->have_symlink())
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
		@gitlog = $self->_create_or_update_mirror($target, $branch);
	}

	if (-d $target)
	{
		my @updatelog = $self->_update_target($target, $branch);
		push(@gitlog, @updatelog);
	}
	elsif ($branch ne 'HEAD'
		&& $self->{use_workdirs}
		&& !defined($self->{reference})
		&& $self->have_symlink())
	{
		# not sure how this plays with --reference, so for now I'm excluding
		# that, too
		# currently the following 4 members use --reference:
		#     castoroides protosciurus mastodon narwhal
		my @newwdlog = $self->_setup_new_workdir($target, $branch);
		push(@gitlog, @newwdlog);
	}
	else    # directory doesn't exist, not setting it up as a workdir
	{
		my @newbaselog = $self->_setup_new_basedir($target, $branch);
		push(@gitlog, @newbaselog);
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
		push(@gitlog, "===========\n", @gitstat);
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

sub get_branches
{
	my $self   = shift;
	my $prefix = shift;
	my $target = $self->{target};
	chdir $target;
	my @allbranches = `git branch -a`;
	my @branches;
	foreach (@allbranches)
	{
		chomp;
		s/..//;
		s/ ->.*//;
		s/^$prefix// || next;
		push @branches, $_;
	}
	chdir "..";
	return @branches;
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
