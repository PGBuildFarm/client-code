
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
	# 'checkout' => \&checkout,
	# 'setup-target' => \&setup_target,
	'need-run' => \&need_run,
	# 'configure' => \&configure,
	'build' => \&build,
	# 'check' => \&check,
	# 'install' => \&install,
	# 'installcheck' => \&installcheck,
	# 'locale-end' => \&locale_end,
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

	mkdir $abi_compare_root unless -d $abi_compare_root;

	my $scm = PGBuild::SCM::Git->new(\%PGBuild::conf);
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

# sub checkout
# {
# 	my $self = shift;
# 	my $savescmlog = shift;    # array ref to the log lines

# 	print time_str(), "checking out ", __PACKAGE__, "\n" if $verbose;

# 	push(@$savescmlog, "Skeleton processed checkout\n");
# 	return;
# }

# sub setup_target
# {
# 	my $self = shift;

# 	# copy the code or setup a vpath dir if supported as appropriate

# 	print time_str(), "setting up ", __PACKAGE__, "\n" if $verbose;
# 	return;

# }

sub need_run
{
	my $self = shift;
	my $run_needed = shift;    # ref to flag

	print time_str(), "checking if run needed by ", __PACKAGE__, "\n"
	  if $verbose;

	my $buildroot = $self->{buildroot}; # Build root directory
	my $branch = $self->{pgbranch};      # PostgreSQL branch/tag/commit
	my $abi_compare_root = $self->{abi_compare_root};
	my $pg_checkout_dir  = $self->{pgsql};    # PostgreSQL checkout directory
	my $pg_branch_name   = $self->{pgbranch}; # PostgreSQL branch/tag/commit
	my $scm = $self->{scm};
	my $last_commit_hash_file = "$abi_compare_root/$branch/last_pg_commit_hash.txt";
	my $animal = $self->{bfconf}->{animal};

	if (-f $last_commit_hash_file)
	{
		my $last_commit_hash=file_contents($last_commit_hash_file);

		chomp $last_commit_hash if defined $last_commit_hash;

		
		my $head_commit_hash =
		file_contents(
				"$buildroot/$branch/$animal.lastrun-logs/githead.log");

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


# sub configure
# {
# 	my $self = shift;

# 	print time_str(), "configuring ", __PACKAGE__, "\n" if $verbose;
# 	return;
# }

sub build
{
	my $self = shift;
	my $abi_compare_root = $self->{abi_compare_root};
	my $branch = $self->{pgbranch};
	my $animal = $self->{bfconf}->{animal};
	my $last_commit_hash= $self->{last_commit_hash};
	my $head_commit_hash = $self->{head_commit_hash};
	my $buildroot = $self->{buildroot};
	my $pgsql = $self->{pgsql};

	if (!defined $last_commit_hash || $last_commit_hash eq '')
	{
		print time_str(),
		  "ABICompCheck: No previous commit hash found, this runs.\n"
		  if $verbose;
		return;
	}

	my @commits = `git rev-list --reverse $last_commit_hash..HEAD`;
	chomp @commits;

	foreach my $commit (@commits) {
		print "Processing commit: $commit\n";

		# Checkout the commit
		system("git checkout -f $commit") == 0
			or die "Failed to checkout $commit";

		print "It works\n";
	}


	print time_str(), "building ", __PACKAGE__, "\n" if $verbose;
	return;
}

# sub install
# {
# 	my $self = shift;

# 	print time_str(), "installing ", __PACKAGE__, "\n" if $verbose;
# 	return;
# }

# sub check
# {
# 	my $self = shift;

# 	print time_str(), "checking ", __PACKAGE__, "\n" if $verbose;
# 	return;
# }

# sub installcheck
# {
# 	my $self = shift;
# 	my $locale = shift;

# 	print time_str(), "installchecking $locale", __PACKAGE__, "\n"
# 	  if $verbose;
# 	return;
# }

# sub locale_end
# {
# 	my $self = shift;
# 	my $locale = shift;

# 	print time_str(), "end of locale $locale processing", __PACKAGE__, "\n"
# 	  if $verbose;
# 	return;
# }

sub cleanup
{
	my $self = shift;

	print time_str(), "cleaning up ", __PACKAGE__, "\n" if $verbose > 1;
	return;
}

1;
