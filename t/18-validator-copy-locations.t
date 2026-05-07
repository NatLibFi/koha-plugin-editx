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

use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator');

{
    package Editx::ValidatorCopyLocationLogger;

    sub new {
        my ($class) = @_;
        return bless { errors => [] }, $class;
    }

    sub logError {
        my ( $self, $message ) = @_;
        push @{ $self->{errors} }, $message;
        return 1;
    }
}

sub _xpath_context {
    my ($copy_detail_xml) = @_;
    my $xml = <<"XML";
<LibraryShipNotice>
  <ItemDetail>
$copy_detail_xml
  </ItemDetail>
</LibraryShipNotice>
XML

    my $doc = XML::LibXML->load_xml( string => $xml );
    return XML::LibXML::XPathContext->new($doc);
}

subtest 'matching copy locations pass validation' => sub {
    my $logger = Editx::ValidatorCopyLocationLogger->new;
    my $xc = _xpath_context(<<'XML');
    <CopyDetail>
      <DeliverToLocation>MAINSTACK2026</DeliverToLocation>
      <DestinationLocation>MAINSTACK2026</DestinationLocation>
    </CopyDetail>
XML

    my $errors = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validate_copy_locations( $xc, $logger, 'order.xml: ' );

    is( $errors, 0, 'Matching DeliverToLocation and DestinationLocation pass' );
    is_deeply( $logger->{errors}, [], 'No location errors are logged' );
};

subtest 'mismatched copy locations fail validation' => sub {
    my $logger = Editx::ValidatorCopyLocationLogger->new;
    my $xc = _xpath_context(<<'XML');
    <CopyDetail>
      <DeliverToLocation>MAINSTACK2026</DeliverToLocation>
      <DestinationLocation>BRANCHSTACK2026</DestinationLocation>
    </CopyDetail>
XML

    my $errors = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validate_copy_locations( $xc, $logger, 'order.xml: ' );

    is( $errors, 1, 'Mismatched DeliverToLocation and DestinationLocation fail' );
    is_deeply(
        $logger->{errors},
        ['order.xml: DeliverToLocation and DestinationLocation do not match: MAINSTACK2026 != BRANCHSTACK2026'],
        'Mismatch error names both fields and values'
    );
};

subtest 'each CopyDetail must carry both location elements' => sub {
    my $logger = Editx::ValidatorCopyLocationLogger->new;
    my $xc = _xpath_context(<<'XML');
    <CopyDetail>
      <DeliverToLocation>MAINSTACK2026</DeliverToLocation>
      <DestinationLocation>MAINSTACK2026</DestinationLocation>
    </CopyDetail>
    <CopyDetail>
      <DeliverToLocation>MAINSTACK2026</DeliverToLocation>
    </CopyDetail>
XML

    my $errors = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validate_copy_locations( $xc, $logger, 'order.xml: ' );

    is( $errors, 1, 'Missing DestinationLocation in one CopyDetail fails even when another copy has it' );
    is_deeply( $logger->{errors}, ['order.xml: DestinationLocation not present '], 'Missing per-copy DestinationLocation is logged once' );
};

done_testing();
