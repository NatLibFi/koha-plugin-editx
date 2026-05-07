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

    my $dbh = $self->dbh;
    $dbh->begin_work or die( $dbh->errstr || 'Could not start EDItX import transaction.' );

    return Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::TransactionManager::Transaction->new(
        {
            dbh => $dbh,
        }
    );
}

sub dbh {
    my ($self) = @_;

    return $self->{dbh} if $self->{dbh};

    require C4::Context;
    return C4::Context->dbh;
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

    my $dbh = $self->{dbh};
    $dbh->commit or die( $dbh->errstr || 'Could not commit EDItX import transaction.' );
    $self->{active} = 0;

    return 1;
}

sub rollback {
    my ($self) = @_;

    return 1 if !$self->{active};

    my $dbh = $self->{dbh};
    $dbh->rollback or die( $dbh->errstr || 'Could not roll back EDItX import transaction.' );
    $self->{active} = 0;

    return 1;
}

1;
