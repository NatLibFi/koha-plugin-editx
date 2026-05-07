#!/usr/bin/perl

use Modern::Perl;

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

use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator');

sub write_xml {
    my ( $path, $xml ) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print {$fh} $xml;
    close $fh or die "Cannot close $path: $!";
    return $path;
}

subtest 'parse_editx_xml accepts shell metacharacters as filename characters' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, q{notice; still a filename.xml} );
    write_xml( $path, '<LibraryShipNotice><Header><ShipNoticeNumber>ASN-TEST</ShipNoticeNumber></Header></LibraryShipNotice>' );

    my ( $doc, $xc ) = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::parse_editx_xml($path);

    isa_ok( $doc, 'XML::LibXML::Document', 'XML document is parsed' );
    isa_ok( $xc,  'XML::LibXML::XPathContext', 'XPath context is returned' );
    is( $xc->find('LibraryShipNotice')->get_node(1)->nodeName, 'LibraryShipNotice', 'Root node is retained' );
};

subtest 'parse_editx_xml treats shell payloads as filenames' => sub {
    my $sentinel = File::Spec->catfile( $plugin_root, 'validator_shell_injected' );
    unlink $sentinel if -e $sentinel;

    my $fixture = File::Spec->catfile( $Bin, 'fixtures', 'library_ship_notice_business.xml' );
    my $payload = "$fixture; touch validator_shell_injected; #";

    my $ok = eval {
        Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Validator::parse_editx_xml($payload);
        1;
    };

    ok( !$ok, 'Payload is not split by a shell and therefore is not a valid filename' );
    ok( !-e $sentinel, 'Shell payload did not create a sentinel file' );

    unlink $sentinel if -e $sentinel;
};

done_testing();
