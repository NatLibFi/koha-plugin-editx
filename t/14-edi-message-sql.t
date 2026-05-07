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
        return bless { do_calls => [], prepared => [], vendor_id => $params->{vendor_id} }, $class;
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
}

{
    package Editx::TestEdiSth;

    sub new {
        my ( $class, $dbh, $sql ) = @_;
        return bless { dbh => $dbh, sql => $sql, executed => [] }, $class;
    }

    sub execute {
        my ( $self, @bind ) = @_;
        push @{ $self->{executed} }, \@bind;
        push @{ $self->{dbh}->{executed} }, [ $self->{sql}, @bind ];
        return 1;
    }

    sub fetchrow_array {
        my ($self) = @_;
        return $self->{dbh}->{vendor_id};
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
    my $dbh = Editx::TestEdiDbh->new( { vendor_id => q{vendor'42} } );
    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    my $fixture = File::Spec->catfile( $Bin, 'fixtures', 'library_ship_notice_business.xml' );
    $message->findBookseller($fixture);

    is_deeply(
        $dbh->{executed}->[0],
        [
            "SELECT vendor_id FROM vendor_edi_accounts WHERE san = ? AND id_code_qualifier=? AND transport='FILE' AND orders_enabled='1'",
            'LIBSAN001',
            91,
        ],
        'Vendor lookup binds SAN and qualifier'
    );
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

done_testing();
