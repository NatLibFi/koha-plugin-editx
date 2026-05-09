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
        my $columns = exists $params->{columns} ? $params->{columns} : { transport => 1, orders_enabled => 1 };
        my $rows    = $params->{rows} || [];
        return bless {
            column_checks => [],
            columns       => $columns,
            executed      => [],
            rows          => $rows,
        }, $class;
    }

    sub prepare {
        my ( $self, $sql ) = @_;
        return Editx::OrderProcessorTestSth->new( $self, $sql );
    }

    sub selectrow_array {
        my ( $self, $sql, $attrs, @bind ) = @_;
        my ( $table, $column ) = @bind;
        push @{ $self->{column_checks} }, "$table.$column";
        return $self->{columns}->{"$table.$column"} || $self->{columns}->{$column} ? 1 : 0;
    }

    sub errstr {
        return;
    }
}

{
    package Editx::OrderProcessorTestSth;

    sub new {
        my ( $class, $dbh, $sql ) = @_;
        return bless { dbh => $dbh, rows => [], sql => $sql }, $class;
    }

    sub execute {
        my ( $self, @bind ) = @_;
        push @{ $self->{dbh}->{executed} }, [ $self->{sql}, @bind ];
        $self->{rows} = [ $self->_matching_vendor_rows(@bind) ];
        return 1;
    }

    sub fetchrow_hashref {
        my ($self) = @_;
        return shift @{ $self->{rows} };
    }

    sub fetchrow_array {
        my ($self) = @_;
        my $row = $self->fetchrow_hashref;
        return $row ? $row->{vendor_id} : ();
    }

    sub _matching_vendor_rows {
        my ( $self, @bind ) = @_;

        return () unless $self->{sql} =~ /FROM vendor_edi_accounts/;

        my $san = shift @bind;
        my $qualifier;
        if ( $self->{sql} =~ /vea\.id_code_qualifier = \?/ ) {
            $qualifier = shift @bind;
        }
        my $orders_enabled;
        if ( $self->{sql} =~ /vea\.orders_enabled = \?/ ) {
            $orders_enabled = shift @bind;
        }
        my $transport;
        if ( $self->{sql} =~ /(?:ft|vea)\.transport = \?/ ) {
            $transport = shift @bind;
        }

        my @rows = @{ $self->{dbh}->{rows} };
        @rows = grep { ( $_->{san} // q{} ) eq $san } @rows;
        @rows = grep { ( $_->{id_code_qualifier} // q{} ) eq $qualifier } @rows if defined $qualifier;
        @rows = grep { ( $_->{orders_enabled} // q{} ) eq $orders_enabled } @rows if defined $orders_enabled;
        if ( defined $transport ) {
            my $field = $self->{sql} =~ /ft\.transport = \?/ ? 'file_transport' : 'legacy_transport';
            @rows = grep { ( $_->{$field} // q{} ) eq $transport } @rows;
        }
        return @rows;
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

{
    package Editx::OrderProcessorTestSchema;

    sub new {
        my ($class) = @_;
        return bless { resultsets => [] }, $class;
    }

    sub resultset {
        my ( $self, $type ) = @_;
        my $resultset = Editx::OrderProcessorTestResultSet->new($type);
        push @{ $self->{resultsets} }, $resultset;
        return $resultset;
    }
}

{
    package Editx::OrderProcessorTestResultSet;

    sub new {
        my ( $class, $type ) = @_;
        return bless { type => $type, searches => [] }, $class;
    }

    sub search {
        my ( $self, @args ) = @_;
        push @{ $self->{searches} }, \@args;
        return Editx::OrderProcessorTestRows->new;
    }
}

{
    package Editx::OrderProcessorTestRows;

    sub new {
        my ($class) = @_;
        return bless {}, $class;
    }
}

subtest 'getBookseller dies with the missing VendorAssignedID mapping' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new;
    my $order = Editx::OrderProcessorTestOrder->new( 'LIBSAN001', '' );

    no warnings qw(redefine once);
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
    like( $dbh->{executed}->[0]->[0], qr{vea\.id_code_qualifier = \?.*vea\.transport = \?}, 'Vendor lookup uses the legacy transport filter' );
    is_deeply( [ @{ $dbh->{executed}->[0] }[ 1 .. 4 ] ], [ 'LIBSAN001', 91, 1, 'FILE' ], 'Vendor lookup uses VendorAssignedID qualifier 91' );
};

subtest 'getBookseller prefers VendorAssignedID and trims identifiers' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new(
        {
            rows => [
                {
                    id                => 1,
                    vendor_id         => 42,
                    san               => 'LIBSAN001',
                    id_code_qualifier => 91,
                    orders_enabled    => 1,
                    legacy_transport  => 'FILE',
                },
                {
                    id                => 2,
                    vendor_id         => 99,
                    san               => 'VENDOR-KOHA-001',
                    id_code_qualifier => 92,
                    orders_enabled    => 1,
                    legacy_transport  => 'FILE',
                },
            ],
        }
    );
    my $order = Editx::OrderProcessorTestOrder->new( '  LIBSAN001  ', 'VENDOR-KOHA-001' );

    no warnings qw(redefine once);
    local *C4::Context::dbh = sub { return $dbh };

    is( $processor->getBookseller($order), 42, 'Vendor lookup returns the mapped vendor id' );
    is_deeply( [ @{ $dbh->{executed}->[0] }[ 1 .. 4 ] ], [ 'LIBSAN001', 91, 1, 'FILE' ], 'VendorAssignedID qualifier 91 wins before BuyerAssignedID fallback' );
};

subtest 'getBookseller supports vendor_edi_accounts without transport flags' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new(
        {
            columns => {},
            rows    => [
                {
                    id                => 1,
                    vendor_id         => 42,
                    san               => 'LIBSAN001',
                    id_code_qualifier => 91,
                },
            ],
        }
    );
    my $order = Editx::OrderProcessorTestOrder->new( 'LIBSAN001', '' );

    no warnings qw(redefine once);
    local *C4::Context::dbh = sub { return $dbh };

    is( $processor->getBookseller($order), 42, 'Vendor lookup returns the mapped vendor id without optional flags' );
    is_deeply(
        $dbh->{column_checks},
        [
            'vendor_edi_accounts.file_transport_id',
            'file_transports.transport',
            'vendor_edi_accounts.transport',
            'vendor_edi_accounts.orders_enabled',
        ],
        'Vendor lookup checks optional schema columns'
    );
    unlike( $dbh->{executed}->[0]->[0], qr{(?:orders_enabled|transport)\s+=\s+\?}, 'Vendor lookup omits optional filters when the Koha schema lacks those columns' );
    is_deeply( [ @{ $dbh->{executed}->[0] }[ 1 .. 2 ] ], [ 'LIBSAN001', 91 ], 'Vendor lookup still binds SAN and qualifier' );
};

subtest 'getBookseller supports file_transports local delivery on newer Koha' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new(
        {
            columns => {
                'vendor_edi_accounts.file_transport_id' => 1,
                'file_transports.transport'             => 1,
                'vendor_edi_accounts.orders_enabled'    => 1,
            },
            rows => [
                {
                    id                => 1,
                    vendor_id         => 42,
                    san               => 'LIBSAN001',
                    id_code_qualifier => 91,
                    orders_enabled    => 1,
                    file_transport    => 'local',
                },
            ],
        }
    );
    my $order = Editx::OrderProcessorTestOrder->new( 'LIBSAN001', '' );

    no warnings qw(redefine once);
    local *C4::Context::dbh = sub { return $dbh };

    is( $processor->getBookseller($order), 42, 'Vendor lookup supports new file_transports local transport' );
    like( $dbh->{executed}->[0]->[0], qr{LEFT JOIN file_transports ft.*ft\.transport = \?}, 'Vendor lookup joins file_transports on newer Koha schemas' );
    is_deeply( [ @{ $dbh->{executed}->[0] }[ 1 .. 4 ] ], [ 'LIBSAN001', 91, 1, 'local' ], 'Vendor lookup binds local file transport' );
};

subtest 'getBookseller accepts a single active account with missing file transport' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new(
        {
            columns => {
                'vendor_edi_accounts.file_transport_id' => 1,
                'file_transports.transport'             => 1,
                'vendor_edi_accounts.orders_enabled'    => 1,
            },
            rows => [
                {
                    id                => 1,
                    vendor_id         => 42,
                    san               => '67027',
                    id_code_qualifier => 91,
                    orders_enabled    => 1,
                    file_transport    => undef,
                },
            ],
        }
    );
    my $order = Editx::OrderProcessorTestOrder->new( '67027', '' );

    no warnings qw(redefine once);
    local *C4::Context::dbh = sub { return $dbh };

    is( $processor->getBookseller($order), 42, 'Vendor lookup does not reject the only active account solely because Koha file transport is not linked' );
    like( $dbh->{executed}->[0]->[0], qr{ft\.transport = \?}, 'Vendor lookup first tries the strict local file transport match' );
    unlike( $dbh->{executed}->[1]->[0], qr{ft\.transport = \?}, 'Vendor lookup falls back to the single active SAN and qualifier match' );
    is_deeply( [ @{ $dbh->{executed}->[1] }[ 1 .. 3 ] ], [ '67027', 91, 1 ], 'Fallback still requires SAN, qualifier, and enabled orders' );
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
    is_deeply( [ @{ $dbh->{executed}->[0] }[ 1 .. 4 ] ], [ 'VENDOR-KOHA-001', 92, 1, 'FILE' ], 'Vendor lookup uses BuyerAssignedID qualifier 92' );
};

subtest 'getBookseller reports missing shipment notice vendor identifiers without SQL lookup' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new;
    my $order = Editx::OrderProcessorTestOrder->new( '', '   ' );

    no warnings qw(redefine once);
    local *C4::Context::dbh = sub { return $dbh };

    my $ok = eval {
        $processor->getBookseller($order);
        1;
    };

    ok( !$ok, 'getBookseller dies when both shipment notice vendor identifiers are missing' );
    like( $@, qr{No vendor in shipment notice: missing BuyerParty VendorAssignedID and SellerParty BuyerAssignedID\.}, 'Error explains which XML identifiers are missing' );
    is_deeply( $dbh->{executed}, [], 'Missing shipment notice vendor identifiers do not trigger a SQL lookup' );
};

subtest 'getBookseller reports qualifier mismatch' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new(
        {
            rows => [
                {
                    id                => 1,
                    vendor_id         => 42,
                    san               => 'LIBSAN001',
                    id_code_qualifier => 14,
                    orders_enabled    => 1,
                    legacy_transport  => 'FILE',
                },
            ],
        }
    );
    my $order = Editx::OrderProcessorTestOrder->new( 'LIBSAN001', '' );

    no warnings qw(redefine once);
    local *C4::Context::dbh = sub { return $dbh };

    my $ok = eval {
        $processor->getBookseller($order);
        1;
    };

    ok( !$ok, 'getBookseller dies when SAN exists with the wrong qualifier' );
    like( $@, qr{EDI account exists for SAN LIBSAN001, but qualifier does not match expected 91\. Found qualifiers: 14\.}, 'Error explains the expected qualifier' );
};

subtest 'getBookseller reports disabled EDI orders' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new(
        {
            rows => [
                {
                    id                => 1,
                    vendor_id         => 42,
                    san               => 'LIBSAN001',
                    id_code_qualifier => 91,
                    orders_enabled    => 0,
                    legacy_transport  => 'FILE',
                },
            ],
        }
    );
    my $order = Editx::OrderProcessorTestOrder->new( 'LIBSAN001', '' );

    no warnings qw(redefine once);
    local *C4::Context::dbh = sub { return $dbh };

    my $ok = eval {
        $processor->getBookseller($order);
        1;
    };

    ok( !$ok, 'getBookseller dies when EDI orders are disabled' );
    like( $@, qr{EDI account exists for SAN LIBSAN001 qualifier 91, but orders are disabled\.}, 'Error explains disabled EDI orders' );
};

subtest 'getBookseller refuses ambiguous EDI accounts' => sub {
    my $logger = Editx::OrderProcessorTestLogger->new;
    my $processor = bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my $dbh = Editx::OrderProcessorTestDbh->new(
        {
            rows => [
                {
                    id                => 1,
                    vendor_id         => 42,
                    san               => 'LIBSAN001',
                    id_code_qualifier => 91,
                    orders_enabled    => 1,
                    legacy_transport  => 'FILE',
                },
                {
                    id                => 2,
                    vendor_id         => 43,
                    san               => 'LIBSAN001',
                    id_code_qualifier => 91,
                    orders_enabled    => 1,
                    legacy_transport  => 'FILE',
                },
            ],
        }
    );
    my $order = Editx::OrderProcessorTestOrder->new( 'LIBSAN001', '' );

    no warnings qw(redefine once);
    local *C4::Context::dbh = sub { return $dbh };

    my $ok = eval {
        $processor->getBookseller($order);
        1;
    };

    ok( !$ok, 'getBookseller dies when more than one active EDI account matches' );
    like( $@, qr{Multiple active EDI accounts match SAN LIBSAN001 qualifier 91; refusing to choose vendor_id automatically\. Matching account ids: 1, 2\.}, 'Error explains ambiguous accounts' );
};

subtest 'getItemsByIsbns searches with all ISBN values' => sub {
    my $schema = Editx::OrderProcessorTestSchema->new;
    my $processor = bless { schema => $schema }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';

    $processor->getItemsByIsbns( '978951001', '978951002' );

    is_deeply(
        $schema->{resultsets}->[0]->{searches}->[0]->[0],
        { isbn => { in => [ '978951001', '978951002' ] } },
        'ISBN automatch receives every ISBN argument'
    );
};

subtest 'barcodePrefixesFromPreference accepts a missing system preference' => sub {
    my $processor = bless {}, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';

    is_deeply( $processor->barcodePrefixesFromPreference(undef), {}, 'Missing BarcodePrefix preference becomes an empty mapping' );
    is_deeply( $processor->barcodePrefixesFromPreference(q{}), {}, 'Blank BarcodePrefix preference becomes an empty mapping' );

    no warnings qw(redefine once);
    local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor::advanceBarcodeValue = sub { return 1 };
    local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor::getBarcodeValue = sub { return '00042' };

    is(
        $processor->generateBarcode( { date => '260508', prefixes => [] }, undef ),
        'HANK_26050800042',
        'Barcode generation falls back to the HANK prefix without a configured branch prefix'
    );
};

subtest 'barcodePrefixesFromPreference parses branch prefix YAML' => sub {
    my $processor = bless {}, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';

    is_deeply(
        $processor->barcodePrefixesFromPreference("Default: HANK_\nMAIN: MAIN_\n"),
        {
            Default => 'HANK_',
            MAIN    => 'MAIN_',
        },
        'BarcodePrefix YAML mapping is parsed'
    );
};

subtest 'barcodePrefixesFromPreference treats scalar YAML as a default prefix' => sub {
    my $processor = bless {}, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';

    is_deeply(
        $processor->barcodePrefixesFromPreference('3AMK_'),
        { Default => '3AMK_' },
        'Scalar BarcodePrefix value is treated as the default prefix'
    );
};

subtest 'barcodePrefixesFromPreference rejects structured non-mapping YAML' => sub {
    my $processor = bless {}, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';

    my $ok = eval {
        $processor->barcodePrefixesFromPreference("- HANK_\n- MAIN_\n");
        1;
    };

    ok( !$ok, 'Structured non-mapping BarcodePrefix YAML is rejected' );
    like( $@, qr{BarcodePrefix system preference must be a YAML mapping.*single global prefix}, 'Error explains the accepted BarcodePrefix shapes' );
};

subtest 'getMarcFromKohaFieldCompat uses the modern API before falling back' => sub {
    my $processor = bless {}, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
    my @calls;

    {
        no warnings qw(redefine once);
        local *C4::Biblio::GetMarcFromKohaField = sub {
            push @calls, [@_];
            return ( '952', 'p' );
        };

        is_deeply(
            [ $processor->getMarcFromKohaFieldCompat('items.barcode') ],
            [ '952', 'p' ],
            'Modern one-argument mapping lookup returns the mapping'
        );
    }

    is_deeply( \@calls, [ ['items.barcode'] ], 'Modern lookup does not pass the obsolete framework argument' );

    @calls = ();
    {
        no warnings qw(redefine once);
        local *C4::Biblio::GetMarcFromKohaField = sub {
            push @calls, [@_];
            return () if @_ == 1;
            return ( '952', 'a' );
        };

        is_deeply(
            [ $processor->getMarcFromKohaFieldCompat('items.homebranch') ],
            [ '952', 'a' ],
            'Legacy fallback returns the mapping when the one-argument lookup is unavailable'
        );
    }

    is_deeply(
        \@calls,
        [
            ['items.homebranch'],
            [ 'items.homebranch', '' ],
        ],
        'Fallback passes the legacy empty framework argument only after the modern lookup fails'
    );
};

done_testing();
