package Koha::Plugin::Fi::KohaSuomi::Editx::SchemaLifecycle;

use Modern::Perl;
use C4::Context;

sub new {
    my ( $class, %args ) = @_;

    return bless { plugin => $args{plugin} }, $class;
}

sub install {
    my ($self) = @_;

    $self->_log_runtime( info => 'EDItX plugin install creates qualified tables without legacy migration', { operation => 'install' } );

    return $self->_install_or_upgrade_tables( migrate_legacy => 0 );
}

sub upgrade {
    my ($self) = @_;

    my $success = $self->_install_or_upgrade_tables( migrate_legacy => 1 );
    $success &&= $self->_drop_obsolete_procurement_file_table();

    return $success;
}

sub uninstall {
    my ($self) = @_;

    return $self->_drop_tables_if_exist(
        $self->_qualified_table_name('sequences'),
        $self->_qualified_table_name('map_productform')
    );
}

sub _install_or_upgrade_tables {
    my ( $self, %args ) = @_;

    my $dbh = C4::Context->dbh;
    my $migrate_legacy = $args{migrate_legacy} ? 1 : 0;
    my $sequences_table_name = $self->_qualified_table_name('sequences');
    my $map_productform_table_name = $self->_qualified_table_name('map_productform');
    my %table_existed_before_upgrade;

    if ($migrate_legacy) {
        %table_existed_before_upgrade = (
            sequences       => $self->_table_exists($sequences_table_name),
            map_productform => $self->_table_exists($map_productform_table_name),
        );
        $self->_log_runtime(
            info => 'EDItX plugin upgrade table migration started',
            {
                operation => 'upgrade_table_migration',
                tables    => [ sort keys %table_existed_before_upgrade ],
            }
        );
    }

    my $sequences_table = $self->_quote_identifier($sequences_table_name);
    my $map_productform_table = $self->_quote_identifier($map_productform_table_name);

    my $success = $dbh->do( "
        CREATE TABLE IF NOT EXISTS $sequences_table (
          `invoicenumber` int(11) NOT NULL,
          `item_barcode_nextval` int(11) NOT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    " );

    if ( !$success ) {
        my $message = "Failed to create sequences table: " . $dbh->errstr;
        $self->_log_runtime( error => $message, { operation => 'install_or_upgrade' } );
        warn $message;
    }

    $success &&= $dbh->do( "
        CREATE TABLE IF NOT EXISTS $map_productform_table (
          `onix_code` varchar(10) NOT NULL,
          `productform` varchar(10) DEFAULT NULL,
          `productform_alternative` varchar(10) DEFAULT NULL,
          PRIMARY KEY (`onix_code`),
          KEY `fk_productform_itemtypes` (`productform`),
          KEY `fk_productformalt_itemtypes` (`productform_alternative`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    " );

    if ( !$success ) {
        my $message = "Failed to create map_productform table: " . $dbh->errstr;
        $self->_log_runtime( error => $message, { operation => 'install_or_upgrade' } );
        warn $message;
    }

    $success &&= $self->_drop_map_productform_foreign_keys();
    $success &&= $self->_allow_nullable_map_productform_columns();
    if ($migrate_legacy) {
        if ( $table_existed_before_upgrade{sequences} ) {
            $self->_log_runtime(
                info => 'Qualified EDItX table already existed before upgrade; legacy migration skipped',
                {
                    operation => 'upgrade_table_migration',
                    table     => $sequences_table_name,
                }
            );
        } else {
            $success &&= $self->_migrate_legacy_sequences_table();
        }

        if ( $table_existed_before_upgrade{map_productform} ) {
            $self->_log_runtime(
                info => 'Qualified EDItX table already existed before upgrade; legacy migration skipped',
                {
                    operation => 'upgrade_table_migration',
                    table     => $map_productform_table_name,
                }
            );
        } else {
            $success &&= $self->_migrate_legacy_map_productform_table();
        }
    }
    $success &&= $self->_ensure_sequences_row();

    return $success;
}

sub _migrate_legacy_sequences_table {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $target = $self->_qualified_table_name('sequences');
    my $quoted_target = $self->_quote_identifier($target);

    my @legacy_sources;
    for my $source ( $self->_legacy_table_names('sequences') ) {
        next if $source eq $target;
        next unless $self->_table_exists($source);

        push @legacy_sources, $source;
        $self->_log_runtime(
            info => 'Legacy EDItX source table found for migration',
            {
                operation    => 'upgrade_table_migration',
                table        => $target,
                source_table => $source,
            }
        );

        my $quoted_source = $self->_quote_identifier($source);
        my ($target_count) = $dbh->selectrow_array("SELECT COUNT(*) FROM $quoted_target");
        if ( !$target_count ) {
            my $rows = $dbh->do( "
                INSERT INTO $quoted_target (invoicenumber, item_barcode_nextval)
                SELECT invoicenumber, item_barcode_nextval FROM $quoted_source LIMIT 1
            " ) or return $self->_log_table_migration_db_error(
                $dbh,
                'Legacy EDItX sequences table migration failed',
                {
                    table        => $target,
                    source_table => $source,
                }
            );
            $self->_log_runtime(
                info => 'Legacy EDItX rows copied into qualified table',
                {
                    operation    => 'upgrade_table_migration',
                    table        => $target,
                    source_table => $source,
                    rows         => 0 + $rows,
                }
            );
        } else {
            $self->_log_runtime(
                info => 'Qualified EDItX table already had rows; legacy source copy skipped',
                {
                    operation    => 'upgrade_table_migration',
                    table        => $target,
                    source_table => $source,
                    rows         => $target_count,
                }
            );
        }
    }

    return @legacy_sources
        ? $self->_drop_legacy_tables_after_migration( $target, @legacy_sources )
        : 1;
}

sub _migrate_legacy_map_productform_table {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $target = $self->_qualified_table_name('map_productform');
    my $quoted_target = $self->_quote_identifier($target);

    my @legacy_sources;
    for my $source ( $self->_legacy_table_names('map_productform') ) {
        next if $source eq $target;
        next unless $self->_table_exists($source);

        push @legacy_sources, $source;
        $self->_log_runtime(
            info => 'Legacy EDItX source table found for migration',
            {
                operation    => 'upgrade_table_migration',
                table        => $target,
                source_table => $source,
            }
        );

        my ($target_count) = $dbh->selectrow_array("SELECT COUNT(*) FROM $quoted_target");
        if ($target_count) {
            $self->_log_runtime(
                info => 'Qualified EDItX table already had rows; legacy source copy skipped',
                {
                    operation    => 'upgrade_table_migration',
                    table        => $target,
                    source_table => $source,
                    rows         => $target_count,
                }
            );
            next;
        }

        my $quoted_source = $self->_quote_identifier($source);
        my $rows = $dbh->do( "
            INSERT INTO $quoted_target (onix_code, productform, productform_alternative)
            SELECT onix_code, productform, productform_alternative FROM $quoted_source
            ON DUPLICATE KEY UPDATE
                productform = VALUES(productform),
                productform_alternative = VALUES(productform_alternative)
        " ) or return $self->_log_table_migration_db_error(
            $dbh,
            'Legacy EDItX ProductForm table migration failed',
            {
                table        => $target,
                source_table => $source,
            }
        );
        $self->_log_runtime(
            info => 'Legacy EDItX rows copied into qualified table',
            {
                operation    => 'upgrade_table_migration',
                table        => $target,
                source_table => $source,
                rows         => 0 + $rows,
            }
        );
    }

    return @legacy_sources
        ? $self->_drop_legacy_tables_after_migration( $target, @legacy_sources )
        : 1;
}

sub _legacy_table_names {
    my ( $self, $table_name ) = @_;

    my %legacy_table_names = (
        sequences       => ['sequences'],
        map_productform => ['map_productform'],
    );

    return @{ $legacy_table_names{$table_name} || [] };
}

sub _drop_legacy_tables_after_migration {
    my ( $self, $table_name, @legacy_sources ) = @_;

    my $dbh = C4::Context->dbh;
    for my $source (@legacy_sources) {
        my $quoted_source = $self->_quote_identifier($source);
        $dbh->do("DROP TABLE IF EXISTS $quoted_source") or return $self->_log_table_migration_db_error(
            $dbh,
            'Legacy EDItX table cleanup failed after migration',
            {
                table        => $table_name,
                source_table => $source,
            }
        );
        $self->_log_runtime(
            info => 'Legacy EDItX table dropped after migration',
            {
                operation    => 'upgrade_table_migration',
                table        => $table_name,
                source_table => $source,
            }
        );
    }

    return 1;
}

sub _drop_obsolete_procurement_file_table {
    my ($self) = @_;

    my $table_name = 'procurement_file';
    if ( !$self->_table_exists($table_name) ) {
        $self->_log_runtime(
            info => 'Obsolete EDItX file-hash ledger table not found; cleanup skipped',
            {
                operation => 'upgrade_table_migration',
                table     => $table_name,
            }
        );
        return 1;
    }

    my $dbh = C4::Context->dbh;
    my $quoted_table_name = $self->_quote_identifier($table_name);
    my ($rows) = $dbh->selectrow_array("SELECT COUNT(*) FROM $quoted_table_name");
    return $self->_log_table_migration_db_error(
        $dbh,
        'Obsolete EDItX file-hash ledger row count failed',
        { table => $table_name }
    ) if !defined $rows;

    $self->_log_runtime(
        info => 'Obsolete EDItX file-hash ledger table found for cleanup',
        {
            operation => 'upgrade_table_migration',
            table     => $table_name,
            rows      => 0 + $rows,
            reason    => 'Duplicate protection now uses ShipNoticeNumber via aqbasket.basketname',
        }
    );

    $dbh->do("DROP TABLE IF EXISTS $quoted_table_name") or return $self->_log_table_migration_db_error(
        $dbh,
        'Obsolete EDItX file-hash ledger cleanup failed',
        {
            table => $table_name,
            rows  => 0 + $rows,
        }
    );

    $self->_log_runtime(
        info => 'Obsolete EDItX file-hash ledger table dropped after upgrade cleanup',
        {
            operation => 'upgrade_table_migration',
            table     => $table_name,
            rows      => 0 + $rows,
        }
    );

    return 1;
}

sub _log_table_migration_db_error {
    my ( $self, $dbh, $message, $context ) = @_;

    my $error = $self->_compact_message( $dbh->errstr ) || 'unknown database error';
    $self->_log_runtime(
        error => "$message: $error",
        {
            operation => 'upgrade_table_migration',
            error     => $error,
            %{ $context || {} },
        }
    );

    return;
}

sub _drop_tables_if_exist {
    my ( $self, @table_names ) = @_;

    my $dbh = C4::Context->dbh;
    my %seen;
    for my $table_name (@table_names) {
        next unless defined $table_name && length $table_name;
        next if $seen{$table_name}++;

        my $quoted_table_name = $self->_quote_identifier($table_name);
        $dbh->do("DROP TABLE IF EXISTS $quoted_table_name") or return;
    }

    return 1;
}

sub _drop_map_productform_foreign_keys {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $table_name = $self->_qualified_table_name('map_productform');
    my $quoted_table_name = $self->_quote_identifier($table_name);
    my $sth = $dbh->prepare( "
        SELECT CONSTRAINT_NAME
        FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = ?
          AND REFERENCED_TABLE_NAME IS NOT NULL
    " );
    $sth->execute($table_name);

    while ( my ($constraint_name) = $sth->fetchrow_array ) {
        my $quoted_constraint_name = $self->_quote_identifier($constraint_name);
        $dbh->do("ALTER TABLE $quoted_table_name DROP FOREIGN KEY $quoted_constraint_name") or return;
    }

    return 1;
}

sub _allow_nullable_map_productform_columns {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->_qualified_table_name('map_productform') );

    return $dbh->do( "
        ALTER TABLE $map_productform_table
          MODIFY `productform` varchar(10) DEFAULT NULL,
          MODIFY `productform_alternative` varchar(10) DEFAULT NULL
    " );
}

sub _ensure_sequences_row {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $sequences_table = $self->_quote_identifier( $self->_qualified_table_name('sequences') );
    my ($count) = $dbh->selectrow_array("SELECT COUNT(*) FROM $sequences_table");

    return 1 if $count;

    return $dbh->do("INSERT INTO $sequences_table (invoicenumber, item_barcode_nextval) VALUES (0, 0)");
}

sub _qualified_table_name {
    my ( $self, $table_name ) = @_;

    return $self->{plugin}->get_qualified_table_name($table_name);
}

sub _log_runtime {
    my ( $self, @args ) = @_;

    return $self->{plugin}->_log_runtime(@args);
}

sub _compact_message {
    my ( $self, $message ) = @_;

    return '' unless defined $message;

    $message =~ s/\A\s+|\s+\z//g;
    $message =~ s/\s+/ /g;
    return '' if $message eq '';

    if ( length $message > 800 ) {
        $message = substr( $message, 0, 397 ) . ' ... ' . substr( $message, -398 );
    }

    return $message;
}

sub _table_exists {
    my ( $self, $table_name ) = @_;

    my $sth = C4::Context->dbh->prepare("SHOW TABLES LIKE ?");
    $sth->execute($table_name);

    return $sth->fetchrow_array ? 1 : 0;
}

sub _quote_identifier {
    my ( $self, $identifier ) = @_;

    $identifier =~ s/`/``/g;
    return "`$identifier`";
}

1;
