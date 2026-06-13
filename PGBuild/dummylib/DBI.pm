# Dummy DBI module for the CheckPerl module's "perl -cw" step.
#
# Some files in the Postgres tree (e.g. contrib/intarray/bench/bench.pl)
# do "use DBI()". Compiling them with "perl -cw" loads DBI, which in turn
# can drag in DBD::Pg and dlopen libpq. Since the perl-check step runs with
# LD_LIBRARY_PATH pointing at the freshly built libpq, a symbol mismatch
# between that libpq and the installed DBD::Pg breaks the syntax check.
#
# This stub is placed ahead of the real DBI in @INC (via -I) so the syntax
# check never loads the real module. See also DBD/Pg.pm here, and the
# analogous src/tools/msvc/dummylib stubs for the Win32 modules.

=comment

Copyright (c) 2003-2026, Andrew Dunstan

See accompanying License file for license details

=cut

package DBI;

use strict;
use warnings;

1;
