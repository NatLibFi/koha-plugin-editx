#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $plugin_root = File::Spec->catdir( $Bin, '..' );
my @core_candidates = (
    File::Spec->catdir( $plugin_root, '..', '..', 'Koha' ),
    File::Spec->catdir( $ENV{HOME} || q{}, 'git', 'koha', 'Koha' ),
    File::Spec->catdir( $ENV{HOME} || q{}, 'git', 'KohaCommunity' ),
    File::Spec->catdir( $ENV{HOME} || q{}, 'git', 'Koha' ),
);
my ($core_root) = grep { -d $_ } @core_candidates;

unshift @INC, $plugin_root;
if ($core_root) {
    unshift @INC, $core_root;
    unshift @INC, File::Spec->catdir( $core_root, 'misc', 'translator' );
    unshift @INC, File::Spec->catdir( $core_root, 't', 'lib' );
}

use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory::LibraryShipNotice');
use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::Parser');

my $fixture = File::Spec->catfile( $Bin, 'fixtures', 'library_ship_notice_business.xml' );
my $factory = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory::LibraryShipNotice->new;
my $parser  = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::Parser->new( objectFactory => $factory );

my $notice = $parser->parseFile($fixture);

isa_ok(
    $notice,
    'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice',
    'Fixture parses as a generic LibraryShipNotice'
);

is( $notice->getBasketName,       'ASN-TEST-0001',    'ShipNoticeNumber is used as basket name' );
is( $notice->getPersonName,       'Test Acquisitions', 'Buyer contact person is parsed' );
is( $notice->getVendorAssignedId, 'LIBSAN001',        'BuyerParty VendorAssignedID is parsed' );
is( $notice->getBuyerAssignedId,  'VENDOR-KOHA-001',  'SellerParty BuyerAssignedID is parsed' );

my $item = $notice->getItems->[0];
isa_ok(
    $item,
    'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail',
    'Fixture creates one item detail'
);

is( $item->getTitle,           'EDItX Business Fixture', 'Item title is parsed' );
is( $item->getProductForm,     'BA',                     'ONIX ProductForm is parsed' );
is( $item->getReferenceNumber, 'ORDER-REF-42',           'ReferenceNumber is parsed for order internal note' );
is_deeply(
    $item->getIsbns,
    [ '9789510000001', '9789510000002' ],
    'Seller and EAN identifiers are exposed as ISBN candidates'
);

my $copy = $item->getCopyDetail->[0];
isa_ok(
    $copy,
    'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail::CopyDetail',
    'Fixture creates one copy detail'
);

is( $copy->getCopyQuantity,       '1',             'CopyQuantity is parsed' );
is( $copy->getFundNumber,         'FUND-2026',     'FundNumber is parsed for acquisition fund lookup' );
is( $copy->getFundMonetaryAmount, '12.34',         'Fund monetary amount is parsed' );
is( $copy->getDeliverToLocation,  'MAINSTACK2026', 'DeliverToLocation is parsed for branch/location/year routing' );
is(
    $copy->getXmlData->findnodes('DestinationLocation')->string_value,
    'MAINSTACK2026',
    'DestinationLocation matches DeliverToLocation in the parsed copy detail'
);
is(
    $copy->getMessages->get_node(1)->findnodes('MessageType')->string_value,
    '04',
    'MARCXML MessageType is parsed'
);

done_testing();
