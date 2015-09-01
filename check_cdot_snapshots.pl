#!/usr/bin/perl

# --
# check_cdot_snapshots - Check if old Snapshots exists
# Copyright (C) 2013 noris network AG, http://www.noris.net/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

use lib "/usr/lib/netapp-manageability-sdk-5.1/lib/perl/NetApp";
use NaServer;
use NaElement;
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;

GetOptions(
    'hostname=s' => \my $Hostname,
    'username=s' => \my $Username,
    'password=s' => \my $Password,
    'age=i'      => \my $AgeOpt,
    'help|?'     => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

sub Error {
    print "$0: " . $_[0] . "\n";
    exit 2;
}
Error('Option --hostname needed!') unless $Hostname;
Error('Option --username needed!') unless $Username;
Error('Option --password needed!') unless $Password;
$AgeOpt = 3600 * 24 * 90 unless $AgeOpt; # 90 days

my @old_snapshots;
my $now = time;

my $s = NaServer->new( $Hostname, 1, 3 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

my @snapmirrors = snapmirror_volumes();

my $snap_iterator = NaElement->new("snapshot-get-iter");
my $tag_elem = NaElement->new("tag");
$snap_iterator->child_add($tag_elem);

my $xi = new NaElement('desired-attributes');
$snap_iterator->child_add($xi);
my $xi1 = new NaElement('snapshot-info');
$xi->child_add($xi1);
$xi1->child_add_string('name','name');
$xi1->child_add_string('volume','volume');
$xi1->child_add_string('access-time','access-time');

my $next = "";

while(defined($next)){
        unless($next eq ""){
            $tag_elem->set_content($next);    
        }

        $snap_iterator->child_add_string("max-records", 1000);
        my $snap_output = $s->invoke_elem($snap_iterator);

        if ($snap_output->results_errno != 0) {
            my $r = $snap_output->results_reason();
            print "UNKNOWN: $r\n";
            exit 3;
        }

        my @snapshots = $snap_output->child_get("attributes-list")->children_get();

        unless(@snapshots){
            print "OK - No snapshots\n";
            exit 0;
        }

        foreach my $snap (@snapshots){

            my $vol_name = $snap->child_get_string("volume");
            my $snap_time = $snap->child_get_string("access-time");
            my $age = $now - $snap_time;

            if($age >= $AgeOpt){
                unless(grep(/$vol_name/, @snapmirrors)){
                    my $snap_name  = $snap->child_get_string("name");
                    push @old_snapshots, "$vol_name/$snap_name";
                }
            }
        }
        $next = $snap_output->child_get_string("next-tag");
}

if (@old_snapshots) {
    print @old_snapshots . " snapshot(s) older than $AgeOpt seconds:\n";
    print "@old_snapshots\n";
    exit 1;
}
else {
    print "No snapshots are older than $AgeOpt seconds\n";
    exit 0;
}

sub snapmirror_volumes {

    my @volumes;

    my $snapmirror_iterator = NaElement->new("snapmirror-get-iter");
    my $snapmirror_tag_elem = NaElement->new("tag");
    $snapmirror_iterator->child_add($snapmirror_tag_elem);

    my $snapmirror_next_tag = "";

    while(defined($snapmirror_next_tag)){
        unless($snapmirror_next_tag eq ""){
            $snapmirror_tag_elem->set_content($snapmirror_next_tag);
        }

        $snapmirror_iterator->child_add_string("max-records", 1000);
        my $snapmirror_output = $s->invoke_elem($snapmirror_iterator);

        if ($snapmirror_output->results_errno != 0) {
            my $r = $snapmirror_output->results_reason();
            print "UNKNOWN: $r\n";
            exit 3;
        }

        if($snapmirror_output->child_get("attributes-list")){
            my @snap_relations = $snapmirror_output->child_get("attributes-list")->children_get();

            if(@snap_relations){

                foreach my $mirror (@snap_relations){
                    my $dest_vol = $mirror->child_get_string("destination-volume");
                    push(@volumes,$dest_vol);
                }
            }
        }
        $snapmirror_next_tag = $snapmirror_output->child_get_string("next-tag");
    }
    return @volumes;
}
__END__

=encoding utf8

=head1 NAME

check_cdot_snapshots - Check if there are old Snapshots

=head1 SYNOPSIS

check_cdot_snapshots.pl --hostname HOSTNAME \
    --username USERNAME --password PASSWORD [--age AGE-SECONDS]

=head1 DESCRIPTION

Checks if old ( > 90 days ) Snapshots exist

=head1 OPTIONS

=over 4

=item --hostname FQDN

The Hostname of the NetApp to monitor

=item --username USERNAME

The Login Username of the NetApp to monitor

=item --password PASSWORD

The Login Password of the NetApp to monitor

=item --age AGE-SECONDS

Snapshot age in Seconds. Default 90 days

=item -help

=item -?

to see this Documentation

=back

=head1 EXIT CODE

3 if timeout occured
1 if Warning Threshold (90 days) has been reached
0 if everything is ok

=head1 AUTHORS

 Alexander Krogloth <git at krogloth.de>
 Stelios Gikas <sgikas at demokrit.de>
