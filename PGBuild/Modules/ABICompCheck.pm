
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
	return if $branch !~ /^(?:HEAD|REL_?\d+(?:_\d+)?_STABLE)$/;

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

	mkdir $abi_compare_root
	  unless -d $abi_compare_root;
	mkdir "$abi_compare_root/logs"
	  unless -d "$abi_compare_root/logs";
	mkdir "$abi_compare_root/xmls"
	  unless -d "$abi_compare_root/xmls";
	mkdir "$abi_compare_root/install"
	  unless -d "$abi_compare_root/install";

	my $scm = PGBuild::SCM->new(\%PGBuild::conf);
	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql,
		abi_compare_root => $abi_compare_root,
		scm => $scm,
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

	my $buildroot = $self->{buildroot};        # Build root directory
	my $branch = $self->{pgbranch};            # PostgreSQL branch/tag/commit
	my $abi_compare_root = $self->{abi_compare_root};
	my $pg_checkout_dir = $self->{pgsql};      # PostgreSQL checkout directory
	my $pg_branch_name = $self->{pgbranch};    # PostgreSQL branch/tag/commit
	my $last_commit_hash_file =
	  "$abi_compare_root/$branch/last_pg_commit_hash.txt";
	my $animal = $self->{bfconf}->{animal};

	if (-f $last_commit_hash_file)
	{
		my $last_commit_hash = file_contents($last_commit_hash_file);

		chomp $last_commit_hash if defined $last_commit_hash;


		my $head_commit_hash =
		  file_contents("$buildroot/$branch/$animal.lastrun-logs/githead.log");

		$self->{last_commit_hash} = $last_commit_hash;
		$self->{head_commit_hash} = $head_commit_hash;

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
	}
	else
	{
		# Last commit hash file does not exist, so a run is needed.
		print time_str(),
		  "ABICompCheck: Stored PostgreSQL commit hash file ('$last_commit_hash_file') not found. Run needed.\n"
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
	my ($self, $cmd, $commit_hash, $cmd_desc) = @_;

	my $abi_compare_root = $self->{abi_compare_root};
	my $log_dir = "$abi_compare_root/logs/$commit_hash";

	# Ensure log directory exists
	mkdir $log_dir unless -d $log_dir;

	my $log_file = "$log_dir/$cmd_desc.log";

	print time_str(), "Executing: $cmd_desc\n" if $verbose;

	my @output = run_log($cmd);
	my $exit_status = $? >> 8;

	open my $fh, '>', $log_file
	  or die "Cannot open log file $log_file for writing: $!";
	print $fh "$_\n" for @output;
	close $fh;

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

	print time_str(),
	  "Configuring, making, and installing for commit $commit_hash in ",
	  __PACKAGE__, "\n"
	  if $verbose;

	chdir "$abi_compare_root/pgsql"
	  or die
	  "Cannot change to PostgreSQL source directory: $abi_compare_root/pgsql for commit $commit_hash";

	_log_command_output($self,
		qq{./configure CFLAGS="-Og -g" --prefix=$abi_compare_root/install/},
		$commit_hash, 'configure');
	print time_str(), "Configuration complete for commit $commit_hash.\n"
	  if $verbose;

	_log_command_output($self, qq{make}, $commit_hash, 'make');

	_log_command_output($self, q{make install}, $commit_hash, 'makeinstall');

	return;
}

sub _generate_abidw_xml
{
	my $self = shift;
	my @abidw_flags_list = (
		'--drop-undefined-syms', '--no-architecture',
		'--no-comp-dir-path', '--no-elf-needed',
		'--no-show-locs', '--type-id-style',
		'hash',
	);
	my $abidw_flags_str = join(' ', @abidw_flags_list);
	my $commit_hash = shift;

	print time_str(), "Generating ABIDW XML for commit $commit_hash in ",
	  __PACKAGE__, "\n"
	  if $verbose;

	my $abi_compare_root = $self->{abi_compare_root};
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

	my @targets_to_process = (
		{
			name => 'postgres',
			input_path => "$install_bin_dir/postgres",
			output_file => "$commit_xml_dir/postgres.abi",
		},
		{
			name => 'ecpg',
			input_path => "$install_bin_dir/ecpg",
			output_file => "$commit_xml_dir/ecpg.abi",
		},
		{
			name => 'libpq.so',
			input_path => "$install_lib_dir/libpq.so",
			output_file => "$commit_xml_dir/libpq.so.abi",
		}
	);

	foreach my $target (@targets_to_process)
	{
		my $target_name = $target->{name};
		my $input_file_path = $target->{input_path};
		my $output_abi_file = $target->{output_file};

		unless (-e $input_file_path)
		{
			print time_str(),
			  "Warning: Input file '$input_file_path' for $target_name not found. Skipping ABI generation for this target (commit $commit_hash).\n"
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

sub _process_commits_list
{
	my $self = shift;
	my $commits_list = shift;
	my $scm = $self->{scm};

	print time_str(), "Processing commits list in ", __PACKAGE__, "\n"
	  if $verbose;

	foreach my $commit (@$commits_list)
	{
		_checkout_commit($self, $commit);
		_configure_make_and_build($self, $commit);
		_generate_abidw_xml($self, $commit);
	}

	return;
}

sub print_logs
{
	my ($clonelog) = @_;

	# Print the git clone log if it exists
	if (@$clonelog)
	{
		print "ABICompCheck: git clone log:\n";
		foreach my $line (@$clonelog)
		{
			print $line, "\n";
		}
	}
}

sub install
{
	my $self = shift;
	my $abi_compare_root = $self->{abi_compare_root};
	my $branch = $self->{pgbranch};
	my $animal = $self->{bfconf}->{animal};
	my $last_commit_hash = $self->{last_commit_hash};
	my $head_commit_hash = $self->{head_commit_hash};
	my $buildroot = $self->{buildroot};
	my $pgsql = $self->{pgsql};
	my $mirror_base = $self->{scm}->{mirror};

	print time_str(), "building ", __PACKAGE__, "\n" if $verbose;

	my @clonelog;
	my $status;
	if (-d "$abi_compare_root/pgsql")
	{
		print time_str(),
		  "ABICompCheck: pgsql directory already exists, skipping clone.\n"
		  if $verbose;
		$status = 0;
	}
	else
	{
		print "running ", qq{git clone -q  "$mirror_base" "pgsql"}, "\n";
		@clonelog =
		  run_log(qq{git clone -q "$mirror_base" "$abi_compare_root/pgsql"});
		$status = $? >> 8;
	}

	print_logs(\@clonelog);

	if (!$status)
	{
		chdir "$abi_compare_root/pgsql"
		  or die "Cannot change to PostgreSQL source directory: $!";
		print time_str(),
		  "ABICompCheck: Cloned PostgreSQL source to $abi_compare_root/pgsql\n"
		  if $verbose;

		my @checkout_log = run_log(qq{git checkout -q "$branch"});
		print_logs(\@checkout_log);
		$status = $? >> 8;
		if ($status)
		{
			die "git checkout failed with status $status";
		}
		print time_str(),
		  "ABICompCheck: Checked out branch '$branch' in $abi_compare_root/pgsql\n"
		  if $verbose;

		if (!defined $last_commit_hash || $last_commit_hash eq '')
		{
			print time_str(),
			  "ABICompCheck: No previous commit hash found, comparing last 2 commits only.\n"
			  if $verbose;
			my @two_commit_hashes = split /\n/,
			  `git rev-list --max-count=2 HEAD^`;
			print "Two commit hashes: @two_commit_hashes\n" if $verbose;
			if (@two_commit_hashes < 2)
			{
				print time_str(),
				  "ABICompCheck: Not enough commits found for comparison. Skipping build.\n"
				  if $verbose;
				return;
			}

			_process_commits_list($self, \@two_commit_hashes);
			return;
		}

		my @commits = `git rev-list --reverse $last_commit_hash..HEAD`;
		chomp @commits;
		if (!@commits)
		{
			print time_str(),
			  "ABICompCheck: No new commits found since last run. Skipping build.\n"
			  if $verbose;
			return;
		}

		print time_str(),
		  "ABICompCheck: Found new commits since last run. Processing commits:\n"
		  if $verbose;
		_process_commits_list($self, @commits);
	}
	else
	{
		die "clone status: $status";
	}
	return;
}

sub cleanup
{
	my $self = shift;

	print time_str(), "cleaning up ", __PACKAGE__, "\n" if $verbose > 1;
	return;
}

1;
