# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=pod

Copyright (c) 2003-2025, Andrew Dunstan

See accompanying License file for license details

=head1 PGBuild::Modules::ABICompCheck

This module is used for ABI compliance checking of PostgreSQL builds by
comparing the latest commit on a stable branch with the most recent tag on that
branch. This helps detect unintended changes that could break compatibility for
extensions or client applications.

=head2 EXECUTION FLOW

The module follows these steps to perform an ABI comparison:

=over 4

=item 1.

The build farm completes its standard build and installation of PostgreSQL for
the latest commit on a given stable branch.

=item 2.

The C<install> hook of the ABICompCheck module is triggered.

=item 3.

The module identifies the most recent tag for a particular branch (e.g.,
REL_16_1) to use as a baseline for comparison against the most recent commit of
the branch.

=item 4.

It checks if a pre-existing, complete build and ABI dump for this baseline tag
exists in its working directory (C<buildroot/abicheck.$animal_name>).

=item 5.

If the baseline tag's build is missing or incomplete, the module performs a
fresh build of that tag:
	- It checks out the source code for the tag.
	- It runs C<configure>, C<make>, and C<make install> for the tag in an
	  isolated directory.
	- It uses C<abidw> to generate XML representations of the ABI for key
	  binaries (like C<postgres>, C<libpq.so>, C<ecpg> - These are the
	  default binaries and can be customised by animal owners) from this tag
	  build. These are stored for future runs.

=item 6.

The module then generates ABI XML files for the same set of key binaries from
the main build (the latest commit).

=item 7.

Using C<abidiff>, it compares the ABI XML file of each binary from the latest
commit against the corresponding file from the baseline tag.

=item 8.

Any differences detected by C<abidiff> are collected into a log report. If no
differences are found, a success message is logged.

=item 9.

The final report, containing either the ABI differences or "no abi diffs found
in this run", is sent to the build farm server as part of the overall build
status.

=back

=head2 CONFIGURATION OPTIONS

The module supports the following configuration options under `abi_comp_check`
key in build-farm.conf:

=over 4

=item B<abi_compare_root>

Specifies the root directory for ABI comparison data. If not set, defaults to
C<buildroot/abicheck.$animal_name>.

=item B<binaries_rel_path>

A hash reference mapping binary names to their relative paths for ABI
comparison. Defaults to:

  {
    'postgres' => 'bin/postgres',
    'ecpg' => 'bin/ecpg',
    'libpq.so' => 'lib/libpq.so',
  }

=item B<abidw_flags_list>

An array reference containing flags to pass to C<abidw>. Defaults to:

  [qw(
    --drop-undefined-syms --no-architecture --no-comp-dir-path
    --no-elf-needed --no-show-locs --type-id-style hash
  )]

=item B<tag_for_branch>

A hash reference mapping branch names to their corresponding tags for ABI
comparison. Defaults to empty hash which means latest tags for all branches:

  {}

=back

=head2 EXTRA BUT IMPORTANT INFO

=over 4

=item *

This module have msvc related duped from run_build.pl script but later I
realised C<abidiff> supports only elf binaries. Maybe those functions can be
used in future if some other ABI Compliance checking tool supports them.

=item *

This module only works for stable branches in compliance with the PostgreSQL
ABI policy for minor releases.

=item *

Debug information is required for build to be able to use this module

=item *

Before using this module, ensure that you have the build-essential,
abigail-tools, git installed for your animal.

=back

=head2 EXAMPLE LOG OUTPUT

The output on the server will have name 'abi-compliance-check'
Example output will be:

	Branch: REL_17_STABLE
	Git HEAD: 61c37630774002fb36a5fa17f57caa3a9c2165d9
	Changes since: REL_17_6

	latest_tag updated from REL_17_5 to REL_17_6
	no abi diffs found in this run - Or ABI diff if any
	....other build logs for recent tag if any

=cut

package PGBuild::Modules::ABICompCheck;
use PGBuild::Log;
use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $branch_root $steps_completed);

use strict;
use warnings;
use File::Path 'mkpath';
use File::Copy;
use Cwd qw(abs_path getcwd);


# strip required namespace from package name
(my $MODULE = __PACKAGE__) =~ s/PGBuild::Modules:://;

our ($VERSION); $VERSION = 'REL_19_1';

# Helper function to emit timestamped debug messages
sub emit {
	print time_str(), "ABICompCheck :: ", @_, "\n" if $verbose;
}

my $hooks = {
	# 'need-run' => \&need_run,
	'installcheck' => \&installcheck,      # Main ABI comparison logic runs after install
	'cleanup' => \&cleanup,      # Clean up temporary files after build
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch = shift;       # The branch of Postgres that's being built.
	my $conf = shift;         # ref to the whole config object
	my $pgsql = shift;        # postgres build dir

	if ($^O ne 'linux')
	{
		emit("Only Linux is supported for ABICompCheck Module, skipping.");
		return;
	}

	# Only proceed if this is a stable branch with git SCM, not using msvc
	if ($conf->{scm} ne 'git')
	{
		emit("Only git SCM is supported for ABICompCheck Module, skipping.");
		return;
	}
	if ($branch !~ /_STABLE$/)
	{
		emit("Skipping ABI check, '$branch' is not a stable branch.");
		return;
	}
	
	# Ensure debug information is available in compilation - required for libabigail tools
	if ($conf->{using_meson})
	{
		# not working, can't understand why
		my $meson_opts = $conf->{meson_opts} || [];
		unless (grep { $_ eq '--debug' } @$meson_opts)
		{
			emit("--debug is required option for ABICompCheck with meson.");
			return;
		}
	}else{
		my $config_opts = $conf->{config_opts} || [];
		unless (grep { $_ eq '--enable-debug' } @$config_opts)
		{
			emit("--enable-debug is required option for ABICompCheck.");
			return;
		}
	}

	# Set up working directory for ABI comparison data
	my $abi_compare_root =
	  $conf->{abi_compare_root} || "$buildroot/abicheck.$conf->{animal}";
	if (   !defined($conf->{abi_compare_root})
		&& !-d $abi_compare_root
		&& -d "$buildroot/abicheck/HEAD")
	{
		# support legacy use without animal name
		$abi_compare_root = "$buildroot/abicheck";
	}

	# Define which binaries to compare
	my $binaries_rel_path = $conf->{abi_comp_check}{binaries_rel_path}
	  || {
		'postgres' => 'bin/postgres',      # Main server binary
		'ecpg' => 'bin/ecpg',             # Embedded SQL preprocessor
		'libpq.so' => 'lib/libpq.so',     # Client library
	  };

	# Configure abidw tool flags for ABI XML generation
	my $abidw_flags_list = $conf->{abi_comp_check}{abidw_flags_list}
	  || [qw(
        --drop-undefined-syms --no-architecture --no-comp-dir-path  
        --no-elf-needed --no-show-locs --type-id-style hash  
      )];


	# the tag_for_branch is to specify a tag to compare the ABIs with in a specific branch
	# expected to look like { <branchname> : <tag_name> }
	my $tag_for_branch = $conf->{abi_comp_check}{tag_for_branch} || {};

	mkdir $abi_compare_root
	  unless -d $abi_compare_root;

	# we need to segregate from-source builds so they don't corrupt
	# non-from-source saves

	# my $fs_abi_compare_root = "$buildroot/fs-upgrade.$animal";

	# mkdir $fs_abi_compare_root
	#   if $from_source && !-d $fs_abi_compare_root;

	# could even set up several of these (e.g. for different branches)
	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql,
		abi_compare_root => $abi_compare_root,
		binaries_rel_path => $binaries_rel_path,
		abidw_flags_list => $abidw_flags_list,
		tag_for_branch => $tag_for_branch,

		  # fs_abi_compare_root => $fs_abi_compare_root,
	};
	bless($self, $class);

	# Register this module's hooks with the build farm framework
	register_module_hooks($self, $hooks);
	return;
}

# Main function - runs after PostgreSQL installation to perform ABI comparison
sub installcheck
{
	my $self = shift;
	return unless step_wanted('abi_comp-check');

	emit "installcheck";
	my $scm = PGBuild::SCM->new($self->{bfconf});

	my $pgbranch = $self->{pgbranch};
	my $abi_compare_loc = "$self->{abi_compare_root}/$pgbranch";
	mkdir $abi_compare_loc unless -d $abi_compare_loc;
	my $tag_for_branch = $self->{tag_for_branch} || {};
	my $baseline_tag;

	# find the tag to compare with for the branch
	if (exists $tag_for_branch->{$pgbranch})
	{
		my $tag_pattern = $tag_for_branch->{$pgbranch};
		my @tags = run_log(qq{git -C ./pgsql tag --list '$tag_pattern'}); # get the list of tags based on the tag pattern provided in config
		chomp(@tags);

		unless (@tags) {
			emit "Specified tag pattern '$tag_pattern' for branch '$pgbranch' does not match any tags.";
			return;
		}
		# use the first tag from the list in case of regex
		emit "Using $tags[0] as the baseline tag for branch $pgbranch based on pattern '$tag_pattern'";
		$baseline_tag = $tags[0];
	}else{
		emit "Finding latest tag for branch $pgbranch";
		$baseline_tag = run_log(qq{git -C ./pgsql describe --tags --abbrev=0 2>/dev/null});	# Find the latest tag
	}
	chomp $baseline_tag;
	my $comparison_ref = '';
	$comparison_ref = run_log(qq{git -C ./pgsql merge-base master bf_$pgbranch});	# Find the very first commit for current branch
	die "git merge-base failed: $?" if $?;
	chomp $comparison_ref;

	if ($baseline_tag) {
		# if some latest tag is found, then get the commit SHA for the latest tagged commit
		# and compare with the first commit for current branch
		# using `git merge-base --is-ancestor A B` to
		my $tag_commit = run_log(qq{git -C ./pgsql rev-list -n 1 $baseline_tag});
		die "git rev-list failed: $?" if $?;
		chomp $tag_commit;

		my $is_ancestor = system(qq{git -C ./pgsql merge-base --is-ancestor $tag_commit $comparison_ref 2>/dev/null});
		if ($is_ancestor != 0) {
			# If the latest tag is not an ancestor of the first branch commit
			# we need to use the latest tag as the comparison reference
			# else we use the first commit of the branch instead of tag
			$comparison_ref = $baseline_tag;
			emit "Baseline tag: $baseline_tag";
		}
	}

	# get the previous tag from the latest_tag file for current branch if exists
	my $latest_tag_file = "$abi_compare_loc/latest_tag";
	my $previous_tag = '';
	if (-e $latest_tag_file)
	{
		open my $fh, '<', $latest_tag_file
		  or die "Cannot open $latest_tag_file: $!";
		$previous_tag = <$fh>;
		close $fh;
		chomp $previous_tag if $previous_tag;
	}

	# Initialise output log with basic information
	my $latest_commit_sha = run_log(qq{git -C ./pgsql rev-parse HEAD});
	die "git rev-parse HEAD failed: $?" if $?;
	chomp $latest_commit_sha;
	my @saveout = (
		"Branch: $pgbranch\n",
		"Git HEAD: $latest_commit_sha\n",
		"Changes since: $comparison_ref\n\n"
	);

	# Determine if we need to rebuild the latest tag binaries
	my $rebuild_tag = 0;
	if ($previous_tag ne $comparison_ref)
	{
		push(@saveout,"baseline_tag updated from $previous_tag to $comparison_ref\n");
		$rebuild_tag = 1;
	}
	else
	{
		# Check if all XML files for the baseline tag exist. If not, we need to rebuild.
		my $tag_xml_dir = "$abi_compare_loc/$comparison_ref/xmls";
		foreach my $key (keys %{ $self->{binaries_rel_path} })
		{
			my $xml_file = "$tag_xml_dir/$key.abi";
			if (!-e $xml_file)
			{
				emit "ABI XML for '$key' is missing for tag '$comparison_ref'. Triggering rebuild.";
				push(@saveout, "rebuild for tag '$comparison_ref' due to missing ABI XML for '$key'.\n");
				$rebuild_tag = 1;
				last;
			}
		}
	}

	# Rebuild the latest tag from scratch, if needed by any of the checks above
	if ($rebuild_tag)
	{
		# Clean up old tag directory
		rmtree("$abi_compare_loc/$previous_tag")
		  if $previous_tag && -d "$abi_compare_loc/$previous_tag";


		# Set up directories for tag build
		my $tag_build_dir = "$abi_compare_loc/$comparison_ref";
		my $tag_log_dir = "$tag_build_dir/build_logs";

		mkpath($tag_log_dir)
		  unless -d $tag_log_dir;

		# Checkout the tag we want to compare against
		run_log(qq{git -C ./pgsql checkout $comparison_ref});
		die "git checkout $comparison_ref failed: $?" if $?;

		# got this git save piece of code from PGBuild::SCM::Git::copy_source
		move "./pgsql/.git", "./git-save";
		PGBuild::SCM::copy_source($self->{bfconf}{using_msvc},
			"./pgsql", "$tag_build_dir/pgsql");
		move "./git-save", "./pgsql/.git";

		# checkout back to original branch
		run_log(qq{git -C ./pgsql checkout bf_$pgbranch});
		die "git checkout bf_$pgbranch failed: $?" if $?;

		# Build the tag: configure, make, install
		$self->configure($abi_compare_loc, $comparison_ref);
		$self->make($abi_compare_loc, $comparison_ref);
		$self->make_install($abi_compare_loc, $comparison_ref);

		# Generate ABI XML files for the tag build
		my $installdir = "$abi_compare_loc/$comparison_ref/inst";
		$self->_generate_abidw_xml($installdir, $abi_compare_loc, $comparison_ref);

		# Store latest tag to file for future runs
		open my $tag_fh, '>', $latest_tag_file
		  or die "Could not open $latest_tag_file: $!";
		print $tag_fh $comparison_ref;
		close $tag_fh;
	}

	# Generate ABI XML files for the current build or the most recent commit
	if (-d "./inst")
	{
		$self->_generate_abidw_xml("./inst", $abi_compare_loc, $pgbranch);
	}

	# Compare ABI between current branch and latest tag
	my ($diff_found, $diff_log) = $self->_compare_and_log_abi_diff($comparison_ref, $pgbranch);

	# Add comparison results to output
	my $status=0;
	if ($diff_found)
	{
		push(@saveout, $diff_log->log_string);
		$status=1;
	}
	else
	{
		push(@saveout, "no abi diffs found in this run\n");
	}
	# Include tag build logs if we rebuilt
	if ($rebuild_tag)
	{
		my $tag_log_dir = "$abi_compare_loc/$comparison_ref/build_logs";
		foreach my $log_name ('configure', 'build', 'install')
		{
			my $log_file = "$tag_log_dir/$log_name.log";
			if (-e $log_file)
			{
				my $build_log = PGBuild::Log->new("${log_name}_log");
				$build_log->add_log($log_file);
				push(@saveout, $build_log->log_string);
			}
		}
	}

	# Write final report to build farm logs
	writelog("abi-compliance-check", \@saveout);

	send_result('ABICompCheck', $status, \@saveout) if $status;
	$steps_completed .= " ABICompCheck";

	return;
}

# Configure step for meson builds
sub meson_setup
{
	my $self = shift;
	my $installdir = shift;
	my $latest_tag = shift;
	my $env = $self->{bfconf}{config_env};
	$env = {%$env};    # clone it
	delete $env->{CC}
	  if $self->{bfconf}{using_msvc};    # this can confuse meson in this case
	local %ENV = (%ENV, %$env);
	$ENV{MSYS2_ARG_CONV_EXCL} = "-Dextra";

	my $meson_opts = $self->{bfconf}{meson_opts} || [];
	my @quoted_opts;
	foreach my $c_opt (@$meson_opts)
	{
		if ($c_opt =~ /['"]/)
		{
			push(@quoted_opts, $c_opt);
		}
		elsif ($self->{bfconf}{using_msvc})
		{
			push(@quoted_opts, qq{"$c_opt"});
		}
		else
		{
			push(@quoted_opts, "'$c_opt'");
		}
	}

	my $docs_opts = "";
	$docs_opts = "-Ddocs=enabled"
	  if defined($self->{bfconf}{optional_steps}{build_docs});
	$docs_opts .= " -Ddocs_pdf=enabled"
	  if $docs_opts && ($self->{bfconf}{extra_doc_targets} || "") =~ /[.]pdf/;

	my $confstr = join(" ",
		"-Dauto_features=disabled", @quoted_opts,
		$docs_opts, "-Dlibdir=lib",
		qq{-Dprefix="$installdir"});

	my $srcdir = $self->{bfconf}{from_source} || 'pgsql';
	my $pgsql = $self->{pgsql};

	# use default ninja backend on all platforms
	my @confout = run_log("meson setup $confstr $pgsql $srcdir");

	my $status = $? >> 8;

	move "$pgsql/meson-logs/meson-log.txt", "$pgsql/meson-logs/setup.log";

	my $log = PGBuild::Log->new($latest_tag . "setup");
	foreach my $logfile ("$pgsql/meson-logs/setup.log",
		"$pgsql/src/include/pg_config.h")
	{
		$log->add_log($logfile) if -s $logfile;
	}
	push(@confout, $log->log_string);

	emit "======== setup output ===========\n", @confout if ($verbose > 1);

	# writelog($latest_tag . 'configure', \@confout);

	# if ($status)
	# {
	# 	send_result('Configure', $status, \@confout);
	# }

	# return @confout;
}

# non-meson MSVC setup
sub msvc_setup
{
	my $self = shift;
	my $config_opts = $self->{bfconf}{config_opts} || {};
	my $lconfig = {%$config_opts};
	my $conf = Data::Dumper->Dump([$lconfig], ['config']);
	my @text = (
		"# Configuration arguments for vcbuild.\n",
		"# written by buildfarm client \n",
		"use strict; \n",
		"use warnings;\n",
		"our $conf \n", "1;\n"
	);

	my $pgsql = $self->{pgsql};
	my $handle;
	open($handle, ">", "$pgsql/src/tools/msvc/config.pl")
	  || die "opening $pgsql/src/tools/msvc/config.pl: $!";
	print $handle @text;
	close($handle);

	push(@text, "# no configure step for MSCV - config file shown\n");

	# writelog('configure', \@text);

	# return @text;
}

sub configure
{
	my $self = shift;
	my $abi_compare_loc = shift;
	my $latest_tag = shift;
	emit "running configure ...";
	my $branch = $self->{pgbranch};
	my $tag_log_dir = "$abi_compare_loc/$latest_tag/build_logs";
	my @confout;

	# Choose configuration method based on build system
	if ($self->{bfconf}{using_meson}
		&& ($branch eq 'HEAD' || $branch ge 'REL_16_STABLE'))
	{
		$self->meson_setup("$abi_compare_loc/$latest_tag/inst");
	}

	if ($self->{bfconf}{using_msvc})
	{
		$self->msvc_setup();
	}

	# traditional PostgreSQL build start
	my $config_opts = $self->{bfconf}{config_opts} || [];

	# Quote configuration options properly
	my @quoted_opts;
	foreach my $c_opt (@$config_opts)
	{
		if ($c_opt =~ /['"]/)
		{
			push(@quoted_opts, $c_opt);
		}
		else
		{
			push(@quoted_opts, "'$c_opt'");
		}
	}

	# Set install prefix to our tag-specific directory
	my $confstr =
	  join(" ", @quoted_opts, "--prefix=$abi_compare_loc/$latest_tag/inst");

	# Set up environment variables for configure
	my $env = $self->{bfconf}{config_env};
	$env = {%$env};    # shallow clone it
	if ($self->{bfconf}{use_valgrind}
		&& exists $self->{bfconf}{valgrind_config_env_extra})
	{
		my $vgenv = $self->{bfconf}{valgrind_config_env_extra};
		while (my ($key, $val) = each %$vgenv)
		{
			if (defined $env->{$key})
			{
				$env->{$key} .= " $val";
			}
			else
			{
				$env->{$key} = $val;
			}
		}
	}

	# create environment string for command
	my $envstr = "";
	while (my ($key, $val) = each %$env)
	{
		$envstr .= "$key='$val' ";
	}

	# Run configure command
	@confout = run_log(
		"$envstr cd $abi_compare_loc/$latest_tag/pgsql && ./configure $confstr"
	);

	my $status = $? >> 8;

	emit "======== configure output ===========\n", @confout  if ($verbose > 1);

	# Include config.log if available
	if (-s "$abi_compare_loc/$latest_tag/pgsql/config.log")
	{
		my $log = PGBuild::Log->new($latest_tag . "_configure");
		$log->add_log("config.log");
		push(@confout, $log->log_string);
	}

	# Save configure log: will be visible only if --keepall option is enabled
	open my $fh, '>', "$tag_log_dir/configure.log"
	  or die "Could not open $tag_log_dir/configure.log: $!";
	print $fh @confout;
	close $fh;

	# if ($status)
	# {
	# 	send_result('Configure', $status, \@confout);
	# }

	# return \@confout;
}

sub make
{
	my $self = shift;
	my $abi_compare_loc = shift;
	my $latest_tag = shift;
	emit "running build ...";

	my $pgsql = "$abi_compare_loc/$latest_tag/pgsql";
	my $tag_log_dir = "$abi_compare_loc/$latest_tag/build_logs";
	my (@makeout);
	
	# Choose build command based on build system
	if ($self->{bfconf}{using_meson})
	{
		my $meson_jobs = $self->{bfconf}{meson_jobs};
		my $jflag = defined($meson_jobs) ? " --jobs=$meson_jobs" : "";
		@makeout = run_log("meson compile -C $pgsql --verbose $jflag");
		move "$pgsql/meson-logs/meson-log.txt", "$pgsql/meson-logs/compile.log";
		if (-s "$pgsql/meson-logs/compile.log")
		{
			my $log = PGBuild::Log->new("compile");
			$log->add_log("$pgsql/meson-logs/compile.log");
			push(@makeout, $log->log_string);
		}
	}
	elsif ($self->{bfconf}{using_msvc})
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log("perl build.pl");
		chdir $branch_root;
	}
	else
	{
		# Traditional make build
		my $make = $self->{bfconf}{make} || 'make';
		my $make_jobs = $self->{bfconf}{make_jobs} || 1;
		my $make_cmd = $make;
		$make_cmd = "$make -j $make_jobs"
		  if ($make_jobs > 1);
		@makeout = run_log("cd $pgsql && $make_cmd");
	}
	my $status = $? >> 8;
	
	# Save build log: will be visible only if --keepall option is enabled
	open my $fh, '>', "$tag_log_dir/build.log"
	  or die "Could not open $tag_log_dir/build.log: $!";
	print $fh @makeout;
	close $fh;
	emit "======== make log ===========\n", @makeout if ($verbose > 1);
	# $status ||= check_make_log_warnings('latestbuild', $verbose)
	#   if $check_warnings;

	# send_result('Build', $status, \@makeout) if $status;
	# return \@makeout;
}

sub make_install
{
	my $self = shift;
	my $abi_compare_loc = shift;
	my $latest_tag = shift;
	emit "running install ...";

	my $pgsql = "$abi_compare_loc/$latest_tag/pgsql";
	my $installdir = "$abi_compare_loc/$latest_tag/inst";
	my $tag_log_dir = "$abi_compare_loc/$latest_tag/build_logs";
	my @makeout;
	
	# Choose install command based on build system
	if ($self->{bfconf}{using_meson})
	{
		@makeout = run_log("meson install -C $pgsql ");
		move "$pgsql/meson-logs/meson-log.txt", "$pgsql/meson-logs/install.log";
		my $log = PGBuild::Log->new("install");
		if (-s "$pgsql/meson-logs/install.log")
		{
			$log->add_file("$pgsql/meson-logs/install.log");
			push(@makeout, $log->log_string);
		}
	}
	elsif ($self->{bfconf}{using_msvc})
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log(qq{perl install.pl "$installdir"});
		chdir $branch_root;
	}
	else
	{
		# Traditional make install
		my $make = $self->{bfconf}{make} || 'make';
		@makeout = run_log("cd $pgsql && $make install");
	}
	my $status = $? >> 8;
	
	# Save install log: will be visible only if --keepall option is enabled
	open my $fh, '>', "$tag_log_dir/install.log"
	  or die "Could not open $tag_log_dir/install.log: $!";
	print $fh @makeout;
	close $fh;
	emit "======== make install log ===========\n", @makeout if ($verbose > 1);

	# send_result('Install', $status, \@makeout) if $status;

	# On Windows and Cygwin avoid path problems associated with DLLs
	# by copying them to the bin dir where the system will pick them

	foreach my $dll (glob("$installdir/lib/*pq.dll"))
	{
		my $dest = "$installdir/bin/" . basename($dll);
		copy($dll, $dest);
		chmod 0755, $dest;
	}

	# return @makeout;
}

# Generate ABI XML files using abidw tool for specified binaries
sub _generate_abidw_xml
{
	my $self = shift;
	my $install_dir = shift;
	my $abi_compare_loc = shift;
	my $version_identifier = shift; # either comparison ref(i.e. latest tag or latest tag SHA) OR branch name Because both are expected to have separate path for install directories

	emit "Generating ABIDW XML for $version_identifier";

	my $binaries_rel_path = $self->{binaries_rel_path};
	my $abidw_flags_str = join ' ', @{ $self->{abidw_flags_list} };

	# Determine if this is for a tag or current branch
	my $xml_dir;
	my $log_dir;
	if ($version_identifier eq $self->{pgbranch})
	{
		# Current branch - stored in branch directory
		$xml_dir = "$abi_compare_loc/xmls";
		$log_dir = "$abi_compare_loc/logs";
	}
	else
	{
		# Latest tag - stored in tag-specific directory
		$xml_dir = "$abi_compare_loc/$version_identifier/xmls";
		$log_dir = "$abi_compare_loc/$version_identifier/build_logs";
	}

	mkpath($xml_dir) unless -d $xml_dir;
	mkpath($log_dir) unless -d $log_dir;

	# Generate ABI XML for each configured binary
	while (my ($target_name, $rel_path) = each %{$binaries_rel_path})
	{
		my $input_path = "$install_dir/$rel_path";
		my $output_file = "$xml_dir/$target_name.abi";

		if (-e $input_path && -f $input_path)
		{
			# Run abidw to extract ABI information into XML format
			my $cmd =
			  qq{abidw --out-file "$output_file" "$input_path" $abidw_flags_str};
			my $log_file = "$log_dir/abidw-$target_name.log";

			my $exit_status =
			  $self->_log_command_output($cmd, $log_file,
				"abidw for $target_name", 1);

			if ($exit_status)
			{
				emit "abidw failed for $target_name (from $input_path) with status $exit_status. Version: $version_identifier";
			}
			else
			{
				emit "Successfully generated ABI XML for $target_name";
			}
		}
		else
		{
			emit "Warning: Input file '$input_path' for $target_name not found. Skipping ABI generation for this target.";
		}
	}

	return;
}

# Execute a command and log its output to a file
sub _log_command_output
{
	my ($self, $cmd, $log_file, $cmd_desc, $no_die) = @_;

	emit "Executing: $cmd_desc";

	my @output = run_log(qq{$cmd});
	my $exit_status = $? >> 8;

	if (@output)
	{
		open my $fh, '>', $log_file or warn "could not open $log_file: $!";
		if ($fh)
		{
			print $fh @output;
			close $fh;
		}
	}

	if ($exit_status && !$no_die)
	{
		die "$cmd_desc failed with status $exit_status. Log: $log_file";
	}
	else
	{
		emit "Successfully executed $cmd_desc";
	}
	return $exit_status;
}

# Compare ABI XML files between tag and current branch using abidiff
sub _compare_and_log_abi_diff
{
	my ($self, $latest_tag, $current_branch) = @_;
	if (!defined $latest_tag || !defined $current_branch)
	{
		emit "Warning: _compare_and_log_abi_diff called with undefined parameters. Skipping comparison.";
		return (0, undef);
	}

	my $abi_compare_root = $self->{abi_compare_root};
	my $pgbranch = $self->{pgbranch};

	emit "Comparing ABI between baseline tag $latest_tag and it's latest commit";

	# Set up directories for comparison
	my $tag_xml_dir = "$abi_compare_root/$pgbranch/$latest_tag/xmls";
	my $branch_xml_dir = "$abi_compare_root/$pgbranch/xmls";
	my $log_dir = "$abi_compare_root/$pgbranch/diffs";

	# Clean up any previous existing logs
	rmtree($log_dir) if -d $log_dir;
	mkpath($log_dir) unless -d $log_dir;
	
	my $diff_found = 0;
	my $log = PGBuild::Log->new("abi-compliance-check");

	# Compare each binary's ABI using abidiff
	foreach my $key (keys %{ $self->{binaries_rel_path} })
	{
		my $tag_file = "$tag_xml_dir/$key.abi";
		my $branch_file = "$branch_xml_dir/$key.abi";

		if (-e $tag_file && -e $branch_file)
		{
			# Run abidiff to compare ABI XML files
			my $log_file = "$log_dir/$key-$latest_tag.log";
			my $exit_status = $self->_log_command_output(
				qq{abidiff "$tag_file" "$branch_file" --leaf-changes-only --no-added-syms --show-bytes},
				$log_file, "abidiff for $key", 1
			);

			# Non-zero exit means differences were found
			if ($exit_status != 0)
			{
				$diff_found = 1;
				$log->add_log($log_file);
				emit "ABI difference found for $key.abi";
			}
		}
		else
		{
			# Handle missing XML files
			$diff_found = 1;
			my $log_file = "$log_dir/$key-$latest_tag.log";
			emit "ABI difference for $key: one file is missing (tag: $tag_file, branch: $branch_file). Comparison skipped.";
			open my $fh, '>', $log_file
			  or warn "could not open $log_file: $!";
			if ($fh)
			{
				print $fh "ABI difference: file is missing.\n";
				print $fh "Tag file: $tag_file (exists: "
				  . ((-e $tag_file) ? 1 : 0) . ")\n";
				print $fh "Branch file: $branch_file (exists: "
				  . ((-e $branch_file) ? 1 : 0) . ")\n";
				close $fh;
				$log->add_log($log_file);
			}
		}
	}

	return ($diff_found, $log);
}

# Clean up temporary files to save disk space
sub cleanup
{
	my $self = shift;
	if (!$keepall) {
		my $abi_compare_loc = "$self->{abi_compare_root}/$self->{pgbranch}";
		my $latest_tag_file = "$abi_compare_loc/latest_tag";

		# Find which tag directory to clean up
		my $current_tag = '';
		if (-e $latest_tag_file)
		{
			open my $fh, '<', $latest_tag_file
			or die "Cannot open $latest_tag_file: $!";
			$current_tag = <$fh>;
			close $fh;
			chomp $current_tag if $current_tag;
		}
		return unless $current_tag; # this could happen only in some worst case

		# Remove all files in latest tag directory except xmls
		rmtree("$abi_compare_loc/$current_tag/inst") if -d "$abi_compare_loc/$current_tag/inst";
		rmtree("$abi_compare_loc/$current_tag/pgsql") if -d "$abi_compare_loc/$current_tag/pgsql";
		rmtree("$abi_compare_loc/$current_tag/build_logs") if -d "$abi_compare_loc/$current_tag/build_logs";
	}

	emit "cleaning up" if $verbose > 1;
	return;
}

1;
