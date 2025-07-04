# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::ABICompCheck;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils;

use strict;
use warnings;

# strip required namespace from package name
(my $MODULE = __PACKAGE__) =~ s/PGBuild::Modules:://;

our ($VERSION); $VERSION = 'REL_19_1';

my $hooks = {
	'need-run' => \&need_run,
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

	# We are only testing HEAD and stable branches, so ignore all others.
	return if $branch ne 'HEAD' && $branch !~ /_STABLE$/;

	my $animal = $conf->{animal};
	my $abi_compare_root =
	  $conf->{abi_compare_root} || "$buildroot/abicheck.$animal";
	if (   !defined($conf->{abi_compare_root})
		&& !-d $abi_compare_root
		&& -d "$buildroot/abicheck/HEAD")
	{
		# support legacy use without animal name
		$abi_compare_root = "$buildroot/abicheck";
	}

	my $binaries_rel_path = $conf->{binaries_rel_path}
	  || {
		'postgres' => 'bin/postgres',
		'ecpg' => 'bin/ecpg',
		'libpq.so' => 'lib/libpq.so',
	  };

	my $abidw_flags_list = $conf->{abidw_flags_list}
	  || [
		'--drop-undefined-syms', '--no-architecture', '--no-comp-dir-path',
		'--no-elf-needed', '--no-show-locs', '--type-id-style',
		'hash',
	  ];

	mkdir $abi_compare_root
	  unless -d $abi_compare_root;
	mkdir "$abi_compare_root/logs"
	  unless -d "$abi_compare_root/logs";
	mkdir "$abi_compare_root/xmls"
	  unless -d "$abi_compare_root/xmls";
	mkdir "$abi_compare_root/install"
	  unless -d "$abi_compare_root/install";

	my $last_commit_hash_file = "$abi_compare_root/githead.log";
	my $last_commit_hash;
	if (-f $last_commit_hash_file)
	{
		$last_commit_hash = file_contents($last_commit_hash_file);
		chomp $last_commit_hash if defined $last_commit_hash;
	}

	my $scm = PGBuild::SCM->new(\%PGBuild::conf);
	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql,
		abi_compare_root => $abi_compare_root,
		scm => $scm,
		binaries_rel_path => $binaries_rel_path,
		abidw_flags_list => $abidw_flags_list,
		clone_name => 'pgsql',
		last_commit_hash => $last_commit_hash,
	};
	bless($self, $class);

	# for each instance you create, do:
	register_module_hooks($self, $hooks);
	return;
}

sub need_run
{
	my $self = shift;
	my $run_needed = shift;    # ref to flag

	print time_str(), "checking if run needed by ", __PACKAGE__, "\n"
	  if $verbose;

	my $abi_compare_root = $self->{abi_compare_root};
	my $clone_name = $self->{clone_name};
	my $mirror_base = $self->{scm}->{mirror};
	my $branch = $self->{pgbranch};
	my $git_repo_path = "$abi_compare_root/$clone_name";

	my @clonelog;
	my $status;
	if (-d $git_repo_path)
	{
		print time_str(),
		  "ABICompCheck: $clone_name directory already exists, fetching updates.\n"
		  if $verbose;
		my @fetch_log = run_log(qq{git -C "$git_repo_path" fetch});
		$status = $? >> 8;
		print_logs(\@fetch_log);
		if ($status)
		{
			die "git fetch failed with status $status";
		}
	}
	else
	{
		print "running ", qq{git clone -q  "$mirror_base" "$clone_name"}, "\n";
		@clonelog = run_log(qq{git clone -q "$mirror_base" "$git_repo_path"});
		$status = $? >> 8;
		print_logs(\@clonelog);
		if ($status)
		{
			die "clone failed with status: $status";
		}
	}

	my @checkout_log =
	  run_log(qq{git -C "$git_repo_path" checkout -q "$branch"});
	$status = $? >> 8;
	print_logs(\@checkout_log);
	if ($status)
	{
		die "git checkout failed with status $status";
	}

	# my @pull_log = run_log(qq{git -C "$git_repo_path" pull});
	# $status = $? >> 8;
	# print_logs(\@pull_log);
	# if ($status)
	# {
	# 	die "git pull failed with status $status";
	# }

	my $head_commit_hash = `git -C "$git_repo_path" rev-parse HEAD`;
	chomp $head_commit_hash;

	$self->{head_commit_hash} = $head_commit_hash;
	my $last_commit_hash = $self->{last_commit_hash};

	if (   defined $last_commit_hash
		&& $last_commit_hash ne ''
		&& $last_commit_hash eq $head_commit_hash)
	{
		# Hashes match, so this module does not require a run.
		# $$run_needed remains unchanged (it might be true due to other modules or settings).
		print time_str(),
		  "ABICompCheck: PostgreSQL commit hash ($head_commit_hash) matches stored hash. Run not needed by this module.\n"
		  if $verbose;
	}
	else
	{
		# Hashes differ or stored hash was unreadable/empty.
		my $reason =
		  (defined $last_commit_hash && $last_commit_hash ne '')
		  ? "differs from stored hash ('$last_commit_hash')"
		  : "stored hash file is empty or unreadable";
		print time_str(),
		  "ABICompCheck: PostgreSQL commit hash ($head_commit_hash) $reason. Run needed.\n"
		  if $verbose;
		$$run_needed = 1;
	}

	return;
}

sub _checkout_commit
{
	my $self = shift;
	my $commit_hash = shift;

	print time_str(), "Checking out commit $commit_hash in ", __PACKAGE__, "\n"
	  if $verbose;

	my @checkout_log = run_log(qq{git checkout -q "$commit_hash"});
	if ($? >> 8)
	{
		die "Checkout failed for commit $commit_hash: @checkout_log";
	}

	print_logs(\@checkout_log);

	return;
}

sub _log_command_output
{
	my ($self, $cmd, $log_dir, $cmd_desc) = @_;

	# Ensure log directory exists
	mkdir $log_dir unless -d $log_dir;

	my $log_file = "$log_dir/$cmd_desc.log";

	print time_str(), "Executing: $cmd_desc\n" if $verbose;

	run_log(qq{$cmd > "$log_file" 2>&1});
	my $exit_status = $? >> 8;
	if ($exit_status)
	{
		die "$cmd_desc failed with status $exit_status. Log: $log_file";
	}
	else
	{
		print time_str(), "Successfully executed $cmd_desc\n"
		  if $verbose;
	}
	return;
}

sub _configure_make_and_build
{
	my ($self, $commit_hash) = @_;    # Added $commit_hash argument
	my $abi_compare_root = $self->{abi_compare_root};
	my $clone_name = $self->{clone_name};
	my $log_dir = "$abi_compare_root/logs/$commit_hash";
	my $make = $self->{bfconf}->{make};
	my $make_jobs = $self->{bfconf}->{make_jobs};
	print time_str(),
	  "Configuring, making, and installing for commit $commit_hash in ",
	  __PACKAGE__, "\n"
	  if $verbose;

	chdir "$abi_compare_root/$clone_name"
	  or die
	  "Cannot change to PostgreSQL source directory: $abi_compare_root/$clone_name for commit $commit_hash";

	_log_command_output($self,
		qq{./configure CFLAGS="-Og -g" --prefix=$abi_compare_root/install/},
		$log_dir, 'configure');
	my $make_cmd = $make;
	$make_cmd = "$make -j $make_jobs"
	  if ($make_jobs > 1);
	_log_command_output($self, $make_cmd, $log_dir, 'make');

	_log_command_output($self, qq{$make install}, $log_dir, 'makeinstall');

	return;
}

sub _generate_abidw_xml
{
	my $self = shift;
	my $abidw_flags_list = $self->{abidw_flags_list};
	my $abidw_flags_str = join(' ', @$abidw_flags_list);
	my $commit_hash = shift;

	print time_str(), "Generating ABIDW XML for commit $commit_hash in ",
	  __PACKAGE__, "\n"
	  if $verbose;

	my $abi_compare_root = $self->{abi_compare_root};
	my $binaries_rel_path = $self->{binaries_rel_path};
	my $commit_xml_dir = "$abi_compare_root/xmls/$commit_hash";

	mkdir $commit_xml_dir unless -d $commit_xml_dir;

	my $install_dir = "$abi_compare_root/install";
	my $install_bin_dir = "$install_dir/bin";
	my $install_lib_dir = "$install_dir/lib";

	# Ensure $abi_compare_root/install/bin/ exists and has content
	unless (-d $install_bin_dir)
	{
		die
		  "Error: Directory $install_bin_dir does not exist. Cannot generate ABI XML for commit $commit_hash.";
	}
	unless (scalar glob("$install_bin_dir/*"))
	{
		die
		  "Error: Directory $install_bin_dir is empty. Cannot generate ABI XML for commit $commit_hash.";
	}

	my @targets_to_process = ();
	foreach my $target_name (keys %$binaries_rel_path)
	{
		my $input_path = "$install_dir/$binaries_rel_path->{$target_name}";
		my $output_file = "$commit_xml_dir/$target_name.abi";

		if (-e $input_path)
		{
			push @targets_to_process,
			  {
				name => $target_name,
				input_path => $input_path,
				output_file => $output_file,
			  };
		}
		else
		{
			print time_str(),
			  "Warning: Input file '$input_path' for $target_name not found. Skipping ABI generation for this target (commit $commit_hash).\n"
			  if $verbose;
		}
	}

	if (!@targets_to_process)
	{
		die "No valid targets found for ABI generation in commit $commit_hash.";
	}

	foreach my $target (@targets_to_process)
	{
		my $target_name = $target->{name};
		my $input_file_path = $target->{input_path};
		my $output_abi_file = $target->{output_file};

		unless (-e $input_file_path && -f $input_file_path)
		{
			print time_str(),
			  "Warning: Input file '$input_file_path' for $target_name not found or is not a regular file. Skipping ABI generation for this target (commit $commit_hash).\n"
			  if $verbose;
			next;
		}

		my $cmd =
		  qq{abidw --out-file "$output_abi_file" "$input_file_path" $abidw_flags_str};
		print time_str(), "Executing: $cmd\n" if $verbose;

		my @abidw_log = run_log($cmd);
		my $exit_status = $? >> 8;

		print_logs(\@abidw_log);

		if ($exit_status)
		{
			die
			  "abidw failed for $target_name (from $input_file_path) with status $exit_status. Commit: $commit_hash";
		}
		else
		{
			print time_str(),
			  "Successfully generated ABI XML for $target_name to $output_abi_file\n"
			  if $verbose;
		}
	}
	return;
}

sub _compare_and_log_abi_diff
{
	my ($self, $old_commit_hash, $new_commit_hash, $fail_fast) = @_;

	if (!defined $old_commit_hash || !defined $new_commit_hash)
	{
		print time_str(),
		  "Warning: _compare_and_log_abi_diff called with undefined commit hash. Skipping comparison.\n"
		  if $verbose;
		return 0;
	}

	my $abi_compare_root = $self->{abi_compare_root};

	print time_str(),
	  "Comparing ABI for commits $old_commit_hash and $new_commit_hash\n"
	  if $verbose;

	my $old_commit_xml_dir = "$abi_compare_root/xmls/$old_commit_hash";
	my $new_commit_xml_dir = "$abi_compare_root/xmls/$new_commit_hash";
	my $log_dir = "$abi_compare_root/diffs";
	mkdir $log_dir unless -d $log_dir;
	my $diff_found = 0;

	foreach my $key (keys %{ $self->{binaries_rel_path} })
	{
		my $old_file = "$old_commit_xml_dir/$key.abi";
		my $new_file = "$new_commit_xml_dir/$key.abi";

		if (-e $old_file && -e $new_file)
		{
			my $log_file =
			  "$log_dir/$key-$old_commit_hash-$new_commit_hash.log";
			my @output = run_log("abidiff \"$old_file\" \"$new_file\"");
			my $exit_status = $? >> 8;
			if ($exit_status != 0)
			{
				$diff_found = 1;
				open my $fh, '>', $log_file
				  or warn "could not open $log_file: $!";
				print $fh @output if $fh;
				close $fh if $fh;
				print time_str(),
				  "ABI difference found for $key. Log: $log_file\n"
				  if $verbose;
				return 1 if $fail_fast;
			}
		}
		elsif (-e $old_file xor -e $new_file)
		{
			$diff_found = 1;
			print time_str(),
			  "ABI difference for $key: one file is missing (old: $old_file, new: $new_file). Comparison skipped.\n"
			  if $verbose;
			my $log_file =
			  "$log_dir/$key-$old_commit_hash-$new_commit_hash.log";
			open my $fh, '>', $log_file
			  or warn "could not open $log_file: $!";
			if ($fh)
			{
				print $fh "ABI difference: one file is missing.\n";
				print $fh "Old file: $old_file (exists: "
				  . (-e $old_file) . ")\n";
				print $fh "New file: $new_file (exists: "
				  . (-e $new_file) . ")\n";
				close $fh;
			}
			return 1 if $fail_fast;
		}
	}

	if (!$diff_found)
	{
		print time_str(),
		  "No ABI differences found between $old_commit_hash and $new_commit_hash\n"
		  if $verbose;
	}
	return $diff_found;
}

sub _process_commits_list
{
	my ($self, $commits_list, $initial_prev_commit) = @_;
	my $scm = $self->{scm};

	print time_str(), "Processing commits list in ", __PACKAGE__, "\n"
	  if $verbose;

	if (defined $initial_prev_commit && @$commits_list > 2)
	{
		my $head_commit_hash = $self->{head_commit_hash};
		print time_str(),
		  "ABICompCheck: Found more than one new commit, checking for ABI changes between start and end.\n"
		  if $verbose;

		# First, check if the ABI data for the old commit exists.
		# If not, we can't do the fast-path comparison.
		my $can_do_fast_path = 1;
		my $old_commit_xml_dir =
		  "$self->{abi_compare_root}/xmls/$initial_prev_commit";

		if (!-d $old_commit_xml_dir)
		{
			$can_do_fast_path = 0;
		}
		else
		{
			foreach my $key (keys %{ $self->{binaries_rel_path} })
			{
				my $abi_file = "$old_commit_xml_dir/$key.abi";
				if (!-e $abi_file)
				{
					$can_do_fast_path = 0;
					last;
				}
			}
		}

		if (!$can_do_fast_path)
		{
			print time_str(),
			  "ABICompCheck: Missing ABI data for $initial_prev_commit. Will process all commits.\n"
			  if $verbose;
		}
		else
		{
			# Build and generate XML for the head commit
			_checkout_commit($self, $head_commit_hash);
			_configure_make_and_build($self, $head_commit_hash);
			_generate_abidw_xml($self, $head_commit_hash);

			# Compare with the last known commit
			my $diff_found =
			  _compare_and_log_abi_diff($self, $initial_prev_commit,
				$head_commit_hash, 1);

			if (!$diff_found)
			{
				print time_str(),
				  "ABICompCheck: No ABI difference between $initial_prev_commit and $head_commit_hash. Skipping intermediate builds.\n"
				  if $verbose;
				return;
			}
			else
			{
				print time_str(),
				  "ABICompCheck: ABI difference found between $initial_prev_commit and $head_commit_hash. Processing all intermediate commits.\n"
				  if $verbose;
			}
		}
	}
	my $prev_commit = $initial_prev_commit;
	my $idx = 0;
	foreach my $commit (@$commits_list)
	{
		my $commit_xml_dir = "$self->{abi_compare_root}/xmls/$commit";
		if (-d $commit_xml_dir)
		{
			print time_str(),
			  "XML for commit $commit already exists, skipping build.\n"
			  if $verbose;
		}
		else
		{
			_checkout_commit($self, $commit);
			_configure_make_and_build($self, $commit);
			_generate_abidw_xml($self, $commit);
		}

		if (defined $prev_commit)
		{
			_compare_and_log_abi_diff($self, $prev_commit, $commit, 0);
		}
		$prev_commit = $commit;
		$idx++;
	}

	return;
}

sub print_logs
{
	my ($logss) = @_;

	if (@$logss)
	{
		print "ABICompCheck:";
		foreach my $line (@$logss)
		{
			print $line;
		}
	}
}

sub install
{
	my $self = shift;
	my $abi_compare_root = $self->{abi_compare_root};
	my $branch = $self->{pgbranch};
	my $last_commit_hash = $self->{last_commit_hash};
	my $head_commit_hash = $self->{head_commit_hash};
	my $clone_name = $self->{clone_name};

	print time_str(), "building ", __PACKAGE__, "\n" if $verbose;

	chdir "$abi_compare_root/$clone_name"
	  or die "Cannot change to PostgreSQL source directory: $!";

	if (!defined $last_commit_hash || $last_commit_hash eq '')
	{
		print time_str(),
		  "ABICompCheck: No previous commit hash found, comparing last 2 commits only.\n"
		  if $verbose;
		my @two_commit_hashes = split /\n/, `git rev-list --max-count=2 HEAD`;
		print "Two commit hashes: @two_commit_hashes\n" if $verbose;
		if (@two_commit_hashes < 2)
		{
			print time_str(),
			  "ABICompCheck: Not enough commits found for comparison. Skipping build.\n"
			  if $verbose;
			return;
		}
		_process_commits_list($self, \@two_commit_hashes);
	}
	else
	{
		my @commits =
		  `git rev-list --reverse $last_commit_hash..$head_commit_hash`;
		chomp @commits;
		if (!@commits)
		{
			print time_str(),
			  "ABICompCheck: No new commits found since last run. Skipping build.\n"
			  if $verbose;
			return;
		}

		print time_str(),
		  "ABICompCheck: Found new commits since last run. Processing ",
		  scalar(@commits), " commits:\n"
		  if $verbose;
		_process_commits_list($self, \@commits, $last_commit_hash);
	}
	return;
}

sub cleanup
{
	my $self = shift;

	print time_str(), "cleaning up ", __PACKAGE__, "\n" if $verbose > 1;

	my $head_commit_hash = $self->{head_commit_hash};
	my $abi_compare_root = $self->{abi_compare_root};
	chdir $abi_compare_root
	  or die "Cannot change to ABI compare root directory: $abi_compare_root";
	if (defined $head_commit_hash && $head_commit_hash ne '')
	{
		my $last_commit_hash_file = "$abi_compare_root/githead.log";

		open my $fh, '>', $last_commit_hash_file
		  or die "Cannot open $last_commit_hash_file for write: $!";
		print $fh "$head_commit_hash\n";
		close $fh;
		print time_str(),
		  "ABICompCheck: Stored commit hash $head_commit_hash in $last_commit_hash_file\n"
		  if $verbose;
	}
	rmtree("$abi_compare_root/install")
	  if -d "$abi_compare_root/install";
	rmtree("$abi_compare_root/pgsql")
	  if -d "$abi_compare_root/pgsql";
	return;
}

1;
