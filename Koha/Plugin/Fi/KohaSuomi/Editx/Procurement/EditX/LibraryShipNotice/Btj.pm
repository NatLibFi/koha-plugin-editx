#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::Btj;

use Modern::Perl;
use Moose;
use Data::Dumper;

extends "Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice";

sub BUILD {
    my $self = shift;
    $self->setItemObjectName('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail::Btj');
}

sub determineObjectClass {
     my $self = shift;
     my $xmlObject = $_[0];
     my $parser = $_[1];
     my $sellerName = '';
     my $result = 0;

     my $header = $self->getHeader($xmlObject,$parser);
     $sellerName = $self->getSellerName($xmlObject, $header);

     if( $sellerName eq 'BTJ Finland Oy' ){
        print "BTJ \n";
        $result = 1;
     }

    return $result;
}


1;
