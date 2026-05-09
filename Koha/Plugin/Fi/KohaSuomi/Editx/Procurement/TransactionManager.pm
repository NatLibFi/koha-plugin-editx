#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::TransactionManager;

use Modern::Perl;

sub new {
    my ( $class, $params ) = @_;

    $params ||= {};

    return bless { %$params }, $class;
}

sub begin {
    my ($self) = @_;

    my $schema = $self->schema;
    $schema->txn_begin;

    return Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::TransactionManager::Transaction->new(
        {
            schema => $schema,
        }
    );
}

sub schema {
    my ($self) = @_;

    return $self->{schema} if $self->{schema};

    require Koha::Database;
    return Koha::Database->schema;
}

package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::TransactionManager::Transaction;

use Modern::Perl;

sub new {
    my ( $class, $params ) = @_;

    $params ||= {};

    return bless { %$params, active => 1 }, $class;
}

sub commit {
    my ($self) = @_;

    return 1 if !$self->{active};

    my $schema = $self->{schema};
    $schema->txn_commit;
    $self->{active} = 0;

    return 1;
}

sub rollback {
    my ($self) = @_;

    return 1 if !$self->{active};

    my $schema = $self->{schema};
    $schema->txn_rollback;
    $self->{active} = 0;

    return 1;
}

1;
