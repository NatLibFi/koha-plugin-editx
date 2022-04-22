#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::Booky;

use Modern::Perl;
use Moose;
use Data::Dumper;

extends "Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice";

sub BUILD {
    my $self = shift;
    $self->setItemObjectName('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail::Booky');
}

sub determineObjectClass {
     my $self = shift;
     my $xmlObject = $_[0];
     my $parser = $_[1];
     my $sellerName = '';
     my $result = 0;

     my $header = $self->getHeader($xmlObject,$parser);
     $sellerName = $self->getSellerName($xmlObject, $header);

     if( $sellerName eq 'Booky.fi Oy' ){
         $result = 1;
         print "Booky \n";
     }

    return $result;
}

1;
