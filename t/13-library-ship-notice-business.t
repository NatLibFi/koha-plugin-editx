#!/usr/bin/perl

use Modern::Perl;
use utf8;

use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
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

subtest 'matching seller-specific notice class is detected with an object instance' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $seller_file = File::Spec->catfile( $dir, 'kirjavalitys.xml' );

    open my $in, '<:encoding(UTF-8)', $fixture or die "Cannot read $fixture: $!";
    my $xml = do { local $/; <$in> };
    close $in or die "Cannot close $fixture: $!";

    $xml =~ s{<NameLine>Alexandria Test Books</NameLine>}{<NameLine>Kirjavälitys Oy</NameLine>};

    open my $out, '>:encoding(UTF-8)', $seller_file or die "Cannot write $seller_file: $!";
    print {$out} $xml;
    close $out or die "Cannot close $seller_file: $!";

    my $matched_notice = $parser->parseFile($seller_file);

    isa_ok(
        $matched_notice,
        'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::LibraryShipNotice::Kirjavalitys',
        'Kirjavalitys seller-specific notice is instantiated without class-method logger failure'
    );
};

subtest 'parseFiles dies with context when a file cannot become an order object' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $bad_file = File::Spec->catfile( $dir, 'bad.xml' );
    open my $fh, '>', $bad_file or die "Cannot write $bad_file: $!";
    print {$fh} '<LibraryShipNotice>';
    close $fh or die "Cannot close $bad_file: $!";

    my $ok = eval {
        $parser->parseFiles($dir);
        1;
    };

    ok( !$ok, 'parseFiles dies on an unparseable XML file' );
    like( $@, qr{Could not parse EDItX file \Q$bad_file\E into an order object}, 'parseFiles reports the failing file path' );
};

done_testing();
