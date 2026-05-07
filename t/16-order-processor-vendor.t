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

use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor');

{
    package Editx::OrderProcessorTestLogger;

    sub new {
        my ($class) = @_;
        return bless { warnings => [] }, $class;
    }

    sub warn {
        my ( $self, $message ) = @_;
        push @{ $self->{warnings} }, $message;
        return 1;
    }
}

{
    package Editx::OrderProcessorTestDbh;

    sub new {
        my ( $class, $params ) = @_;
        $params ||= {};
        return bless { executed => [], vendor_id => $params->{vendor_id} }, $class;
    }

    sub prepare {
        my ( $self, $sql ) = @_;
        return Editx::OrderProcessorTestSth->new( $self, $sql );
    }
}

{
    package Editx::OrderProcessorTestSth;

    sub new {
        my ( $class, $dbh, $sql ) = @_;
        return bless { dbh => $dbh, sql => $sql }, $class;
    }

    sub execute {
        my ( $self, @bind ) = @_;
        push @{ $self->{dbh}->{executed} }, [ $self->{sql}, @bind ];
        return 1;
    }

    sub fetchrow_array {
        my ($self) = @_;
        return $self->{dbh}->{vendor_id};
    }
}

{
    package Editx::OrderProcessorTestOrder;

    sub new {
        my ( $class, $vendor_id, $buyer_id ) = @_;
        return bless { vendor_id => $vendor_id, buyer_id => $buyer_id }, $class;
    }

    sub getVendorAssignedId {
        my ($self) = @_;
        return $self->{vendor_id};
    }

    sub getBuyerAssignedId {
        my ($self) = @_;
        return $self->{buyer_id};
    }
}

subtest 'getBookseller dies with the missing VendorAssignedID mapping' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new;
    my $order = Editx::OrderProcessorTestOrder->new( 'LIBSAN001', '' );

    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    my $ok = eval {
        $processor->getBookseller($order);
        1;
    };

    ok( !$ok, 'getBookseller dies when VendorAssignedID has no vendor mapping' );
    like( $@, qr{No vendor for SAN LIBSAN001 \(qualifier 91\) in vendor_edi_accounts\.}, 'Die message includes SAN and qualifier' );
    is_deeply(
        $logger->{warnings},
        ['No vendor for SAN LIBSAN001 (qualifier 91) in vendor_edi_accounts.'],
        'Warning log keeps the same missing vendor message'
    );
    is_deeply(
        $dbh->{executed}->[0],
        [
            "SELECT vendor_id FROM vendor_edi_accounts WHERE san = ? AND id_code_qualifier=? AND transport='FILE' AND orders_enabled='1'",
            'LIBSAN001',
            91,
        ],
        'Vendor lookup uses VendorAssignedID qualifier 91'
    );
};

subtest 'getBookseller reports the BuyerAssignedID fallback mapping' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new;
    my $order = Editx::OrderProcessorTestOrder->new( '', 'VENDOR-KOHA-001' );

    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    my $ok = eval {
        $processor->getBookseller($order);
        1;
    };

    ok( !$ok, 'getBookseller dies when BuyerAssignedID fallback has no vendor mapping' );
    like( $@, qr{No vendor for SAN VENDOR-KOHA-001 \(qualifier 92\) in vendor_edi_accounts\.}, 'Die message includes fallback SAN and qualifier' );
    is_deeply(
        $dbh->{executed}->[0],
        [
            "SELECT vendor_id FROM vendor_edi_accounts WHERE san = ? AND id_code_qualifier=? AND transport='FILE' AND orders_enabled='1'",
            'VENDOR-KOHA-001',
            92,
        ],
        'Vendor lookup uses BuyerAssignedID qualifier 92'
    );
};

done_testing();
