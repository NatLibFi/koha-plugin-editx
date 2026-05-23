#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use Test::More;
use XML::LibXML;
use XML::LibXML::XPathContext;

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
use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator');

{
    package Editx::Ks25HarvestFixtureLogger;

    sub new {
        my ($class) = @_;
        return bless { errors => [], debug => [] }, $class;
    }

    sub logError {
        my ( $self, $message ) = @_;
        push @{ $self->{errors} }, $message;
        return 1;
    }

    sub debug {
        my ( $self, $message ) = @_;
        push @{ $self->{debug} }, $message;
        return 1;
    }
}

my $btj_fixture        = File::Spec->catfile( $Bin, 'fixtures', 'ks25_v2_btj_ship_notice.xml' );
my $message_01_fixture = File::Spec->catfile( $Bin, 'fixtures', 'ks25_v2_message_type_01_notice.xml' );

sub _parser {
    my $factory = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory::LibraryShipNotice->new;
    return Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::Parser->new( objectFactory => $factory );
}

sub _parse_notice {
    my ($fixture) = @_;
    return _parser()->parseFile($fixture);
}

sub _xpath_context {
    my ($fixture) = @_;
    my $doc = XML::LibXML->load_xml( location => $fixture );
    return XML::LibXML::XPathContext->new($doc);
}

subtest 'BTJ fixture preserves harvested ship notice fields' => sub {
    my $notice = _parse_notice($btj_fixture);

    isa_ok(
        $notice,
        'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::Btj',
        'BTJ seller selects the BTJ notice class'
    );

    is( $notice->getBasketName,       'KS25-BTJ-0001',    'ShipNoticeNumber is parsed as basket name' );
    is( $notice->getVendorAssignedId, '12345',            'BuyerParty VendorAssignedID SAN is parsed' );
    is( $notice->getBuyerAssignedId,  'FI-BTJ',           'SellerParty BuyerAssignedID is parsed' );
    is( $notice->getPersonName,       'Koha Acquisitions', 'Buyer contact person is parsed when present' );
    is( scalar @{ $notice->getItems }, 1,                 'Fixture creates one item detail' );

    my $item = $notice->getItems->[0];
    isa_ok(
        $item,
        'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail::Btj',
        'BTJ notice creates a BTJ item detail'
    );

    is( $item->getTitle,           'Izak.',          'Title is parsed' );
    is( $item->getAuthor,          'Example Author', 'Author is parsed' );
    is( $item->getProductForm,     'BK',             'ProductForm is parsed' );
    is( $item->getReferenceNumber, 'BTJ-ORDER-12345', 'Vendor order reference is parsed' );
    is( $item->getEanIdentifier,   '9789510506103',  'EAN13 product identifier is parsed' );
    is(
        $item->getXmlData->findnodes('ProductID[ProductIDType/text() = "ISBN"]/Identifier')->string_value,
        '978-951-0-50610-3',
        'Hyphenated ISBN product identifier remains available'
    );
    is( $item->getPriceFixedRPExcludingTax, '12.00', 'FixedRPExcludingTax monetary amount is parsed' );
    is( $item->getPriceSRPECurrency,        'EUR',   'SRPExcludingTax currency is parsed' );
    is( $item->getPriceSRPETaxPercent,      '14',    'SRPExcludingTax VAT percent is parsed' );

    my $copy = $item->getCopyDetail->[0];
    isa_ok(
        $copy,
        'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::ItemDetail::CopyDetail::Btj',
        'BTJ item creates a BTJ copy detail'
    );

    is( $copy->getCopyQuantity,       '1',           'CopyQuantity is parsed' );
    is( $copy->getDeliverToLocation,  'OUPKAIK2025', 'DeliverToLocation is parsed' );
    is( $copy->getFundNumber,         'OUPKAIK2025', 'FundNumber is parsed' );
    is( $copy->getFundMonetaryAmount, '12.00',       'Fund monetary amount is parsed' );
    is(
        $copy->getXmlData->findnodes('DestinationLocation')->string_value,
        'OUPKAIK2025',
        'DestinationLocation matches DeliverToLocation in the fixture'
    );
    is(
        $copy->getXmlData->findnodes('LocationCode')->string_value,
        'FI-KOHA;210;1',
        'Vendor LocationCode is preserved for later mapping decisions'
    );
    is(
        $copy->getMessages->get_node(1)->findnodes('MessageType')->string_value,
        '04',
        'MARCXML MessageType is parsed'
    );
    is( $copy->getBooksellerCode, 'FI-Woima', 'Embedded MARCXML can be decoded through the BTJ copy detail' );
};

subtest 'MessageType validation accepts harvested fixture boundaries' => sub {
    my $logger = Editx::Ks25HarvestFixtureLogger->new;
    my $errors = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validate_message_types(
        _xpath_context($btj_fixture),
        $logger,
        'ks25_v2_btj_ship_notice.xml: '
    );

    is( $errors, 0, 'BTJ MessageType 04 fixture passes message validation' );
    is_deeply( $logger->{errors}, [], 'MessageType 04 fixture logs no validation errors' );
    is( $logger->{debug}->[0], 'MessageType 04 present, testing xml', 'MessageType 04 still triggers MARCXML validation' );
    like( $logger->{debug}->[1] || q{}, qr/Izak\./, 'MessageType 04 logs the embedded 245a value' );

    $logger = Editx::Ks25HarvestFixtureLogger->new;
    $errors = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validate_message_types(
        _xpath_context($message_01_fixture),
        $logger,
        'ks25_v2_message_type_01_notice.xml: '
    );

    is( $errors, 0, 'MessageType 01 fixture passes without MARCXML content' );
    is_deeply( $logger->{errors}, [], 'MessageType 01 fixture logs no validation errors' );
    is_deeply( $logger->{debug}, ['MessageType 01 found, passing xml test'], 'MessageType 01 keeps the non-MARCXML boundary visible' );
};

subtest 'MessageType 01 fixture remains parseable as a ship notice' => sub {
    my $notice = _parse_notice($message_01_fixture);
    my $copy   = $notice->getItems->[0]->getCopyDetail->[0];

    isa_ok(
        $notice,
        'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::Btj',
        'MessageType 01 fixture still selects the BTJ notice class'
    );
    is( $notice->getBasketName, 'KS25-BTJ-INFO-0001', 'Informational fixture ShipNoticeNumber is parsed' );
    is( $copy->getMessages->get_node(1)->findnodes('MessageType')->string_value, '01', 'MessageType 01 is parsed' );
    is( $copy->getMessages->get_node(1)->findnodes('MessageLine')->string_value, 'Simple message', 'Plain MessageLine is preserved' );
};

done_testing();
