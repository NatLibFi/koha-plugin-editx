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
    package Editx::SpendLogLogger;

    sub new {
        return bless { messages => [] }, shift;
    }

    sub log {
        my ( $self, $message ) = @_;
        push @{ $self->{messages} }, $message;
        return 1;
    }

    sub messages {
        my ($self) = @_;
        return $self->{messages};
    }
}

{
    package Editx::SpendLogDbh;

    sub new {
        my ( $class, $params ) = @_;
        $params ||= {};
        return bless {
            table_exists   => $params->{table_exists} ? 1 : 0,
            execute_result => exists $params->{execute_result} ? $params->{execute_result} : 1,
            errstr         => $params->{errstr},
            prepared       => [],
            executed       => [],
            table_checks   => [],
        }, $class;
    }

    sub selectrow_array {
        my ( $self, $sql, $attrs, @bind ) = @_;
        push @{ $self->{table_checks} }, $bind[0] if $sql =~ /information_schema\.TABLES/;
        return $self->{table_exists};
    }

    sub prepare {
        my ( $self, $sql ) = @_;
        push @{ $self->{prepared} }, $sql;
        return Editx::SpendLogSth->new($self);
    }

    sub errstr {
        my ($self) = @_;
        return $self->{errstr};
    }
}

{
    package Editx::SpendLogSth;

    sub new {
        my ( $class, $dbh ) = @_;
        return bless { dbh => $dbh }, $class;
    }

    sub execute {
        my ( $self, @bind ) = @_;
        push @{ $self->{dbh}->{executed} }, \@bind;
        return $self->{dbh}->{execute_result};
    }
}

{
    package Editx::SpendLogCopyDetail;

    sub new {
        return bless {}, shift;
    }

    sub getCopyQuantity       { return 3 }
    sub getFundMonetaryAmount { return 12.5 }
    sub getFundNumber         { return 'FUND-2026' }
    sub getBranchCode         { return 'MAIN' }
    sub getLocation           { return 'STACK' }
}

{
    package Editx::SpendLogItemDetail;

    sub new {
        return bless {}, shift;
    }

    sub getPriceFixedRPExcludingTax { return 7.25 }
    sub getProductForm              { return 'BK' }
}

{
    package Editx::SpendLogOrder;

    sub new {
        return bless {}, shift;
    }

    sub getTimeStamp  { return '2026-05-11 09:15:00' }
    sub getFileName   { return 'shipment.xml' }
    sub getPersonName { return 'Acquisitions' }
}

sub _processor {
    my ($logger) = @_;
    return bless { logger => $logger }, 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::OrderProcessor';
}

sub _spend_log_args {
    return (
        Editx::SpendLogCopyDetail->new,
        Editx::SpendLogItemDetail->new,
        Editx::SpendLogOrder->new,
        12345,
    );
}

subtest 'KohaSuomi spend log is skipped when the local table is absent' => sub {
    my $dbh = Editx::SpendLogDbh->new( { table_exists => 0 } );
    my $logger = Editx::SpendLogLogger->new;
    my $processor = _processor($logger);

    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    ok( $processor->updateAqbudgetLog(_spend_log_args()), 'Missing optional spend log table does not fail import' );
    ok( $processor->updateAqbudgetLog(_spend_log_args()), 'Cached missing optional spend log table keeps later imports running' );
    is_deeply( $dbh->{table_checks}, ['aqbudgets_spend_log'], 'Optional spend log table availability is checked once' );
    is_deeply( $dbh->{prepared}, [], 'Missing optional spend log table does not prepare an insert' );
    is_deeply(
        $logger->messages,
        ['Skipping KohaSuomi aqbudgets_spend_log integration because the local table does not exist.'],
        'Missing optional spend log table is logged once'
    );
};

subtest 'KohaSuomi spend log is written when the local table exists' => sub {
    my $dbh = Editx::SpendLogDbh->new( { table_exists => 1 } );
    my $logger = Editx::SpendLogLogger->new;
    my $processor = _processor($logger);

    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    ok( $processor->updateAqbudgetLog(_spend_log_args()), 'Existing optional spend log table receives the import row' );
    is_deeply( $dbh->{table_checks}, ['aqbudgets_spend_log'], 'Existing optional spend log table is detected' );
    like( $dbh->{prepared}->[0], qr{\AINSERT INTO aqbudgets_spend_log }, 'Spend log insert targets the KohaSuomi local table' );
    is_deeply(
        $dbh->{executed}->[0],
        [ 7.25, '2026-05-11 09:15:00', 'shipment.xml', 'FUND-2026', 'Acquisitions', 'BK', 3, 37.5, 'MAIN', 'STACK', 12345 ],
        'Spend log insert keeps the KohaSuomi local feature payload'
    );
    is_deeply( $logger->messages, [], 'Existing optional spend log table is not logged as skipped' );
};

subtest 'KohaSuomi spend log failures still fail when the integration table exists' => sub {
    my $dbh = Editx::SpendLogDbh->new(
        {
            table_exists   => 1,
            execute_result => 0,
            errstr         => 'insert failed',
        }
    );
    my $logger = Editx::SpendLogLogger->new;
    my $processor = _processor($logger);

    no warnings 'redefine';
    local *C4::Context::dbh = sub { return $dbh };

    my $ok = eval { $processor->updateAqbudgetLog(_spend_log_args()); 1 };
    ok( !$ok, 'Existing optional spend log table insert failure is not hidden' );
    like( $@, qr{insert failed}, 'Insert failure reports the database error' );
};

done_testing();
