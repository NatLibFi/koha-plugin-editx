package Koha::Plugin::Fi::KohaSuomi::Editx;
## It's good practice to use Modern::Perl
use Modern::Perl;
## Required for all plugins
use base qw(Koha::Plugins::Base);
## We will also need to include any Koha libraries we want to access
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile tempdir);
use Fcntl qw(S_ISDIR);
use IO::Handle;
use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Patrons;
use Koha::Token;
use Koha::Plugin::Fi::KohaSuomi::Editx::Config;
use Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie;
use Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw(url_escape);
use Net::SFTP::Foreign;
use POSIX qw(strftime);
use Text::CSV_XS;
use XML::LibXML;
use YAML::XS qw(Load Dump);
use utf8;

use constant PRODUCTFORM_MAPPINGS_ANCHOR => 'ProductFormMappings';

## Here we set our plugin version
our $VERSION = "0.0.2";
## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'EDItX-plugin',
    author          => 'Lari Strand and Kansalliskirjasto Koha Dev Team',
    date_authored   => '2022-04-05',
    date_updated    => '1900-01-01',
    minimum_version => '23.11',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Adds EDItX functionality to Koha. KK version. (Paikalliskannat)',
};

our $INSTANCE = _instance_from_koha_conf_path( _guess_koha_conf_path() );

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;
    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual 
    my $self = $class->SUPER::new($args);
    return $self;
}
## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    $self->_log_runtime( info => 'EDItX plugin install started', { operation => 'install' } );
    $self->_log_runtime( info => 'EDItX plugin install creates qualified tables without legacy migration', { operation => 'install' } );
    my $success = $self->_install_or_upgrade_tables( migrate_legacy => 0 );
    $self->_log_runtime(
        $success ? 'info' : 'error',
        $success ? 'EDItX plugin install finished' : 'EDItX plugin install failed',
        { operation => 'install' }
    );

    return $success;
}

sub _install_or_upgrade_tables {
    my ( $self, %args ) = @_;

    my $dbh = C4::Context->dbh;
    my $migrate_legacy = $args{migrate_legacy} ? 1 : 0;
    my $sequences_table_name = $self->get_qualified_table_name('sequences');
    my $map_productform_table_name = $self->get_qualified_table_name('map_productform');
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

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    $self->_log_runtime( info => 'EDItX plugin upgrade started', { operation => 'upgrade' } );
    my $success = $self->_install_or_upgrade_tables( migrate_legacy => 1 );
    $self->_log_runtime(
        $success ? 'info' : 'error',
        $success ? 'EDItX plugin upgrade finished' : 'EDItX plugin upgrade failed',
        { operation => 'upgrade' }
    );

    return $success;
}
## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    my $success = 1;
    $success &&= $self->_drop_tables_if_exist(
        $self->get_qualified_table_name('sequences'),
        $self->get_qualified_table_name('map_productform')
    );

    $self->_log_runtime(
        $success ? 'info' : 'error',
        $success ? 'EDItX plugin uninstall removed plugin tables' : 'EDItX plugin uninstall failed while removing plugin tables',
        { operation => 'uninstall' }
    );

    return $success;
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my @messages;
    my $manual_sync_result;
    my $manual_run_attempted;
    my $manual_run_confirmation;
    my $manual_stage;

    if ( $cgi->request_method eq 'GET' && $cgi->param('manual_stage_run_id') ) {
        my $manual_messages;
        ( $manual_messages, $manual_stage, $manual_sync_result, $manual_run_attempted ) = $self->_manual_stage_resume($cgi);
        push @messages, @$manual_messages;
    } elsif ( $cgi->request_method eq 'POST' && $cgi->param('stage_check_remote') ) {
        my $manual_messages;
        ( $manual_messages, $manual_stage ) = $self->_manual_stage_check_remote($cgi);
        push @messages, @$manual_messages;
    } elsif ( $cgi->request_method eq 'POST' && $cgi->param('stage_download_selected') ) {
        my $manual_messages;
        ( $manual_messages, $manual_stage ) = $self->_manual_stage_download_selected($cgi);
        if ( $manual_stage && $manual_stage->{run_id} ) {
            print $cgi->redirect( $self->_manual_stage_url( $manual_stage->{run_id}, 'downloaded' ) );
            return;
        }
        push @messages, @$manual_messages;
    } elsif ( $cgi->request_method eq 'POST' && $cgi->param('stage_import_selected') ) {
        $manual_run_attempted = 1;
        my $manual_messages;
        ( $manual_messages, $manual_stage, $manual_sync_result ) = $self->_manual_stage_import_selected($cgi);
        if ( $manual_stage && $manual_stage->{run_id} && $manual_stage->{step} && $manual_stage->{step} eq 'imported' ) {
            print $cgi->redirect( $self->_manual_stage_url( $manual_stage->{run_id}, 'imported' ) );
            return;
        }
        push @messages, @$manual_messages;
    } elsif ( $cgi->request_method eq 'POST' && $cgi->param('run_sync_now') ) {
        $manual_run_attempted = 1;
        my $manual_messages;
        ( $manual_messages, $manual_sync_result ) = $self->_run_manual_sync_action($cgi);
        push @messages, @$manual_messages;
    } elsif ( $cgi->request_method eq 'POST' && $cgi->param('review_stage_check_remote') ) {
        my $manual_messages;
        ( $manual_messages, $manual_run_confirmation ) = $self->_manual_sync_confirmation( $cgi, action => 'stage_check_remote' );
        push @messages, @$manual_messages;
    }

    $self->_output_tool_page(
        messages                => \@messages,
        manual_sync_result      => $manual_sync_result,
        manual_run_attempted    => $manual_run_attempted,
        manual_run_confirmation => $manual_run_confirmation,
        manual_stage            => $manual_stage,
    );
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my @messages;
    my $is_save = $cgi->request_method eq 'POST' && $cgi->param('save');
    my $is_export_mapping_csv = $cgi->request_method eq 'POST' && $cgi->param('export_mapping_csv');
    my $is_import_mapping_csv = $cgi->request_method eq 'POST' && $cgi->param('import_mapping_csv');
    my $is_add_mapping_row = $cgi->request_method eq 'POST' && $cgi->param('add_mapping_row');
    my $is_update_mapping_row = $cgi->request_method eq 'POST' && $cgi->param('update_mapping_row');
    my $is_delete_mapping_row = $cgi->request_method eq 'POST' && $cgi->param('delete_mapping_row');
    my $is_mapping_action = $is_import_mapping_csv || $is_add_mapping_row || $is_update_mapping_row || $is_delete_mapping_row;
    my $flash = $cgi->request_method eq 'GET'
        ? Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->consume(
            {
                cgi       => $cgi,
                namespace => 'editx_configure',
            }
        )
        : {};
    if ( my $flash_message = $self->_configure_flash_message( $flash->{code} ) ) {
        push @messages, $flash_message;
    }

    my $runtime_log_level =
          $is_save
        ? Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->normalize_level( scalar $cgi->param('runtime_log_level') )
        : $self->_runtime_log_level();
    my $nightly_sync_enabled =
          $is_save
        ? ( $cgi->param('nightly_sync_enabled') ? 1 : 0 )
        : $self->_nightly_sync_enabled();
    my $sftp_sources =
          $is_save
        ? $self->_sftp_sources_from_cgi($cgi)
        : $self->_sftp_sources();
    my $procurement_settings =
          $is_save
        ? $self->_procurement_settings_from_cgi($cgi)
        : $self->_procurement_settings();

    if ($is_mapping_action) {
        my $handled = $self->_handle_productform_mapping_action(
            cgi                    => $cgi,
            messages               => \@messages,
            sftp_sources           => $sftp_sources,
            procurement_settings   => $procurement_settings,
            nightly_sync_enabled   => $nightly_sync_enabled,
            runtime_log_level      => $runtime_log_level,
        );
        return if $handled;
    }

    if ($is_export_mapping_csv) {
        if ( !$self->_csrf_token_valid($cgi) ) {
            push @messages, $self->_configure_message( error => 'ProductForm mapping CSV was not exported because the security token was invalid. Reload the page and try again.' );
            $self->_output_configure_page(
                mapping_rows           => $self->_productform_mapping_rows(),
                sftp_sources           => $sftp_sources,
                procurement_settings   => $procurement_settings,
                messages               => \@messages,
                nightly_sync_enabled   => $nightly_sync_enabled,
                runtime_log_level      => $runtime_log_level,
            );
            return;
        }

        $self->_output_productform_mapping_csv();
        return;
    }

    if ($is_save) {
        if ( !$self->_csrf_token_valid($cgi) ) {
            push @messages, $self->_configure_message( error => 'Configuration was not saved because the security token was invalid. Reload the page and try again.' );
            $self->_output_configure_page(
                mapping_rows           => $self->_productform_mapping_rows(),
                sftp_sources           => $sftp_sources,
                procurement_settings   => $procurement_settings,
                messages               => \@messages,
                nightly_sync_enabled   => $nightly_sync_enabled,
                runtime_log_level      => $runtime_log_level,
            );
            return;
        }

        my ( $normalized_sftp_sources, $sftp_messages, $has_sftp_blocking_errors ) = $self->_normalize_sftp_sources($sftp_sources);
        $sftp_sources = $normalized_sftp_sources;
        my ( $procurement_messages, $has_procurement_blocking_errors ) = $self->_validate_procurement_settings( $procurement_settings, $nightly_sync_enabled );
        push @messages, @$sftp_messages;
        push @messages, @$procurement_messages;
        my $has_blocking_errors = $has_sftp_blocking_errors;
        $has_blocking_errors ||= $has_procurement_blocking_errors;

        if ( !$has_blocking_errors && $nightly_sync_enabled ) {
            if ( !@$sftp_sources ) {
                push @messages, $self->_configure_message( error => 'Nightly sync is enabled but no SFTP sources are configured.' );
                $has_blocking_errors = 1;
            } else {
                for my $source (@$sftp_sources) {
                    next if $source->{local_dir} || $procurement_settings->{import_tmp_path};
                    push @messages, $self->_configure_message( error => "SFTP source '$source->{id}' has no local_dir and import_tmp_path is not set." );
                    $has_blocking_errors = 1;
                }
            }
        }

        if ($has_blocking_errors) {
            $self->_output_configure_page(
                mapping_rows           => $self->_productform_mapping_rows(),
                sftp_sources           => $sftp_sources,
                procurement_settings   => $procurement_settings,
                messages               => \@messages,
                nightly_sync_enabled   => $nightly_sync_enabled,
                runtime_log_level      => $runtime_log_level,
            );
            return;
        }
        $self->store_data(
            {
                nightly_sync_enabled => $nightly_sync_enabled,
                runtime_log_level    => $runtime_log_level,
                %{ Koha::Plugin::Fi::KohaSuomi::Editx::Config->store_data(
                    Koha::Plugin::Fi::KohaSuomi::Editx::Config->from_flat(
                        {
                            procurement_settings => $procurement_settings,
                            sftp_sources         => $sftp_sources,
                        }
                    )
                ) },
                last_configured_by   => ( C4::Context->userenv || {} )->{'number'},
                last_configured_at   => $self->_current_timestamp(),
            }
        );
        $self->_log_runtime(
            info => 'EDItX plugin configuration saved',
            {
                operation            => 'configure',
                nightly_sync_enabled => $nightly_sync_enabled,
                runtime_log_level    => $runtime_log_level,
            },
            { runtime_log_level => $runtime_log_level }
        );

        $self->_redirect_configure_with_flash('configuration_saved');
        return;
    }

    $self->_output_configure_page(
        mapping_rows           => $self->_productform_mapping_rows(),
        sftp_sources           => $sftp_sources,
        procurement_settings   => $procurement_settings,
        messages               => \@messages,
        nightly_sync_enabled   => $nightly_sync_enabled,
        runtime_log_level      => $runtime_log_level,
        cookies                => $flash->{cookie},
    );
}

sub cronjob_nightly {
    my ($self) = @_;

    unless ( $self->_nightly_sync_enabled() ) {
        $self->_log_runtime( info => 'EDItX nightly synchronization skipped because it is disabled', { operation => 'nightly', interface => 'cron' } );
        print "EDItX nightly synchronization is disabled in plugin configuration.\n";
        return 1;
    }

    $self->_log_runtime( info => 'EDItX nightly synchronization hook started', { operation => 'nightly', interface => 'cron' } );
    return $self->_run_nightly_sync();
}

sub static_routes {
    my ($self) = @_;

    return decode_json( $self->mbf_read('staticapi.json') );
}

sub api_namespace {
    return 'editx';
}

sub plugin_method_url {
    my ( $self, $method ) = @_;

    $method ||= 'tool';

    return '/cgi-bin/koha/plugins/run.pl?class='
        . url_escape( ref($self) || __PACKAGE__ )
        . '&method='
        . url_escape($method);
}

sub template_include_paths {
    my ($self) = @_;

    return [ $self->mbf_path('includes') ];
}

sub _migrate_legacy_sequences_table {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $target = $self->get_qualified_table_name('sequences');
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
    my $target = $self->get_qualified_table_name('map_productform');
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
    my $table_name = $self->get_qualified_table_name('map_productform');
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
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );

    return $dbh->do( "
        ALTER TABLE $map_productform_table
          MODIFY `productform` varchar(10) DEFAULT NULL,
          MODIFY `productform_alternative` varchar(10) DEFAULT NULL
    " );
}

sub _ensure_sequences_row {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $sequences_table = $self->_quote_identifier( $self->get_qualified_table_name('sequences') );
    my ($count) = $dbh->selectrow_array("SELECT COUNT(*) FROM $sequences_table");

    return 1 if $count;

    return $dbh->do("INSERT INTO $sequences_table (invoicenumber, item_barcode_nextval) VALUES (0, 0)");
}

sub _run_manual_sync_action {
    my ( $self, $cgi ) = @_;

    my @messages;
    my $manual_sync_result;

    if ( !$self->_csrf_token_valid($cgi) ) {
        push @messages, $self->_configure_message( error => 'Manual EDItX synchronization was not started because the security token was invalid. Reload the page and try again.' );
        $self->_log_runtime( warn => 'Manual EDItX synchronization rejected by invalid CSRF token', { operation => 'manual_sync', interface => 'staff' } );
        return ( \@messages, undef );
    }

    my $run_output;
    my $run_started_at = $self->_database_timestamp();
    $self->_log_runtime( info => 'Manual EDItX download and import started', { operation => 'manual_sync', interface => 'staff' } );
    my $success = eval {
        $run_output = $self->_run_nightly_sync_for_web();
        1;
    };
    my $run_error = $@;

    my $summary_loaded = eval {
        $manual_sync_result = $self->_manual_sync_result($run_started_at);
        1;
    };
    if ( !$summary_loaded ) {
        push @messages, $self->_configure_message( warning => 'Manual run finished, but the created order summary could not be loaded: ' . $self->_compact_message($@) );
        $self->_log_runtime( warn => 'Manual EDItX order summary could not be loaded', { operation => 'manual_sync', error => $self->_compact_message($@) } );
    }

    if ($success) {
        $self->_log_runtime(
            info => 'Manual EDItX download and import finished',
            {
                operation   => 'manual_sync',
                order_count => $manual_sync_result ? $manual_sync_result->{order_count} : undef,
                item_count  => $manual_sync_result ? $manual_sync_result->{item_count} : undef,
            }
        );
        push @messages, $self->_configure_message( success => 'Manual EDItX download and import finished.' );
        if ( my $summary = $self->_compact_message($run_output) ) {
            push @messages, $self->_configure_message( info => "Manual run output: $summary" );
        }
    } else {
        $self->_log_runtime( error => 'Manual EDItX download/import failed', { operation => 'manual_sync', error => $self->_compact_message($run_error) } );
        push @messages, $self->_configure_message( error => 'Manual EDItX download/import failed: ' . $self->_compact_message($run_error) );
    }

    return ( \@messages, $manual_sync_result );
}

sub _manual_sync_confirmation {
    my ( $self, $cgi, %params ) = @_;

    my @messages;
    my $action = $params{action} || 'run_sync_now';
    if ( !$self->_csrf_token_valid($cgi) ) {
        push @messages, $self->_configure_message( error => 'Manual EDItX synchronization confirmation was not prepared because the security token was invalid. Reload the page and try again.' );
        $self->_log_runtime( warn => 'Manual EDItX synchronization confirmation rejected by invalid CSRF token', { operation => 'manual_sync', interface => 'staff' } );
        return ( \@messages, undef );
    }

    my $procurement_settings = $self->_procurement_settings();
    my ( $procurement_messages, $has_procurement_errors ) = $self->_validate_procurement_settings( $procurement_settings, 1 );
    push @messages, @$procurement_messages;

    my ( $sources, $sftp_messages, $has_sftp_errors ) = $self->_normalize_sftp_sources( $self->_sftp_sources );
    push @messages, @$sftp_messages;
    if ( !@$sources ) {
        push @messages, $self->_configure_message( error => 'No EDItX SFTP sources are configured.' );
        $has_sftp_errors = 1;
    }
    if ( $action eq 'stage_check_remote' ) {
        my ( $selected_sources, $source_messages, $has_source_errors ) =
            $self->_manual_selected_sftp_sources( $cgi, $sources, require_selection => 1 );
        push @messages, @$source_messages;
        $sources = $selected_sources if !$has_source_errors;
        $has_sftp_errors ||= $has_source_errors;
    }

    return ( \@messages, undef ) if $has_procurement_errors || $has_sftp_errors;

    my @sources = map {
        my $local_dir = $_->{local_dir} || $procurement_settings->{import_tmp_path};
        {
            id             => $_->{id},
            host           => $_->{host},
            port           => $_->{port},
            user           => $_->{user},
            identity_file  => $_->{identity_file},
            remote_dir     => $_->{remote_dir},
            pattern        => $_->{pattern},
            local_dir      => $local_dir,
            local_dir_note => $_->{local_dir} ? 'SFTP source override' : 'Temporary download folder',
            after_download => $_->{after_download},
            remote_archive_dir => $_->{remote_archive_dir},
            known_hosts_file   => $_->{known_hosts_file},
        }
    } @$sources;

    my @folders = (
        { label => 'Temporary download folder', path => $procurement_settings->{import_tmp_path} },
        { label => 'Import load folder',        path => $procurement_settings->{import_load_path} },
        { label => 'Successful archive folder', path => $procurement_settings->{import_archive_path} },
        { label => 'Failed import folder',      path => $procurement_settings->{import_failed_path} },
        { label => 'Archived failed folder',    path => $procurement_settings->{import_failed_archived_path} },
    );

    return (
        \@messages,
        {
            sources      => \@sources,
            folders      => \@folders,
            action       => $action,
            title        => $action eq 'stage_check_remote' ? 'Confirm staged remote check' : 'Confirm manual download and import',
            description  => $action eq 'stage_check_remote' ? 'Review the saved configuration before checking remote EDItX files.' : 'Review the saved configuration that will be used for this run.',
            op           => $action eq 'stage_check_remote' ? 'cud-stage-check-remote' : 'cud-run-sync-now',
            input_name   => $action eq 'stage_check_remote' ? 'stage_check_remote' : 'run_sync_now',
            button_label => $action eq 'stage_check_remote' ? 'Confirm and check remote files' : 'Confirm and run import',
        }
    );
}

sub _manual_stage_check_remote {
    my ( $self, $cgi ) = @_;

    my @messages;
    if ( !$self->_csrf_token_valid($cgi) ) {
        push @messages, $self->_configure_message( error => 'Remote EDItX files were not checked because the security token was invalid. Reload the page and try again.' );
        return ( \@messages, undef );
    }

    my ( $procurement_settings, $sources, $config_messages, $has_errors ) = $self->_manual_stage_prerequisites($cgi);
    push @messages, @$config_messages;
    return ( \@messages, undef ) if $has_errors;

    my @files;
    for my $source (@$sources) {
        my $listed = eval { $self->_manual_stage_list_sftp_source( $source, $procurement_settings ) };
        if ( my $error = $@ ) {
            push @messages, $self->_configure_message( error => "Could not check remote files for source '$source->{id}': " . $self->_compact_message($error) );
            next;
        }
        push @files, @{ $listed->{files} };
        if ( !@{ $listed->{files} } ) {
            my $detail = "No remote EDItX files were parsed for source '$source->{id}' in $source->{remote_dir} using pattern '$source->{pattern}'.";
            if ( my $operation = $self->_compact_message( $listed->{sftp_operation} ) ) {
                $detail .= " SFTP operation: $operation.";
            }
            if ( my $summary = $self->_compact_message( $listed->{sftp_output} ) ) {
                $detail .= " SFTP output: $summary";
            } else {
                $detail .= " SFTP returned no listing details.";
            }
            push @messages, $self->_configure_message( warning => $detail );
        }
    }

    push @messages, $self->_configure_message( info => @files ? 'Remote EDItX files were checked. Select the files to download.' : 'No remote EDItX files matched the configured sources.' );

    return (
        \@messages,
        {
            step  => 'remote',
            title => 'Stage 1: Check remote files',
            files => \@files,
        }
    );
}

sub _manual_stage_resume {
    my ( $self, $cgi ) = @_;

    my @messages;
    my $run_id = scalar $cgi->param('manual_stage_run_id') // '';
    if ( !$self->_manual_stage_valid_run_id($run_id) ) {
        push @messages, $self->_configure_message( warning => 'The staged EDItX file list is no longer available. Check remote files again.' );
        return ( \@messages, undef, undef, undef );
    }

    my $manifest = eval { $self->_manual_stage_load_manifest($run_id) };
    if ( my $error = $@ ) {
        push @messages, $self->_configure_message( warning => 'The staged EDItX file list could not be loaded. Check remote files again. Details: ' . $self->_compact_message($error) );
        return ( \@messages, undef, undef, undef );
    }

    my $stage = $self->_manual_stage_manifest_for_template($manifest);
    my $status = scalar $cgi->param('stage_status') // '';
    if ( $status eq 'downloaded' ) {
        push @messages, $self->_configure_message( success => 'Selected EDItX files were downloaded for preview. Remote files were not changed.' );
    } elsif ( $status eq 'imported' && $manifest->{import_result} ) {
        # The imported stage renders its own result summary and skipped-file details.
    }

    my $manual_sync_result = $manifest->{manual_sync_result};
    return ( \@messages, $stage, $manual_sync_result, $manual_sync_result ? 1 : undef );
}

sub _manual_stage_download_selected {
    my ( $self, $cgi ) = @_;

    my @messages;
    if ( !$self->_csrf_token_valid($cgi) ) {
        push @messages, $self->_configure_message( error => 'Selected EDItX files were not downloaded because the security token was invalid. Reload the page and try again.' );
        return ( \@messages, undef );
    }

    my @selected = $cgi->multi_param('remote_file');
    if ( !@selected ) {
        push @messages, $self->_configure_message( warning => 'Select at least one remote EDItX file to download.' );
        return ( \@messages, undef );
    }

    my ( $procurement_settings, $sources, $config_messages, $has_errors ) = $self->_manual_stage_prerequisites();
    push @messages, @$config_messages;
    return ( \@messages, undef ) if $has_errors;

    my %sources_by_id = map { $_->{id} => $_ } @$sources;
    my %selected_by_source;
    for my $key (@selected) {
        my ( $source_id, $filename ) = $self->_manual_stage_parse_remote_key($key);
        if ( !$source_id || !$filename || !$sources_by_id{$source_id} || !$self->_manual_stage_safe_filename($filename) ) {
            push @messages, $self->_configure_message( error => 'One selected remote EDItX file was invalid. Refresh the file list and try again.' );
            return ( \@messages, undef );
        }
        push @{ $selected_by_source{$source_id} }, $filename;
    }

    my ( $run_id, $run_dir ) = $self->_manual_stage_create_run_dir($procurement_settings);
    my @downloaded;

    for my $source_id ( sort keys %selected_by_source ) {
        my $source = $sources_by_id{$source_id};
        my $downloaded = eval {
            $self->_manual_stage_download_sftp_files(
                $source,
                $procurement_settings,
                $run_dir,
                $selected_by_source{$source_id}
            );
        };
        if ( my $error = $@ ) {
            push @messages, $self->_configure_message( error => "Could not download EDItX files from source '$source_id': " . $self->_compact_message($error) );
            next;
        }
        push @downloaded, @$downloaded;
    }

    if ( !@downloaded ) {
        push @messages, $self->_configure_message( error => 'No selected EDItX files were downloaded.' );
        return ( \@messages, undef );
    }

    my @files = map { $self->_manual_stage_preview_file($_) } @downloaded;
    $self->_manual_stage_mark_batch_duplicates(\@files);
    my $manifest = {
        run_id     => $run_id,
        created_at => $self->_database_timestamp(),
        step       => 'downloaded',
        run_dir    => $run_dir,
        files      => \@files,
    };
    $self->_manual_stage_save_manifest($manifest);

    push @messages, $self->_configure_message( success => 'Selected EDItX files were downloaded for preview. Remote files were not changed.' );

    return (
        \@messages,
        {
            step    => 'downloaded',
            title   => 'Stage 2: Preview downloaded files',
            run_id  => $run_id,
            files   => \@files,
            summary => $self->_manual_stage_summary(\@files),
        }
    );
}

sub _manual_stage_import_selected {
    my ( $self, $cgi ) = @_;

    my @messages;
    if ( !$self->_csrf_token_valid($cgi) ) {
        push @messages, $self->_configure_message( error => 'Selected EDItX files were not imported because the security token was invalid. Reload the page and try again.' );
        return ( \@messages, undef, undef );
    }

    my $run_id = scalar $cgi->param('manual_stage_run_id') // '';
    my @selected_ids = $cgi->multi_param('stage_file');
    if ( !$self->_manual_stage_valid_run_id($run_id) ) {
        push @messages, $self->_configure_message( warning => 'The staged EDItX file list is no longer available. Check remote files again.' );
        return ( \@messages, undef, undef );
    }

    my $manifest = eval { $self->_manual_stage_load_manifest($run_id) };
    if ( my $error = $@ ) {
        push @messages, $self->_configure_message( warning => 'The staged EDItX file list could not be loaded. Check remote files again. Details: ' . $self->_compact_message($error) );
        return ( \@messages, undef, undef );
    }

    if ( !@selected_ids ) {
        push @messages, $self->_configure_message( warning => 'Select at least one downloaded EDItX file to import.' );
        return ( \@messages, $self->_manual_stage_manifest_for_template($manifest), undef );
    }

    my %selected = map { $_ => 1 } @selected_ids;
    my @files = grep { $selected{ $_->{id} } } @{ $manifest->{files} || [] };
    if ( !@files ) {
        push @messages, $self->_configure_message( warning => 'Selected staged EDItX files were not found. Refresh the remote file list and try again.' );
        return ( \@messages, $self->_manual_stage_manifest_for_template($manifest), undef );
    }

    my @invalid_files = grep { ( $_->{status} || '' ) ne 'valid' } @files;
    if (@invalid_files) {
        push @messages, $self->_configure_message( error => 'Selected EDItX files include invalid XML. Import only files with XML OK status.' );
        return ( \@messages, $self->_manual_stage_manifest_for_template($manifest), undef );
    }

    my @duplicate_files = grep { $_->{duplicate_import_blocked} } @files;
    if (@duplicate_files) {
        push @messages, $self->_configure_message( warning => 'Selected EDItX files include duplicate notices and were not imported. Review the existing Koha basket links in the preview.' );
        return ( \@messages, $self->_manual_stage_manifest_for_template($manifest), undef );
    }

    my @paths = map { $_->{local_path} } @files;
    my $run_started_at = $self->_database_timestamp();
    my $manual_sync_result;

    my $result = eval {
        require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner;
        Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::ImportRunner->new( { echo => 0 } )->run_file_paths(\@paths);
    };
    my $error = $@;

    if ($error) {
        push @messages, $self->_configure_message( error => 'Selected EDItX import failed: ' . $self->_compact_message($error) );
        return ( \@messages, $self->_manual_stage_manifest_for_template($manifest), undef );
    }
    $self->_manual_stage_enrich_import_result( $result, \@files );

    my $summary_loaded = eval {
        $manual_sync_result = $self->_manual_sync_result($run_started_at);
        1;
    };
    if ( !$summary_loaded ) {
        push @messages, $self->_configure_message( warning => 'Selected EDItX files were imported, but the created order summary could not be loaded: ' . $self->_compact_message($@) );
    }

    $manifest->{step} = 'imported';
    $manifest->{files} = \@files;
    $manifest->{import_result} = $result;
    $manifest->{manual_sync_result} = $manual_sync_result if $manual_sync_result;
    my $saved_import_manifest = eval { $self->_manual_stage_save_manifest($manifest); 1 };
    if ( !$saved_import_manifest ) {
        push @messages, $self->_configure_message( warning => 'Selected EDItX files were imported, but the staged import result could not be saved for reload-safe display: ' . $self->_compact_message($@) );
    }

    return (
        \@messages,
        {
            step          => 'imported',
            title         => 'Stage 3: Import selected files',
            run_id        => $run_id,
            files         => \@files,
            import_result => $result,
        },
        $manual_sync_result
    );
}

sub _manual_stage_enrich_import_result {
    my ( $self, $result, $files ) = @_;

    return $result if !$result || ref $result ne 'HASH';

    my %files_by_path = map {
        defined $_->{local_path} && $_->{local_path} ne '' ? ( $_->{local_path} => $_ ) : ()
    } @{ $files || [] };
    my @skipped_files;

    for my $skip ( @{ $result->{skipped_files} || [] } ) {
        my $file = $files_by_path{ $skip->{file} // '' };
        push @skipped_files, $self->_manual_stage_skipped_file_detail( $skip, $file );
    }

    if ( !@skipped_files && ( $result->{skipped} || 0 ) ) {
        for my $file ( grep { $_->{duplicate_import_blocked} } @{ $files || [] } ) {
            last if @skipped_files >= ( $result->{skipped} || 0 );
            push @skipped_files, $self->_manual_stage_skipped_file_detail(
                {
                    file        => $file->{local_path},
                    reason      => 'already_imported',
                    basket_name => $file->{ship_notice_number},
                    message     => 'File matched an existing Koha basket and was not imported.',
                },
                $file
            );
        }
    }

    $result->{skipped_files} = \@skipped_files if @skipped_files;

    return $result;
}

sub _manual_stage_skipped_file_detail {
    my ( $self, $skip, $file ) = @_;

    $skip ||= {};
    $file ||= {};

    return {
        file                  => $skip->{file} // $file->{local_path} // '',
        filename              => $file->{filename} // basename( $skip->{file} // '' ),
        source_id             => $file->{source_id} // '',
        reason                => $skip->{reason} // 'skipped',
        reason_label          => $self->_manual_stage_skip_reason_label( $skip, $file ),
        message               => $file->{duplicate_message} // $skip->{message} // '',
        ship_notice_number    => $file->{ship_notice_number} // $skip->{basket_name} // '',
        duplicate_status      => $file->{duplicate_status} // '',
        existing_basketno     => $file->{existing_basketno} // '',
        existing_basketname   => $file->{existing_basketname} // '',
        existing_basket_url   => $file->{existing_basket_url} // '',
        existing_vendor_name  => $file->{existing_vendor_name} // '',
        existing_vendor_url   => $file->{existing_vendor_url} // '',
        existing_order_count  => $file->{existing_order_count} // '',
        existing_item_count   => $file->{existing_item_count} // '',
        existing_order_range  => $file->{existing_order_range} // '',
    };
}

sub _manual_stage_skip_reason_label {
    my ( $self, $skip, $file ) = @_;

    return 'Another selected file has the same ShipNoticeNumber'
        if ( $file->{duplicate_status} // '' ) eq 'duplicate in preview';
    return 'Existing Koha basket has the same ShipNoticeNumber'
        if ( $skip->{reason} // '' ) eq 'already_imported';

    return 'Skipped by the importer';
}

sub _manual_stage_prerequisites {
    my ( $self, $cgi ) = @_;

    my @messages;
    my $procurement_settings = $self->_procurement_settings();
    my ( $procurement_messages, $has_procurement_errors ) = $self->_validate_procurement_settings( $procurement_settings, 1 );
    push @messages, @$procurement_messages;

    my ( $sources, $sftp_messages, $has_sftp_errors ) = $self->_normalize_sftp_sources( $self->_sftp_sources );
    push @messages, @$sftp_messages;
    if ( !@$sources ) {
        push @messages, $self->_configure_message( error => 'No EDItX SFTP sources are configured.' );
        $has_sftp_errors = 1;
    }
    if ($cgi) {
        my ( $selected_sources, $source_messages, $has_source_errors ) =
            $self->_manual_selected_sftp_sources( $cgi, $sources, require_selection => 0 );
        push @messages, @$source_messages;
        $sources = $selected_sources if !$has_source_errors;
        $has_sftp_errors ||= $has_source_errors;
    }

    return ( $procurement_settings, $sources, \@messages, $has_procurement_errors || $has_sftp_errors ? 1 : 0 );
}

sub _manual_selected_sftp_sources {
    my ( $self, $cgi, $sources, %params ) = @_;

    my @messages;
    my @selected_ids = grep { defined $_ && $_ ne q{} } $cgi->multi_param('manual_source_id');
    if ( !@selected_ids ) {
        return ( $sources, \@messages, 0 ) if !$params{require_selection};

        push @messages, $self->_configure_message( warning => 'Select at least one SFTP source to check.' );
        return ( [], \@messages, 1 );
    }

    my %sources_by_id = map { $_->{id} => $_ } @$sources;
    my %seen;
    my @selected_sources;
    my $has_errors = 0;
    for my $source_id (@selected_ids) {
        next if $seen{$source_id}++;
        if ( !$sources_by_id{$source_id} ) {
            push @messages, $self->_configure_message( error => "Selected SFTP source '$source_id' is no longer configured." );
            $has_errors = 1;
            next;
        }
        push @selected_sources, $sources_by_id{$source_id};
    }

    if ( !@selected_sources && !$has_errors ) {
        push @messages, $self->_configure_message( warning => 'Select at least one SFTP source to check.' );
        $has_errors = 1;
    }

    return ( \@selected_sources, \@messages, $has_errors ? 1 : 0 );
}

sub _manual_stage_source_options {
    my ( $self, $procurement_settings ) = @_;

    my ( $sources ) = $self->_normalize_sftp_sources( $self->_sftp_sources );
    return [
        map {
            {
                id     => $_->{id},
                remote => ( $_->{user} || q{} ) . '@' . ( $_->{host} || q{} ) . ':' . ( $_->{port} || q{} ) . ' ' . ( $_->{remote_dir} || q{} ),
            }
        } @$sources
    ];
}

sub _manual_stage_list_sftp_source {
    my ( $self, $source, $procurement_settings ) = @_;

    my $pattern = $source->{pattern} || '*.xml';
    my $remote_dir = $source->{remote_dir} || '/';
    my $sftp = $self->_manual_stage_sftp_connect($source);
    my $entries = $sftp->ls($remote_dir);
    if ( !$entries ) {
        my $error = $self->_manual_stage_sftp_error($sftp);
        $sftp->disconnect if $sftp->can('disconnect');
        die "Failed to list remote EDItX files in $remote_dir: $error\n";
    }

    my @files;
    for my $entry (@$entries) {
        my $filename = $entry->{filename} // '';
        next if !$self->_manual_stage_safe_filename($filename);
        my $attrs = $entry->{a};
        my $perm = eval { $attrs && $attrs->perm };
        next if defined $perm && S_ISDIR($perm);
        next if !$self->_manual_stage_filename_matches_pattern( $filename, $pattern );

        my $size = eval { $attrs && $attrs->size };
        $size = '' if !defined $size || $@;
        my $mtime = eval { $attrs && $attrs->mtime };
        my $modified = defined $mtime && !$@ ? strftime( '%Y-%m-%d %H:%M:%S', localtime($mtime) ) : '';
        my $local_dir = $source->{local_dir} || $procurement_settings->{import_tmp_path};
        my $local_path = $local_dir ? File::Spec->catfile( $local_dir, $filename ) : '';
        my $local_status = $local_path && -f $local_path ? 'downloaded' : 'remote only';

        push @files, {
            key          => $self->_manual_stage_remote_key( $source->{id}, $filename ),
            source_id    => $source->{id},
            filename     => $filename,
            size         => $size,
            modified     => $modified,
            local_status => $local_status,
            remote_dir   => $source->{remote_dir},
            after_action => 'manual keeps remote',
        };
    }
    $sftp->disconnect if $sftp->can('disconnect');

    return {
        files          => \@files,
        sftp_output    => @$entries ? scalar(@$entries) . ' remote entr' . ( @$entries == 1 ? 'y' : 'ies' ) . ' returned.' : 'Net::SFTP::Foreign returned an empty remote directory listing.',
        sftp_operation => "Net::SFTP::Foreign ls($remote_dir)",
    };
}

sub _manual_stage_download_sftp_files {
    my ( $self, $source, $procurement_settings, $run_dir, $filenames ) = @_;

    my $source_dir = File::Spec->catdir( $run_dir, $source->{id} );
    make_path($source_dir) if !-d $source_dir;
    my $remote_dir = $source->{remote_dir} || '';
    $remote_dir =~ s{/+\z}{};
    my $sftp = $self->_manual_stage_sftp_connect($source);

    my @downloaded;
    for my $filename (@$filenames) {
        my $local_path = File::Spec->catfile( $source_dir, $filename );
        my $remote_path = $remote_dir eq '' || $remote_dir eq '/' ? "/$filename" : "$remote_dir/$filename";
        if ( !$sftp->get( $remote_path, $local_path ) ) {
            my $error = $self->_manual_stage_sftp_error($sftp);
            $sftp->disconnect if $sftp->can('disconnect');
            die "Selected EDItX file was not downloaded: $filename: $error\n";
        }
        die "Selected EDItX file was not downloaded: $filename\n" if !-f $local_path;
        push @downloaded, {
            id          => $self->_manual_stage_file_id( $source->{id}, $filename ),
            source_id   => $source->{id},
            source_name => $source->{id},
            remote_file => $filename,
            filename    => $filename,
            local_path  => $local_path,
        };
    }
    $sftp->disconnect if $sftp->can('disconnect');

    return \@downloaded;
}

sub _manual_stage_sftp_connect {
    my ( $self, $source ) = @_;

    my $stderr = '';
    open my $stderr_fh, '>', \$stderr or die "Cannot capture SFTP stderr: $!";

    my @more = ( '-o', 'BatchMode=yes' );
    push @more, ( '-F', $source->{ssh_config} ) if $source->{ssh_config};
    push @more, ( '-o', 'UserKnownHostsFile=' . $source->{known_hosts_file} ) if $source->{known_hosts_file};
    push @more, ( '-o', 'StrictHostKeyChecking=' . ( $source->{strict_host_key_checking} || 'yes' ) );

    my $sftp = Net::SFTP::Foreign->new(
        host      => $source->{host},
        port      => $source->{port} || 22,
        user      => $source->{user},
        timeout   => 30,
        stderr_fh => $stderr_fh,
        more      => \@more,
        $source->{identity_file} ? ( key_path => $source->{identity_file} ) : (),
    );
    $sftp->{_editx_stderr_fh}      = $stderr_fh;
    $sftp->{_editx_stderr_capture} = \$stderr;

    die 'SFTP connection failed for ' . $source->{user} . '@' . $source->{host} . ': ' . $self->_manual_stage_sftp_error($sftp) . "\n" if $sftp->error;

    return $sftp;
}

sub _manual_stage_sftp_error {
    my ( $self, $sftp ) = @_;

    my $error = eval { $sftp->error };
    $error = '' if !defined $error || $error eq '0';
    my $stderr_ref = eval { $sftp->{_editx_stderr_capture} };
    my $stderr = $stderr_ref && ref $stderr_ref eq 'SCALAR' ? $$stderr_ref : '';
    $stderr =~ s/\s+\z// if defined $stderr;
    return join( ' ', grep { defined $_ && $_ ne '' } ( $error, $stderr ) ) || 'unknown SFTP error';
}

sub _manual_stage_preview_file {
    my ( $self, $file ) = @_;

    my %preview = %$file;
    $preview{status} = 'valid';

    my $doc = eval { XML::LibXML->new( no_network => 1 )->parse_file( $file->{local_path} ) };
    if ( my $error = $@ ) {
        $preview{status} = 'invalid';
        $preview{error} = $self->_compact_message($error);
        return \%preview;
    }

    my @items = $doc->findnodes('/LibraryShipNotice/ItemDetail');
    my ( %product_forms, %currencies, $copy_count, $estimated_total );
    for my $item (@items) {
        my $product_form = $self->_manual_stage_node_value( $item, 'ItemDescription/ProductForm' );
        $product_forms{$product_form}++ if $product_form ne '';

        my $price = $self->_manual_stage_node_value( $item, 'PricingDetail/Price[PriceQualifierCode/text() = "FixedRPExcludingTax"]/MonetaryAmount' );
        my $currency = $self->_manual_stage_node_value( $item, 'PricingDetail/Price[PriceQualifierCode/text() = "FixedRPExcludingTax"]/CurrencyCode' );
        $currencies{$currency}++ if $currency ne '';

        my $item_copy_count = 0;
        for my $copy ( $item->findnodes('CopyDetail') ) {
            my $quantity = $self->_manual_stage_node_value( $copy, 'CopyQuantity' );
            $quantity = 0 if $quantity !~ /\A\d+(?:\.\d+)?\z/;
            $item_copy_count += $quantity;
        }
        $copy_count += $item_copy_count;
        $estimated_total += $price * $item_copy_count if $price =~ /\A\d+(?:\.\d+)?\z/;
    }

    my $vendor_assigned_id = $self->_manual_stage_node_value( $doc, '/LibraryShipNotice/Header/BuyerParty/PartyID[PartyIDType/text() = "VendorAssignedID"]/Identifier' );
    my $buyer_assigned_id  = $self->_manual_stage_node_value( $doc, '/LibraryShipNotice/Header/SellerParty/PartyID[PartyIDType/text() = "BuyerAssignedID"]/Identifier' );
    my $vendor = eval {
        require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount;
        my ( $san, $qualifier ) = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount->identifier_from_values( $vendor_assigned_id, $buyer_assigned_id );
        Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::VendorEdiAccount->find_vendor(
            {
                san       => $san,
                qualifier => $qualifier,
            }
        );
    };

    $preview{document_type}      = $doc->documentElement ? $doc->documentElement->nodeName : '';
    $preview{ship_notice_number} = $self->_manual_stage_node_value( $doc, '/LibraryShipNotice/Header/ShipNoticeNumber' );
    $preview{seller_name}        = $self->_manual_stage_node_value( $doc, '/LibraryShipNotice/Header/SellerParty/PartyName/NameLine' );
    $preview{buyer_contact}      = $self->_manual_stage_node_value( $doc, '/LibraryShipNotice/Header/BuyerParty/ContactPerson/PersonName' );
    $preview{vendor_assigned_id} = $vendor_assigned_id;
    $preview{buyer_assigned_id}  = $buyer_assigned_id;
    $preview{item_count}         = scalar @items;
    $preview{copy_count}         = $copy_count || 0;
    $preview{product_forms}      = join( ', ', sort keys %product_forms );
    $preview{currencies}         = join( ', ', sort keys %currencies );
    $preview{estimated_total}    = defined $estimated_total ? sprintf( '%.2f', $estimated_total ) : '';
    my $existing_basket = $self->_manual_stage_existing_basket( $preview{ship_notice_number} );
    if ($existing_basket) {
        $preview{duplicate_status} = 'duplicate basket';
        $preview{duplicate_message} = 'Basket ' . $existing_basket->{basketno} . ' already exists for this ShipNoticeNumber.';
        $preview{duplicate_import_blocked} = 1;
        $self->_manual_stage_apply_existing_basket_preview( \%preview, $existing_basket );
    } else {
        $preview{duplicate_status} = 'new';
        $preview{duplicate_import_blocked} = 0;
    }
    $preview{vendor_status}      = $vendor && ref $vendor eq 'HASH' ? $vendor->{status} : 'error';
    $preview{vendor_message}     = $vendor && ref $vendor eq 'HASH' ? ( $vendor->{message} // '' ) : $self->_compact_message($@);

    return \%preview;
}

sub _manual_stage_node_value {
    my ( $self, $node, $xpath ) = @_;

    my $value = eval { $node->findvalue($xpath) };
    $value = '' if !defined $value || $@;
    $value =~ s/\A\s+|\s+\z//g;
    $value =~ s/\s+/ /g;
    return "$value";
}

sub _manual_stage_summary {
    my ( $self, $files ) = @_;

    my $files_count = scalar @$files;
    my $item_count = 0;
    my $copy_count = 0;
    for my $file (@$files) {
        $item_count += $file->{item_count} || 0;
        $copy_count += $file->{copy_count} || 0;
    }

    return {
        files => $files_count,
        items => $item_count,
        copies => $copy_count,
    };
}

sub _manual_stage_mark_batch_duplicates {
    my ( $self, $files ) = @_;

    my %seen_notice;
    for my $file (@$files) {
        next if ( $file->{status} || '' ) ne 'valid';
        my $ship_notice_number = $file->{ship_notice_number} // '';
        next if $ship_notice_number eq '';

        if ( $file->{duplicate_import_blocked} ) {
            $seen_notice{$ship_notice_number} ||= $file;
            next;
        }

        if ( my $first = $seen_notice{$ship_notice_number} ) {
            $file->{duplicate_status} = 'duplicate in preview';
            $file->{duplicate_message} = 'Another downloaded file in this preview has the same ShipNoticeNumber';
            $file->{duplicate_message} .= ': ' . ( $first->{filename} // 'unknown file' ) . '.';
            $file->{duplicate_import_blocked} = 1;
            next;
        }

        $seen_notice{$ship_notice_number} = $file;
    }

    return $files;
}

sub _manual_stage_create_run_dir {
    my ( $self, $procurement_settings ) = @_;

    my $base_dir = $self->_manual_stage_base_dir($procurement_settings);
    make_path($base_dir) if !-d $base_dir;
    my $run_dir = tempdir( 'run-XXXXXX', DIR => $base_dir, CLEANUP => 0 );
    my $run_id = basename($run_dir);

    return ( $run_id, $run_dir );
}

sub _manual_stage_base_dir {
    my ( $self, $procurement_settings ) = @_;

    $procurement_settings ||= $self->_procurement_settings();
    my $tmp_path = $procurement_settings->{import_tmp_path};
    die 'Temporary download folder is not configured.' if !$tmp_path;
    return File::Spec->catdir( $tmp_path, '.manual' );
}

sub _manual_stage_manifest_path {
    my ( $self, $run_id ) = @_;

    die 'Invalid manual EDItX staging run id.' if !$self->_manual_stage_valid_run_id($run_id);
    return File::Spec->catfile( $self->_manual_stage_base_dir(), $run_id, 'manifest.json' );
}

sub _manual_stage_valid_run_id {
    my ( $self, $run_id ) = @_;

    return $run_id && $run_id =~ /\Arun-[A-Za-z0-9_]+\z/ ? 1 : 0;
}

sub _manual_stage_save_manifest {
    my ( $self, $manifest ) = @_;

    my $path = $self->_manual_stage_manifest_path( $manifest->{run_id} );
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write EDItX staging manifest $path: $!";
    print {$fh} encode_json($manifest);
    close $fh or die "Cannot close EDItX staging manifest $path: $!";
    return 1;
}

sub _manual_stage_load_manifest {
    my ( $self, $run_id ) = @_;

    my $path = $self->_manual_stage_manifest_path($run_id);
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read EDItX staging manifest $path: $!";
    my $json = do { local $/; <$fh> };
    close $fh;
    return decode_json($json);
}

sub _manual_stage_load_for_template {
    my ( $self, $run_id ) = @_;

    return $self->_manual_stage_manifest_for_template( $self->_manual_stage_load_manifest($run_id) );
}

sub _manual_stage_manifest_for_template {
    my ( $self, $manifest ) = @_;

    my $files = $manifest->{files} || [];
    if ( ( $manifest->{step} || '' ) eq 'imported' ) {
        return {
            step          => 'imported',
            title         => 'Stage 3: Import selected files',
            run_id        => $manifest->{run_id},
            files         => $files,
            import_result => $manifest->{import_result},
        };
    }

    return {
        step    => 'downloaded',
        title   => 'Stage 2: Preview downloaded files',
        run_id  => $manifest->{run_id},
        files   => $files,
        summary => $self->_manual_stage_summary($files),
    };
}

sub _manual_stage_url {
    my ( $self, $run_id, $status ) = @_;

    return $self->plugin_method_url('tool')
        . '&manual_stage_run_id=' . url_escape($run_id)
        . '&stage_status=' . url_escape( $status || '' );
}

sub _manual_stage_remote_key {
    my ( $self, $source_id, $filename ) = @_;

    return $source_id . '::' . $filename;
}

sub _manual_stage_parse_remote_key {
    my ( $self, $key ) = @_;

    return split /::/, $key || '', 2;
}

sub _manual_stage_file_id {
    my ( $self, $source_id, $filename ) = @_;

    my $id = "$source_id--$filename";
    $id =~ s/[^A-Za-z0-9_.-]/_/g;
    return $id;
}

sub _manual_stage_safe_filename {
    my ( $self, $filename ) = @_;

    return defined $filename && $filename ne '' && $filename !~ m{[\\/\0]} && $filename !~ /\A\./;
}

sub _manual_stage_sftp_glob {
    my ( $self, $pattern ) = @_;

    $pattern //= '*.xml';
    die "Invalid EDItX SFTP file pattern: $pattern\n" if $pattern !~ /\A[A-Za-z0-9_.?*\[\]-]+\z/;
    return $pattern;
}

sub _manual_stage_filename_matches_pattern {
    my ( $self, $filename, $pattern ) = @_;

    return 0 if !$filename;
    $pattern = $self->_manual_stage_sftp_glob($pattern);

    my $regex = quotemeta($pattern);
    $regex =~ s/\\\*/.*/g;
    $regex =~ s/\\\?/./g;

    return $filename =~ /\A$regex\z/ ? 1 : 0;
}

sub _manual_stage_existing_basket {
    my ( $self, $basket_name ) = @_;

    return if !defined $basket_name || $basket_name eq '';

    my $basket = C4::Context->dbh->selectrow_hashref(
        q{
            SELECT
                b.basketno,
                b.basketname,
                b.booksellerid,
                v.name AS vendor_name,
                COUNT(o.ordernumber) AS order_count,
                COALESCE(SUM(o.quantity), 0) AS item_count,
                MIN(o.ordernumber) AS first_ordernumber,
                MAX(o.ordernumber) AS last_ordernumber
            FROM aqbasket b
            LEFT JOIN aqbooksellers v ON v.id = b.booksellerid
            LEFT JOIN aqorders o ON o.basketno = b.basketno
            WHERE b.basketname = ?
            GROUP BY b.basketno, b.basketname, b.booksellerid, v.name
            ORDER BY b.basketno DESC
            LIMIT 1
        },
        undef,
        $basket_name
    );

    return $self->_manual_stage_prepare_existing_basket($basket);
}

sub _manual_stage_prepare_existing_basket {
    my ( $self, $basket ) = @_;

    return if !$basket;

    $basket->{basket_url} = '/cgi-bin/koha/acqui/basket.pl?basketno=' . url_escape( $basket->{basketno} )
        if defined $basket->{basketno};
    $basket->{vendor_url} = '/cgi-bin/koha/acqui/booksellers.pl?booksellerid=' . url_escape( $basket->{booksellerid} )
        if defined $basket->{booksellerid};
    if ( defined $basket->{first_ordernumber} && defined $basket->{last_ordernumber} ) {
        $basket->{order_range} = $basket->{first_ordernumber} eq $basket->{last_ordernumber}
            ? $basket->{first_ordernumber}
            : $basket->{first_ordernumber} . '-' . $basket->{last_ordernumber};
    }

    return $basket;
}

sub _manual_stage_apply_existing_basket_preview {
    my ( $self, $preview, $basket ) = @_;

    return if !$preview || !$basket;

    $preview->{existing_basketno}    = $basket->{basketno} // '';
    $preview->{existing_basketname}  = $basket->{basketname} // '';
    $preview->{existing_basket_url}  = $basket->{basket_url} // '';
    $preview->{existing_vendor_name} = $basket->{vendor_name} // '';
    $preview->{existing_vendor_url}  = $basket->{vendor_url} // '';
    $preview->{existing_order_count} = $basket->{order_count} // '';
    $preview->{existing_item_count}  = $basket->{item_count} // '';
    $preview->{existing_order_range} = $basket->{order_range} // '';

    return $preview;
}

sub _tool_sftp_status {
    my ( $self, $procurement_settings ) = @_;

    my ( $sources, $messages, $has_errors ) = $self->_normalize_sftp_sources( $self->_sftp_sources );
    my $default_local_dir = $procurement_settings->{import_tmp_path} // '';

    if ( !$has_errors && !@$sources ) {
        push @$messages, $self->_configure_message( warning => 'No SFTP sources are saved in the EDItX plugin configuration.' );
        $has_errors = 1;
    }

    for my $source (@$sources) {
        next if $source->{local_dir} || $default_local_dir;
        push @$messages, $self->_configure_message( warning => "SFTP source '$source->{id}' has no local_dir and import_tmp_path is not set." );
        $has_errors = 1;
    }

    return {
        count      => scalar @$sources,
        has_errors => $has_errors ? 1 : 0,
        messages   => $messages,
    };
}

sub _output_tool_page {
    my ( $self, %params ) = @_;

    my $procurement_settings = $self->_procurement_settings();
    my $sftp_status = $self->_tool_sftp_status($procurement_settings);
    my $template = $self->get_template( { file => 'tool.tt' } );
    $template->param(
        messages               => $params{messages},
        manual_sync_result     => $params{manual_sync_result},
        manual_run_attempted   => $params{manual_run_attempted},
        manual_run_confirmation => $params{manual_run_confirmation},
        manual_stage           => $params{manual_stage},
        manual_stage_sources   => $self->_manual_stage_source_options($procurement_settings),
        nightly_sync_enabled   => $self->_nightly_sync_enabled(),
        procurement_settings   => $procurement_settings,
        sftp_sources_count     => $sftp_status->{count},
        sftp_config_has_errors => $sftp_status->{has_errors},
        sftp_config_messages   => $sftp_status->{messages},
        manual_run_available   => !$sftp_status->{has_errors} && $sftp_status->{count} ? 1 : 0,
        configure_href         => $self->plugin_method_url('configure'),
        tool_href              => $self->plugin_method_url('tool'),
        plugin_display_version => $self->plugin_display_version(),
    );

    return $self->output_html( $template->output() );
}

sub _output_configure_page {
    my ( $self, %params ) = @_;

    my $template = $self->get_template( { file => 'configure.tt' } );
    my $itemtypes = $self->_itemtypes();
    $template->param(
        mapping_rows           => $params{mapping_rows},
        mapping_editor         => $params{mapping_editor},
        sftp_sources           => $params{sftp_sources},
        procurement_settings   => $params{procurement_settings},
        messages               => $params{messages},
        nightly_sync_enabled   => $params{nightly_sync_enabled},
        itemtypes              => $itemtypes,
        itemtypes_text         => join( ', ', @{$itemtypes} ),
        locations_text         => join( ', ', @{ $self->_authorised_values('LOC') } ),
        branches_text          => join( ', ', @{ $self->_branches() } ),
        last_configured_by     => scalar $self->_last_configured_by_context(),
        last_configured_at     => scalar $self->retrieve_data('last_configured_at'),
        last_upgraded          => scalar $self->retrieve_data('last_upgraded'),
        recommended_import_paths => $self->_recommended_import_paths(),
        recommended_sftp_paths   => $self->_recommended_sftp_paths(),
        configure_href         => $self->plugin_method_url('configure'),
        tool_href              => $self->plugin_method_url('tool'),
        plugin_display_version => $self->plugin_display_version(),
        runtime_log_level      => $params{runtime_log_level} || $self->_runtime_log_level(),
        runtime_log_levels     => Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->levels,
        runtime_log_path       => Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->path,
        runtime_log_tail       => Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->tail,
    );

    return $self->output_html(
        $template->output(),
        undef,
        undef,
        undef,
        Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->merge_cookies(
            $self->{_auth_cookies},
            $params{cookies},
        )
    );
}

sub _output_productform_mapping_csv {
    my ($self) = @_;

    my $cgi = $self->{'cgi'};
    print $cgi->header(
        -type       => 'text/csv; charset=utf-8',
        -attachment => 'editx-productform-mappings.csv',
    );
    print $self->_productform_mapping_csv();

    return;
}

sub _handle_productform_mapping_action {
    my ( $self, %params ) = @_;

    my $cgi = $params{cgi};
    my $messages = $params{messages} || [];

    if ( !$self->_csrf_token_valid($cgi) ) {
        push @{$messages}, $self->_configure_message( error => 'ProductForm mapping was not changed because the security token was invalid. Reload the page and try again.' );
        $self->_output_configure_page(
            mapping_rows           => $self->_productform_mapping_rows(),
            mapping_editor         => $self->_productform_mapping_editor_from_cgi($cgi),
            sftp_sources           => $params{sftp_sources},
            procurement_settings   => $params{procurement_settings},
            messages               => $messages,
            nightly_sync_enabled   => $params{nightly_sync_enabled},
            runtime_log_level      => $params{runtime_log_level},
        );
        return 1;
    }

    if ( $cgi->param('import_mapping_csv') ) {
        return $self->_handle_productform_mapping_csv_import(%params);
    }

    if ( $cgi->param('delete_mapping_row') ) {
        my $onix_code = $self->_trim_csv_value( scalar $cgi->param('delete_mapping_row') );
        my $delete_messages = $self->_delete_productform_mapping($onix_code);
        push @{$messages}, @{$delete_messages};
        if ( @{$delete_messages} ) {
            $self->_output_configure_page(
                mapping_rows           => $self->_productform_mapping_rows(),
                sftp_sources           => $params{sftp_sources},
                procurement_settings   => $params{procurement_settings},
                messages               => $messages,
                nightly_sync_enabled   => $params{nightly_sync_enabled},
                runtime_log_level      => $params{runtime_log_level},
            );
            return 1;
        }

        $self->_store_last_configured_by();
        $self->_redirect_configure_with_flash( 'productform_mapping_deleted', PRODUCTFORM_MAPPINGS_ANCHOR );
        return 1;
    }

    my ( $row, $original_mapping_onix_code, $mapping_editor, $action_code );
    if ( $cgi->param('update_mapping_row') ) {
        $row = $self->_productform_mapping_row_from_cgi( $cgi, 'add_mapping', 'Mapping row' );
        $original_mapping_onix_code = $self->_trim_csv_value( scalar $cgi->param('mapping_original_onix_code') );
        $mapping_editor = $self->_productform_mapping_editor_from_cgi($cgi);
        $action_code = 'productform_mapping_updated';
    } else {
        $row = $self->_productform_mapping_row_from_cgi( $cgi, 'add_mapping', 'New mapping row' );
        $mapping_editor = $self->_productform_mapping_editor_from_cgi($cgi);
        $action_code = 'productform_mapping_added';
    }

    my ( $rows, $row_messages, $has_blocking_errors ) = $self->_normalize_productform_mapping_rows( [$row] );
    push @{$messages}, @{$row_messages};
    if ($has_blocking_errors) {
        $self->_output_configure_page(
            mapping_rows           => $self->_productform_mapping_rows(),
            sftp_sources           => $params{sftp_sources},
            procurement_settings   => $params{procurement_settings},
            messages               => $messages,
            nightly_sync_enabled   => $params{nightly_sync_enabled},
            runtime_log_level      => $params{runtime_log_level},
            mapping_editor         => $mapping_editor,
        );
        return 1;
    }

    my $save_messages = $cgi->param('update_mapping_row')
        ? $self->_update_productform_mapping( $original_mapping_onix_code, $rows->[0] )
        : $self->_add_productform_mapping( $rows->[0] );
    push @{$messages}, @{$save_messages};
    if ( @{$save_messages} ) {
        $self->_output_configure_page(
            mapping_rows           => $self->_productform_mapping_rows(),
            sftp_sources           => $params{sftp_sources},
            procurement_settings   => $params{procurement_settings},
            messages               => $messages,
            nightly_sync_enabled   => $params{nightly_sync_enabled},
            runtime_log_level      => $params{runtime_log_level},
            mapping_editor         => $mapping_editor,
        );
        return 1;
    }

    $self->_store_last_configured_by();
    $self->_redirect_configure_with_flash(
        $action_code,
        PRODUCTFORM_MAPPINGS_ANCHOR,
        { productform_focus => $rows->[0]->{onix_code} }
    );
    return 1;
}

sub _handle_productform_mapping_csv_import {
    my ( $self, %params ) = @_;

    my $cgi = $params{cgi};
    my $messages = $params{messages} || [];
    my $mapping_csv_import = $self->_uploaded_productform_mapping_csv($cgi);

    if ( !defined $mapping_csv_import ) {
        push @{$messages}, $self->_configure_message( error => 'Choose a ProductForm mapping CSV file before importing.' );
        $self->_output_configure_page(
            mapping_rows         => $self->_productform_mapping_rows(),
            sftp_sources         => $params{sftp_sources},
            procurement_settings => $params{procurement_settings},
            messages             => $messages,
            nightly_sync_enabled => $params{nightly_sync_enabled},
            runtime_log_level    => $params{runtime_log_level},
        );
        return 1;
    }

    my ( $rows, $parse_messages, $has_blocking_errors ) = $self->_parse_productform_mapping_csv($mapping_csv_import);
    push @{$messages}, @{$parse_messages};
    if ($has_blocking_errors) {
        $self->_output_configure_page(
            mapping_rows         => $self->_productform_mapping_rows(),
            sftp_sources         => $params{sftp_sources},
            procurement_settings => $params{procurement_settings},
            messages             => $messages,
            nightly_sync_enabled => $params{nightly_sync_enabled},
            runtime_log_level    => $params{runtime_log_level},
        );
        return 1;
    }

    my $save_messages = $self->_save_productform_mappings($rows);
    push @{$messages}, @{$save_messages};
    if ( @{$save_messages} ) {
        $self->_output_configure_page(
            mapping_rows         => $self->_productform_mapping_rows(),
            sftp_sources         => $params{sftp_sources},
            procurement_settings => $params{procurement_settings},
            messages             => $messages,
            nightly_sync_enabled => $params{nightly_sync_enabled},
            runtime_log_level    => $params{runtime_log_level},
        );
        return 1;
    }

    $self->_store_last_configured_by();
    $self->_redirect_configure_with_flash( 'productform_mapping_imported', PRODUCTFORM_MAPPINGS_ANCHOR );
    return 1;
}

sub _redirect_configure_with_flash {
    my ( $self, $code, $anchor, $query ) = @_;

    Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->redirect_with_flash(
        {
            cgi       => $self->{'cgi'},
            uri       => $self->_configure_uri( anchor => $anchor, query => $query ),
            namespace => 'editx_configure',
            code      => $code,
            cookies   => $self->{_auth_cookies},
        }
    );

    return;
}

sub _configure_uri {
    my ( $self, %params ) = @_;

    my $uri = $self->plugin_method_url('configure');
    if ( my $query = $params{query} ) {
        for my $name ( sort keys %{$query} ) {
            next unless $name =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
            my $value = $query->{$name};
            next unless defined $value && length $value;
            $uri .= ( $uri =~ /\?/ ? '&' : '?' ) . url_escape($name) . '=' . url_escape($value);
        }
    }

    my $anchor = $params{anchor};
    $uri .= '#' . $anchor if defined $anchor && $anchor =~ /\A[A-Za-z][A-Za-z0-9_-]*\z/;

    return $uri;
}

sub _configure_flash_message {
    my ( $self, $code ) = @_;

    return unless defined $code && length $code;

    my %messages = (
        configuration_saved          => [ success => 'EDItX plugin configuration saved.' ],
        productform_mapping_added    => [ success => 'ProductForm mapping row added.' ],
        productform_mapping_updated  => [ success => 'ProductForm mapping row updated.' ],
        productform_mapping_deleted  => [ success => 'ProductForm mapping row deleted.' ],
        productform_mapping_imported => [ success => 'ProductForm mapping CSV imported.' ],
    );

    return unless $messages{$code};

    return $self->_configure_message( @{ $messages{$code} } );
}

sub _store_last_configured_by {
    my ($self) = @_;

    $self->store_data(
        {
            last_configured_by => ( C4::Context->userenv || {} )->{'number'},
            last_configured_at => $self->_current_timestamp(),
        }
    );

    return;
}

sub _current_timestamp {
    my ($self) = @_;

    my $dt = dt_from_string();
    return $dt->ymd('-') . ' ' . $dt->hms(':');
}

sub _last_configured_by_context {
    my ($self) = @_;

    my $borrowernumber = $self->retrieve_data('last_configured_by');
    return unless defined $borrowernumber && length $borrowernumber;

    my $patron = eval { Koha::Patrons->find($borrowernumber) };
    if ($patron) {
        my $label = join q{ }, grep { defined $_ && length $_ } ( $patron->firstname, $patron->surname );
        $label ||= $patron->cardnumber;
        $label ||= 'borrowernumber ' . $borrowernumber;

        return {
            borrowernumber => $borrowernumber,
            label          => $label,
            href           => '/cgi-bin/koha/members/moremember.pl?borrowernumber=' . url_escape($borrowernumber),
        };
    }

    return {
        borrowernumber => $borrowernumber,
        label          => 'borrowernumber ' . $borrowernumber,
    };
}

sub _write_sftp_config_file {
    my ( $self, $koha_instance ) = @_;

    my ( $sources, $messages, $has_errors ) = $self->_normalize_sftp_sources( $self->_sftp_sources );
    die join( "\n", map { $_->{text} } @$messages ) . "\n" if $has_errors;
    die "No EDItX SFTP sources configured.\n" unless @$sources;
    $self->_log_runtime( debug => 'Writing temporary EDItX SFTP configuration', { source_count => scalar @$sources } );

    my $default_local_dir = $self->_default_import_tmp_path();
    my $safe_instance = $koha_instance;
    $safe_instance =~ s/[^A-Za-z0-9_.-]/_/g;

    my ( $fh, $config_file ) = tempfile( "editx-sftp-$safe_instance-XXXXXX", DIR => '/tmp', UNLINK => 0 );

    print {$fh} "SFTP_TARGETS=" . $self->_shell_quote( join( ' ', map { $_->{id} } @$sources ) ) . "\n";

    for my $source (@$sources) {
        my $id = $source->{id};
        my $local_dir = $source->{local_dir} || $default_local_dir;
        die "No local_dir configured for SFTP source '$id' and import_tmp_path is not set.\n" unless $local_dir;

        my %values = (
            HOST                     => $source->{host},
            PORT                     => $source->{port},
            USER                     => $source->{user},
            IDENTITY_FILE            => $source->{identity_file},
            REMOTE_DIR               => $source->{remote_dir},
            LOCAL_DIR                => $local_dir,
            PATTERN                  => $source->{pattern},
            AFTER_DOWNLOAD           => $source->{after_download},
            REMOTE_ARCHIVE_DIR       => $source->{remote_archive_dir},
            KNOWN_HOSTS_FILE         => $source->{known_hosts_file},
            STRICT_HOST_KEY_CHECKING => $source->{strict_host_key_checking},
            SSH_CONFIG               => $source->{ssh_config},
        );

        for my $suffix ( sort keys %values ) {
            next unless defined $values{$suffix} && $values{$suffix} ne '';
            print {$fh} "SFTP_${id}_${suffix}=" . $self->_shell_quote( $values{$suffix} ) . "\n";
        }
    }

    close $fh or die "Cannot close temporary EDItX SFTP config $config_file: $!";
    chmod 0600, $config_file or die "Cannot chmod temporary EDItX SFTP config $config_file: $!";
    $self->_log_runtime( debug => 'Temporary EDItX SFTP configuration written', { source_count => scalar @$sources } );

    return $config_file;
}

sub _run_nightly_sync {
    my ( $self, $options ) = @_;

    $options ||= {};

    my $koha_instance = $self->_koha_instance();
    die "Koha instance could not be detected from Koha configuration." unless $koha_instance;

    my $plugin_path = $self->bundle_path();
    my $fetch_script = "$plugin_path/cronjobs/fetch_editx_sftp.sh";
    my $import_script = "$plugin_path/cronjobs/runEditXImport.pl";
    my $lock_instance = $koha_instance;
    $lock_instance =~ s/[^A-Za-z0-9_.-]/_/g;
    my $lock_dir = "/tmp/editx-nightly-$lock_instance.lock";
    my $sftp_config_file;

    die "No executable EDItX SFTP fetch script: $fetch_script" unless -x $fetch_script;
    die "No EDItX import script: $import_script" unless -f $import_script;

    if ( !mkdir $lock_dir ) {
        $self->_log_runtime( warn => 'EDItX synchronization skipped because another run is active', { operation => 'sync', koha_instance => $koha_instance } );
        $self->_sync_print( $options, "Another EDItX nightly synchronization is already active for $koha_instance.\n" );
        return 1;
    }

    my $success = eval {
        $sftp_config_file = $self->_write_sftp_config_file($koha_instance);
        local $ENV{EDITX_RUNTIME_LOG} = Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->path;
        local $ENV{EDITX_RUNTIME_LOG_LEVEL} = $self->_runtime_log_level();

        $self->_log_runtime( info => 'Starting EDItX synchronization chain', { operation => 'sync', koha_instance => $koha_instance } );
        $self->_sync_print( $options, "Starting EDItX nightly synchronization for $koha_instance.\n" );
        $self->_run_command( $options, $fetch_script, $sftp_config_file, $koha_instance );
        $self->_run_command( $options, $^X, $import_script );
        $self->_sync_print( $options, "Finished EDItX nightly synchronization for $koha_instance.\n" );
        $self->_log_runtime( info => 'Finished EDItX synchronization chain', { operation => 'sync', koha_instance => $koha_instance } );
        1;
    };
    my $error = $@;

    unlink $sftp_config_file if $sftp_config_file && -f $sftp_config_file;
    if ( !rmdir $lock_dir ) {
        my $message = "Could not remove EDItX nightly lock $lock_dir: $!";
        $self->_log_runtime( warn => $message, { operation => 'sync', koha_instance => $koha_instance } );
        warn $message;
    }
    $self->_log_runtime( error => 'EDItX synchronization chain failed', { operation => 'sync', koha_instance => $koha_instance, error => $self->_compact_message($error) } )
        unless $success;
    die $error unless $success;

    return 1;
}

sub _run_nightly_sync_for_web {
    my ($self) = @_;

    my ( $fh, $output_file ) = tempfile( 'editx-manual-sync-XXXXXX', DIR => '/tmp', UNLINK => 0 );
    $fh->autoflush(1);

    my $success = eval {
        $self->_run_nightly_sync( { output_fh => $fh } );
        1;
    };
    my $error = $@;

    close $fh or die "Cannot close temporary EDItX manual sync log $output_file: $!";

    my $output = $self->_read_file_tail( $output_file, 6000 );
    unlink $output_file if -f $output_file;

    die $self->_sync_error_message( $error, $output ) unless $success;

    return $output;
}

sub _run_command {
    my ( $self, @args ) = @_;

    my $options = ref $args[0] eq 'HASH' ? shift @args : {};
    my @command = @args;
    my $command_text = join ' ', @command;

    $self->_log_runtime( debug => "Starting EDItX command: $command_text", { operation => 'sync_command' } );

    if ( my $output_fh = $options->{output_fh} ) {
        my $pid = fork;
        die 'Cannot fork EDItX command: ' . $! unless defined $pid;
        if ( !$pid ) {
            open STDOUT, '>&', $output_fh or die "Cannot redirect child STDOUT: $!";
            open STDERR, '>&', $output_fh or die "Cannot redirect child STDERR: $!";
            exec @command;
            die 'Failed to execute ' . join( ' ', @command ) . ": $!";
        }
        my $waited = waitpid $pid, 0;
        die 'Failed to wait for EDItX command: ' . $! if $waited == -1;
    } else {
        system @command;
    }

    if ( $? == -1 ) {
        $self->_log_runtime( error => "Failed to execute EDItX command: $command_text", { operation => 'sync_command', error => "$!" } );
        die "Failed to execute $command_text: $!";
    }
    if ( $? & 127 ) {
        my $signal = $? & 127;
        $self->_log_runtime( error => "EDItX command died with signal $signal: $command_text", { operation => 'sync_command', signal => $signal } );
        die "$command_text died with signal $signal";
    }
    if ( $? != 0 ) {
        my $status = $? >> 8;
        $self->_log_runtime( error => "EDItX command exited with status $status: $command_text", { operation => 'sync_command', status => $status } );
        die "$command_text exited with status $status";
    }

    $self->_log_runtime( debug => "Finished EDItX command: $command_text", { operation => 'sync_command' } );

    return 1;
}

sub _sync_print {
    my ( $self, $options, $message ) = @_;

    if ( $options && $options->{output_fh} ) {
        print { $options->{output_fh} } $message;
        return 1;
    }

    print $message;
    return 1;
}

sub _database_timestamp {
    my ($self) = @_;

    my ($timestamp) = C4::Context->dbh->selectrow_array('SELECT NOW()');
    die 'Could not read database timestamp.' unless $timestamp;

    return $timestamp;
}

sub _manual_sync_result {
    my ( $self, $started_at ) = @_;

    die 'Manual sync start timestamp is missing.' unless $started_at;

    my $dbh = C4::Context->dbh;
    my $baskets = $dbh->selectall_arrayref(
        "
        SELECT
            b.basketno,
            b.basketname,
            b.booksellerid,
            v.name AS vendor_name,
            COUNT(o.ordernumber) AS order_count,
            COALESCE(SUM(o.quantity), 0) AS item_count,
            MIN(o.ordernumber) AS first_ordernumber,
            MAX(o.ordernumber) AS last_ordernumber
        FROM aqorders o
        JOIN aqbasket b ON b.basketno = o.basketno
        LEFT JOIN aqbooksellers v ON v.id = b.booksellerid
        WHERE o.timestamp >= ?
        GROUP BY b.basketno, b.basketname, b.booksellerid, v.name
        ORDER BY b.basketno DESC
        LIMIT 20
        ",
        { Slice => {} },
        $started_at
    );

    my ( $order_count, $item_count ) = ( 0, 0 );
    my $run_date = substr( $started_at, 0, 10 );
    my $history_url = '/cgi-bin/koha/acqui/histsearch.pl?do_search=1'
        . '&from=' . url_escape($run_date)
        . '&to=' . url_escape($run_date);

    for my $basket (@$baskets) {
        $order_count += $basket->{order_count} || 0;
        $item_count += $basket->{item_count} || 0;
        $basket->{basket_url} = '/cgi-bin/koha/acqui/basket.pl?basketno=' . url_escape( $basket->{basketno} );
        $basket->{vendor_url} = '/cgi-bin/koha/acqui/booksellers.pl?booksellerid=' . url_escape( $basket->{booksellerid} )
            if defined $basket->{booksellerid};
    }

    return {
        started_at  => $started_at,
        baskets     => $baskets,
        history_url => $history_url,
        order_count => $order_count,
        item_count  => $item_count,
    };
}

sub _koha_instance {
    my ($self) = @_;

    return $INSTANCE;
}

sub _guess_koha_conf_path {
    my $koha_conf = eval {
        require Koha::Config;
        Koha::Config->guess_koha_conf();
    };

    return $koha_conf || '';
}

sub _instance_from_koha_conf_path {
    my ($koha_conf) = @_;

    return unless defined $koha_conf;
    return $1 if $koha_conf =~ m{\A/etc/koha/sites/([^/]+)/koha-conf\.xml\z};

    return;
}

sub _nightly_sync_enabled {
    my ($self) = @_;

    return $self->retrieve_data('nightly_sync_enabled') ? 1 : 0;
}

sub _sftp_sources_yaml {
    my ($self) = @_;

    my $config_json = $self->retrieve_data( Koha::Plugin::Fi::KohaSuomi::Editx::Config::CONFIG_KEY() );
    if ( defined $config_json && $config_json =~ /\S/ ) {
        return Dump( { sources => $self->_sftp_sources } );
    }

    my $sftp_sources_yaml = $self->retrieve_data('sftp_sources_yaml');
    return defined $sftp_sources_yaml ? $sftp_sources_yaml : $self->_empty_sftp_sources_yaml();
}

sub _empty_sftp_sources_yaml {
    return "sources: []\n";
}

sub _editx_config {
    my ($self) = @_;

    return Koha::Plugin::Fi::KohaSuomi::Editx::Config->load($self);
}

sub _sftp_sources {
    my ($self) = @_;

    return Koha::Plugin::Fi::KohaSuomi::Editx::Config->sftp_sources( $self->_editx_config );
}

sub _sftp_sources_from_cgi {
    my ( $self, $cgi ) = @_;

    my @ids = $cgi->multi_param('sftp_id');
    my @keys = qw(
        id host port user identity_file remote_dir local_dir pattern after_download remote_archive_dir
        known_hosts_file strict_host_key_checking ssh_config
    );
    my %values = (
        id                       => \@ids,
        host                     => [ $cgi->multi_param('sftp_host') ],
        port                     => [ $cgi->multi_param('sftp_port') ],
        user                     => [ $cgi->multi_param('sftp_user') ],
        identity_file            => [ $cgi->multi_param('sftp_identity_file') ],
        remote_dir               => [ $cgi->multi_param('sftp_remote_dir') ],
        local_dir                => [ $cgi->multi_param('sftp_local_dir') ],
        pattern                  => [ $cgi->multi_param('sftp_pattern') ],
        after_download           => [ $cgi->multi_param('sftp_after_download') ],
        remote_archive_dir       => [ $cgi->multi_param('sftp_remote_archive_dir') ],
        known_hosts_file         => [ $cgi->multi_param('sftp_known_hosts_file') ],
        strict_host_key_checking => [ $cgi->multi_param('sftp_strict_host_key_checking') ],
        ssh_config               => [ $cgi->multi_param('sftp_ssh_config') ],
    );

    my $max_index = -1;
    for my $key (@keys) {
        $max_index = $#{ $values{$key} } if $#{ $values{$key} } > $max_index;
    }

    my @sources;
    for my $index ( 0 .. $max_index ) {
        my %source;
        for my $key (@keys) {
            $source{$key} = $values{$key}->[$index];
        }
        next unless grep { defined $_ && $_ ne '' } @source{qw(id host user remote_dir)};
        push @sources, \%source;
    }

    return \@sources;
}

sub _parse_productform_mapping_csv {
    my ( $self, $mapping_csv ) = @_;

    my $csv = Text::CSV_XS->new(
        {
            binary           => 1,
            allow_whitespace => 1,
            blank_is_undef   => 1,
        }
    );
    my %itemtypes = map { $_ => 1 } @{ $self->_itemtypes() };
    my ( @rows, @messages, %seen_onix_codes );
    my $has_blocking_errors;
    my $line_number = 0;

    open my $fh, '<', \$mapping_csv or die "Cannot read product form mapping CSV: $!";

    while ( my $fields = $csv->getline($fh) ) {
        $line_number++;
        next unless grep { defined $_ && $_ ne '' } @$fields;
        next if $line_number == 1 && $self->_is_productform_mapping_csv_header($fields);

        if ( @$fields != 3 ) {
            push @messages, $self->_configure_message( error => "Line $line_number has " . scalar(@$fields) . " columns; expected 3." );
            $has_blocking_errors = 1;
            next;
        }

        my ( $onix_code, $productform, $productform_alternative ) = map { $self->_trim_csv_value($_) } @$fields;

        unless ($onix_code) {
            push @messages, $self->_configure_message( error => "Line $line_number has no ONIX code." );
            $has_blocking_errors = 1;
            next;
        }

        if ( $seen_onix_codes{$onix_code}++ ) {
            push @messages, $self->_configure_message( warning => "Line $line_number repeats ONIX code '$onix_code'; the later value will win." );
        }

        if ( $productform && !$itemtypes{$productform} ) {
            push @messages, $self->_configure_message( warning => "Line $line_number: item type '$productform' does not exist; productform was stored as NULL." );
            $productform = undef;
        }

        if ( $productform_alternative && !$itemtypes{$productform_alternative} ) {
            push @messages, $self->_configure_message( warning => "Line $line_number: item type '$productform_alternative' does not exist; productform_alternative was stored as NULL." );
            $productform_alternative = undef;
        }

        push @rows,
            {
                onix_code               => $onix_code,
                productform             => $productform,
                productform_alternative => $productform_alternative,
            };
    }

    if ( !$csv->eof ) {
        my ( $code, $message, $position ) = $csv->error_diag();
        push @messages, $self->_configure_message( error => "CSV parse failed at line $line_number, position $position: $message ($code)." );
        $has_blocking_errors = 1;
    }

    close $fh;

    unless (@rows) {
        push @messages, $self->_configure_message( error => 'No product form mappings found in CSV.' );
        $has_blocking_errors = 1;
    }

    return ( \@rows, \@messages, $has_blocking_errors );
}

sub _uploaded_productform_mapping_csv {
    my ( $self, $cgi ) = @_;

    return unless $cgi;

    my $upload = $cgi->upload('mapping_csv_file');
    return unless $upload;

    local $/;
    my $mapping_csv = <$upload>;

    return $mapping_csv // '';
}

sub _productform_mapping_row_from_cgi {
    my ( $self, $cgi, $prefix, $label ) = @_;

    return {
        onix_code               => $self->_trim_csv_value( scalar $cgi->param( $prefix . '_onix_code' ) ),
        productform             => $self->_trim_csv_value( scalar $cgi->param( $prefix . '_productform' ) ),
        productform_alternative => $self->_trim_csv_value( scalar $cgi->param( $prefix . '_productform_alternative' ) ),
        _label                  => $label,
    };
}

sub _productform_mapping_editor_from_cgi {
    my ( $self, $cgi ) = @_;

    return unless $cgi && ( $cgi->param('add_mapping_row') || $cgi->param('update_mapping_row') );

    my $is_editing = $cgi->param('update_mapping_row') ? 1 : 0;
    my $row = $self->_productform_mapping_row_from_cgi(
        $cgi,
        'add_mapping',
        $is_editing ? 'Mapping row' : 'New mapping row',
    );

    return {
        mode                    => $is_editing ? 'edit' : 'add',
        original_onix_code      => $self->_trim_csv_value( scalar $cgi->param('mapping_original_onix_code') ),
        onix_code               => $row->{onix_code},
        productform             => $row->{productform},
        productform_alternative => $row->{productform_alternative},
    };
}

sub _productform_mapping_rows_from_cgi {
    my ( $self, $cgi ) = @_;

    my @onix_codes = $cgi->multi_param('mapping_onix_code');
    my @productforms = $cgi->multi_param('mapping_productform');
    my @productform_alternatives = $cgi->multi_param('mapping_productform_alternative');

    my $max_index = $#onix_codes;
    $max_index = $#productforms if $#productforms > $max_index;
    $max_index = $#productform_alternatives if $#productform_alternatives > $max_index;

    my @rows;
    for my $index ( 0 .. $max_index ) {
        my $row = {
            onix_code               => $self->_trim_csv_value( $onix_codes[$index] ),
            productform             => $self->_trim_csv_value( $productforms[$index] ),
            productform_alternative => $self->_trim_csv_value( $productform_alternatives[$index] ),
        };
        next unless grep { defined $_ && $_ ne '' } values %{$row};
        $row->{_label} = 'Row ' . ( $index + 1 );
        push @rows, $row;
    }

    return \@rows;
}

sub _normalize_productform_mapping_rows {
    my ( $self, $raw_rows ) = @_;

    my %itemtypes = map { $_ => 1 } @{ $self->_itemtypes() };
    my ( @rows, @messages, %seen_onix_codes );
    my $has_blocking_errors;

    for my $index ( 0 .. $#$raw_rows ) {
        my $raw = $raw_rows->[$index] || {};
        my $label = $raw->{_label} || 'Row ' . ( $index + 1 );
        my $onix_code = $self->_trim_csv_value( $raw->{onix_code} );
        my $productform = $self->_trim_csv_value( $raw->{productform} );
        my $productform_alternative = $self->_trim_csv_value( $raw->{productform_alternative} );

        unless ($onix_code) {
            push @messages, $self->_configure_message( error => "$label has no ONIX code." );
            $has_blocking_errors = 1;
            next;
        }

        if ( $seen_onix_codes{$onix_code}++ ) {
            push @messages, $self->_configure_message( warning => "$label repeats ONIX code '$onix_code'; the later value will win." );
        }

        if ( $productform && !$itemtypes{$productform} ) {
            push @messages, $self->_configure_message( warning => "$label: item type '$productform' does not exist; productform was stored as NULL." );
            $productform = undef;
        }

        if ( $productform_alternative && !$itemtypes{$productform_alternative} ) {
            push @messages, $self->_configure_message( warning => "$label: item type '$productform_alternative' does not exist; productform_alternative was stored as NULL." );
            $productform_alternative = undef;
        }

        push @rows,
            {
                onix_code               => $onix_code,
                productform             => $productform,
                productform_alternative => $productform_alternative,
            };
    }

    unless (@rows) {
        push @messages, $self->_configure_message( error => 'No product form mappings found.' );
        $has_blocking_errors = 1;
    }

    return ( \@rows, \@messages, $has_blocking_errors );
}

sub _parse_sftp_sources_yaml {
    my ( $self, $sftp_sources_yaml ) = @_;

    my $config = eval { Load($sftp_sources_yaml) };

    if ($@) {
        return ( [], [ $self->_configure_message( error => "SFTP YAML parse failed: $@" ) ], 1 );
    }

    $config ||= {};
    if ( ref $config ne 'HASH' ) {
        return ( [], [ $self->_configure_message( error => 'SFTP YAML must be a mapping with a sources list.' ) ], 1 );
    }

    my $sources = $config->{sources} || [];
    if ( ref $sources ne 'ARRAY' ) {
        return ( [], [ $self->_configure_message( error => 'SFTP YAML sources must be a list.' ) ], 1 );
    }

    return $self->_normalize_sftp_sources($sources);
}

sub _normalize_sftp_sources {
    my ( $self, $sources ) = @_;

    $sources ||= [];
    my ( @messages, %seen_ids );
    my $has_blocking_errors;
    my @sources;
    for my $index ( 0 .. $#$sources ) {
        my $source = $sources->[$index];
        my $source_number = $index + 1;

        if ( ref $source ne 'HASH' ) {
            push @messages, $self->_configure_message( error => "SFTP source $source_number must be a mapping." );
            $has_blocking_errors = 1;
            next;
        }

        my %normalized;
        for my $key (qw(
            id host port user identity_file remote_dir local_dir pattern after_download remote_archive_dir
            known_hosts_file strict_host_key_checking ssh_config
        )) {
            my $raw_value = $source->{$key};
            my $value = $self->_trim_csv_value($raw_value);
            $value = '0' if $key eq 'strict_host_key_checking' && defined $raw_value && !defined $value && !$raw_value;
            $normalized{$key} = $value;
        }

        $normalized{port} //= 22;
        $normalized{pattern} //= '*.xml';
        $normalized{after_download} //= 'keep';
        $normalized{strict_host_key_checking} //= 'yes';

        if ( $normalized{strict_host_key_checking} =~ /\A(?:1|true)\z/i ) {
            $normalized{strict_host_key_checking} = 'yes';
        } elsif ( $normalized{strict_host_key_checking} =~ /\A(?:0|false)\z/i ) {
            $normalized{strict_host_key_checking} = 'no';
        }

        for my $required (qw(id host user remote_dir)) {
            next if defined $normalized{$required} && $normalized{$required} ne '';
            push @messages, $self->_configure_message( error => "SFTP source $source_number has no $required." );
            $has_blocking_errors = 1;
        }

        if ( $normalized{id} && $normalized{id} !~ /\A[A-Za-z0-9_]+\z/ ) {
            push @messages, $self->_configure_message( error => "SFTP source $source_number id '$normalized{id}' is invalid; use only letters, numbers, and underscores." );
            $has_blocking_errors = 1;
        }

        if ( $normalized{id} && $seen_ids{ $normalized{id} }++ ) {
            push @messages, $self->_configure_message( error => "SFTP source $source_number repeats id '$normalized{id}'." );
            $has_blocking_errors = 1;
        }

        if ( defined $normalized{port} && $normalized{port} !~ /\A[0-9]+\z/ ) {
            push @messages, $self->_configure_message( error => "SFTP source $source_number port '$normalized{port}' is not numeric." );
            $has_blocking_errors = 1;
        } elsif ( defined $normalized{port} && ( $normalized{port} < 1 || $normalized{port} > 65535 ) ) {
            push @messages, $self->_configure_message( error => "SFTP source $source_number port '$normalized{port}' must be between 1 and 65535." );
            $has_blocking_errors = 1;
        }

        if ( $normalized{pattern} && $normalized{pattern} !~ /\A[A-Za-z0-9_.?*\[\]-]+\z/ ) {
            push @messages, $self->_configure_message( error => "SFTP source $source_number pattern '$normalized{pattern}' is invalid; use only filename characters and simple SFTP wildcards." );
            $has_blocking_errors = 1;
        }

        if ( $normalized{after_download} !~ /\A(?:keep|archive|delete)\z/ ) {
            push @messages, $self->_configure_message( error => "SFTP source $source_number after_download must be keep, archive, or delete." );
            $has_blocking_errors = 1;
        }

        if ( $normalized{after_download} eq 'archive' && !$normalized{remote_archive_dir} ) {
            push @messages, $self->_configure_message( error => "SFTP source $source_number uses archive but has no remote_archive_dir." );
            $has_blocking_errors = 1;
        }

        if ( $normalized{strict_host_key_checking} !~ /\A(?:yes|no|ask|accept-new)\z/ ) {
            push @messages, $self->_configure_message( error => "SFTP source $source_number strict_host_key_checking must be yes, no, ask, or accept-new." );
            $has_blocking_errors = 1;
        }

        push @sources, \%normalized;
    }

    return ( \@sources, \@messages, $has_blocking_errors );
}

sub _save_productform_mappings {
    my ( $self, $rows ) = @_;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my @messages;

    my $saved = eval {
        $dbh->begin_work;
        $dbh->do("DELETE FROM $map_productform_table") or die $dbh->errstr;

        my $sth = $dbh->prepare( "
            INSERT INTO $map_productform_table (onix_code, productform, productform_alternative)
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE
                productform = VALUES(productform),
                productform_alternative = VALUES(productform_alternative)
        " );

        for my $row (@$rows) {
            $sth->execute( $row->{onix_code}, $row->{productform}, $row->{productform_alternative} ) or die $dbh->errstr;
        }

        $dbh->commit;
        1;
    };

    if ( !$saved ) {
        my $error = $@ || $dbh->errstr;
        eval { $dbh->rollback };
        push @messages, $self->_configure_message( error => "Could not save product form mappings: $error" );
    }

    return \@messages;
}

sub _add_productform_mapping {
    my ( $self, $row ) = @_;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my @messages;

    if ( $self->_productform_mapping_exists( $row->{onix_code} ) ) {
        return [
            $self->_configure_message(
                error => "ProductForm mapping for ONIX code '$row->{onix_code}' already exists. Edit that row instead."
            )
        ];
    }

    my $saved = eval {
        my $sth = $dbh->prepare( "
            INSERT INTO $map_productform_table (onix_code, productform, productform_alternative)
            VALUES (?, ?, ?)
        " );
        $sth->execute( $row->{onix_code}, $row->{productform}, $row->{productform_alternative} ) or die $dbh->errstr;
        1;
    };

    if ( !$saved ) {
        my $error = $@ || $dbh->errstr;
        push @messages, $self->_configure_message( error => "Could not save product form mapping row: $error" );
    }

    return \@messages;
}

sub _update_productform_mapping {
    my ( $self, $original_onix_code, $row ) = @_;

    $original_onix_code = $self->_trim_csv_value($original_onix_code);
    return [ $self->_configure_message( error => 'Could not update product form mapping row: original ONIX code is missing.' ) ]
        unless $original_onix_code;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my @messages;

    if ( $original_onix_code ne $row->{onix_code} && $self->_productform_mapping_exists( $row->{onix_code} ) ) {
        return [
            $self->_configure_message(
                error => "ProductForm mapping for ONIX code '$row->{onix_code}' already exists. Choose a different ONIX code or edit that row."
            )
        ];
    }

    my $saved = eval {
        $dbh->begin_work;
        my ($exists) = $dbh->selectrow_array(
            "SELECT COUNT(*) FROM $map_productform_table WHERE onix_code = ?",
            undef,
            $original_onix_code
        );
        die "original ONIX code '$original_onix_code' was not found" unless $exists;

        $dbh->do(
            "
            UPDATE $map_productform_table
            SET onix_code = ?, productform = ?, productform_alternative = ?
            WHERE onix_code = ?
            ",
            undef,
            $row->{onix_code},
            $row->{productform},
            $row->{productform_alternative},
            $original_onix_code
        ) or die $dbh->errstr;
        $dbh->commit;
        1;
    };

    if ( !$saved ) {
        my $error = $@ || $dbh->errstr;
        eval { $dbh->rollback };
        push @messages, $self->_configure_message( error => "Could not update product form mapping row: $error" );
    }

    return \@messages;
}

sub _productform_mapping_exists {
    my ( $self, $onix_code ) = @_;

    return 0 unless defined $onix_code && length $onix_code;

    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my ($count) = C4::Context->dbh->selectrow_array(
        "SELECT COUNT(*) FROM $map_productform_table WHERE onix_code = ?",
        undef,
        $onix_code
    );

    return $count ? 1 : 0;
}

sub _delete_productform_mapping {
    my ( $self, $onix_code ) = @_;

    $onix_code = $self->_trim_csv_value($onix_code);
    return [ $self->_configure_message( error => 'Could not delete product form mapping row: ONIX code is missing.' ) ]
        unless $onix_code;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my @messages;

    my $deleted = eval {
        $dbh->do( "DELETE FROM $map_productform_table WHERE onix_code = ?", undef, $onix_code ) or die $dbh->errstr;
        1;
    };

    if ( !$deleted ) {
        my $error = $@ || $dbh->errstr;
        push @messages, $self->_configure_message( error => "Could not delete product form mapping row: $error" );
    }

    return \@messages;
}

sub _productform_mapping_csv {
    my ($self) = @_;

    my $csv = Text::CSV_XS->new(
        {
            binary => 1,
            eol    => "\n",
        }
    );
    my $mapping_csv = '';

    open my $fh, '>', \$mapping_csv or die "Cannot write product form mapping CSV: $!";
    $csv->print( $fh, [qw(onix_code productform productform_alternative)] );

    for my $row ( @{ $self->_productform_mapping_rows } ) {
        $csv->print(
            $fh,
            [
                $row->{onix_code}               // '',
                $row->{productform}             // '',
                $row->{productform_alternative} // '',
            ]
        );
    }

    close $fh;

    return $mapping_csv;
}

sub _productform_mapping_rows {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my $sth = $dbh->prepare( "
        SELECT onix_code, productform, productform_alternative
        FROM $map_productform_table
        ORDER BY onix_code
    " );
    $sth->execute();

    my @rows;
    while ( my $row = $sth->fetchrow_hashref ) {
        push @rows, $row;
    }

    return \@rows;
}

sub _itemtypes {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare('SELECT itemtype FROM itemtypes ORDER BY itemtype');
    $sth->execute();

    my @itemtypes;
    while ( my ($itemtype) = $sth->fetchrow_array ) {
        push @itemtypes, $itemtype;
    }

    return \@itemtypes;
}

sub _is_productform_mapping_csv_header {
    my ( $self, $fields ) = @_;

    return unless @$fields == 3;

    my @header = map { lc( $self->_trim_csv_value($_) // '' ) } @$fields;
    return $header[0] eq 'onix_code'
        && $header[1] eq 'productform'
        && $header[2] eq 'productform_alternative';
}

sub _procurement_settings_from_cgi {
    my ( $self, $cgi ) = @_;

    my %settings = map {
        my $value = $self->_trim_csv_value( scalar $cgi->param($_) );
        $_ => $value // ''
    } qw(
        import_tmp_path import_load_path import_archive_path import_failed_path import_failed_archived_path
        authoriser allowed_locations productform_alternative_triggers notification_mailto notification_mailfrom
    );

    $settings{automatch_biblios}       = $cgi->param('automatch_biblios')       ? 'yes' : 'no';
    $settings{use_finna_materialtype} = $cgi->param('use_finna_materialtype') ? 'yes' : 'no';

    return \%settings;
}

sub _procurement_settings {
    my ($self) = @_;

    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;
    my $config = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config->new->getSettings();
    my $settings = $config->{settings} || {};
    my $notifications = $config->{notifications} || {};
    my $recommended_import_paths = $self->_recommended_import_paths();

    return {
        import_tmp_path                  => $self->_config_scalar( $settings->{import_tmp_path} ) || $recommended_import_paths->{tmp},
        import_load_path                 => $self->_config_scalar( $settings->{import_load_path} ) || $recommended_import_paths->{load},
        import_archive_path              => $self->_config_scalar( $settings->{import_archive_path} ) || $recommended_import_paths->{archive},
        import_failed_path               => $self->_config_scalar( $settings->{import_failed_path} ) || $recommended_import_paths->{fail},
        import_failed_archived_path      => $self->_config_scalar( $settings->{import_failed_archived_path} ) || $recommended_import_paths->{failed_archived},
        authoriser                       => $self->_config_scalar( $settings->{authoriser} ),
        allowed_locations                => $self->_config_scalar( $settings->{allowed_locations} ),
        productform_alternative_triggers => $self->_config_scalar( $settings->{productform_alternative_triggers} ),
        automatch_biblios                => $self->_yes_no_setting( $settings->{automatch_biblios}, 'yes' ),
        use_finna_materialtype           => $self->_yes_no_setting( $settings->{use_finna_materialtype}, 'no' ),
        notification_mailto              => $self->_config_scalar( $notifications->{mailto} ),
        notification_mailfrom            => $self->_config_scalar( $notifications->{mailfrom} ),
    };
}

sub _procurement_settings_store_data {
    my ( $self, $settings ) = @_;

    my %data;
    for my $key (qw(
        import_tmp_path import_load_path import_archive_path import_failed_path import_failed_archived_path
        authoriser allowed_locations productform_alternative_triggers automatch_biblios use_finna_materialtype
        notification_mailto notification_mailfrom
    )) {
        $data{"procurement_$key"} = $settings->{$key} // '';
    }

    return \%data;
}

sub _validate_procurement_settings {
    my ( $self, $settings, $strict ) = @_;

    my @messages;
    my $has_blocking_errors;
    my $blocking_type = $strict ? 'error' : 'warning';

    for my $field (qw(authoriser allowed_locations)) {
        next if defined $settings->{$field} && $settings->{$field} ne '';
        push @messages, $self->_configure_message( $blocking_type => "$field is required before EDItX import can run." );
        $has_blocking_errors ||= $strict;
    }

    my %folder_labels = (
        import_tmp_path             => 'Temporary download folder',
        import_load_path            => 'Import load folder',
        import_archive_path         => 'Successful archive folder',
        import_failed_path          => 'Failed import folder',
        import_failed_archived_path => 'Archived failed folder',
    );
    for my $field (qw(import_tmp_path import_load_path import_archive_path import_failed_path import_failed_archived_path)) {
        my $path = $settings->{$field};
        for my $error ( @{ $self->_directory_validation_errors( $folder_labels{$field}, $path ) } ) {
            push @messages, $self->_configure_message( error => $error );
            $has_blocking_errors = 1;
        }
    }

    if ( defined $settings->{authoriser} && $settings->{authoriser} ne '' ) {
        if ( $settings->{authoriser} !~ /\A[0-9]+\z/ || !$self->_patron_exists( $settings->{authoriser} ) ) {
            push @messages, $self->_configure_message( $blocking_type => "authoriser must be an existing Koha borrowernumber." );
            $has_blocking_errors ||= $strict;
        }
    }

    my @allowed_locations = $self->_csv_values( $settings->{allowed_locations} );
    my %allowed_locations = map { $_ => 1 } @allowed_locations;
    my %known_locations = map { $_ => 1 } @{ $self->_authorised_values('LOC') };

    if (%known_locations) {
        for my $location (@allowed_locations) {
            next if $known_locations{$location};
            push @messages, $self->_configure_message( $blocking_type => "allowed_locations contains unknown Koha location '$location'." );
            $has_blocking_errors ||= $strict;
        }
    }

    for my $trigger ( $self->_csv_values( $settings->{productform_alternative_triggers} ) ) {
        if ( !%allowed_locations || !$allowed_locations{$trigger} ) {
            push @messages, $self->_configure_message( $blocking_type => "productform_alternative_triggers contains '$trigger', but it is not in allowed_locations." );
            $has_blocking_errors ||= $strict;
        }
        if ( %known_locations && !$known_locations{$trigger} ) {
            push @messages, $self->_configure_message( $blocking_type => "productform_alternative_triggers contains unknown Koha location '$trigger'." );
            $has_blocking_errors ||= $strict;
        }
    }

    for my $email ( $self->_csv_values( $settings->{notification_mailto} ) ) {
        next if $email =~ /\A[^@\s]+@[^@\s]+\z/;
        push @messages, $self->_configure_message( $blocking_type => "Notification recipient '$email' is not a valid simple email address." );
        $has_blocking_errors ||= $strict;
    }

    if ( $settings->{notification_mailfrom} && $settings->{notification_mailfrom} !~ /\A[^@\s]+@[^@\s]+\z/ ) {
        push @messages, $self->_configure_message( $blocking_type => "Notification sender '$settings->{notification_mailfrom}' is not a valid simple email address." );
        $has_blocking_errors ||= $strict;
    }

    return ( \@messages, $has_blocking_errors );
}

sub _directory_validation_errors {
    my ( $self, $label, $path ) = @_;

    my @errors;
    if ( !defined $path || $path eq '' ) {
        push @errors, "$label is required before EDItX import can run.";
        return \@errors;
    }

    if ( !File::Spec->file_name_is_absolute($path) ) {
        push @errors, "$label must be an absolute path: $path";
        return \@errors;
    }

    my @path_parts = File::Spec->splitdir($path);
    if ( grep { $_ eq '..' } @path_parts ) {
        push @errors, "$label must not contain parent-directory segments: $path";
        return \@errors;
    }

    my $normalized_path = File::Spec->canonpath($path);
    if ( -e $normalized_path ) {
        if ( !-d $normalized_path ) {
            push @errors, "$label exists but is not a directory: $normalized_path";
        } elsif ( !-w $normalized_path || !-x $normalized_path ) {
            push @errors, "$label exists but is not writable by the Koha process: $normalized_path";
        }
        return \@errors;
    }

    my $parent = $self->_nearest_existing_path($normalized_path);
    if ( !$parent || !-d $parent ) {
        push @errors, "$label cannot be created because the nearest existing parent is not a directory: $parent";
    } elsif ( !-w $parent || !-x $parent ) {
        push @errors, "$label cannot be created because the nearest existing parent is not writable by the Koha process: $parent";
    }

    return \@errors;
}

sub _nearest_existing_path {
    my ( $self, $path ) = @_;

    my $candidate = File::Spec->canonpath($path);
    while ( defined $candidate && $candidate ne '' ) {
        return $candidate if -e $candidate;

        my @parts = File::Spec->splitdir($candidate);
        last if @parts <= 1;
        pop @parts;
        my $parent = File::Spec->catdir(@parts);
        last if !defined $parent || $parent eq $candidate;
        $candidate = $parent;
    }

    return File::Spec->rootdir;
}

sub _default_import_tmp_path {
    my ($self) = @_;

    require Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;
    my $settings = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config->new->getSettings();

    return $settings->{settings}->{import_tmp_path} // '';
}

sub _recommended_import_paths {
    my ($self) = @_;

    my $instance = $self->_koha_instance();
    if ( defined $instance && $instance ne '' ) {
        $instance =~ s/[^A-Za-z0-9_.-]/_/g;
    } else {
        $instance = '<instance>';
    }

    my $base = "/var/lib/koha/$instance/editx";

    return {
        base            => $base,
        tmp             => "$base/tmp",
        load            => "$base/load",
        archive         => "$base/archive",
        fail            => "$base/fail",
        failed_archived => "$base/failed_archived",
    };
}

sub _recommended_sftp_paths {
    my ($self) = @_;

    my $instance = $self->_koha_instance();
    if ( defined $instance && $instance ne '' ) {
        $instance =~ s/[^A-Za-z0-9_.-]/_/g;
    } else {
        $instance = '<instance>';
    }

    my $base = "/var/lib/koha/$instance/.ssh";

    return {
        identity_file    => "$base/editx_sftp",
        known_hosts_file => "$base/known_hosts",
    };
}

sub _shell_quote {
    my ( $self, $value ) = @_;

    $value //= '';
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

sub _config_scalar {
    my ( $self, $value ) = @_;

    return '' if !defined $value || ref $value;
    return $value;
}

sub _yes_no_setting {
    my ( $self, $value, $default ) = @_;

    $value = $self->_config_scalar($value);
    return $value eq 'yes' || $value eq 'no' ? $value : $default;
}

sub _csv_values {
    my ( $self, $csv_text ) = @_;

    return grep { $_ ne '' } map {
        my $value = $_;
        $value =~ s/\A\s+|\s+\z//g;
        $value;
    } split ',', ( $csv_text // '' );
}

sub _patron_exists {
    my ( $self, $borrowernumber ) = @_;

    return unless defined $borrowernumber && $borrowernumber =~ /\A[0-9]+\z/;

    my ($exists) = C4::Context->dbh->selectrow_array( 'SELECT COUNT(*) FROM borrowers WHERE borrowernumber = ?', undef, $borrowernumber );
    return $exists ? 1 : 0;
}

sub _authorised_values {
    my ( $self, $category ) = @_;

    my $sth = C4::Context->dbh->prepare('SELECT authorised_value FROM authorised_values WHERE category = ? ORDER BY authorised_value');
    $sth->execute($category);

    my @values;
    while ( my ($value) = $sth->fetchrow_array ) {
        push @values, $value;
    }

    return \@values;
}

sub _branches {
    my ($self) = @_;

    my $sth = C4::Context->dbh->prepare('SELECT branchcode FROM branches ORDER BY branchcode');
    $sth->execute();

    my @branches;
    while ( my ($branchcode) = $sth->fetchrow_array ) {
        push @branches, $branchcode;
    }

    return \@branches;
}

sub _csrf_token_valid {
    my ( $self, $cgi ) = @_;

    return unless $cgi;

    return Koha::Token->new->check_csrf(
        {
            session_id => scalar $cgi->cookie('CGISESSID'),
            token      => scalar $cgi->param('csrf_token'),
        }
    );
}

sub plugin_version {
    my ($self) = @_;

    return $metadata->{version} || $VERSION;
}

sub plugin_display_version {
    my ($self) = @_;

    return $self->plugin_version();
}

sub _trim_csv_value {
    my ( $self, $value ) = @_;

    return unless defined $value;

    $value =~ s/\A\x{FEFF}//;
    $value =~ s/\A\s+|\s+\z//g;
    return $value eq '' || uc($value) eq 'NULL' ? undef : $value;
}

sub _configure_message {
    my ( $self, $type, $text ) = @_;

    return {
        type        => $type,
        alert_class => $type eq 'error' ? 'danger' : $type,
        text        => $text,
    };
}

sub _runtime_log_level {
    my ($self) = @_;

    return Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->normalize_level(
        $self->retrieve_data('runtime_log_level')
    );
}

sub _runtime_log_settings {
    my ( $self, $override ) = @_;

    return {
        runtime_log_level => Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->normalize_level(
            $override && exists $override->{runtime_log_level}
            ? $override->{runtime_log_level}
            : $self->retrieve_data('runtime_log_level')
        ),
    };
}

sub _log_runtime {
    my ( $self, $level, $message, $context, $settings ) = @_;

    return Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->log(
        {
            settings  => $self->_runtime_log_settings($settings),
            level     => $level,
            message   => $message,
            component => 'plugin',
            context   => $context,
        }
    );
}

sub _read_file_tail {
    my ( $self, $file, $max_bytes ) = @_;

    return '' unless $file && -f $file;

    $max_bytes ||= 6000;
    open my $fh, '<', $file or return '';
    binmode $fh;
    my $size = -s $file || 0;
    if ( $size > $max_bytes ) {
        seek $fh, -$max_bytes, 2;
        <$fh>;
    }
    local $/;
    my $text = <$fh> // '';
    close $fh;

    return $text;
}

sub _sync_error_message {
    my ( $self, $error, $output ) = @_;

    my $message = $self->_compact_message($error) || 'unknown error';
    if ( my $summary = $self->_compact_message($output) ) {
        $message .= " Last output: $summary";
    }

    return $message;
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
