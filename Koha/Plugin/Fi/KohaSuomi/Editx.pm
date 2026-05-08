package Koha::Plugin::Fi::KohaSuomi::Editx;
## It's good practice to use Modern::Perl
use Modern::Perl;
## Required for all plugins
use base qw(Koha::Plugins::Base);
## We will also need to include any Koha libraries we want to access
use File::Spec;
use File::Temp qw(tempfile);
use IO::Handle;
use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Token;
use Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog;
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(url_escape);
use Text::CSV_XS;
use YAML::XS qw(Load);
use utf8;
## Here we set our plugin version
our $VERSION = "{VERSION}";
## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'EDItX-plugin',
    author          => 'Lari Strand',
    date_authored   => '2022-04-05',
    date_updated    => '1900-01-01',
    minimum_version => '23.11',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Adds EDItX functionality to Koha. (Paikalliskannat)',
};
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
    my $success = $self->_install_or_upgrade_tables();
    $self->_log_runtime(
        $success ? 'info' : 'error',
        $success ? 'EDItX plugin install finished' : 'EDItX plugin install failed',
        { operation => 'install' }
    );

    return $success;
}

sub _install_or_upgrade_tables {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $sequences_table = $self->_quote_identifier( $self->get_qualified_table_name('sequences') );
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my $procurement_file_table = $self->_quote_identifier( $self->get_qualified_table_name('procurement_file') );

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

    $success &&= $dbh->do( "
        CREATE TABLE IF NOT EXISTS $procurement_file_table (
          `file_id` int(11) NOT NULL AUTO_INCREMENT,
          `file_name` varchar(255) NOT NULL,
          `file_hash` varchar(255) NOT NULL,
          `imported_on` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`file_id`),
          UNIQUE KEY `file_name_hash` (`file_name`, `file_hash`),
          KEY `file_hash` (`file_hash`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    " );

    if ( !$success ) {
        my $message = "Failed to create procurement_file table: " . $dbh->errstr;
        $self->_log_runtime( error => $message, { operation => 'install_or_upgrade' } );
        warn $message;
    }

    $success &&= $self->_drop_map_productform_foreign_keys();
    $success &&= $self->_allow_nullable_map_productform_columns();
    $success &&= $self->_migrate_legacy_sequences_table();
    $success &&= $self->_migrate_legacy_map_productform_table();
    $success &&= $self->_migrate_legacy_procurement_file_table();
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
    my $success = $self->_install_or_upgrade_tables();
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
    my $sequences_table = $self->_quote_identifier( $self->get_qualified_table_name('sequences') );
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my $procurement_file_table = $self->_quote_identifier( $self->get_qualified_table_name('procurement_file') );

    $success &&= C4::Context->dbh->do("DROP TABLE IF EXISTS $sequences_table");
    $success &&= C4::Context->dbh->do("DROP TABLE IF EXISTS $map_productform_table");
    $success &&= C4::Context->dbh->do("DROP TABLE IF EXISTS $procurement_file_table");

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

    $self->_install_or_upgrade_tables();

    if ( $cgi->request_method eq 'POST' && $cgi->param('run_sync_now') ) {
        $manual_run_attempted = 1;
        my $manual_messages;
        ( $manual_messages, $manual_sync_result ) = $self->_run_manual_sync_action($cgi);
        push @messages, @$manual_messages;
    }

    $self->_output_tool_page(
        messages             => \@messages,
        manual_sync_result   => $manual_sync_result,
        manual_run_attempted => $manual_run_attempted,
    );
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my @messages;
    my $saved;
    my $is_save = $cgi->request_method eq 'POST' && $cgi->param('save');
    my $runtime_log_level =
          $is_save
        ? Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->normalize_level( scalar $cgi->param('runtime_log_level') )
        : $self->_runtime_log_level();
    my $nightly_sync_enabled =
          $is_save
        ? ( $cgi->param('nightly_sync_enabled') ? 1 : 0 )
        : $self->_nightly_sync_enabled();
    my $sftp_sources_yaml =
          $is_save
        ? ( $cgi->param('sftp_sources_yaml') // '' )
        : $self->_sftp_sources_yaml();
    my $procurement_settings =
          $is_save
        ? $self->_procurement_settings_from_cgi($cgi)
        : $self->_procurement_settings();

    $self->_install_or_upgrade_tables();

    if ($is_save) {
        my $mapping_csv = $cgi->param('mapping_csv') // '';
        if ( !$self->_csrf_token_valid($cgi) ) {
            push @messages, $self->_configure_message( error => 'Configuration was not saved because the security token was invalid. Reload the page and try again.' );
            $self->_output_configure_page(
                mapping_csv            => $mapping_csv,
                sftp_sources_yaml      => $sftp_sources_yaml,
                procurement_settings   => $procurement_settings,
                messages               => \@messages,
                nightly_sync_enabled   => $nightly_sync_enabled,
                saved                  => 0,
                runtime_log_level      => $runtime_log_level,
            );
            return;
        }

        my ( $rows, $parse_messages, $has_blocking_errors ) = $self->_parse_productform_mapping_csv($mapping_csv);
        my ( $sftp_sources, $sftp_messages, $has_sftp_blocking_errors ) = $self->_parse_sftp_sources_yaml($sftp_sources_yaml);
        my ( $procurement_messages, $has_procurement_blocking_errors ) = $self->_validate_procurement_settings( $procurement_settings, $nightly_sync_enabled );
        push @messages, @$parse_messages;
        push @messages, @$sftp_messages;
        push @messages, @$procurement_messages;
        $has_blocking_errors ||= $has_sftp_blocking_errors;
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
                mapping_csv            => $mapping_csv,
                sftp_sources_yaml      => $sftp_sources_yaml,
                procurement_settings   => $procurement_settings,
                messages               => \@messages,
                nightly_sync_enabled   => $nightly_sync_enabled,
                saved                  => 0,
                runtime_log_level      => $runtime_log_level,
            );
            return;
        }

        my $save_messages = $self->_save_productform_mappings($rows);
        push @messages, @$save_messages;
        if (@$save_messages) {
            $self->_output_configure_page(
                mapping_csv            => $mapping_csv,
                sftp_sources_yaml      => $sftp_sources_yaml,
                procurement_settings   => $procurement_settings,
                messages               => \@messages,
                nightly_sync_enabled   => $nightly_sync_enabled,
                saved                  => 0,
                runtime_log_level      => $runtime_log_level,
            );
            return;
        }
        $self->store_data(
            {
                nightly_sync_enabled => $nightly_sync_enabled,
                sftp_sources_yaml    => $sftp_sources_yaml,
                runtime_log_level    => $runtime_log_level,
                %{ $self->_procurement_settings_store_data($procurement_settings) },
                last_configured_by   => ( C4::Context->userenv || {} )->{'number'},
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
        $saved = 1;
    }

    $self->_output_configure_page(
        mapping_csv            => $self->_productform_mapping_csv(),
        sftp_sources_yaml      => $self->_sftp_sources_yaml(),
        procurement_settings   => $procurement_settings,
        messages               => \@messages,
        nightly_sync_enabled   => $nightly_sync_enabled,
        saved                  => $saved,
        runtime_log_level      => $runtime_log_level,
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

sub static_asset_url {
    my ( $self, $path ) = @_;

    $path =~ s{\A/+}{};

    return '/api/v1/contrib/'
        . $self->api_namespace
        . '/static/'
        . $path
        . '?v='
        . $self->_static_asset_version($path);
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

    for my $source ( 'editx_sequences', 'sequences' ) {
        next if $source eq $target;
        next unless $self->_table_exists($source);

        my $quoted_source = $self->_quote_identifier($source);
        my ($target_count) = $dbh->selectrow_array("SELECT COUNT(*) FROM $quoted_target");
        next if $target_count;

        $dbh->do( "
            INSERT INTO $quoted_target (invoicenumber, item_barcode_nextval)
            SELECT invoicenumber, item_barcode_nextval FROM $quoted_source LIMIT 1
        " ) or return;
    }

    return 1;
}

sub _migrate_legacy_map_productform_table {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $target = $self->get_qualified_table_name('map_productform');
    my $quoted_target = $self->_quote_identifier($target);
    my ($target_count) = $dbh->selectrow_array("SELECT COUNT(*) FROM $quoted_target");

    return 1 if $target_count;

    for my $source ( 'editx_map_productform', 'map_productform' ) {
        next if $source eq $target;
        next unless $self->_table_exists($source);

        my $quoted_source = $self->_quote_identifier($source);
        $dbh->do( "
            INSERT INTO $quoted_target (onix_code, productform, productform_alternative)
            SELECT onix_code, productform, productform_alternative FROM $quoted_source
            ON DUPLICATE KEY UPDATE
                productform = VALUES(productform),
                productform_alternative = VALUES(productform_alternative)
        " ) or return;

        return 1;
    }

    return 1;
}

sub _migrate_legacy_procurement_file_table {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $target = $self->get_qualified_table_name('procurement_file');
    my $quoted_target = $self->_quote_identifier($target);

    for my $source ( 'editx_procurement_file', 'procurement_file' ) {
        next if $source eq $target;
        next unless $self->_table_exists($source);

        my $quoted_source = $self->_quote_identifier($source);
        $dbh->do( "
            INSERT IGNORE INTO $quoted_target (file_name, file_hash)
            SELECT file_name, file_hash FROM $quoted_source
            WHERE file_name IS NOT NULL AND file_hash IS NOT NULL
        " ) or return;
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

sub _tool_sftp_status {
    my ( $self, $procurement_settings ) = @_;

    my $saved_sftp_sources_yaml = $self->retrieve_data('sftp_sources_yaml') // '';
    if ( $saved_sftp_sources_yaml !~ /\S/ ) {
        return {
            count      => 0,
            has_errors => 1,
            messages   => [ $self->_configure_message( warning => 'No SFTP sources are saved in the EDItX plugin configuration.' ) ],
        };
    }

    my ( $sources, $messages, $has_errors ) = $self->_parse_sftp_sources_yaml($saved_sftp_sources_yaml);
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
        nightly_sync_enabled   => $self->_nightly_sync_enabled(),
        procurement_settings   => $procurement_settings,
        sftp_sources_count     => $sftp_status->{count},
        sftp_config_has_errors => $sftp_status->{has_errors},
        sftp_config_messages   => $sftp_status->{messages},
        manual_run_available   => !$sftp_status->{has_errors} && $sftp_status->{count} ? 1 : 0,
        configure_href         => $self->plugin_method_url('configure'),
        tool_href              => $self->plugin_method_url('tool'),
        css_href               => $self->static_asset_url('static_files/editx.css'),
        plugin_display_version => $self->plugin_display_version(),
    );

    return $self->output_html( $template->output() );
}

sub _output_configure_page {
    my ( $self, %params ) = @_;

    my $template = $self->get_template( { file => 'configure.tt' } );
    $template->param(
        mapping_csv            => $params{mapping_csv},
        sftp_sources_yaml      => $params{sftp_sources_yaml},
        procurement_settings   => $params{procurement_settings},
        messages               => $params{messages},
        nightly_sync_enabled   => $params{nightly_sync_enabled},
        saved                  => $params{saved},
        itemtypes_text         => join( ', ', @{ $self->_itemtypes() } ),
        locations_text         => join( ', ', @{ $self->_authorised_values('LOC') } ),
        branches_text          => join( ', ', @{ $self->_branches() } ),
        last_configured_by     => $self->retrieve_data('last_configured_by'),
        last_upgraded          => $self->retrieve_data('last_upgraded'),
        recommended_import_paths => $self->_recommended_import_paths(),
        configure_href         => $self->plugin_method_url('configure'),
        tool_href              => $self->plugin_method_url('tool'),
        css_href               => $self->static_asset_url('static_files/editx.css'),
        plugin_display_version => $self->plugin_display_version(),
        runtime_log_level      => $params{runtime_log_level} || $self->_runtime_log_level(),
        runtime_log_levels     => Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->levels,
        runtime_log_path       => Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->path,
        runtime_log_tail       => Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->tail,
    );

    return $self->output_html( $template->output() );
}

sub _write_sftp_config_file {
    my ( $self, $koha_instance ) = @_;

    my ( $sources, $messages, $has_errors ) = $self->_parse_sftp_sources_yaml( $self->_sftp_sources_yaml() );
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

    my $koha_instance = $ENV{KOHA_INSTANCE} || $self->_koha_instance();
    die "KOHA_INSTANCE is not set and could not be detected from KOHA_CONF." unless $koha_instance;

    local $ENV{KOHA_INSTANCE} = $koha_instance;

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
        local $ENV{EDITX_SFTP_CONFIG} = $sftp_config_file;
        local $ENV{EDITX_RUNTIME_LOG} = Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->path;
        local $ENV{EDITX_RUNTIME_LOG_LEVEL} = $self->_runtime_log_level();

        $self->_log_runtime( info => 'Starting EDItX synchronization chain', { operation => 'sync', koha_instance => $koha_instance } );
        $self->_sync_print( $options, "Starting EDItX nightly synchronization for $koha_instance.\n" );
        $self->_run_command( $options, $fetch_script );
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
        order_count => $order_count,
        item_count  => $item_count,
    };
}

sub _koha_instance {
    my ($self) = @_;

    return $ENV{KOHA_INSTANCE} if $ENV{KOHA_INSTANCE};
    return $1 if ( $ENV{KOHA_CONF} // '' ) =~ m{/etc/koha/sites/([^/]+)/koha-conf\.xml\z};
    return;
}

sub _nightly_sync_enabled {
    my ($self) = @_;

    return $self->retrieve_data('nightly_sync_enabled') ? 1 : 0;
}

sub _sftp_sources_yaml {
    my ($self) = @_;

    my $sftp_sources_yaml = $self->retrieve_data('sftp_sources_yaml');
    return defined $sftp_sources_yaml ? $sftp_sources_yaml : $self->_empty_sftp_sources_yaml();
}

sub _empty_sftp_sources_yaml {
    return "sources: []\n";
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

sub _parse_sftp_sources_yaml {
    my ( $self, $sftp_sources_yaml ) = @_;

    my ( @messages, %seen_ids );
    my $has_blocking_errors;
    my $config = eval { Load($sftp_sources_yaml) };

    if ($@) {
        push @messages, $self->_configure_message( error => "SFTP YAML parse failed: $@" );
        return ( [], \@messages, 1 );
    }

    $config ||= {};
    if ( ref $config ne 'HASH' ) {
        push @messages, $self->_configure_message( error => 'SFTP YAML must be a mapping with a sources list.' );
        return ( [], \@messages, 1 );
    }

    my $sources = $config->{sources} || [];
    if ( ref $sources ne 'ARRAY' ) {
        push @messages, $self->_configure_message( error => 'SFTP YAML sources must be a list.' );
        return ( [], \@messages, 1 );
    }

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

sub _productform_mapping_csv {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my $sth = $dbh->prepare( "
        SELECT onix_code, productform, productform_alternative
        FROM $map_productform_table
        ORDER BY onix_code
    " );
    $sth->execute();

    my $csv = Text::CSV_XS->new(
        {
            binary => 1,
            eol    => "\n",
        }
    );
    my $mapping_csv = '';

    open my $fh, '>', \$mapping_csv or die "Cannot write product form mapping CSV: $!";
    $csv->print( $fh, [qw(onix_code productform productform_alternative)] );

    while ( my $row = $sth->fetchrow_hashref ) {
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

    return {
        import_tmp_path                  => $self->_config_scalar( $settings->{import_tmp_path} ),
        import_load_path                 => $self->_config_scalar( $settings->{import_load_path} ),
        import_archive_path              => $self->_config_scalar( $settings->{import_archive_path} ),
        import_failed_path               => $self->_config_scalar( $settings->{import_failed_path} ),
        import_failed_archived_path      => $self->_config_scalar( $settings->{import_failed_archived_path} ),
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

    for my $field (qw(import_tmp_path import_load_path import_archive_path import_failed_path authoriser allowed_locations)) {
        next if defined $settings->{$field} && $settings->{$field} ne '';
        push @messages, $self->_configure_message( $blocking_type => "$field is required before EDItX import can run." );
        $has_blocking_errors ||= $strict;
    }

    for my $field (qw(import_tmp_path import_load_path import_archive_path import_failed_path import_failed_archived_path)) {
        my $path = $settings->{$field};
        next unless defined $path && $path ne '';
        next if -d $path && -w $path;

        push @messages, $self->_configure_message( $blocking_type => "$field does not point to a writable directory: $path" );
        $has_blocking_errors ||= $strict;
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

    my $base = "/var/lib/koha/$instance/spool/editx";

    return {
        base            => $base,
        tmp             => "$base/tmp",
        load            => "$base/load",
        archive         => "$base/archive",
        fail            => "$base/fail",
        failed_archived => "$base/failed_archived",
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

sub _static_asset_version {
    my ( $self, $path ) = @_;

    my $version = $self->plugin_version();
    $version =~ s/[^A-Za-z0-9_.-]+/_/g;

    my @parts = ($version);
    if ( my $bundle_path = $self->bundle_path ) {
        my $full_path = File::Spec->catfile( $bundle_path, split m{/}, $path );
        if ( my @stat = stat $full_path ) {
            push @parts, $stat[9], $stat[7];
        }
    }

    return join '-', @parts;
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
        $message = substr( $message, 0, 797 ) . '...';
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
