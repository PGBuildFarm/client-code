# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::ABICompCheck;
use PGBuild::Log;
use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $branch_root);

use strict;
use warnings;
use File::Path 'mkpath';
use File::Copy;
use Cwd qw(abs_path getcwd);


# strip required namespace from package name
(my $MODULE = __PACKAGE__) =~ s/PGBuild::Modules:://;

our ($VERSION); $VERSION = 'REL_19_1';

sub emit {
	print time_str(), "ABICompCheck :: ", @_, "\n" if $verbose;
}

my $hooks = {
	# 'need-run' => \&need_run,
	'install' => \&install,
	'cleanup' => \&cleanup,
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch = shift;       # The branch of Postgres that's being built.
	my $conf = shift;         # ref to the whole config object
	my $pgsql = shift;        # postgres build dir

	# We are only testing stable branches, so ignore all others.
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
	if ($conf->{using_msvc})
	{
		emit("MSVC builds are not supported for ABICompCheck Module, skipping.");
		return;
	}
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
	# print $buildroot, " ", $branch, " ", $conf, " ", $pgsql, "\n" if $verbose;

	my $abi_compare_root =
	  $conf->{abi_compare_root} || "$buildroot/abicheck.$conf->{animal}";
	if (   !defined($conf->{abi_compare_root})
		&& !-d $abi_compare_root
		&& -d "$buildroot/abicheck/HEAD")
	{
		# support legacy use without animal name
		$abi_compare_root = "$buildroot/abicheck";
	}

	my $binaries_rel_path = $conf->{abi_comp_check}{binaries_rel_path}
	  || {
		'postgres' => 'bin/postgres',
		'ecpg' => 'bin/ecpg',
		'libpq.so' => 'lib/libpq.so',
	  };

	my $abidw_flags_list = $conf->{abi_comp_check}{abidw_flags_list}
	  || [qw(  
        --drop-undefined-syms --no-architecture --no-comp-dir-path  
        --no-elf-needed --no-show-locs --type-id-style hash  
      )];

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
		abidw_flags_list => $abidw_flags_list

		  # fs_abi_compare_root => $fs_abi_compare_root,
	};
	bless($self, $class);

	# for each instance you create, do:
	register_module_hooks($self, $hooks);
	return;
}

sub install
{
	my $self = shift;
	return unless step_wanted('abi_comp-check');

	emit "install";
	my $scm = PGBuild::SCM->new($self->{bfconf});

	my $pgbranch = $self->{pgbranch};
	my $abi_compare_loc = "$self->{abi_compare_root}/$pgbranch";
	mkdir $abi_compare_loc unless -d $abi_compare_loc;

	my $latest_tag = run_log(qq{git -C ./pgsql describe --tags --abbrev=0 2>/dev/null});
	chomp $latest_tag;
	my $comparison_ref = '';
	$comparison_ref = run_log(qq{git -C ./pgsql merge-base master bf_$pgbranch});
	chomp $comparison_ref;

	if ($latest_tag) {
		my $tag_commit = run_log(qq{git -C ./pgsql rev-list -n 1 $latest_tag});
		chomp $tag_commit;

		my $is_ancestor = system(qq{git -C ./pgsql merge-base --is-ancestor $tag_commit $comparison_ref 2>/dev/null});
		if ($is_ancestor != 0) {
			$comparison_ref = $latest_tag;
			emit "Latest tag: $latest_tag";
		}
	}

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
	my $latest_commit_sha = run_log(qq{git -C ./pgsql rev-parse HEAD});
	chomp $latest_commit_sha;
	my @saveout = (
		"Branch: $pgbranch\n",
		"Git HEAD: $latest_commit_sha\n",
		"Changes since: $comparison_ref\n\n"
	);
	# my $log = PGBuild::Log->new("abi-compliance-check");
	my $rebuild_tag = 0;
	if ($previous_tag ne $comparison_ref)
	{
		push(@saveout,"latest_tag updated from $previous_tag to $comparison_ref\n");
		$rebuild_tag = 1;
	}
	else
	{
		# Check if all XML files for the latest tag exist. If not, we need to rebuild.
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

	if ($rebuild_tag)
	{
		rmtree("$abi_compare_loc/$previous_tag")
		  if $previous_tag && -d "$abi_compare_loc/$previous_tag";
		# Store latest tag to file
		open my $tag_fh, '>', $latest_tag_file
		  or die "Could not open $latest_tag_file: $!";
		print $tag_fh $comparison_ref;
		close $tag_fh;

		my $tag_build_dir = "$abi_compare_loc/$comparison_ref";
		my $tag_log_dir = "$tag_build_dir/build_logs";

		mkpath($tag_log_dir)
		  unless -d $tag_log_dir;

		run_log(qq{git -C ./pgsql checkout $comparison_ref});

		# got this git save peice of code from PGBuild::SCM::Git::copy_source
		move "./pgsql/.git", "./git-save";
		PGBuild::SCM::copy_source($self->{bfconf}{using_msvc},
			"./pgsql", "$tag_build_dir/pgsql");

		# finally restore the original branch
		move "./git-save", "./pgsql/.git";

		run_log(qq{git -C ./pgsql checkout bf_$pgbranch});

		# now run the build steps
		my @configure_log = $self->configure($abi_compare_loc, $comparison_ref);
		my @make_log = $self->make($abi_compare_loc, $comparison_ref);
		my @install_log = $self->make_install($abi_compare_loc, $comparison_ref);

		# Generate ABIDW XML files after installation
		my $installdir = "$abi_compare_loc/$comparison_ref/inst";
		$self->_generate_abidw_xml($installdir, $abi_compare_loc, $comparison_ref);
	}

	if (-d "./inst")
	{
		$self->_generate_abidw_xml("./inst", $abi_compare_loc, $pgbranch);
	}

	# Compare ABI between current branch and latest tag
	my ($diff_found, $diff_log) = $self->_compare_and_log_abi_diff($comparison_ref, $pgbranch);

	if ($diff_found)
	{
		push(@saveout, $diff_log->log_string);
	}
	else
	{
		push(@saveout, "no abi diffs found in this run\n");
	}

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

	writelog("abi-compliance-check", \@saveout);

	return;
}

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

	return @confout;
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

	return @text;
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

	if ($self->{bfconf}{using_meson}
		&& ($branch eq 'HEAD' || $branch ge 'REL_16_STABLE'))
	{
		@confout = $self->meson_setup("$abi_compare_loc/$latest_tag/inst");
		return @confout;
	}

	if ($self->{bfconf}{using_msvc})
	{
		@confout = $self->msvc_setup();
		return @confout;
	}

	# autoconf/configure setup
	my $config_opts = $self->{bfconf}{config_opts} || [];

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

	my $confstr =
	  join(" ", @quoted_opts, "--prefix=$abi_compare_loc/$latest_tag/inst");

	# The use of accache kind of looks useless for this module since it will be a single build to be made, that too in only the first run case

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

	my $envstr = "";
	while (my ($key, $val) = each %$env)
	{
		$envstr .= "$key='$val' ";
	}

	@confout = run_log(
		"$envstr cd $abi_compare_loc/$latest_tag/pgsql && ./configure $confstr"
	);

	my $status = $? >> 8;

	emit "======== configure output ===========\n", @confout  if ($verbose > 1);

	if (-s "$abi_compare_loc/$latest_tag/pgsql/config.log")
	{
		my $log = PGBuild::Log->new($latest_tag . "_configure");
		$log->add_log("config.log");
		push(@confout, $log->log_string);
	}

	# writelog($latest_tag . "_configure", \@confout);
	open my $fh, '>', "$tag_log_dir/configure.log"
	  or die "Could not open $tag_log_dir/configure.log: $!";
	print $fh @confout;
	close $fh;

	# if ($status)
	# {
	# 	send_result('Configure', $status, \@confout);
	# }

	return @confout;
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
		my $make = $self->{bfconf}{make} || 'make';
		my $make_jobs = $self->{bfconf}{make_jobs} || 1;
		my $make_cmd = $make;
		$make_cmd = "$make -j $make_jobs"
		  if ($make_jobs > 1);
		@makeout = run_log("cd $pgsql && $make_cmd");
	}
	my $status = $? >> 8;
	# writelog($latest_tag . "_build", \@makeout);
	open my $fh, '>', "$tag_log_dir/build.log"
	  or die "Could not open $tag_log_dir/build.log: $!";
	print $fh @makeout;
	close $fh;
	emit "======== make log ===========\n", @makeout if ($verbose > 1);
	$status ||= check_make_log_warnings('latestbuild', $verbose)
	  if $check_warnings;

	# send_result('Build', $status, \@makeout) if $status;
	return @makeout;
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
		my $make = $self->{bfconf}{make} || 'make';
		@makeout = run_log("cd $pgsql && $make install");
	}
	my $status = $? >> 8;
	# writelog($latest_tag . '_make-install', \@makeout);
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

	return @makeout;
}

sub _generate_abidw_xml
{
	my $self = shift;
	my $install_dir = shift;
	my $abi_compare_loc = shift;
	my $version_identifier = shift;

	emit "Generating ABIDW XML for $version_identifier";

	my $binaries_rel_path = $self->{binaries_rel_path};
	my $abidw_flags_str = join ' ', @{ $self->{abidw_flags_list} };

	# Determine if this is for a tag or current branch
	my $xml_dir;
	my $log_dir;
	if ($version_identifier eq $self->{pgbranch})
	{
		# Current branch
		$xml_dir = "$abi_compare_loc/xmls";
		$log_dir = "$abi_compare_loc/logs";
	}
	else
	{
		# Latest tag
		$xml_dir = "$abi_compare_loc/$version_identifier/xmls";
		$log_dir = "$abi_compare_loc/$version_identifier/build_logs";
	}

	mkpath($xml_dir) unless -d $xml_dir;
	mkpath($log_dir) unless -d $log_dir;

	while (my ($target_name, $rel_path) = each %{$binaries_rel_path})
	{
		my $input_path = "$install_dir/$rel_path";
		my $output_file = "$xml_dir/$target_name.abi";

		if (-e $input_path && -f $input_path)
		{
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

	emit "Comparing ABI between latest tag $latest_tag and it's latest commit";

	my $tag_xml_dir = "$abi_compare_root/$pgbranch/$latest_tag/xmls";
	my $branch_xml_dir = "$abi_compare_root/$pgbranch/xmls";
	my $log_dir = "$abi_compare_root/$pgbranch/diffs";

	rmtree($log_dir) if -d $log_dir;
	mkpath($log_dir) unless -d $log_dir;
	my $diff_found = 0;
	my $log = PGBuild::Log->new("abi-compliance-check");

	foreach my $key (keys %{ $self->{binaries_rel_path} })
	{
		my $tag_file = "$tag_xml_dir/$key.abi";
		my $branch_file = "$branch_xml_dir/$key.abi";

		if (-e $tag_file && -e $branch_file)
		{
			my $log_file = "$log_dir/$key-$latest_tag.log";
			my $exit_status = $self->_log_command_output(
				qq{abidiff "$tag_file" "$branch_file" --leaf-changes-only --no-added-syms --show-bytes},
				$log_file, "abidiff for $key", 1
			);

			if ($exit_status != 0)
			{
				$diff_found = 1;
				$log->add_log($log_file);
				emit "ABI difference found for $key.abi";
			}
		}
		else
		{
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

sub cleanup
{
	my $self = shift;
	if (!$keepall) {
		my $abi_compare_loc = "$self->{abi_compare_root}/$self->{pgbranch}";
		my $latest_tag_file = "$abi_compare_loc/latest_tag";

		# Only proceed if the file doesn't exist or has no content
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

		rmtree("$abi_compare_loc/$current_tag/inst") if -d "$abi_compare_loc/$current_tag/inst";
		rmtree("$abi_compare_loc/$current_tag/pgsql") if -d "$abi_compare_loc/$current_tag/pgsql";
		rmtree("$abi_compare_loc/$current_tag/build_logs") if -d "$abi_compare_loc/$current_tag/build_logs";
	}

	emit "cleaning up" if $verbose > 1;
	return;
}

1;
