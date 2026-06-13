# Dummy DBD::Pg module for the CheckPerl module's "perl -cw" step.
#
# The real DBD::Pg dlopens libpq. The perl-check step runs with
# LD_LIBRARY_PATH pointing at the freshly built libpq, so a symbol mismatch
# between that libpq and the installed DBD::Pg breaks "perl -cw" on files
# that "use DBD::Pg" (e.g. contrib/intarray/bench/bench.pl).
#
# This stub is placed ahead of the real DBD::Pg in @INC (via -I) so the
# syntax check never loads the real module. See also DBI.pm here.

=comment

Copyright (c) 2003-2026, Andrew Dunstan

See accompanying License file for license details

=cut

package DBD::Pg;

use strict;
use warnings;

1;
