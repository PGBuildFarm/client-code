package PGBuild::WebTxn;

=comment

Copyright (c) 2003-2013, Andrew Dunstan

See accompanying License file for license details


Most of this code is imported from the older standalone script run_web_txn.pl
which is now just a shell that calls the function below. It is now only 
needed on older Msys installations (i.e. things running perl < 5.8).

=cut 

use strict;

use vars qw($VERSION); $VERSION = 'REL_4.15';

use vars qw($changed_this_run $changed_since_success $branch $status $stage
  $animal $ts $log_data $confsum $target $verbose $secret);

BEGIN
{

    # see below for why we can't always make these compile time requirements
    if (defined($^V) && $^V ge v5.8.0)
    {
        require LWP;
        require HTTP::Request::Common;
        require MIME::Base64;
        require Digest::SHA;
        require Storable;
    }
}

sub run_web_txn
{

    my $lrname = shift || 'lastrun-logs';

    # make these runtime imports so they are loaded by the perl that's running
    # the procedure. On older Msys it won't be the same as the one that's
    # running run_build.pl.

    require LWP;
    import LWP;
    require HTTP::Request::Common;
    import HTTP::Request::Common;
    require MIME::Base64;
    import MIME::Base64;
    require Digest::SHA;
    import Digest::SHA  qw(sha1_hex);
    require Storable;
    import Storable qw(nfreeze);

    my $txfname = "$lrname/web-txn.data";
    my $txdhandle;
    $/=undef;
    open($txdhandle,"$txfname") or die "opening $txfname: $!";
    my $txdata = <$txdhandle>;
    close($txdhandle);

    eval $txdata;
    if ($@)
    {
        warn $@;
        return undef;
    }

    my $tarname = "$lrname/runlogs.tgz";
    my $tardata="";
    if (open($txdhandle,$tarname))
    {
        binmode $txdhandle;
        $tardata=<$txdhandle>;
        close($txdhandle);
    }

    # add our own version string and time
    my $current_ts = time;
    my $webscriptversion = "'web_script_version' => '$VERSION',\n";
    my $cts	= "'current_ts' => $current_ts,\n";

    # $2 here helps us to preserve the nice spacing from Data::Dumper
    my $scriptline = "((.*)'script_version' => '(REL_)?\\d+\\.\\d+',\n)";
    $confsum =~ s/$scriptline/$1$2$webscriptversion$2$cts/;
    my $sconf = $confsum;
    $sconf =~ s/.*(\$Script_Config)/$1/ms;
    my $Script_Config;
    eval $sconf;

    # for some reason we see intermittent failures of above code
    # so we also set this directly so it gets into frozen_sconf, which is what
    # the server side script examines.
    $Script_Config->{web_script_version} = $VERSION;

    # very modern Storable modules choke on regexes
    # the server has no need of them anyway, so just chop them out
    # they are still there in the text version used for reporting
    foreach my $k ( keys %$Script_Config )
    {
        delete $Script_Config->{$k}
          if ref($Script_Config->{$k}) eq q(Regexp);
    }
    my $frozen_sconf = nfreeze($Script_Config);

    # make the base64 data escape-proof; = is probably ok but no harm done
    # this ensures that what is seen at the other end is EXACTLY what we
    # see when we calculate the signature

    map{ $_=encode_base64($_,""); tr/+=/$@/; }(
        $log_data,$confsum,$changed_this_run,$changed_since_success,$tardata,
        $frozen_sconf
    );

    my $content =
        "changed_files=$changed_this_run&"
      . "changed_since_success=$changed_since_success&"
      ."branch=$branch&res=$status&stage=$stage&animal=$animal&ts=$ts"
      ."&log=$log_data&conf=$confsum";
    my $sig= sha1_hex($content,$secret);

    $content .= "&frozen_sconf=$frozen_sconf";

    if ($tardata)
    {
        $content .= "&logtar=$tardata";
    }

    my $ua = new LWP::UserAgent;
    $ua->agent("Postgres Build Farm Reporter");
    if (my $proxy = $ENV{BF_PROXY})
    {
        $ua->proxy('http',$proxy);
    }

    my $request=HTTP::Request->new(POST => "$target/$sig");
    $request->content_type("application/x-www-form-urlencoded");
    $request->content($content);

    my $response=$ua->request($request);

    unless ($response->is_success || $verbose > 1)
    {
        print
          "Query for: stage=$stage&animal=$animal&ts=$ts\n",
          "Target: $target/$sig\n";
        print "Status Line: ",$response->status_line,"\n";
        print "Content: \n", $response->content,"\n"
          if ($verbose && $response->content);
        return undef;
    }

    return 1;
}

1;
