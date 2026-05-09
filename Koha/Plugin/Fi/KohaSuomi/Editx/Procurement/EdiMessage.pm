#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EdiMessage;

use C4::Context;
use Data::Dumper;
use File::Basename;
use XML::LibXML;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount;

my $singleton;

sub new {
    my $class = shift;
    $singleton ||= bless {}, $class;
}

sub add {
    my $self = shift;
    my $messagefile = $_[0];
    my $raw_message = $_[1];
    my $dbh = C4::Context->dbh;
    $dbh->do("DELETE FROM edifact_messages WHERE filename=?", undef, $messagefile)
        or die( $dbh->errstr || "Could not delete existing EDItX EDI message '$messagefile'." );
    my $sth = $dbh->prepare("INSERT INTO edifact_messages (message_type, transfer_date, raw_msg, filename) VALUES ('EDItX', NOW(), ?, ?)");
    $sth->execute($raw_message, $messagefile)
        or die( $dbh->errstr || "Could not insert EDItX EDI message '$messagefile'." );
}

sub update {
    my $self = shift;
    my $messagefile = $_[0];
    my $status = $_[1];
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("UPDATE edifact_messages SET status=? WHERE filename=?");
    $sth->execute($status, $messagefile)
        or die( $dbh->errstr || "Could not update EDItX EDI message '$messagefile' to status '$status'." );
}

sub findBookseller {
    my $self = shift;
    my $messagefile = $_[0];

    my $xml = XML::LibXML->new()->parse_file($messagefile);
    my ( $san, $qualifier ) = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount->identifier_from_values(
        $xml->findnodes('/LibraryShipNotice/Header/BuyerParty/PartyID[PartyIDType/text() = "VendorAssignedID"]/Identifier')->string_value(),
        $xml->findnodes('/LibraryShipNotice/Header/SellerParty/PartyID[PartyIDType/text() = "BuyerAssignedID"]/Identifier')->string_value()
    );

    my $dbh = C4::Context->dbh;
    my $vendor = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount->find_vendor(
        {
            dbh       => $dbh,
            san       => $san,
            qualifier => $qualifier,
        }
    );
    my $basename = basename($messagefile);
    die $vendor->{message} . "\n" if $vendor->{status} ne 'found';

    $dbh->do("UPDATE edifact_messages SET vendor_id=? WHERE filename=?", undef, $vendor->{vendor_id}, $basename)
        or die( $dbh->errstr || "Could not update EDI vendor id for '$basename'." );
}

1;
