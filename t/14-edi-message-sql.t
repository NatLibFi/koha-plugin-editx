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

use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EdiMessage');

{
    package Editx::TestEdiDbh;

    sub new {
        my ( $class, $params ) = @_;
        $params ||= {};
        my $columns = exists $params->{columns} ? $params->{columns} : { transport => 1, orders_enabled => 1 };
        my $rows    = $params->{rows} || [];
        return bless {
            column_checks => [],
            columns       => $columns,
            do_calls      => [],
            executed      => [],
            prepared      => [],
            rows          => $rows,
        }, $class;
    }

    sub do {
        my ( $self, $sql, $attrs, @bind ) = @_;
        push @{ $self->{do_calls} }, [ $sql, $attrs, @bind ];
        return 1;
    }

    sub prepare {
        my ( $self, $sql ) = @_;
        push @{ $self->{prepared} }, $sql;
        return Editx::TestEdiSth->new( $self, $sql );
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
    package Editx::TestEdiSth;

    sub new {
        my ( $class, $dbh, $sql ) = @_;
        return bless { dbh => $dbh, rows => [], sql => $sql, executed => [] }, $class;
    }

    sub execute {
        my ( $self, @bind ) = @_;
        push @{ $self->{executed} }, \@bind;
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

my $message = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EdiMessage->new;

subtest 'add stores raw EDItX message with bound filename' => sub {
    my $dbh = Editx::TestEdiDbh->new;
    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    $message->add( q{order' OR '1'='1.xml}, '<LibraryShipNotice />' );

    is_deeply(
        $dbh->{do_calls}->[0],
        [ 'DELETE FROM edifact_messages WHERE filename=?', undef, q{order' OR '1'='1.xml} ],
        'Delete uses a placeholder for filename'
    );
    is_deeply(
        $dbh->{executed}->[0],
        [
            "INSERT INTO edifact_messages (message_type, transfer_date, raw_msg, filename) VALUES ('EDItX', NOW(), ?, ?)",
            '<LibraryShipNotice />',
            q{order' OR '1'='1.xml},
        ],
        'Insert binds raw message and filename'
    );
};

subtest 'update binds status and filename' => sub {
    my $dbh = Editx::TestEdiDbh->new;
    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    $message->update( q{order' OR '1'='1.xml}, 'FAILED' );

    is_deeply(
        $dbh->{executed}->[0],
        [ 'UPDATE edifact_messages SET status=? WHERE filename=?', 'FAILED', q{order' OR '1'='1.xml} ],
        'Status update binds status and filename'
    );
};

subtest 'findBookseller binds SAN and edifact update values' => sub {
    my $dbh = Editx::TestEdiDbh->new(
        {
            rows => [
                {
                    id                => 1,
                    vendor_id         => q{vendor'42},
                    san               => 'LIBSAN001',
                    id_code_qualifier => 91,
                    orders_enabled    => 1,
                    legacy_transport  => 'FILE',
                },
            ],
        }
    );
    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    my $fixture = File::Spec->catfile( $Bin, 'fixtures', 'library_ship_notice_business.xml' );
    $message->findBookseller($fixture);

    like( $dbh->{executed}->[0]->[0], qr{FROM vendor_edi_accounts vea.*vea\.id_code_qualifier = \?.*vea\.orders_enabled = \?.*vea\.transport = \?}, 'Vendor lookup uses active legacy FILE account filters' );
    is_deeply( [ @{ $dbh->{executed}->[0] }[ 1 .. 4 ] ], [ 'LIBSAN001', 91, 1, 'FILE' ], 'Vendor lookup binds SAN, qualifier, orders flag, and transport' );
    is_deeply(
        $dbh->{do_calls}->[0],
        [
            'UPDATE edifact_messages SET vendor_id=? WHERE filename=?',
            undef,
            q{vendor'42},
            'library_ship_notice_business.xml',
        ],
        'Vendor update binds vendor id and basename'
    );
};

subtest 'findBookseller supports vendor_edi_accounts without transport flags' => sub {
    my $dbh = Editx::TestEdiDbh->new(
        {
            columns => {},
            rows    => [
                {
                    id                => 1,
                    vendor_id         => q{vendor'42},
                    san               => 'LIBSAN001',
                    id_code_qualifier => 91,
                },
            ],
        }
    );
    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    my $fixture = File::Spec->catfile( $Bin, 'fixtures', 'library_ship_notice_business.xml' );
    $message->findBookseller($fixture);

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

done_testing();
