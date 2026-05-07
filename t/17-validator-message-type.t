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
    package Editx::ValidatorMessageTypeLogger;

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

sub _xpath_context {
    my ($copy_detail_xml) = @_;
    my $xml = <<"XML";
<LibraryShipNotice>
  <ItemDetail>
    <CopyDetail>
$copy_detail_xml
    </CopyDetail>
  </ItemDetail>
</LibraryShipNotice>
XML

    my $doc = XML::LibXML->load_xml( string => $xml );
    return XML::LibXML::XPathContext->new($doc);
}

subtest 'missing MessageType is counted once' => sub {
    my $logger = Editx::ValidatorMessageTypeLogger->new;
    my $xc = _xpath_context('<Message><MessageLine /></Message>');

    my $errors = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validate_message_types( $xc, $logger, 'order.xml: ' );

    is( $errors, 1, 'Missing MessageType adds one validation error' );
    is_deeply( $logger->{errors}, ['order.xml: MessageType not present '], 'Missing MessageType is logged once' );
};

subtest 'MessageType 01 passes without MARCXML validation' => sub {
    my $logger = Editx::ValidatorMessageTypeLogger->new;
    my $xc = _xpath_context('<Message><MessageType>01</MessageType></Message>');

    my $errors = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validate_message_types( $xc, $logger, 'order.xml: ' );

    is( $errors, 0, 'MessageType 01 is accepted' );
    is_deeply( $logger->{errors}, [], 'MessageType 01 logs no validation errors' );
    is_deeply( $logger->{debug}, ['MessageType 01 found, passing xml test'], 'MessageType 01 keeps debug logging' );
};

subtest 'unknown MessageType is rejected once' => sub {
    my $logger = Editx::ValidatorMessageTypeLogger->new;
    my $xc = _xpath_context('<Message><MessageType>99</MessageType></Message>');

    my $errors = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::validate_message_types( $xc, $logger, 'order.xml: ' );

    is( $errors, 1, 'Unknown MessageType adds one validation error' );
    is_deeply( $logger->{errors}, ['order.xml: Wrong type of MessageType found: 99'], 'Unknown MessageType logs the rejected value once' );
};

done_testing();
