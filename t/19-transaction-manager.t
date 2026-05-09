#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $plugin_root = File::Spec->catdir( $Bin, '..' );
unshift @INC, $plugin_root;

use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::TransactionManager');

{
    package Editx::TestSchema;

    sub new {
        my ($class) = @_;
        return bless { events => [] }, $class;
    }

    sub txn_begin {
        my ($self) = @_;
        push @{ $self->{events} }, 'txn_begin';
        return 1;
    }

    sub txn_commit {
        my ($self) = @_;
        push @{ $self->{events} }, 'txn_commit';
        return 1;
    }

    sub txn_rollback {
        my ($self) = @_;
        push @{ $self->{events} }, 'txn_rollback';
        return 1;
    }
}

subtest 'transaction manager uses Koha DBIx::Class transaction API' => sub {
    my $schema = Editx::TestSchema->new;
    my $manager = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::TransactionManager->new( { schema => $schema } );

    my $transaction = $manager->begin;
    $transaction->commit;
    $transaction->rollback;

    is_deeply(
        $schema->{events},
        [ 'txn_begin', 'txn_commit' ],
        'Commit uses DBIx::Class transaction methods and deactivates the transaction'
    );
};

subtest 'rollback uses Koha DBIx::Class transaction API' => sub {
    my $schema = Editx::TestSchema->new;
    my $manager = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::TransactionManager->new( { schema => $schema } );

    my $transaction = $manager->begin;
    $transaction->rollback;

    is_deeply(
        $schema->{events},
        [ 'txn_begin', 'txn_rollback' ],
        'Rollback uses DBIx::Class transaction methods'
    );
};

done_testing();
