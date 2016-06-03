#!/usr/bin/perl

# nagios: -epn
# --
# check_cdot_snapshots - Check if old Snapshots exists
# Copyright (C) 2013 noris network AG, http://www.noris.net/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

use lib "/usr/lib/netapp-manageability-sdk/lib/perl/NetApp";
use NaServer;
use NaElement;
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;

GetOptions(
    'hostname=s'        => \my $Hostname,
    'username=s'        => \my $Username,
    'password=s'        => \my $Password,
    'age=i'             => \my $AgeOpt,
    'numbersnapshot=i'  => \my $SnapshotNumber,
    'retentiondays=i'   => \my $retention_days,
    'volume=s'          => \my $volumename,
    'help|?'            => sub { exec perldoc => -F => $0 or die "Cannot execute perldoc: $!\n"; },
) or Error("$0: Error in command line arguments\n");

sub Error {
    print "$0: " . $_[0] . "\n";
    exit 2;
}
Error('Option --hostname needed!') unless $Hostname;
Error('Option --username needed!') unless $Username;
Error('Option --password needed!') unless $Password;
$AgeOpt = 3600 * 24 * 90 unless $AgeOpt; # 90 days

$retention_days = $retention_days * 86400;

my @old_snapshots;
my $now = time;

my $s = NaServer->new( $Hostname, 1, 3 );
$s->set_transport_type("HTTPS");
$s->set_style("LOGIN");
$s->set_admin_user( $Username, $Password );

single_volume_check() if $volumename;

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

        my $snaps = $snap_output->child_get("attributes-list");
        my @snapshots = $snaps->children_get();

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

sub single_volume_check {
    my $critical_state = "false";
    my $warning_state = "false";
    my $temp_best_snap = "";
    my $timestamp_best_snap = -1;
    my $snaptime_second = $retention_days*86400;
    my $found = 0;
    my $out = $s->invoke(  
        "volume-list-info", 
        "volume", 
        $volumename
    );
    if($out->results_status() eq "failed") {
        print ("ERROR: Failed script: ".$out->results_reason()."\n");
        exit(2);
    }
    my $out = $connection->invoke(  
        "volume-list-info", 
        "volume", 
        $volumename
    );

    if($out->results_status() eq "failed") {
        print ("ERROR: Script fallito. ".$out->results_reason()."\n");
        exit(2);
    }    

    my $volume_info = $out->child_get("volumes");
    my @volume_list = $volume_info->children_get();


    foreach my $vol (@volume_list) {
        $out = $connection -> invoke(
            "snapshot-list-info", 
            "target-name", $vol->child_get_string("name"),
            "target-type", "volume"
        );
        if ($out->results_status() eq "failed") {
            print("ERROR: Script fallito. ".$out->results_reason()."\n");
            exit(2);
        }
        my $snapshot_info = $out -> child_get("snapshots");
        if ($snapshot_info->has_children() && $snapshotnumber != 0){
            my @snapshot_list = $snapshot_info -> children_get();
            if (scalar @snapshot_list != $snapshotnumber){
                print "WARNING - The snapshot number is different from the requested (=".$snapshotnumber.")\n";
                exit(1);
            }
            foreach my $snap(@snapshot_list){
                my $snap_name = $snap->child_get_string("name");
                my $snap_create_time = $snap->child_get_int("access-time");
                my $current_time = time;
                my $temp = $current_time - $snap_create_time;
                if($current_time - $snap_create_time <= $snaptime_second){
                    if($found == 0){
                        $found = 1;
                        $temp_best_snap = $snap_name;
                        $timestamp_best_snap = $snap_create_time;
                    }elsif ($timestamp_best_snap - $snap_create_time > 0){
                        $temp_best_snap = $snap_name;
                        $timestamp_best_snap = $snap_create_time;
                    }
                }
            }
            if ($found == 1){
                print "OK - Snapshots OK\n";
                exit(0);
            } else {
                print "CRITICAL - The newest snapshot is older than the time requested (=".$retention_days." gg)\n";
                exit(2);
            }
        } else {
            if ((scalar $snapshot_info->has_children() != 0) && $snapshotnumber == 0){
                print "CRITICAL - There are snapshots for a volume that shouldn't have any\n";
                exit(2);
            }elsif ((scalar $snapshot_info->has_children() == 0) && $snapshotnumber != 0){
                print "WARNING - The number of snapshots is different from the expected (=".$snapshotnumber.")\n";
                exit(1);
            }else{
                print "OK - No snapshot for the requested volume\n";
                exit(0);
            }
        }
    }


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

=item --volume VOLUME

Name of the single snapshot that has to be checked (useful for check that a snapshot retention works)

=item --numbersnapshot NUMBER-ITEMS

The number of snapshots that should be present in VOLUME volume (useful for check that a snapshot retention works)

=item --retentiondays AGE-DAYS

Snapshot age in days of the newest snapshot in VOLUME volume (useful for check that a snapshot retention works)

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
