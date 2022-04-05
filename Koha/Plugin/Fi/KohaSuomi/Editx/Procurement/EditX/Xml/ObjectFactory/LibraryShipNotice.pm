#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory::LibraryShipNotice;

use Modern::Perl;
use Moose;
extends "Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory";

use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice;
use Data::Dumper;

sub BUILD {
    my $self = shift;
    $self->setSchemaName('EDItX_LibraryShipNotice_V1.0.xsd');
    $self->setObjectName('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice');

    $self->addObjectCandidate('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::Booky');
    $self->addObjectCandidate('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::Btj');
    $self->addObjectCandidate('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::Kirjavalitys');
}

sub fillValues{
    my $self = shift;
    my $object = $_[0];
    my $xmlObject = $_[1];
    my $parser = $_[2];

    $object->setXmlData($xmlObject);
    $object->setParser($parser);

    my $itemDetails = $object->getItemDetails($xmlObject, $parser);
    $self->createItemObjects($object, $xmlObject, $xmlObject, $parser, $itemDetails);

    my $items = $object->getItems();
    my $item;

    my $copyDetails;
    foreach(@$items){
        $item = $_;
        $copyDetails = $item->getCopydetails();
        $self->createItemObjects($item, $item->getXmlData(), $xmlObject, $item->getParser(), $copyDetails);
    }
}

1;
