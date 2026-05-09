#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount;

use Modern::Perl;

use C4::Context;

sub identifier_from_values {
    my ( $class, $vendor_assigned_id, $buyer_assigned_id ) = @_;

    my $san = $class->normalize_identifier($vendor_assigned_id);
    return ( $san, 91 ) if $san ne '';

    $san = $class->normalize_identifier($buyer_assigned_id);
    return ( $san, 92 ) if $san ne '';

    return ( q{}, 91 );
}

sub normalize_identifier {
    my ( $class, $identifier ) = @_;

    return q{} unless defined $identifier;
    $identifier =~ s/^\s+|\s+$//g;
    return $identifier;
}

sub find_vendor {
    my ( $class, $params ) = @_;

    $params ||= {};

    my $san = $class->normalize_identifier( $params->{san} );
    return {
        status  => 'missing_identifier',
        message => 'No vendor in shipment notice: missing BuyerParty VendorAssignedID and SellerParty BuyerAssignedID.',
    } if $san eq '';

    my $qualifier = $class->normalize_identifier( $params->{qualifier} // 91 );
    my $dbh       = $params->{dbh} || C4::Context->dbh;
    my $schema    = $class->_schema_capabilities($dbh);

    my @matches = $class->_vendor_rows(
        {
            dbh              => $dbh,
            schema           => $schema,
            san              => $san,
            qualifier        => $qualifier,
            active_local_only => 1,
        }
    );

    if ( !@matches && ( $schema->{new_file_transport} || $schema->{legacy_transport} ) ) {
        my @active_matches = $class->_vendor_rows(
            {
                dbh         => $dbh,
                schema      => $schema,
                san         => $san,
                qualifier   => $qualifier,
                active_only => 1,
            }
        );

        return $class->_vendor_result_from_matches( $san, $qualifier, \@active_matches )
            if @active_matches;
    }

    return $class->_vendor_result_from_matches( $san, $qualifier, \@matches )
        if @matches;

    my @san_rows = $class->_vendor_rows(
        {
            dbh    => $dbh,
            schema => $schema,
            san    => $san,
        }
    );

    return $class->_missing_vendor_result( $san, $qualifier, $schema, \@san_rows );
}

sub find_vendor_id {
    my ( $class, $params ) = @_;

    my $result = $class->find_vendor($params);
    return $result->{vendor_id} if $result->{status} eq 'found';
    die $result->{message} . "\n" if $result->{status} eq 'ambiguous';
    return;
}

sub _vendor_result_from_matches {
    my ( $class, $san, $qualifier, $matches ) = @_;
    my @matches = @{$matches};

    if ( @matches > 1 ) {
        return {
            status  => 'ambiguous',
            message => sprintf(
                'Multiple active EDI accounts match SAN %s qualifier %s; refusing to choose vendor_id automatically. Matching account ids: %s.',
                $san,
                $qualifier,
                join( ', ', map { defined $_->{id} ? $_->{id} : '(unknown)' } @matches )
            ),
        };
    }

    if (@matches) {
        my $vendor_id = $matches[0]->{vendor_id};
        return { status => 'found', vendor_id => $vendor_id }
            if defined $vendor_id && $vendor_id ne '';

        return {
            status  => 'missing_vendor_id',
            message => sprintf(
                'EDI account for SAN %s qualifier %s has no vendor_id.',
                $san,
                $qualifier
            ),
        };
    }
}

sub _vendor_rows {
    my ( $class, $params ) = @_;

    my $schema = $params->{schema};
    my @select = (
        'vea.id',
        'vea.vendor_id',
        'vea.san',
        'vea.id_code_qualifier',
        $schema->{orders_enabled} ? 'vea.orders_enabled' : 'NULL AS orders_enabled',
    );
    my $join = q{};

    if ( $schema->{new_file_transport} ) {
        push @select, 'ft.transport AS file_transport';
        $join = ' LEFT JOIN file_transports ft ON ft.file_transport_id = vea.file_transport_id';
    } elsif ( $schema->{legacy_transport} ) {
        push @select, 'vea.transport AS legacy_transport';
    } else {
        push @select, 'NULL AS file_transport', 'NULL AS legacy_transport';
    }

    my @where = ('vea.san = ?');
    my @bind  = ( $params->{san} );

    if ( exists $params->{qualifier} ) {
        push @where, 'vea.id_code_qualifier = ?';
        push @bind,  $params->{qualifier};
    }

    if ( $params->{active_local_only} || $params->{active_only} ) {
        if ( $schema->{orders_enabled} ) {
            push @where, 'vea.orders_enabled = ?';
            push @bind,  1;
        }
    }

    if ( $params->{active_local_only} ) {
        if ( $schema->{new_file_transport} ) {
            push @where, 'ft.transport = ?';
            push @bind,  'local';
        } elsif ( $schema->{legacy_transport} ) {
            push @where, 'vea.transport = ?';
            push @bind,  'FILE';
        }
    }

    my $sql = sprintf(
        'SELECT %s FROM vendor_edi_accounts vea%s WHERE %s ORDER BY vea.id',
        join( ', ', @select ),
        $join,
        join( ' AND ', @where )
    );

    my $dbh = $params->{dbh};
    my $sth = $dbh->prepare($sql);
    $sth->execute(@bind)
        or die( $dbh->errstr || "Could not read EDI vendor mapping for SAN '$params->{san}'." );

    my @rows;
    while ( my $row = $sth->fetchrow_hashref ) {
        push @rows, $row;
    }
    return @rows;
}

sub _missing_vendor_result {
    my ( $class, $san, $qualifier, $schema, $rows ) = @_;

    return {
        status  => 'not_found',
        message => "No vendor for SAN $san (qualifier $qualifier) in vendor_edi_accounts.",
    } unless @{$rows};

    my @same_qualifier = grep { $class->normalize_identifier( $_->{id_code_qualifier} ) eq $qualifier } @{$rows};
    if ( !@same_qualifier ) {
        return {
            status  => 'qualifier_mismatch',
            message => sprintf(
                'EDI account exists for SAN %s, but qualifier does not match expected %s. Found qualifiers: %s.',
                $san,
                $qualifier,
                $class->_join_values( map { $_->{id_code_qualifier} } @{$rows} )
            ),
        };
    }

    my @orders_enabled = $schema->{orders_enabled}
        ? grep { $_->{orders_enabled} } @same_qualifier
        : @same_qualifier;
    if ( !@orders_enabled ) {
        return {
            status  => 'orders_disabled',
            message => "EDI account exists for SAN $san qualifier $qualifier, but orders are disabled.",
        };
    }

    my @local_transport = @orders_enabled;
    if ( $schema->{new_file_transport} ) {
        @local_transport = grep { ( $_->{file_transport} // q{} ) eq 'local' } @orders_enabled;
    } elsif ( $schema->{legacy_transport} ) {
        @local_transport = grep { uc( $_->{legacy_transport} // q{} ) eq 'FILE' } @orders_enabled;
    }

    if ( !@local_transport ) {
        my @transports = $schema->{new_file_transport}
            ? map { $_->{file_transport} } @orders_enabled
            : map { $_->{legacy_transport} } @orders_enabled;
        return {
            status  => 'transport_mismatch',
            message => sprintf(
                'EDI account exists for SAN %s qualifier %s, but transport is not local FILE delivery. Found transports: %s.',
                $san,
                $qualifier,
                $class->_join_values(@transports)
            ),
        };
    }

    return {
        status  => 'missing_vendor_id',
        message => "EDI account for SAN $san qualifier $qualifier has no vendor_id.",
    };
}

sub _join_values {
    my ( $class, @values ) = @_;

    my %seen;
    my @formatted;
    for my $value (@values) {
        $value = '(NULL)'  if !defined $value;
        $value = '(blank)' if defined $value && $value eq '';
        next if $seen{$value}++;
        push @formatted, $value;
    }

    return @formatted ? join( ', ', @formatted ) : '(none)';
}

sub _schema_capabilities {
    my ( $class, $dbh ) = @_;

    my $has_file_transport_id = $class->_column_exists( $dbh, 'vendor_edi_accounts', 'file_transport_id' );
    my $has_file_transport    = $class->_column_exists( $dbh, 'file_transports',       'transport' );

    return {
        legacy_transport  => $class->_column_exists( $dbh, 'vendor_edi_accounts', 'transport' ),
        new_file_transport => $has_file_transport_id && $has_file_transport,
        orders_enabled    => $class->_column_exists( $dbh, 'vendor_edi_accounts', 'orders_enabled' ),
    };
}

sub _column_exists {
    my ( $class, $dbh, $table, $column ) = @_;

    my ($exists) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME = ?
              AND COLUMN_NAME = ?
        },
        undef,
        $table,
        $column
    );

    return $exists ? 1 : 0;
}

1;
