#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
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

my $plugin_class = 'Koha::Plugin::Fi::KohaSuomi::Editx';
my $schema_lifecycle_class = 'Koha::Plugin::Fi::KohaSuomi::Editx::SchemaLifecycle';
use_ok($plugin_class);
use_ok('Koha::Plugin::Fi::KohaSuomi::Editx::Config');
use_ok($schema_lifecycle_class);

my $plugin = bless {}, $plugin_class;
my $schema_lifecycle = $schema_lifecycle_class->new( plugin => $plugin );

{
    package KohaSuomi::Editx::TestCGI;

    sub multi_param {
        my ( $self, $name ) = @_;

        return @{ $self->{$name} || [] };
    }
}

{
    package KohaSuomi::Editx::TestDbh;

    sub new {
        my ( $class, %args ) = @_;
        $args{do_calls}     ||= [];
        $args{select_calls} ||= [];
        return bless \%args, $class;
    }

    sub do {
        my ( $self, $sql, $attrs, @bind ) = @_;

        push @{ $self->{do_calls} }, $sql;
        push @{ $self->{do_binds} }, \@bind if @bind;
        return exists $self->{do_result} ? $self->{do_result} : 1;
    }

    sub prepare {
        my ( $self, $sql ) = @_;

        push @{ $self->{prepared} }, $sql;
        return bless { dbh => $self, sql => $sql }, 'KohaSuomi::Editx::TestSth';
    }

    sub selectrow_array {
        my ( $self, $sql, $attrs, @bind ) = @_;

        push @{ $self->{select_calls} }, $sql;
        push @{ $self->{select_binds} }, \@bind if @bind;
        return shift @{ $self->{counts} } if $self->{counts} && @{ $self->{counts} };
        return $self->{count} || 0;
    }

    sub begin_work {
        my ($self) = @_;

        push @{ $self->{txn_calls} }, 'begin_work';
        return 1;
    }

    sub commit {
        my ($self) = @_;

        push @{ $self->{txn_calls} }, 'commit';
        return 1;
    }

    sub rollback {
        my ($self) = @_;

        push @{ $self->{txn_calls} }, 'rollback';
        return 1;
    }

    sub errstr {
        return shift->{errstr};
    }
}

{
    package KohaSuomi::Editx::TestSth;

    sub execute {
        my ( $self, @bind ) = @_;

        push @{ $self->{dbh}->{executed} }, [ $self->{sql}, @bind ];
        return exists $self->{dbh}->{execute_result} ? $self->{dbh}->{execute_result} : 1;
    }
}

sub _message_text {
    my ($messages) = @_;

    return join "\n", map { $_->{text} } @$messages;
}

sub _capture_runtime_log {
    my ($logs) = @_;

    return sub {
        my ( $self, $level, $message, $context ) = @_;
        push @{$logs}, {
            level   => $level,
            message => $message,
            context => $context,
        };
        return 1;
    };
}

sub _valid_procurement_settings {
    my ($base) = @_;

    return {
        import_tmp_path                  => File::Spec->catdir( $base, 'tmp' ),
        import_load_path                 => File::Spec->catdir( $base, 'load' ),
        import_archive_path              => File::Spec->catdir( $base, 'archive' ),
        import_failed_path               => File::Spec->catdir( $base, 'fail' ),
        import_failed_archived_path      => File::Spec->catdir( $base, 'failed_archived' ),
        authoriser                       => 1,
        allowed_locations                => 'MAIN',
        productform_alternative_triggers => '',
        notification_mailto              => '',
        notification_mailfrom            => '',
    };
}

subtest 'Install calls table setup without legacy migration' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my @logs;
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $schema_lifecycle_class . '::_drop_obsolete_procurement_file_table' } = sub { die 'install must not clean obsolete procurement_file'; };
    local *{ $schema_lifecycle_class . '::_install_or_upgrade_tables' } = sub {
        my ( $self, %args ) = @_;
        is_deeply( \%args, { migrate_legacy => 0 }, 'Install disables legacy migration in table setup' );
        return 1;
    };

    ok( $schema_lifecycle->install, 'Install succeeds with legacy migration disabled' );
    like(
        join( "\n", map { $_->{message} } @logs ),
        qr{qualified tables without legacy migration},
        'Install logs that qualified tables are created without legacy migration'
    );
};

subtest 'Upgrade cleans obsolete procurement_file ledger after table setup' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my %called;
    local *{ $schema_lifecycle_class . '::_install_or_upgrade_tables' } = sub {
        my ( $self, %args ) = @_;
        is_deeply( \%args, { migrate_legacy => 1 }, 'Upgrade enables legacy migration in table setup' );
        $called{table_setup}++;
        return 1;
    };
    local *{ $schema_lifecycle_class . '::_drop_obsolete_procurement_file_table' } = sub {
        $called{drop_obsolete_procurement_file}++;
        return 1;
    };

    ok( $schema_lifecycle->upgrade, 'Upgrade succeeds after obsolete procurement_file cleanup' );
    is( $called{table_setup}, 1, 'Upgrade runs table setup once' );
    is( $called{drop_obsolete_procurement_file}, 1, 'Upgrade runs obsolete procurement_file cleanup once' );
};

subtest 'Plugin lifecycle hooks delegate schema lifecycle work' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my %called;
    my $fake_schema_lifecycle = bless { called => \%called }, 'KohaSuomi::Editx::FakeSchemaLifecycle';
    local *{ $plugin_class . '::_schema_lifecycle' } = sub { return $fake_schema_lifecycle; };
    local *{ $plugin_class . '::_log_runtime' } = sub { return 1; };
    local *{ $plugin_class . '::store_data' } = sub { $called{store_data}++; return 1; };
    local *KohaSuomi::Editx::FakeSchemaLifecycle::install = sub {
        my ($self) = @_;
        $self->{called}->{install}++;
        return 1;
    };
    local *KohaSuomi::Editx::FakeSchemaLifecycle::upgrade = sub {
        my ($self) = @_;
        $self->{called}->{upgrade}++;
        return 1;
    };
    local *KohaSuomi::Editx::FakeSchemaLifecycle::uninstall = sub {
        my ($self) = @_;
        $self->{called}->{uninstall}++;
        return 1;
    };

    ok( $plugin->install, 'Plugin install succeeds through schema lifecycle' );
    ok( $plugin->upgrade, 'Plugin upgrade succeeds through schema lifecycle' );
    ok( $plugin->uninstall, 'Plugin uninstall succeeds through schema lifecycle' );
    is( $called{install}, 1, 'Plugin install delegates schema lifecycle install once' );
    is( $called{upgrade}, 1, 'Plugin upgrade delegates schema lifecycle upgrade once' );
    is( $called{uninstall}, 1, 'Plugin uninstall delegates schema lifecycle uninstall once' );
    is( $called{store_data}, 1, 'Plugin upgrade still records the upgrade timestamp' );
};

subtest 'Install table setup does not touch legacy tables' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new;
    my %called;
    my @logs;
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };
    local *{ $schema_lifecycle_class . '::_drop_map_productform_foreign_keys' } = sub { $called{drop_foreign_keys}++; return 1; };
    local *{ $schema_lifecycle_class . '::_allow_nullable_map_productform_columns' } = sub { $called{allow_nullable}++; return 1; };
    local *{ $schema_lifecycle_class . '::_ensure_sequences_row' } = sub { $called{ensure_sequences}++; return 1; };
    local *{ $schema_lifecycle_class . '::_table_exists' } = sub { die 'install must not inspect legacy or qualified table existence'; };
    local *{ $schema_lifecycle_class . '::_migrate_legacy_sequences_table' } = sub { die 'install must not migrate legacy sequences'; };
    local *{ $schema_lifecycle_class . '::_migrate_legacy_map_productform_table' } = sub { die 'install must not migrate legacy ProductForm mappings'; };

    ok( $schema_lifecycle->_install_or_upgrade_tables( migrate_legacy => 0 ), 'Install table setup succeeds without legacy migration' );
    is( $called{ensure_sequences}, 1, 'Install still ensures the qualified sequences row' );
    like( join( "\n", @{ $dbh->{do_calls} } ), qr{CREATE TABLE IF NOT EXISTS `koha_plugin_fi_kohasuomi_editx_map_productform`}, 'Install creates the qualified ProductForm table' );
};

subtest 'Upgrade table setup enables legacy migration' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new;
    my %called;
    my @checked_tables;
    my @logs;
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };
    local *{ $schema_lifecycle_class . '::_drop_map_productform_foreign_keys' } = sub { $called{drop_foreign_keys}++; return 1; };
    local *{ $schema_lifecycle_class . '::_allow_nullable_map_productform_columns' } = sub { $called{allow_nullable}++; return 1; };
    local *{ $schema_lifecycle_class . '::_ensure_sequences_row' } = sub { $called{ensure_sequences}++; return 1; };
    local *{ $schema_lifecycle_class . '::_table_exists' } = sub {
        my ( $self, $table_name ) = @_;
        push @checked_tables, $table_name;
        return 0;
    };
    local *{ $schema_lifecycle_class . '::_migrate_legacy_sequences_table' } = sub { $called{migrate_sequences}++; return 1; };
    local *{ $schema_lifecycle_class . '::_migrate_legacy_map_productform_table' } = sub { $called{migrate_productform}++; return 1; };

    ok( $schema_lifecycle->_install_or_upgrade_tables( migrate_legacy => 1 ), 'Upgrade table setup succeeds with legacy migration enabled' );
    is_deeply(
        \@checked_tables,
        [
            'koha_plugin_fi_kohasuomi_editx_sequences',
            'koha_plugin_fi_kohasuomi_editx_map_productform',
        ],
        'Upgrade captures qualified table existence before creating tables'
    );
    is( $called{migrate_sequences}, 1, 'Upgrade migrates legacy sequences' );
    is( $called{migrate_productform}, 1, 'Upgrade migrates legacy ProductForm mappings' );
    like( join( "\n", map { $_->{message} } @logs ), qr{upgrade table migration started}, 'Upgrade logs the migration start' );
};

subtest 'Upgrade ignores legacy when qualified tables already exist' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new;
    my %called;
    my @logs;
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };
    local *{ $schema_lifecycle_class . '::_drop_map_productform_foreign_keys' } = sub { $called{drop_foreign_keys}++; return 1; };
    local *{ $schema_lifecycle_class . '::_allow_nullable_map_productform_columns' } = sub { $called{allow_nullable}++; return 1; };
    local *{ $schema_lifecycle_class . '::_ensure_sequences_row' } = sub { $called{ensure_sequences}++; return 1; };
    local *{ $schema_lifecycle_class . '::_table_exists' } = sub { return 1; };
    local *{ $schema_lifecycle_class . '::_migrate_legacy_sequences_table' } = sub { die 'upgrade must not inspect legacy sequences when the qualified table already exists'; };
    local *{ $schema_lifecycle_class . '::_migrate_legacy_map_productform_table' } = sub { die 'upgrade must not inspect legacy ProductForm mappings when the qualified table already exists'; };

    ok( $schema_lifecycle->_install_or_upgrade_tables( migrate_legacy => 1 ), 'Upgrade table setup succeeds without legacy migration when qualified tables exist' );
    is( $called{ensure_sequences}, 1, 'Upgrade still runs normal qualified-table maintenance' );
    is(
        scalar( grep { $_->{message} =~ /legacy migration skipped/ } @logs ),
        2,
        'Upgrade logs a skip for each qualified table that existed before upgrade'
    );
};

subtest 'Upgrade migrates only qualified tables missing before upgrade' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new;
    my %called;
    my @logs;
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };
    local *{ $schema_lifecycle_class . '::_drop_map_productform_foreign_keys' } = sub { $called{drop_foreign_keys}++; return 1; };
    local *{ $schema_lifecycle_class . '::_allow_nullable_map_productform_columns' } = sub { $called{allow_nullable}++; return 1; };
    local *{ $schema_lifecycle_class . '::_ensure_sequences_row' } = sub { $called{ensure_sequences}++; return 1; };
    local *{ $schema_lifecycle_class . '::_table_exists' } = sub {
        my ( $self, $table_name ) = @_;
        return $table_name eq 'koha_plugin_fi_kohasuomi_editx_sequences' ? 1 : 0;
    };
    local *{ $schema_lifecycle_class . '::_migrate_legacy_sequences_table' } = sub { die 'upgrade must skip legacy sequences when the qualified table existed'; };
    local *{ $schema_lifecycle_class . '::_migrate_legacy_map_productform_table' } = sub { $called{migrate_productform}++; return 1; };

    ok( $schema_lifecycle->_install_or_upgrade_tables( migrate_legacy => 1 ), 'Upgrade table setup succeeds with mixed pre-existing qualified tables' );
    is( $called{migrate_productform}, 1, 'Upgrade migrates only the missing qualified ProductForm table' );
    is(
        scalar( grep { $_->{message} =~ /legacy migration skipped/ && $_->{context}->{table} eq 'koha_plugin_fi_kohasuomi_editx_sequences' } @logs ),
        1,
        'Upgrade logs that legacy sequence migration was skipped'
    );
};

subtest 'ProductForm legacy migration imports supported Koha Suomi source and removes that old table' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new( counts => [ 0, 3 ] );
    my @checked_tables;
    my @logs;
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };
    local *{ $schema_lifecycle_class . '::_table_exists' } = sub {
        my ( $self, $table_name ) = @_;
        push @checked_tables, $table_name;
        return $table_name eq 'map_productform';
    };

    ok( $schema_lifecycle->_migrate_legacy_map_productform_table, 'ProductForm migration succeeds from the legacy unqualified table' );
    my $sql = join "\n", @{ $dbh->{do_calls} };
    is_deeply( \@checked_tables, ['map_productform'], 'ProductForm migration checks only the supported Koha Suomi legacy source table' );
    like( $sql, qr{INSERT INTO `koha_plugin_fi_kohasuomi_editx_map_productform`.*FROM `map_productform`}s, 'Legacy ProductForm rows are copied for a newly created target table' );
    like( $sql, qr{DROP TABLE IF EXISTS `map_productform`}, 'Unqualified ProductForm legacy table is removed after upgrade migration' );
    unlike( $sql, qr{`editx_map_productform`}, 'ProductForm migration does not walk or drop unsupported prefixed legacy table names' );
    my $log_text = join "\n", map { $_->{message} } @logs;
    like( $log_text, qr{source table found}, 'ProductForm migration logs that a legacy source table was found' );
    like( $log_text, qr{rows copied}, 'ProductForm migration logs copied rows' );
    like( $log_text, qr{table dropped}, 'ProductForm migration logs legacy cleanup' );
};

subtest 'ProductForm legacy migration logs DB errors and keeps the old table' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new( counts => [0], do_result => 0, errstr => 'copy failed' );
    my @logs;
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };
    local *{ $schema_lifecycle_class . '::_table_exists' } = sub {
        my ( $self, $table_name ) = @_;
        return $table_name eq 'map_productform';
    };

    ok( !$schema_lifecycle->_migrate_legacy_map_productform_table, 'ProductForm migration fails when the DB copy fails' );
    like( join( "\n", map { $_->{message} } @logs ), qr{migration failed: copy failed}, 'ProductForm migration logs the DB error' );
    unlike( join( "\n", @{ $dbh->{do_calls} } ), qr{DROP TABLE}, 'Failed ProductForm migration does not drop the legacy source table' );
};

subtest 'Obsolete procurement_file cleanup drops only the known KohaSuomi file-hash ledger' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new( counts => [42] );
    my @checked_tables;
    my @logs;
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $schema_lifecycle_class . '::_table_exists' } = sub {
        my ( $self, $table_name ) = @_;
        push @checked_tables, $table_name;
        return $table_name eq 'procurement_file';
    };

    ok( $schema_lifecycle->_drop_obsolete_procurement_file_table, 'Obsolete procurement_file cleanup succeeds' );
    is_deeply( \@checked_tables, ['procurement_file'], 'Cleanup checks only the supported KohaSuomi procurement_file table' );
    like( join( "\n", @{ $dbh->{select_calls} } ), qr{SELECT COUNT\(\*\) FROM `procurement_file`}, 'Cleanup counts existing file-hash ledger rows' );
    like( join( "\n", @{ $dbh->{do_calls} } ), qr{DROP TABLE IF EXISTS `procurement_file`}, 'Cleanup drops the obsolete file-hash ledger' );
    unlike( join( "\n", @{ $dbh->{do_calls} } ), qr{editx_procurement_file}, 'Cleanup does not walk unsupported prefixed procurement_file names' );
    my $log_text = join "\n", map { $_->{message} . ' ' . ( $_->{context}->{rows} // '' ) } @logs;
    like( $log_text, qr{file-hash ledger table found for cleanup 42}, 'Cleanup logs the old ledger row count' );
    like( $log_text, qr{file-hash ledger table dropped}, 'Cleanup logs the ledger drop' );
};

subtest 'Obsolete procurement_file cleanup skips missing KohaSuomi file-hash ledger' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my @checked_tables;
    my @logs;
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $schema_lifecycle_class . '::_table_exists' } = sub {
        my ( $self, $table_name ) = @_;
        push @checked_tables, $table_name;
        return 0;
    };

    ok( $schema_lifecycle->_drop_obsolete_procurement_file_table, 'Missing obsolete procurement_file table is skipped' );
    is_deeply( \@checked_tables, ['procurement_file'], 'Missing cleanup checks only the supported KohaSuomi procurement_file table' );
    like( join( "\n", map { $_->{message} } @logs ), qr{not found; cleanup skipped}, 'Missing cleanup decision is logged' );
};

subtest 'Obsolete procurement_file cleanup logs DB errors and keeps upgrade failed' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new( counts => [7], do_result => 0, errstr => 'drop failed' );
    my @logs;
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $schema_lifecycle_class . '::_table_exists' } = sub {
        my ( $self, $table_name ) = @_;
        return $table_name eq 'procurement_file';
    };

    ok( !$schema_lifecycle->_drop_obsolete_procurement_file_table, 'Obsolete procurement_file cleanup fails when the drop fails' );
    like( join( "\n", map { $_->{message} } @logs ), qr{cleanup failed: drop failed}, 'Cleanup logs the DB error' );
};

subtest 'Uninstall drops only current qualified table names' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my @dropped_tables;
    my @logs;
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };
    local *{ $schema_lifecycle_class . '::_drop_tables_if_exist' } = sub {
        my ( $self, @table_names ) = @_;
        @dropped_tables = @table_names;
        return 1;
    };

    ok( $schema_lifecycle->uninstall, 'Uninstall succeeds' );
    is_deeply(
        \@dropped_tables,
        [
            'koha_plugin_fi_kohasuomi_editx_sequences',
            'koha_plugin_fi_kohasuomi_editx_map_productform',
        ],
        'Uninstall drops only current qualified plugin tables'
    );
};

subtest 'Structured config model stores stable settings and preserves scalar runtime-style keys outside the blob' => sub {
    my $config = Koha::Plugin::Fi::KohaSuomi::Editx::Config->from_flat(
        {
            procurement_settings => {
                import_tmp_path                  => '/var/lib/koha/kohadev/editx/tmp',
                import_load_path                 => '/var/lib/koha/kohadev/editx/load',
                import_archive_path              => '/var/lib/koha/kohadev/editx/archive',
                import_failed_path               => '/var/lib/koha/kohadev/editx/fail',
                import_failed_archived_path      => '/var/lib/koha/kohadev/editx/failed_archived',
                authoriser                       => 51,
                allowed_locations                => 'MAIN,STACK',
                productform_alternative_triggers => 'STACK',
                automatch_biblios                => 'yes',
                use_finna_materialtype           => 'no',
                notification_mailto              => 'editx@example.org',
                notification_mailfrom            => 'koha@example.org',
                runtime_log_level                => 'debug',
            },
            sftp_sources => [
                {
                    enabled        => 'yes',
                    id             => 'alexandria',
                    host           => 'sftp.example.org',
                    user           => 'editx-user',
                    remote_dir     => '/out',
                    success_action => 'delete',
                },
            ],
            folder_sources => [
                {
                    enabled           => 'no',
                    id                => 'publisher_inbox',
                    local_dir         => '/var/lib/koha/kohadev/editx/inbound',
                    success_action    => 'archive',
                    local_archive_dir => '/var/lib/koha/kohadev/editx/source_archive',
                },
            ],
        }
    );
    my $json = Koha::Plugin::Fi::KohaSuomi::Editx::Config->to_json($config);

    like( $json, qr{"sftp_sources"}, 'Structured config JSON stores SFTP sources' );
    like( $json, qr{"folder_sources"}, 'Structured config JSON stores folder sources' );
    unlike( $json, qr{runtime_log_level}, 'Runtime log level is not packed into structured config JSON' );

    my $settings = Koha::Plugin::Fi::KohaSuomi::Editx::Config->procurement_settings($config);
    is( $settings->{authoriser}, 51, 'Structured config exposes flat procurement settings' );
    is( $settings->{notification_mailto}, 'editx@example.org', 'Structured config exposes notification settings' );
    is( $config->{sftp_sources}->[0]->{port}, 22, 'Structured config defaults SFTP port' );
    is( $config->{sftp_sources}->[0]->{pattern}, '*.xml', 'Structured config defaults SFTP pattern' );
    is( $config->{sftp_sources}->[0]->{success_action}, 'delete', 'Structured config stores SFTP source success action' );
    is( $config->{folder_sources}->[0]->{enabled}, 'no', 'Structured config stores folder source enabled flag' );
    is( $config->{folder_sources}->[0]->{pattern}, '*.xml', 'Structured config defaults folder pattern' );
    is( $config->{folder_sources}->[0]->{minimum_age_seconds}, 60, 'Structured config defaults folder source minimum age' );
};

subtest 'Structured config model ignores experimental plugin_data keys without config_json' => sub {
    my $config = Koha::Plugin::Fi::KohaSuomi::Editx::Config->from_plugin_data(
        {
            procurement_import_tmp_path       => '/tmp/editx',
            procurement_authoriser            => 51,
            procurement_notification_mailto   => 'editx@example.org',
            procurement_notification_mailfrom => 'koha@example.org',
            sftp_sources_yaml                 => <<'YAML',
sources:
  - id: legacy
    host: sftp.example.org
    user: editx-user
    remote_dir: /out
YAML
        }
    );

    my $settings = Koha::Plugin::Fi::KohaSuomi::Editx::Config->procurement_settings($config);
    is( $settings->{import_tmp_path}, '', 'Experimental flat import folder is ignored' );
    is( $settings->{notification_mailfrom}, '', 'Experimental flat notification sender is ignored' );
    is_deeply( $config->{sftp_sources}, [], 'Experimental SFTP YAML source is ignored' );
};

subtest 'SFTP source normalization defaults optional fields' => sub {
    my ( $sources, $messages, $has_blocking_errors ) = $plugin->_normalize_sftp_sources(
        [
            {
                id                       => 'alexandria',
                host                     => 'sftp.example.org',
                user                     => 'editx-user',
                remote_dir               => '/out/alexandria',
                strict_host_key_checking => 0,
            }
        ]
    );

    ok( !$has_blocking_errors, 'Valid SFTP source has no blocking errors' );
    is_deeply( $messages, [], 'Valid SFTP source has no messages' );
    is( scalar @$sources, 1, 'Normalizer returns one source' );
    is( $sources->[0]->{enabled}, 'yes', 'Normalizer defaults SFTP source to enabled' );
    is( $sources->[0]->{port}, 22, 'Normalizer defaults port to 22' );
    is( $sources->[0]->{pattern}, '*.xml', 'Normalizer defaults pattern to *.xml' );
    is( $sources->[0]->{success_action}, 'keep', 'Normalizer defaults success_action to keep' );
    is( $sources->[0]->{strict_host_key_checking}, 'no', 'Normalizer normalizes false strict_host_key_checking to no' );
};

subtest 'SFTP source normalization reports blocking source errors' => sub {
    my ( $sources, $messages, $has_blocking_errors ) = $plugin->_normalize_sftp_sources(
        [
            {
                id             => 'invalid-id',
                port           => 'abc',
                success_action => 'archive',
            },
            {
                id         => 'invalid-id',
                host       => 'sftp.example.org',
                user       => 'editx-user',
                remote_dir => '/out',
            },
            {
                id         => 'out_of_range',
                host       => 'sftp.example.org',
                user       => 'editx-user',
                remote_dir => '/out',
                port       => 70000,
            },
        ]
    );

    my $message_text = _message_text($messages);

    ok( $has_blocking_errors, 'Invalid SFTP source has blocking errors' );
    is( scalar @$sources, 3, 'Normalizer still returns normalized source entries for reporting' );
    like( $message_text, qr{SFTP source 1 has no host\.}, 'Normalizer reports missing host' );
    like( $message_text, qr{SFTP source 1 has no user\.}, 'Normalizer reports missing user' );
    like( $message_text, qr{SFTP source 1 has no remote_dir\.}, 'Normalizer reports missing remote_dir' );
    like( $message_text, qr{SFTP source 1 port 'abc' is not numeric\.}, 'Normalizer reports a nonnumeric port' );
    like( $message_text, qr{SFTP source 1 archives successful imports but has no remote_archive_dir\.}, 'Normalizer reports archive without remote_archive_dir' );
    like( $message_text, qr{SFTP source 2 repeats id 'invalid-id'\.}, 'Normalizer reports duplicate source ids' );
    like( $message_text, qr{SFTP source 3 port '70000' must be between 1 and 65535\.}, 'Normalizer reports an out-of-range port' );
};

subtest 'SFTP source normalization allows simple globs and rejects unsafe patterns' => sub {
    my ( $sources, $messages, $has_blocking_errors ) = $plugin->_normalize_sftp_sources(
        [
            {
                id         => 'valid_glob',
                host       => 'sftp.example.org',
                user       => 'editx-user',
                remote_dir => '/out',
                pattern    => 'LibraryShipNotice_*.xml',
            },
            {
                id         => 'unsafe_glob',
                host       => 'sftp.example.org',
                user       => 'editx-user',
                remote_dir => '/out',
                pattern    => '../*.xml',
            },
        ]
    );

    my $message_text = _message_text($messages);

    ok( $has_blocking_errors, 'Unsafe SFTP pattern has blocking errors' );
    is( $sources->[0]->{pattern}, 'LibraryShipNotice_*.xml', 'Normalizer keeps a simple SFTP glob pattern' );
    like( $message_text, qr{SFTP source 2 pattern '\.\./\*\.xml' is invalid}, 'Normalizer rejects path-like SFTP patterns' );
    is( $plugin->_manual_stage_file_glob('LibraryShipNotice_*.xml'), 'LibraryShipNotice_*.xml', 'Manual staged list accepts a simple filename pattern' );
};

subtest 'Folder source normalization validates local source actions' => sub {
    my $root = tempdir( CLEANUP => 1 );
    my $inbox = File::Spec->catdir( $root, 'inbox' );
    my $archive = File::Spec->catdir( $root, 'archive' );
    make_path($inbox);

    my ( $sources, $messages, $has_blocking_errors ) = $plugin->_normalize_folder_sources(
        [
            {
                enabled           => 0,
                id                => 'publisher_inbox',
                local_dir         => $inbox,
                success_action    => 'archive',
                local_archive_dir => $archive,
            }
        ]
    );

    ok( !$has_blocking_errors, 'Valid folder source has no blocking errors' );
    is_deeply( $messages, [], 'Valid folder source has no messages' );
    is( $sources->[0]->{enabled}, 'no', 'Folder source enabled flag is normalized' );
    is( $sources->[0]->{pattern}, '*.xml', 'Folder source pattern defaults to XML files' );
    is( $sources->[0]->{minimum_age_seconds}, 60, 'Folder source minimum age defaults to 60 seconds' );

    ( $sources, $messages, $has_blocking_errors ) = $plugin->_normalize_folder_sources(
        [
            {
                id             => 'bad-folder',
                local_dir      => '../inbox',
                success_action => 'archive',
            },
            {
                id        => 'bad-folder',
                local_dir => $inbox,
                pattern   => '../*.xml',
            },
        ]
    );

    my $message_text = _message_text($messages);
    ok( $has_blocking_errors, 'Invalid folder source has blocking errors' );
    like( $message_text, qr{Folder source 1 id 'bad-folder' is invalid}, 'Folder source id format is validated' );
    like( $message_text, qr{Folder source 1 archives successful imports but has no local_archive_dir}, 'Folder archive action requires archive folder' );
    like( $message_text, qr{Folder source 1 local_dir must be an absolute path}, 'Folder local_dir must be absolute' );
    like( $message_text, qr{Folder source 2 repeats id 'bad-folder'}, 'Duplicate folder source ids are rejected' );
    like( $message_text, qr{Folder source 2 pattern '\.\./\*\.xml' is invalid}, 'Folder source pattern rejects path-like globs' );
};

subtest 'Configured source ids must be unique across transports' => sub {
    my ( $messages, $has_blocking_errors ) = $plugin->_validate_config_source_ids(
        [ { id => 'shared' } ],
        [ { id => 'shared' } ],
    );

    ok( $has_blocking_errors, 'Duplicate source ids across transports block configuration save' );
    like( _message_text($messages), qr{EDItX source id 'shared' is used by more than one source}, 'Cross-transport duplicate is reported' );
};

{
    package t::EditXFakeSFTPAttr;

    sub new {
        my ( $class, %values ) = @_;
        return bless \%values, $class;
    }

    sub size  { return shift->{size}; }
    sub mtime { return shift->{mtime}; }
    sub perm  { return shift->{perm}; }

    package t::EditXFakeSFTPConnection;

    sub new {
        my ( $class, $entries ) = @_;
        return bless { entries => $entries, downloads => [], removals => [], renames => [] }, $class;
    }

    sub ls {
        my ( $self, $remote_dir ) = @_;
        $self->{last_ls} = $remote_dir;
        return $self->{entries};
    }

    sub get {
        my ( $self, $remote_path, $local_path ) = @_;
        push @{ $self->{downloads} }, [ $remote_path, $local_path ];
        open my $fh, '>', $local_path or return 0;
        print {$fh} '<LibraryShipNotice />';
        close $fh;
        return 1;
    }

    sub remove {
        my ( $self, $remote_path ) = @_;
        push @{ $self->{removals} }, $remote_path;
        return $self->{remove_fails} ? 0 : 1;
    }

    sub rename {
        my ( $self, $remote_path, $archive_path ) = @_;
        push @{ $self->{renames} }, [ $remote_path, $archive_path ];
        return $self->{rename_fails} ? 0 : 1;
    }

    sub error      { return shift->{error} || 0; }
    sub disconnect { shift->{disconnected} = 1; return 1; }

    package t::EditXFakeCGI;

    sub new {
        my ( $class, $params ) = @_;
        return bless { params => $params || {} }, $class;
    }

    sub param {
        my ( $self, $name ) = @_;
        return $self->{params}->{$name};
    }

    sub multi_param {
        my ( $self, $name ) = @_;
        my $value = $self->{params}->{$name};
        return if !defined $value;
        return @$value if ref $value eq 'ARRAY';
        return ($value);
    }
}

subtest 'Manual staged source selection scopes source checks without affecting default batch scope' => sub {
    my $sources = [
        { id => 'alpha', host => 'sftp-a.example.org' },
        { id => 'beta',  host => 'sftp-b.example.org' },
    ];

    my ( $selected, $messages, $has_errors ) = $plugin->_manual_selected_sources(
        t::EditXFakeCGI->new( { manual_source_id => ['beta'] } ),
        $sources,
        require_selection => 1
    );
    is_deeply( [ map { $_->{id} } @$selected ], ['beta'], 'Selected staged source limits the next remote check' );
    is_deeply( $messages, [], 'Selected staged source has no warning messages' );
    ok( !$has_errors, 'Selected staged source has no errors' );

    ( $selected, $messages, $has_errors ) = $plugin->_manual_selected_sources(
        t::EditXFakeCGI->new( {} ),
        $sources,
        require_selection => 0
    );
    is_deeply( [ map { $_->{id} } @$selected ], [qw(alpha beta)], 'Missing source selection keeps the default all-source scope' );
    ok( !$has_errors, 'Default all-source scope has no errors' );

    ( $selected, $messages, $has_errors ) = $plugin->_manual_selected_sources(
        t::EditXFakeCGI->new( {} ),
        $sources,
        require_selection => 1
    );
    ok( $has_errors, 'Review step requires at least one selected source' );
    like( _message_text($messages), qr{Select at least one EDItX source to check}, 'Review step reports missing source selection' );

    ( $selected, $messages, $has_errors ) = $plugin->_manual_selected_sources(
        t::EditXFakeCGI->new( { manual_source_id => ['missing'] } ),
        $sources,
        require_selection => 1
    );
    ok( $has_errors, 'Unknown selected source is rejected' );
    like( _message_text($messages), qr{Selected EDItX source 'missing' is no longer configured}, 'Unknown selected source has an actionable warning' );
};

subtest 'Manual staged SFTP listing parses Net::SFTP::Foreign entries and keeps diagnostics' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $fake_sftp = t::EditXFakeSFTPConnection->new(
        [
            {
                filename => 'LibraryShipNotice_22877649_20260423133028.xml',
                a        => t::EditXFakeSFTPAttr->new( size => 6477, mtime => 1_775_216_128, perm => 0100644 ),
            },
            {
                filename => 'LibraryShipNotice_22886798_20260427144844.xml',
                a        => t::EditXFakeSFTPAttr->new( size => 11340, mtime => 1_775_216_129, perm => 0100644 ),
            },
            {
                filename => 'IgnoreMe_1.xml',
                a        => t::EditXFakeSFTPAttr->new( size => 10, mtime => 1_775_216_130, perm => 0100644 ),
            },
            {
                filename => 'remote_directory',
                a        => t::EditXFakeSFTPAttr->new( size => 0, mtime => 1_775_216_131, perm => 0040755 ),
            },
        ]
    );
    local *{ $plugin_class . '::_manual_stage_sftp_connect' } = sub {
        return $fake_sftp;
    };

    my $listing = $plugin->_manual_stage_list_sftp_source(
        {
            id         => 'haaga_helia',
            remote_dir => '/out',
            pattern    => 'LibraryShipNotice_*.xml',
        },
        { import_tmp_path => '/tmp/editx' }
    );

    is( scalar @{ $listing->{files} }, 2, 'Manual staged listing parses long and filename-only SFTP rows' );
    is( $listing->{files}->[0]->{key}, 'haaga_helia::LibraryShipNotice_22877649_20260423133028.xml', 'Manual staged listing builds a stable source/file selection key' );
    is( $listing->{files}->[0]->{filename}, 'LibraryShipNotice_22877649_20260423133028.xml', 'Manual staged listing keeps the long-list filename' );
    is( $listing->{files}->[0]->{size}, 6477, 'Manual staged listing keeps the long-list file size' );
    is( $listing->{files}->[1]->{filename}, 'LibraryShipNotice_22886798_20260427144844.xml', 'Manual staged listing keeps the second matching file' );
    ok( !grep( { $_->{filename} eq 'IgnoreMe_1.xml' } @{ $listing->{files} } ), 'Manual staged listing filters filenames by pattern locally' );
    ok( !grep( { $_->{filename} eq 'remote_directory' } @{ $listing->{files} } ), 'Manual staged listing ignores remote directories' );
    is( $fake_sftp->{last_ls}, '/out', 'Manual staged listing passes the configured remote directory to Net::SFTP::Foreign' );
    ok( $fake_sftp->{disconnected}, 'Manual staged listing disconnects the SFTP connection' );
    is( $listing->{source_output}, '4 remote entries returned.', 'Manual staged listing reports structured SFTP result count' );
    is( $listing->{source_operation}, 'Net::SFTP::Foreign ls(/out)', 'Manual staged listing reports the SFTP list operation for diagnostics' );
};

subtest 'Manual staged folder listing and copy uses local sources without SFTP' => sub {
    my $root = tempdir( CLEANUP => 1 );
    my $source_dir = File::Spec->catdir( $root, 'inbound' );
    my $run_dir = File::Spec->catdir( $root, 'run' );
    make_path( $source_dir, $run_dir );

    my $old_file = File::Spec->catfile( $source_dir, 'LibraryShipNotice_22877649.xml' );
    open my $old_fh, '>', $old_file or die "Cannot write $old_file: $!";
    print {$old_fh} '<LibraryShipNotice />';
    close $old_fh;
    utime time - 120, time - 120, $old_file;

    my $young_file = File::Spec->catfile( $source_dir, 'LibraryShipNotice_young.xml' );
    open my $young_fh, '>', $young_file or die "Cannot write $young_file: $!";
    print {$young_fh} '<LibraryShipNotice />';
    close $young_fh;

    my $ignored_file = File::Spec->catfile( $source_dir, 'IgnoreMe.txt' );
    open my $ignored_fh, '>', $ignored_file or die "Cannot write $ignored_file: $!";
    print {$ignored_fh} 'ignore';
    close $ignored_fh;

    my $source = {
        id                  => 'publisher_inbox',
        transport           => 'folder',
        local_dir           => $source_dir,
        pattern             => 'LibraryShipNotice_*.xml',
        minimum_age_seconds => 60,
        success_action      => 'keep',
    };

    my $listing = $plugin->_manual_stage_list_folder_source( $source, { import_tmp_path => File::Spec->catdir( $root, 'tmp' ) } );
    is( scalar @{ $listing->{files} }, 1, 'Folder source listing returns only stable matching files' );
    is( $listing->{files}->[0]->{key}, 'publisher_inbox::LibraryShipNotice_22877649.xml', 'Folder source listing builds a stable source/file selection key' );
    is( $listing->{files}->[0]->{transport}, 'folder', 'Folder source listing marks the transport' );
    is( $listing->{files}->[0]->{after_action}, 'keep after successful import', 'Folder source listing reports the configured successful import action' );
    is( $listing->{source_operation}, "folder scan($source_dir)", 'Folder source listing reports the local scan operation' );

    my $copied = $plugin->_manual_stage_copy_folder_files( $source, {}, $run_dir, ['LibraryShipNotice_22877649.xml'] );
    is( scalar @$copied, 1, 'Folder source copy stages the selected source file' );
    ok( -f $copied->[0]->{local_path}, 'Folder source copy creates a staged local file' );
    is( $copied->[0]->{source_path}, $old_file, 'Folder source copy keeps source path metadata for later cleanup' );
    ok( -f $old_file, 'Folder source copy leaves the source file in place' );
};

subtest 'Nightly folder source staging copies stable source files into import tmp' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $root = tempdir( CLEANUP => 1 );
    my $source_dir = File::Spec->catdir( $root, 'inbound' );
    my $target_dir = File::Spec->catdir( $root, 'tmp' );
    make_path( $source_dir, $target_dir );

    my $source_file = File::Spec->catfile( $source_dir, 'LibraryShipNotice_22877649.xml' );
    open my $source_fh, '>', $source_file or die "Cannot write $source_file: $!";
    print {$source_fh} '<LibraryShipNotice />';
    close $source_fh;
    utime time - 120, time - 120, $source_file;

    my @logs;
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);

    my $result = $plugin->_stage_folder_source_for_import(
        {
            id                  => 'publisher_inbox',
            local_dir           => $source_dir,
            pattern             => 'LibraryShipNotice_*.xml',
            minimum_age_seconds => 60,
        },
        $target_dir
    );

    is( $result->{copied}, 1, 'Nightly folder source scan copies one stable file' );
    ok( -f File::Spec->catfile( $target_dir, 'LibraryShipNotice_22877649.xml' ), 'Nightly folder source scan copies into import tmp staging' );
    ok( -f $source_file, 'Nightly folder source scan leaves the source file in place until import succeeds' );
    like( join( "\n", map { $_->{message} } @logs ), qr{copied to staging}, 'Nightly folder source scan logs copied files' );
};

subtest 'Source cleanup mutates folder sources only after successful imports' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $root = tempdir( CLEANUP => 1 );
    my $source_dir = File::Spec->catdir( $root, 'inbound' );
    my $archive_dir = File::Spec->catdir( $root, 'archive' );
    my $stage_dir = File::Spec->catdir( $root, 'stage' );
    make_path( $source_dir, $archive_dir, $stage_dir );

    my %source_files;
    for my $filename (qw(delete.xml archive.xml keep.xml unprocessed.xml)) {
        my $path = File::Spec->catfile( $source_dir, $filename );
        open my $fh, '>', $path or die "Cannot write $path: $!";
        print {$fh} '<LibraryShipNotice />';
        close $fh;
        $source_files{$filename} = $path;
    }

    my @logs;
    local *{ $plugin_class . '::_log_runtime' } = _capture_runtime_log(\@logs);

    my $result = $plugin->_apply_source_success_actions(
        {
            processed_files => [
                File::Spec->catfile( $stage_dir, 'delete.xml' ),
                'archive.xml',
                'keep.xml',
            ],
        },
        [
            {
                transport      => 'folder',
                source_id      => 'folder_delete',
                filename       => 'delete.xml',
                source_path    => $source_files{'delete.xml'},
                local_path     => File::Spec->catfile( $stage_dir, 'delete.xml' ),
                success_action => 'delete',
            },
            {
                transport         => 'folder',
                source_id         => 'folder_archive',
                filename          => 'archive.xml',
                source_path       => $source_files{'archive.xml'},
                local_path        => File::Spec->catfile( $stage_dir, 'archive.xml' ),
                success_action    => 'archive',
                local_archive_dir => $archive_dir,
            },
            {
                transport      => 'folder',
                source_id      => 'folder_keep',
                filename       => 'keep.xml',
                source_path    => $source_files{'keep.xml'},
                local_path     => File::Spec->catfile( $stage_dir, 'keep.xml' ),
                success_action => 'keep',
            },
            {
                transport      => 'folder',
                source_id      => 'folder_unprocessed',
                filename       => 'unprocessed.xml',
                source_path    => $source_files{'unprocessed.xml'},
                local_path     => File::Spec->catfile( $stage_dir, 'unprocessed.xml' ),
                success_action => 'delete',
            },
        ]
    );

    is_deeply(
        $result,
        { kept => 1, deleted => 1, archived => 1, failed => 0 },
        'Folder source cleanup counts only successfully processed files'
    );
    ok( !-e $source_files{'delete.xml'}, 'Folder delete action removes the original source file' );
    ok( !-e $source_files{'archive.xml'}, 'Folder archive action moves the original source file' );
    ok( -f File::Spec->catfile( $archive_dir, 'archive.xml' ), 'Folder archive action creates the archive file' );
    ok( -f $source_files{'keep.xml'}, 'Folder keep action leaves the original source file' );
    ok( -f $source_files{'unprocessed.xml'}, 'Unprocessed folder source files are not cleaned up' );
    like( join( "\n", map { $_->{message} } @logs ), qr{Source cleanup after successful import finished}i, 'Folder cleanup writes a runtime summary' );
};

subtest 'Source cleanup applies SFTP delete and archive actions after successful imports' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $fake_sftp = t::EditXFakeSFTPConnection->new( [] );
    local *{ $plugin_class . '::_manual_stage_sftp_connect' } = sub {
        return $fake_sftp;
    };
    local *{ $plugin_class . '::_log_runtime' } = sub {
        return 1;
    };

    my $result = $plugin->_apply_source_success_actions(
        {
            processed_files => [
                '/var/lib/koha/kohadev/editx/load/delete.xml',
                'archive.xml',
                'keep.xml',
            ],
        },
        [
            {
                transport      => 'sftp',
                source_id      => 'sftp_delete',
                filename       => 'delete.xml',
                source_path    => '/out/delete.xml',
                local_path     => '/var/lib/koha/kohadev/editx/tmp/delete.xml',
                success_action => 'delete',
            },
            {
                transport          => 'sftp',
                source_id          => 'sftp_archive',
                filename           => 'archive.xml',
                source_path        => '/out/archive.xml',
                local_path         => '/var/lib/koha/kohadev/editx/tmp/archive.xml',
                success_action     => 'archive',
                remote_archive_dir => '/done',
            },
            {
                transport      => 'sftp',
                source_id      => 'sftp_keep',
                filename       => 'keep.xml',
                source_path    => '/out/keep.xml',
                local_path     => '/var/lib/koha/kohadev/editx/tmp/keep.xml',
                success_action => 'keep',
            },
            {
                transport      => 'sftp',
                source_id      => 'sftp_unprocessed',
                filename       => 'unprocessed.xml',
                source_path    => '/out/unprocessed.xml',
                local_path     => '/var/lib/koha/kohadev/editx/tmp/unprocessed.xml',
                success_action => 'delete',
            },
        ]
    );

    is_deeply(
        $result,
        { kept => 1, deleted => 1, archived => 1, failed => 0 },
        'SFTP source cleanup counts only successfully processed files'
    );
    is_deeply( $fake_sftp->{removals}, ['/out/delete.xml'], 'SFTP delete action removes only the processed remote file' );
    is_deeply( $fake_sftp->{renames}, [ [ '/out/archive.xml', '/done/archive.xml' ] ], 'SFTP archive action renames the processed remote file into the archive folder' );
};

subtest 'Manual staged SFTP listing reports empty output to the caller' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $fake_sftp = t::EditXFakeSFTPConnection->new( [] );
    local *{ $plugin_class . '::_manual_stage_sftp_connect' } = sub {
        return $fake_sftp;
    };

    my $listing = $plugin->_manual_stage_list_sftp_source(
        {
            id         => 'haaga_helia',
            remote_dir => '/out',
            pattern    => 'LibraryShipNotice_*.xml',
        },
        { import_tmp_path => '/tmp/editx' }
    );

    is_deeply( $listing->{files}, [], 'Manual staged listing returns no files for empty SFTP output' );
    is( $listing->{source_output}, 'Net::SFTP::Foreign returned an empty remote directory listing.', 'Manual staged listing keeps empty output explicit for warning messages' );
    is( $listing->{source_operation}, 'Net::SFTP::Foreign ls(/out)', 'Manual staged listing reports the SFTP list operation' );
};

subtest 'Manual staging run ids accept File::Temp underscores' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $root = tempdir( CLEANUP => 1 );
    local *{ $plugin_class . '::_manual_stage_base_dir' } = sub {
        return $root;
    };

    my $path = eval { $plugin->_manual_stage_manifest_path('run-vKb_Cu') };
    is( $@, '', 'Underscore staging run ids are accepted' );
    is( $path, File::Spec->catfile( $root, 'run-vKb_Cu', 'manifest.json' ), 'Manifest path keeps the File::Temp run id' );
    ok( !$plugin->_manual_stage_valid_run_id('run-../bad'), 'Path-like staging run ids are still rejected' );
};

subtest 'Manual staged workflow resumes manifests after redirect-safe GET reloads' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $root = tempdir( CLEANUP => 1 );
    local *{ $plugin_class . '::_manual_stage_base_dir' } = sub {
        return $root;
    };

    my $run_id = 'run-vKb_Cu';
    mkdir File::Spec->catdir( $root, $run_id ) or die "Cannot create staged run dir: $!";
    $plugin->_manual_stage_save_manifest(
        {
            run_id => $run_id,
            step   => 'downloaded',
            files  => [],
        }
    );

    my ( $messages, $stage, $sync_result, $attempted ) =
        $plugin->_manual_stage_resume( t::EditXFakeCGI->new( { manual_stage_run_id => $run_id, stage_status => 'downloaded' } ) );
    is( $stage->{step}, 'downloaded', 'Downloaded staged state is resumed from the manifest' );
    is( $sync_result, undef, 'Downloaded staged state has no import summary' );
    is( $attempted, undef, 'Downloaded staged state does not render the import summary section' );
    like( _message_text($messages), qr{staged for preview}, 'Downloaded redirect shows the staff success message' );

    $plugin->_manual_stage_save_manifest(
        {
            run_id             => $run_id,
            step               => 'imported',
            files              => [],
            import_result      => { processed => 1, failed => 0, skipped => 0 },
            manual_sync_result => { order_count => 1, item_count => 1, baskets => [] },
        }
    );
    ( $messages, $stage, $sync_result, $attempted ) =
        $plugin->_manual_stage_resume( t::EditXFakeCGI->new( { manual_stage_run_id => $run_id, stage_status => 'imported' } ) );
    is( $stage->{step}, 'imported', 'Imported staged state is resumed from the manifest' );
    is( $stage->{import_result}->{processed}, 1, 'Imported staged state keeps the import counts' );
    is( $sync_result->{order_count}, 1, 'Imported staged state keeps the acquisition summary for links' );
    ok( $attempted, 'Imported staged state renders the import summary section' );
    is( _message_text($messages), '', 'Imported redirect leaves the result summary inside the staged result section' );
};

subtest 'Manual staged preview blocks duplicate ShipNoticeNumber rows in the same download batch' => sub {
    my @files = (
        {
            status             => 'valid',
            filename           => 'LibraryShipNotice_22886798_a.xml',
            ship_notice_number => '22886798',
        },
        {
            status             => 'valid',
            filename           => 'LibraryShipNotice_22886798_b.xml',
            ship_notice_number => '22886798',
        },
        {
            status             => 'valid',
            filename           => 'LibraryShipNotice_22901735.xml',
            ship_notice_number => '22901735',
        },
    );

    $plugin->_manual_stage_mark_batch_duplicates(\@files);

    ok( !$files[0]->{duplicate_import_blocked}, 'First downloaded notice remains importable' );
    is( $files[1]->{duplicate_status}, 'duplicate in preview', 'Second downloaded notice with the same ShipNoticeNumber is marked duplicate' );
    ok( $files[1]->{duplicate_import_blocked}, 'Second downloaded notice is blocked from selection' );
    like( $files[1]->{duplicate_message}, qr{LibraryShipNotice_22886798_a\.xml}, 'Duplicate message points to the first matching downloaded file' );
    ok( !$files[2]->{duplicate_import_blocked}, 'Different ShipNoticeNumber remains importable' );
};

subtest 'Manual staged import blocks duplicate files server-side' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $manifest = {
        run_id => 'run-ok',
        step   => 'downloaded',
        files  => [
            {
                id                       => 'duplicate-file',
                status                   => 'valid',
                duplicate_import_blocked => 1,
                local_path               => '/tmp/duplicate.xml',
            },
        ],
    };

    local *{ $plugin_class . '::_csrf_token_valid' } = sub {
        return 1;
    };
    local *{ $plugin_class . '::_manual_stage_valid_run_id' } = sub {
        return 1;
    };
    local *{ $plugin_class . '::_manual_stage_load_manifest' } = sub {
        return $manifest;
    };

    my ( $messages, $stage, $result ) = $plugin->_manual_stage_import_selected(
        t::EditXFakeCGI->new(
            {
                manual_stage_run_id => 'run-ok',
                stage_file          => ['duplicate-file'],
            }
        )
    );

    like( _message_text($messages), qr{duplicate notices and were not imported}, 'Duplicate staged imports are blocked' );
    is( $stage->{step}, 'downloaded', 'Blocked duplicate staged import returns to the preview step' );
    is( $result, undef, 'Blocked duplicate staged import does not run the importer' );
};

subtest 'Manual staged import reports stale run ids without a 500' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    local *{ $plugin_class . '::_csrf_token_valid' } = sub {
        return 1;
    };

    my $cgi = t::EditXFakeCGI->new(
        {
            manual_stage_run_id => 'run-../bad',
            stage_file          => ['staged-file'],
        }
    );
    my ( $messages, $stage, $result );
    my $ok = eval {
        ( $messages, $stage, $result ) = $plugin->_manual_stage_import_selected($cgi);
        1;
    };

    ok( $ok, 'Invalid staged import state does not die' );
    is( $stage, undef, 'Invalid staged import state does not keep a stage' );
    is( $result, undef, 'Invalid staged import state has no import result' );
    like( _message_text($messages), qr{staged EDItX file list is no longer available}, 'Invalid staged import state is shown as a staff-facing warning' );
};

subtest 'Missing saved config defaults to empty source lists' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::retrieve_data' } = sub { return; };

    my $config = $plugin->_editx_config();

    is_deeply( $config->{sftp_sources}, [], 'Missing saved config defaults to no SFTP sources' );
    is_deeply( $config->{folder_sources}, [], 'Missing saved config defaults to no folder sources' );
};

subtest 'Tool source status rejects an empty saved source list' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::retrieve_data' } = sub { return; };

    my $status = $plugin->_tool_source_status( { import_tmp_path => '/tmp/editx' } );
    my $message_text = _message_text( $status->{messages} );

    is( $status->{count}, 0, 'Tool status counts no saved EDItX sources' );
    ok( $status->{has_errors}, 'Tool status marks an empty source list as not runnable' );
    like( $message_text, qr{No EDItX intake sources are saved in the plugin configuration\.}, 'Tool status reports missing EDItX sources' );
};

subtest 'Koha instance detection uses the Koha configuration path' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    local $ENV{ 'KOHA' . '_INSTANCE' } = 'kofipre';
    my $detect_instance = \&{ $plugin_class . '::_instance_from_koha_conf_path' };
    local ${ $plugin_class . '::INSTANCE' } = $detect_instance->('/etc/koha/sites/kohadev/koha-conf.xml');

    is( $detect_instance->('/etc/koha/sites/kohadev/koha-conf.xml'), 'kohadev', 'Koha instance parser reads the Debian KOHA_CONF path' );
    is( $plugin->_koha_instance(), 'kohadev', 'Koha instance comes from cached KOHA_CONF parsing, not unofficial instance environment' );
};

subtest 'Koha instance detection does not guess from non-Debian paths' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $detect_instance = \&{ $plugin_class . '::_instance_from_koha_conf_path' };
    local ${ $plugin_class . '::INSTANCE' } = $detect_instance->('/home/koha/etc/koha-conf.xml');

    is( $plugin->_koha_instance(), undef, 'Koha instance is not guessed when KOHA_CONF is not a Debian site path' );
};

subtest 'Recommended import paths are scoped to the Koha instance' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::_koha_instance' } = sub { return 'kohadev'; };

    my $paths = $plugin->_recommended_import_paths();
    my $sftp_paths = $plugin->_recommended_sftp_paths();

    is( $paths->{base}, '/var/lib/koha/kohadev/editx', 'Recommended base path uses the detected Koha instance' );
    is( $paths->{tmp}, '/var/lib/koha/kohadev/editx/tmp', 'Recommended tmp path is below the base path' );
    is( $paths->{load}, '/var/lib/koha/kohadev/editx/load', 'Recommended load path is below the base path' );
    is( $paths->{archive}, '/var/lib/koha/kohadev/editx/archive', 'Recommended archive path is below the base path' );
    is( $paths->{fail}, '/var/lib/koha/kohadev/editx/fail', 'Recommended fail path is below the base path' );
    is( $paths->{failed_archived}, '/var/lib/koha/kohadev/editx/failed_archived', 'Recommended failed archive path is below the base path' );
    is( $sftp_paths->{identity_file}, '/var/lib/koha/kohadev/.ssh/editx_sftp', 'Recommended SFTP identity file uses the detected Koha instance .ssh directory' );
    is( $sftp_paths->{known_hosts_file}, '/var/lib/koha/kohadev/.ssh/known_hosts', 'Recommended SFTP known hosts file uses the detected Koha instance .ssh directory' );
    unlike( $paths->{base}, qr{/spool/}, 'Recommended base path avoids the root-owned Koha spool area' );
};

subtest 'Blank SFTP table defaults do not create an empty source' => sub {
    my $cgi = bless {
        sftp_enabled                  => ['1'],
        sftp_id                       => [''],
        sftp_host                     => [''],
        sftp_port                     => ['22'],
        sftp_user                     => [''],
        sftp_identity_file            => ['/var/lib/koha/kohadev/.ssh/editx_sftp'],
        sftp_remote_dir               => [''],
        sftp_local_dir                => [''],
        sftp_pattern                  => ['*.xml'],
        sftp_success_action           => ['keep'],
        sftp_remote_archive_dir       => [''],
        sftp_known_hosts_file         => ['/var/lib/koha/kohadev/.ssh/known_hosts'],
        sftp_strict_host_key_checking => ['yes'],
        sftp_ssh_config               => [''],
    }, 'KohaSuomi::Editx::TestCGI';

    is_deeply( $plugin->_sftp_sources_from_cgi($cgi), [], 'Path-only SFTP defaults are ignored until a real source is entered' );
};

subtest 'Blank folder source table defaults do not create an empty source' => sub {
    my $cgi = bless {
        folder_enabled             => ['1'],
        folder_id                  => [''],
        folder_local_dir           => [''],
        folder_pattern             => ['*.xml'],
        folder_success_action      => ['keep'],
        folder_local_archive_dir   => [''],
        folder_minimum_age_seconds => ['60'],
    }, 'KohaSuomi::Editx::TestCGI';

    is_deeply( $plugin->_folder_sources_from_cgi($cgi), [], 'Path-only folder source defaults are ignored until a real source is entered' );
};

subtest 'Procurement settings prefill missing import folders from the Koha instance' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;
    local *{ $plugin_class . '::_koha_instance' } = sub { return 'kohadev'; };
    local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config::getSettings = sub {
        return { settings => {}, notifications => {} };
    };

    my $settings = $plugin->_procurement_settings();

    is( $settings->{import_tmp_path}, '/var/lib/koha/kohadev/editx/tmp', 'Missing tmp folder uses the default Koha instance path' );
    is( $settings->{import_load_path}, '/var/lib/koha/kohadev/editx/load', 'Missing load folder uses the default Koha instance path' );
    is( $settings->{import_archive_path}, '/var/lib/koha/kohadev/editx/archive', 'Missing archive folder uses the default Koha instance path' );
    is( $settings->{import_failed_path}, '/var/lib/koha/kohadev/editx/fail', 'Missing fail folder uses the default Koha instance path' );
    is( $settings->{import_failed_archived_path}, '/var/lib/koha/kohadev/editx/failed_archived', 'Missing failed archive folder uses the default Koha instance path' );
};

subtest 'Procurement Config applies the same import folder defaults for console import runs' => sub {
    no warnings qw(once redefine);
    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;

    local $ENV{ 'KOHA' . '_INSTANCE' } = 'kofipre';
    local $Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config::INSTANCE = 'kohadev';
    local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config::kohaConfigPath = sub {
        return '/etc/koha/sites/kohadev/koha-conf.xml';
    };
    local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config::loadConfigXml = sub {
        return { settings => {}, notifications => {} };
    };
    local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config::loadPluginData = sub {
        return {};
    };

    my $settings = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config->new->getSettings;

    is( $settings->{settings}->{import_tmp_path}, '/var/lib/koha/kohadev/editx/tmp', 'Console config defaults tmp folder from KOHA_CONF' );
    is( $settings->{settings}->{import_load_path}, '/var/lib/koha/kohadev/editx/load', 'Console config defaults load folder from KOHA_CONF' );
    is( $settings->{settings}->{import_archive_path}, '/var/lib/koha/kohadev/editx/archive', 'Console config defaults archive folder from KOHA_CONF' );
    is( $settings->{settings}->{import_failed_path}, '/var/lib/koha/kohadev/editx/fail', 'Console config defaults failed folder from KOHA_CONF' );
    is( $settings->{settings}->{import_failed_archived_path}, '/var/lib/koha/kohadev/editx/failed_archived', 'Console config defaults failed archive folder from KOHA_CONF' );
};

subtest 'Procurement folder validation accepts creatable absolute paths' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::_patron_exists' } = sub { return 1; };
    local *{ $plugin_class . '::_authorised_values' } = sub { return ['MAIN']; };

    my $root = tempdir( CLEANUP => 1 );
    my $settings = _valid_procurement_settings( File::Spec->catdir( $root, 'spool', 'editx' ) );
    my ( $messages, $has_blocking_errors ) = $plugin->_validate_procurement_settings( $settings, 1 );

    ok( !$has_blocking_errors, 'Creatable folder hierarchy is accepted' );
    is_deeply( $messages, [], 'Creatable folder hierarchy has no validation messages' );
};

subtest 'Procurement folder validation rejects unsafe paths' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::_patron_exists' } = sub { return 1; };
    local *{ $plugin_class . '::_authorised_values' } = sub { return ['MAIN']; };

    my $root = tempdir( CLEANUP => 1 );
    my $settings = _valid_procurement_settings( File::Spec->catdir( $root, 'spool', 'editx' ) );
    $settings->{import_tmp_path} = File::Spec->catdir( $root, '..', 'editx-tmp' );
    $settings->{import_load_path} = 'relative/load';
    my ( $messages, $has_blocking_errors ) = $plugin->_validate_procurement_settings( $settings, 1 );
    my $message_text = _message_text($messages);

    ok( $has_blocking_errors, 'Unsafe folder paths block configuration save' );
    like( $message_text, qr{Temporary download folder must not contain parent-directory segments}, 'Validation rejects parent-directory path segments' );
    like( $message_text, qr{Import load folder must be an absolute path}, 'Validation rejects relative paths' );
};

subtest 'Procurement folder validation rejects non-directory parents' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::_patron_exists' } = sub { return 1; };
    local *{ $plugin_class . '::_authorised_values' } = sub { return ['MAIN']; };

    my $root = tempdir( CLEANUP => 1 );
    my $file_parent = File::Spec->catfile( $root, 'archive-file' );
    open my $fh, '>', $file_parent or die "Cannot create $file_parent: $!";
    close $fh;

    my $settings = _valid_procurement_settings( File::Spec->catdir( $root, 'spool', 'editx' ) );
    $settings->{import_archive_path} = File::Spec->catdir( $file_parent, 'archive' );
    my ( $messages, $has_blocking_errors ) = $plugin->_validate_procurement_settings( $settings, 1 );
    my $message_text = _message_text($messages);

    ok( $has_blocking_errors, 'Non-directory parent blocks configuration save' );
    like( $message_text, qr{Successful archive folder cannot be created because the nearest existing parent is not a directory}, 'Validation rejects non-directory parents' );
};

subtest 'ProductForm CSV parser blocks unknown itemtypes' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::_itemtypes' } = sub { return [qw(BK ALT)]; };

    my ( $rows, $messages, $has_blocking_errors ) = $plugin->_parse_productform_mapping_csv(<<'CSV');
onix_code,productform,productform_alternative
AA,BK,MISSING
AB,NOPE,ALT
AA,BK,ALT
CSV

    my $message_text = _message_text($messages);

    ok( $has_blocking_errors, 'Unknown itemtypes block ProductForm CSV import' );
    is_deeply( $rows, [], 'Parser does not return rows for saving when itemtypes are unknown' );
    like( $message_text, qr{Line 2: alternative ProductForm item type 'MISSING' does not exist in Koha; choose an existing item type or leave the field empty\.}, 'Parser reports unknown alternative itemtype as an error' );
    like( $message_text, qr{Line 3: ProductForm item type 'NOPE' does not exist in Koha; choose an existing item type or leave the field empty\.}, 'Parser reports unknown primary itemtype as an error' );
    like( $message_text, qr{Line 4 repeats ONIX code 'AA'; the later value will win\.}, 'Parser warns about duplicate ONIX codes' );
};

subtest 'ProductForm row normalization blocks unknown itemtypes' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::_itemtypes' } = sub { return [qw(BK ALT)]; };

    my ( $rows, $messages, $has_blocking_errors ) = $plugin->_normalize_productform_mapping_rows(
        [
            {
                _label                  => 'New mapping row',
                onix_code               => 'AA',
                productform             => 'MISSING',
                productform_alternative => 'ALT',
            }
        ]
    );

    ok( $has_blocking_errors, 'Unknown itemtypes block ProductForm row save' );
    is_deeply( $rows, [], 'Normalizer does not return rows for saving when an itemtype is unknown' );
    like(
        _message_text($messages),
        qr{New mapping row: ProductForm item type 'MISSING' does not exist in Koha; choose an existing item type or leave the field empty\.},
        'Normalizer reports the unknown itemtype as an error'
    );
};

subtest 'ProductForm CSV parser blocks malformed imports' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::_itemtypes' } = sub { return [qw(BK ALT)]; };

    my ( $rows, $messages, $has_blocking_errors ) = $plugin->_parse_productform_mapping_csv(<<'CSV');
onix_code,productform,productform_alternative
NULL,BK,ALT
AA,BK
CSV

    my $message_text = _message_text($messages);

    ok( $has_blocking_errors, 'Malformed ProductForm CSV rows block import' );
    is_deeply( $rows, [], 'Malformed ProductForm CSV rows are not returned for saving' );
    like( $message_text, qr{Line 2 has no ONIX code\.}, 'Parser reports missing ONIX code' );
    like( $message_text, qr{Line 3 has 2 columns; expected 3\.}, 'Parser reports wrong column count' );

    ( $rows, $messages, $has_blocking_errors ) = $plugin->_parse_productform_mapping_csv("onix_code,productform,productform_alternative\n");

    ok( $has_blocking_errors, 'Header-only ProductForm CSV blocks import' );
    like( _message_text($messages), qr{No product form mappings found in CSV\.}, 'Parser reports an empty CSV import' );
};

subtest 'ProductForm CSV import groups blocking diagnostics into one alert' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my @messages;
    my %page_params;

    local *{ $plugin_class . '::_uploaded_productform_mapping_csv' } = sub { return 'bad csv'; };
    local *{ $plugin_class . '::_parse_productform_mapping_csv' } = sub {
        return (
            [],
            [
                $plugin->_configure_message( error   => 'Line 2 has no ONIX code.' ),
                $plugin->_configure_message( error   => 'Line 3 has 2 columns; expected 3.' ),
                $plugin->_configure_message( warning => "Line 4 repeats ONIX code 'AA'; the later value will win." ),
                $plugin->_configure_message(
                    error => "Line 5: ProductForm item type 'NOPE' does not exist in Koha; choose an existing item type or leave the field empty."
                ),
                $plugin->_configure_message(
                    error => "Line 6: ProductForm item type 'MISSING' does not exist in Koha; choose an existing item type or leave the field empty."
                ),
                $plugin->_configure_message(
                    error => "Line 7: ProductForm item type 'BAD' does not exist in Koha; choose an existing item type or leave the field empty."
                ),
            ],
            1
        );
    };
    local *{ $plugin_class . '::_productform_mapping_rows' } = sub { return [] };
    local *{ $plugin_class . '::_save_productform_mappings' } = sub { die 'Blocked ProductForm CSV import must not be saved'; };
    local *{ $plugin_class . '::_output_configure_page' } = sub {
        my ( $self, %params ) = @_;
        %page_params = %params;
        return;
    };

    ok(
        $plugin->_handle_productform_mapping_csv_import(
            cgi                  => bless( {}, 'KohaSuomi::Editx::TestCGI' ),
            messages             => \@messages,
            sftp_sources         => [],
            procurement_settings => {},
            nightly_sync_enabled => 0,
            runtime_log_level    => 'info',
        ),
        'Blocked ProductForm CSV import returns to configure page'
    );

    is( scalar @{ $page_params{messages} }, 1, 'Blocked ProductForm CSV import renders one grouped alert' );
    is( $page_params{messages}->[0]->{type}, 'error', 'Grouped ProductForm CSV alert is an error' );
    like(
        $page_params{messages}->[0]->{text},
        qr{ProductForm mapping CSV import blocked: 5 errors, 1 warning\.},
        'Grouped alert reports counts'
    );
    like( $page_params{messages}->[0]->{text}, qr{Line 2 has no ONIX code\.}, 'Grouped alert includes the first diagnostic' );
    like( $page_params{messages}->[0]->{text}, qr{Warning: Line 4 repeats ONIX code 'AA'}, 'Grouped alert keeps warning context' );
    like(
        $page_params{messages}->[0]->{text},
        qr{Line 6: ProductForm item type 'MISSING'},
        'Grouped alert includes diagnostics up to the display limit'
    );
    unlike(
        $page_params{messages}->[0]->{text},
        qr{Line 7: ProductForm item type 'BAD'},
        'Grouped alert omits diagnostics after the display limit'
    );
    like( $page_params{messages}->[0]->{text}, qr{1 more diagnostic was not shown\.}, 'Grouped alert reports omitted diagnostics' );
};

subtest 'ProductForm row add rejects an existing ONIX code' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new( counts => [1] );
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };

    my $messages = $plugin->_add_productform_mapping(
        {
            onix_code               => 'AA',
            productform             => 'BK',
            productform_alternative => undef,
        }
    );

    like( _message_text($messages), qr{ONIX code 'AA' already exists}, 'Adding a duplicate ONIX code returns a user-facing error' );
    is_deeply( $dbh->{prepared}, undef, 'Duplicate add does not prepare an insert' );
    is_deeply( $dbh->{executed}, undef, 'Duplicate add does not execute an insert' );
};

subtest 'ProductForm row add inserts a new ONIX code' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new( counts => [0] );
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };

    my $messages = $plugin->_add_productform_mapping(
        {
            onix_code               => 'AA',
            productform             => 'BK',
            productform_alternative => undef,
        }
    );
    my $sql = join "\n", @{ $dbh->{prepared} || [] };

    is( _message_text($messages), '', 'Adding a new ProductForm row succeeds without warnings' );
    like( $sql, qr{INSERT INTO `koha_plugin_fi_kohasuomi_editx_map_productform` \(onix_code, productform, productform_alternative\)\s+VALUES \(\?, \?, \?\)}s, 'Add inserts the new ProductForm mapping row' );
    unlike( $sql, qr{ON DUPLICATE KEY UPDATE}, 'Add does not upsert an existing ProductForm mapping row' );
    is_deeply( $dbh->{executed}->[0], [ $dbh->{prepared}->[0], 'AA', 'BK', undef ], 'Add binds the new mapping values' );
};

subtest 'ProductForm row update rejects changing ONIX code to an existing row' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new( counts => [1] );
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };

    my $messages = $plugin->_update_productform_mapping(
        'AA',
        {
            onix_code               => 'BB',
            productform             => 'BK',
            productform_alternative => undef,
        }
    );

    like( _message_text($messages), qr{ONIX code 'BB' already exists}, 'Updating a row to an existing ONIX code returns a user-facing error' );
    is_deeply( $dbh->{do_calls}, [], 'Conflicting edit does not update a row' );
    is_deeply( $dbh->{txn_calls}, undef, 'Conflicting edit does not start a transaction' );
};

subtest 'ProductForm row update does not delete before saving' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    my $dbh = KohaSuomi::Editx::TestDbh->new( counts => [1] );
    local *C4::Context::dbh = sub { return $dbh; };
    local *{ $plugin_class . '::get_qualified_table_name' } = sub {
        my ( $self, $table_name ) = @_;
        return "koha_plugin_fi_kohasuomi_editx_$table_name";
    };

    my $messages = $plugin->_update_productform_mapping(
        'AA',
        {
            onix_code               => 'AA',
            productform             => 'BK',
            productform_alternative => 'BK',
        }
    );
    my $sql = join "\n", @{ $dbh->{select_calls} }, @{ $dbh->{do_calls} };

    is( _message_text($messages), '', 'Updating an existing ProductForm row succeeds without warnings' );
    like( $sql, qr{SELECT COUNT\(\*\) FROM `koha_plugin_fi_kohasuomi_editx_map_productform` WHERE onix_code = \?}, 'Update verifies that the original ONIX code exists' );
    like( $sql, qr{UPDATE `koha_plugin_fi_kohasuomi_editx_map_productform`\s+SET onix_code = \?, productform = \?, productform_alternative = \?\s+WHERE onix_code = \?}s, 'Update modifies the existing row directly' );
    unlike( $sql, qr{DELETE FROM}, 'Update does not delete the original row before saving' );
    is_deeply( $dbh->{do_binds}->[0], [ 'AA', 'BK', 'BK', 'AA' ], 'Update binds the edited values and original ONIX code' );
    is_deeply( $dbh->{txn_calls}, [ 'begin_work', 'commit' ], 'Update commits after the direct update' );
};

subtest 'Configure URI keeps ProductForm focus before anchor' => sub {
    no strict 'refs';
    no warnings qw(once redefine);

    local *{ $plugin_class . '::plugin_method_url' } = sub {
        return '/cgi-bin/koha/plugins/run.pl?class=Plugin&method=configure';
    };

    is(
        $plugin->_configure_uri(
            anchor => 'ProductFormMappings',
            query  => { productform_focus => 'AA' },
        ),
        '/cgi-bin/koha/plugins/run.pl?class=Plugin&method=configure&productform_focus=AA#ProductFormMappings',
        'Configure URI appends ProductForm focus before the section fragment'
    );
};

done_testing();
