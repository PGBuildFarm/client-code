# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=pod

Copyright (c) 2003-2025, Andrew Dunstan

See accompanying License file for license details

=head1 PGBuild::Modules::ABICompCheck

This module is used for ABI compliance checking of PostgreSQL builds by
comparing the latest commit on a stable branch with a baseline reference
specified either in the animal's configuration file or in the
C<.abi-compliance-history> file. This helps detect unintended changes that could
break compatibility for extensions or client applications.

=head2 EXECUTION FLOW

The module follows these steps to perform an ABI comparison:

=over

=item 1.

The build farm completes its standard build and installation of PostgreSQL for
the latest commit on a given stable branch.

=item 2.

The C<installcheck> hook of the ABICompCheck module is triggered. A C<binaries_rel_path> hash
is constructed dynamically by scanning all the .so files directly under the C<inst/lib> directory.

=item 3.

The module identifies a baseline reference for comparison by using the following precedence order:

=over

=item *

The tag specified for the current branch in the animal's configuration file using C<tag_for_branch>.

=item *

The most recent commit SHA specified in C<pgsql/.abi-compliance-history> file.

=back

If neither is configured, the module returns early and does not perform ABI comparison.

=item 4.

It checks if a pre-existing, complete build and ABI dump for this baseline
reference exists in its working directory (C<buildroot/abicheck.$animal_name>).

=item 5.

If the baseline reference's build is missing or has changed, the module performs
a fresh build:

=over

=item *

 It checks out the source code for the baseline reference.

=item *
It runs C<configure>, C<make>, and C<make install> for the baseline reference in an isolated
directory.

=item *

It uses C<abidw> to generate XML representations of the ABI for key binaries
(the C<postgres> executable and all shared libraries found directly under the
installation's C<lib> directory) from this baseline build. These are stored for
future runs.

=back

=item 6.

The module then generates ABI XML files for the same set of key binaries from
the main build (the latest commit).

=item 7.

Using C<abidiff>, it compares the ABI XML file of each binary from the latest
commit against the corresponding file from the baseline reference.

=item 8.

Any differences detected by C<abidiff> are collected into a log report. A list
of successfully compared binaries is also included in the output. If no
differences are found, a success message is logged.

=item 9.

The final report, containing the list of compared binaries, either the ABI
differences or "no abi diffs found in this run", and optionally build logs if
the baseline was rebuilt, is sent to the build farm server as part of the
overall build status.

=back

=head2 CONFIGURATION OPTIONS

The module supports the following configuration options under `abi_comp_check`
key in build-farm.conf:

=over

=item C<abi_compare_root>

Specifies the root directory for ABI comparison data. If not set, defaults to
C<buildroot/abicheck.$animal_name>.

=item C<abidw_flags_list>

An array reference containing flags to pass to C<abidw>. Defaults to:

  [qw(
    --drop-undefined-syms --no-architecture --no-comp-dir-path
    --no-elf-needed --no-show-locs --type-id-style hash
  )]

=item C<tag_for_branch>

OPTIONAL.
A hash reference mapping branch names to their corresponding tags or tag
patterns for ABI comparison. Supports exact tag names or patterns (e.g.,
'REL_17_*'). If a pattern matches multiple tags, the first one is used.
If not defined for a branch then .abi-compliance-history file is used.

=back

=head2 EXTRA BUT IMPORTANT INFO

=over

=item *

This module has msvc related build code duped from F<run_build.pl> script but
later I realised C<abidiff> supports only elf binaries. Maybe those functions
can be used in future if some other ABI Compliance checking tool supports them.

=item *

This module only works for stable branches in compliance with the PostgreSQL
ABI policy for minor releases.

=item *

Debug information is required in the build to be able to use this module.

=item *

Before using this module, ensure that you have the
L<libabigail|https://github.com/libabigail/libabigail> tools (e.g., the
C<abigail-tools> Apt package) installed on your animal.

=item *

You must specify a baseline reference either in the animal's configuration using
C<tag_for_branch> or by creating a C<pgsql/.abi-compliance-history> file containing
the commit SHA or tag. The configuration file takes precedence over the history file.
This ensures explicit control over what baseline is used for comparison.

=back

=head2 EXAMPLE LOG OUTPUT

The output on the server will be named C<abi-compliance-check>.
Example output will be similar to:

	Branch: REL_17_STABLE
	Git HEAD: 61c37630774002fb36a5fa17f57caa3a9c2165d9
	Changes since: REL_17_6

	baseline updated from REL_17_5 to REL_17_6
	Binaries compared: 
	bin/postgres
	lib/libpq.so

	no abi diffs found in this run - Or ABI diff if any
	....other build logs for baseline if rebuilt

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
use File::Basename;
use Cwd qw(abs_path getcwd);


# strip required namespace from package name
(my $MODULE = __PACKAGE__) =~ s/PGBuild::Modules:://;

our ($VERSION); $VERSION = 'REL_19_1';

# Helper function to emit timestamped debug messages
sub emit
{
	print time_str(), "ABICompCheck :: ", @_, "\n" if $verbose;
}

my $hooks = {

	# 'need-run' => \&need_run,
	'installcheck' =>
	  \&installcheck,    # Main ABI comparison logic runs after install
	'cleanup' => \&cleanup,    # Clean up temporary files after build
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;     # where we're building
	my $branch = shift;        # The branch of Postgres that's being built.
	my $conf = shift;          # ref to the whole config object
	my $pgsql = shift;         # postgres build dir

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
	}
	else
	{
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

	# Configure abidw tool flags for ABI XML generation
	my $abidw_flags_list = $conf->{abi_comp_check}{abidw_flags_list}
	  || [
		qw(
		  --drop-undefined-syms --no-architecture --no-comp-dir-path
		  --no-elf-needed --no-show-locs --type-id-style hash
		)
	  ];


	# the tag_for_branch is to specify a tag to compare the ABIs with in a specific branch
	# expected to look like { <branchname> : <tag_name> }
	my $tag_for_branch = $conf->{abi_comp_check}{tag_for_branch} || {};

	mkdir $abi_compare_root
	  unless -d $abi_compare_root;

	# Store module configuration for later use in hooks.
	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql,
		abi_compare_root => $abi_compare_root,
		abidw_flags_list => $abidw_flags_list,
		tag_for_branch => $tag_for_branch,
	};
	bless($self, $class);

	# Register this module's hooks with the build farm framework
	register_module_hooks($self, $hooks);
	return;
}

# Determine the comparison reference from the animal's config file.
sub _get_comparison_ref_from_config
{
	my $self = shift;
	my $tag_pattern = $self->{tag_for_branch}->{ $self->{pgbranch} };
	my @tags = run_log(qq{git -C ./pgsql tag --list '$tag_pattern'})
	  ;    # get the list of tags based on the tag pattern provided in config
	chomp(@tags);

	unless (@tags)
	{
		emit
		  "Specified tag pattern '$tag_pattern' for branch '$self->{pgbranch}' does not match any tags.";
		return '';
	}

	# If multiple tags match, use the first one.
	return $tags[0];
}

# Determine the comparison reference from the .abi-compliance-history file.
sub _get_comparison_ref_from_history_file
{
	my $self = shift;

	# this function reads the .abi-compliance-history file and returns the first valid line
	# that is not a comment(starting with a '#' symbol) or empty line, assumes it to be a commit SHA
	# and verifies if it actually exists in the git history
	open my $fh, '<', "pgsql/.abi-compliance-history"
	  or die "Cannot open pgsql/.abi-compliance-history: $!";
	while (my $line = <$fh>)
	{
		next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
		$line =~ s/\s*#.*//;
		$line =~ s/^\s+|\s+$//g;

		# Check that the commit SHA actually exists.
		my $exit_status =
		  system(qq{git -C ./pgsql cat-file -e $line^{commit} 2>/dev/null});
		if ($exit_status != 0)
		{
			die
			  "Wrong or non-existent commit '$line' found in .abi-compliance-history";
		}
		close $fh;
		return $line;
	}
	writelog("abi-compliance-check",
		["No valid commit SHA found in .abi-compliance-history"]);
	return '';
}

# Main function - runs after PostgreSQL installation to perform ABI comparison
sub installcheck
{
	my $self = shift;
	return unless step_wanted('abi-compliance-check');

	if ( !(-f "pgsql/.abi-compliance-history"
		|| (
			defined $self->{bfconf}{abi_comp_check}{tag_for_branch}
			&& exists $self->{bfconf}{abi_comp_check}{tag_for_branch}{$self->{pgbranch}}
			)
		)
	)
	{
		emit("No .abi-compliance-history file found in $self->{pgbranch}");
		writelog("abi-compliance-check",
			["no .abi-compliance-history file found in $self->{pgbranch}"]) if $self->{pgbranch} =~ /_STABLE$/;
		return;
	}

	emit "installcheck";

	my %binaries_rel_path;
	$binaries_rel_path{'postgres'} = 'bin/postgres';

	# the inst directory should have been created by now which contains
	# installed binaries for the most recent commit
	if (-d 'inst/lib')
	{
		my @so_files = glob 'inst/lib/*.so';
		for my $file (@so_files)
		{
			if (-f $file)
			{
				(my $rel_path = $file) =~ s,^inst/,,;
				$binaries_rel_path{ basename($file) } = $rel_path;
			}
		}
	}

	my $pgbranch = $self->{pgbranch};
	my $abi_compare_loc = "$self->{abi_compare_root}/$pgbranch";
	mkdir $abi_compare_loc unless -d $abi_compare_loc;
	my $tag_for_branch = $self->{tag_for_branch} || {};
	my $comparison_ref = '';

	# Determine the baseline reference for comparison, in order of precedence:
	# 1. Animal-specific config
	# 2. .abi-compliance-history file
	if (exists $tag_for_branch->{$pgbranch})
	{
		$comparison_ref = $self->_get_comparison_ref_from_config();
		emit
		  "Using $comparison_ref as the baseline tag based on the animal config"
		  if $comparison_ref;
	}
	else
	{
		$comparison_ref = $self->_get_comparison_ref_from_history_file();
		return unless $comparison_ref;
		emit "Using baseline '$comparison_ref' from .abi-compliance-history";
	}

	# Get the previous baseline from the baseline file for current branch if it exists.
	my $baseline_file = "$abi_compare_loc/latest_tag";
	my $previous_baseline = '';
	if (-e $baseline_file)
	{
		open my $fh, '<', $baseline_file
		  or die "Cannot open $baseline_file: $!";
		$previous_baseline = <$fh>;
		close $fh;
		chomp $previous_baseline if $previous_baseline;
	}

	# Initialise output log with basic information.
	my $latest_commit_sha = run_log(qq{git -C ./pgsql rev-parse HEAD});
	die "git rev-parse HEAD failed: $?" if $?;
	chomp $latest_commit_sha;
	my @saveout = (
		"Branch: $pgbranch\n",
		"Git HEAD: $latest_commit_sha\n",
		"Changes since: $comparison_ref\n\n"
	);

	# Determine if we need to rebuild the baseline binaries
	my $rebuild_baseline = 0;
	if ($previous_baseline ne $comparison_ref)
	{
		push(@saveout,
			"baseline updated from $previous_baseline to $comparison_ref\n");
		$rebuild_baseline = 1;
	}

	# Rebuild the comparison ref from scratch, if needed by any of the checks above
	if ($rebuild_baseline)
	{
		# Clean up old baseline directory
		rmtree("$abi_compare_loc/$previous_baseline")
		  if $previous_baseline && -d "$abi_compare_loc/$previous_baseline";


		# Set up directories for baseline build
		my $baseline_build_dir = "$abi_compare_loc/$comparison_ref";
		my $baseline_log_dir = "$baseline_build_dir/build_logs";

		mkpath($baseline_log_dir)
		  unless -d $baseline_log_dir;

		# Checkout the baseline we want to compare against
		run_log(qq{git -C ./pgsql checkout $comparison_ref});
		die "git checkout $comparison_ref failed: $?" if $?;

		# got this git save piece of code from PGBuild::SCM::Git::copy_source
		move "./pgsql/.git", "./git-save";
		PGBuild::SCM::copy_source($self->{bfconf}{using_msvc},
			"./pgsql", "$baseline_build_dir/pgsql");
		move "./git-save", "./pgsql/.git";

		# checkout back to original branch
		run_log(qq{git -C ./pgsql checkout bf_$pgbranch});
		die "git checkout bf_$pgbranch failed: $?" if $?;

		# Build the baseline: configure, make, install
		$self->configure($abi_compare_loc, $comparison_ref);
		$self->make($abi_compare_loc, $comparison_ref);
		$self->make_install($abi_compare_loc, $comparison_ref);

		# Generate ABI XML files for the baseline build
		my $installdir = "$abi_compare_loc/$comparison_ref/inst";
		$self->_generate_abidw_xml(
			$installdir, $abi_compare_loc,
			$comparison_ref, \%binaries_rel_path
		);

		# Store baseline to file for future runs
		open my $baseline_fh, '>', $baseline_file
		  or die "Could not open $baseline_file: $!";
		print $baseline_fh $comparison_ref;
		close $baseline_fh;

		emit
		  "Build and ABIXMLs generation for baseline '$comparison_ref' for branch '$pgbranch' done.";
	}

	# Generate ABI XML files for the current build or the most recent commit
	if (-d "./inst")
	{
		$self->_generate_abidw_xml("./inst", $abi_compare_loc, $pgbranch,
			\%binaries_rel_path);
	}

	# Compare ABI between current branch and comparison reference (baseline)
	my ($diff_found, $diff_log, $success_binaries) =
	  $self->_compare_and_log_abi_diff($comparison_ref, $pgbranch,
		\%binaries_rel_path);

	# Add binaries comparison status to output at the start
	if ($success_binaries && @$success_binaries)
	{
		push(@saveout,
				"Binaries compared: \n"
			  . join("\n", sort @$success_binaries)
			  . "\n\n");
	}

	# Add comparison results to output
	my $status = 0;
	if ($diff_found)
	{
		push(@saveout, $diff_log->log_string);
		$status = 1;
		emit "Some ABI differences found";
	}
	else
	{
		push(@saveout, "no abi diffs found in this run\n");
		emit "No ABI differences found";
	}

	# Include baseline build logs if we rebuilt
	if ($rebuild_baseline)
	{
		my $baseline_log_dir = "$abi_compare_loc/$comparison_ref/build_logs";
		foreach my $log_name ('configure', 'build', 'install')
		{
			my $log_file = "$baseline_log_dir/$log_name.log";
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

	send_result('abi-compliance-check', $status, \@saveout) if $status;
	$steps_completed .= " abi-compliance-check";

	return;
}

# Configure step for meson builds
sub meson_setup
{
	my $self = shift;
	my $installdir = shift;
	my $baseline = shift;
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

	my $log = PGBuild::Log->new($baseline . "setup");
	foreach my $logfile ("$pgsql/meson-logs/setup.log",
		"$pgsql/src/include/pg_config.h")
	{
		$log->add_log($logfile) if -s $logfile;
	}
	push(@confout, $log->log_string);

	emit "======== setup output ===========\n", @confout if ($verbose > 1);
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
	my $baseline = shift;
	emit "running configure ...";
	my $branch = $self->{pgbranch};
	my $baseline_log_dir = "$abi_compare_loc/$baseline/build_logs";
	my @confout;

	# Choose configuration method based on build system
	if ($self->{bfconf}{using_meson}
		&& ($branch eq 'HEAD' || $branch ge 'REL_16_STABLE'))
	{
		$self->meson_setup("$abi_compare_loc/$baseline/inst");
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

	# Set install prefix to our baseline-specific directory
	my $confstr =
	  join(" ", @quoted_opts, "--prefix=$abi_compare_loc/$baseline/inst");

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
		"$envstr cd $abi_compare_loc/$baseline/pgsql && ./configure $confstr"
	);

	my $status = $? >> 8;

	emit "======== configure output ===========\n", @confout if ($verbose > 1);

	# Include config.log if available
	if (-s "$abi_compare_loc/$baseline/pgsql/config.log")
	{
		my $log = PGBuild::Log->new($baseline . "_configure");
		$log->add_log("config.log");
		push(@confout, $log->log_string);
	}

	# Save configure log: will be visible only if --keepall option is enabled
	open my $fh, '>', "$baseline_log_dir/configure.log"
	  or die "Could not open $baseline_log_dir/configure.log: $!";
	print $fh @confout;
	close $fh;
}

sub make
{
	my $self = shift;
	my $abi_compare_loc = shift;
	my $baseline = shift;
	emit "running build ...";

	my $pgsql = "$abi_compare_loc/$baseline/pgsql";
	my $baseline_log_dir = "$abi_compare_loc/$baseline/build_logs";
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
	open my $fh, '>', "$baseline_log_dir/build.log"
	  or die "Could not open $baseline_log_dir/build.log: $!";
	print $fh @makeout;
	close $fh;
	emit "======== make log ===========\n", @makeout if ($verbose > 1);
}

sub make_install
{
	my $self = shift;
	my $abi_compare_loc = shift;
	my $baseline = shift;
	emit "running install ...";

	my $pgsql = "$abi_compare_loc/$baseline/pgsql";
	my $installdir = "$abi_compare_loc/$baseline/inst";
	my $baseline_log_dir = "$abi_compare_loc/$baseline/build_logs";
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
	open my $fh, '>', "$baseline_log_dir/install.log"
	  or die "Could not open $baseline_log_dir/install.log: $!";
	print $fh @makeout;
	close $fh;
	emit "======== make install log ===========\n", @makeout if ($verbose > 1);

	# On Windows and Cygwin avoid path problems associated with DLLs
	# by copying them to the bin dir where the system will pick them

	foreach my $dll (glob("$installdir/lib/*pq.dll"))
	{
		my $dest = "$installdir/bin/" . basename($dll);
		copy($dll, $dest);
		chmod 0755, $dest;
	}
}

# Generate ABI XML files using abidw tool for specified binaries
sub _generate_abidw_xml
{
	my $self = shift;
	my $install_dir = shift;
	my $abi_compare_loc = shift;
	my $version_identifier = shift
	  ; # either comparison ref(i.e. baseline commit/tag) OR branch name Because both are expected to have separate path for install directories
	my $binaries_rel_path = shift;

	emit "Generating ABIDW XML for $version_identifier";

	my $abidw_flags_str = join ' ', @{ $self->{abidw_flags_list} };

	# Determine if this is for a baseline or current branch
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
		# Baseline - stored in baseline-specific directory
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
				emit
				  "FAILURE - $target_name, Exit Status - $exit_status, Input Path - $input_path, Version: $version_identifier";
			}
			else
			{
				emit "SUCCESS - $target_name";
			}
		}
		else
		{
			emit "FAILURE - $target_name not found";
		}
	}

	return;
}

# Execute a command and log its output to a file
sub _log_command_output
{
	my ($self, $cmd, $log_file, $cmd_desc, $no_die) = @_;

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
	return $exit_status;
}

# Compare ABI XML files between baseline and current branch using abidiff
sub _compare_and_log_abi_diff
{
	my ($self, $baseline, $current_branch, $binaries_rel_path) = @_;
	if (!defined $baseline || !defined $current_branch)
	{
		emit
		  "Warning: _compare_and_log_abi_diff called with undefined parameters. Skipping comparison.";
		return (0, undef, undef, undef);
	}

	my $abi_compare_root = $self->{abi_compare_root};
	my $pgbranch = $self->{pgbranch};

	emit "Comparing ABI between baseline $baseline and the latest commit";

	# Set up directories for comparison
	my $baseline_xml_dir = "$abi_compare_root/$pgbranch/$baseline/xmls";
	my $branch_xml_dir = "$abi_compare_root/$pgbranch/xmls";
	my $log_dir = "$abi_compare_root/$pgbranch/diffs";

	# Clean up any previous existing logs
	rmtree($log_dir) if -d $log_dir;
	mkpath($log_dir) unless -d $log_dir;

	my $diff_found = 0;
	my $log = PGBuild::Log->new("abi-compliance-check");

	my @success_binaries;

	# Compare each binary's ABI using abidiff
	while (my ($key, $value) = each %$binaries_rel_path)
	{
		my $baseline_file = "$baseline_xml_dir/$key.abi";
		my $branch_file = "$branch_xml_dir/$key.abi";

		if (-e $baseline_file && -e $branch_file)
		{
			push(@success_binaries, $value);

			# Run abidiff to compare ABI XML files
			my $log_file = "$log_dir/$key-$baseline.log";
			my $exit_status = $self->_log_command_output(
				qq{abidiff "$baseline_file" "$branch_file" --leaf-changes-only --no-added-syms --show-bytes},
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
	}

	return ($diff_found, $log, \@success_binaries);
}

# Clean up temporary files to save disk space
sub cleanup
{
	my $self = shift;
	if (!$keepall)
	{
		my $abi_compare_loc = "$self->{abi_compare_root}/$self->{pgbranch}";
		my $baseline_tag_file = "$abi_compare_loc/latest_tag";

		# Find which baseline directory to clean up
		my $current_baseline = '';
		if (-e $baseline_tag_file)
		{
			open my $fh, '<', $baseline_tag_file
			  or die "Cannot open $baseline_tag_file: $!";
			$current_baseline = <$fh>;
			close $fh;
			chomp $current_baseline if $current_baseline;
		}
		return unless $current_baseline;  # this could happen only in some worst case

		# Remove all files in baseline tag directory except xmls
		rmtree("$abi_compare_loc/$current_baseline/inst")
		  if -d "$abi_compare_loc/$current_baseline/inst";
		rmtree("$abi_compare_loc/$current_baseline/pgsql")
		  if -d "$abi_compare_loc/$current_baseline/pgsql";
		rmtree("$abi_compare_loc/$current_baseline/build_logs")
		  if -d "$abi_compare_loc/$current_baseline/build_logs";
	}

	emit "cleaning up" if $verbose > 1;
	return;
}

1;
