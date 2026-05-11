package Koha::Plugin::Fi::KohaSuomi::Editx::ConfigMigration;

use Modern::Perl;
use File::Basename qw(basename dirname);
use File::Spec;
use POSIX qw(strftime);
use XML::Simple;

use Koha::Plugin::Fi::KohaSuomi::Editx::Config;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;

sub new {
    my ( $class, %args ) = @_;

    return bless { plugin => $args{plugin} }, $class;
}

sub migrate_legacy_xml {
    my ($self) = @_;

    my $path = $self->_legacy_xml_path;
    return 1 if !$path || !-e $path;

    my $plugin = $self->{plugin};
    my $existing_config = eval { $plugin->retrieve_data( Koha::Plugin::Fi::KohaSuomi::Editx::Config::CONFIG_KEY() ) };
    if ( defined $existing_config && $existing_config =~ /\S/ ) {
        $self->_log_and_warn(
            warn => 'Legacy procurement-config.xml exists but plugin config_json already exists; XML is ignored by this plugin version',
            {
                operation => 'legacy_config_migration',
                path      => $path,
            }
        );
        $self->_quarantine_legacy_xml($path);
        return 1;
    }

    $self->_log_and_warn(
        info => 'Legacy procurement-config.xml found; migrating values into plugin config_json',
        {
            operation => 'legacy_config_migration',
            path      => $path,
        }
    );

    my $xml = eval {
        XML::Simple->new( ForceArray => 0, KeyAttr => [] )->XMLin($path);
    };
    if ( $@ || ref $xml ne 'HASH' ) {
        $self->_log_and_warn(
            error => 'Legacy procurement-config.xml migration failed: XML could not be parsed',
            {
                operation => 'legacy_config_migration',
                path      => $path,
                error     => "$@",
            }
        );
        return;
    }

    my $config = $self->_config_from_legacy_xml($xml);
    my $stored = eval {
        $plugin->store_data( Koha::Plugin::Fi::KohaSuomi::Editx::Config->store_data($config) );
        1;
    };
    if ( !$stored ) {
        $self->_log_and_warn(
            error => 'Legacy procurement-config.xml migration failed: config_json could not be stored',
            {
                operation => 'legacy_config_migration',
                path      => $path,
                error     => "$@",
            }
        );
        return;
    }

    $self->_log_and_warn(
        warn => 'Legacy procurement-config.xml was migrated to plugin config_json and is ignored by this plugin version. Remove it from deployment/config management.',
        {
            operation => 'legacy_config_migration',
            path      => $path,
        }
    );
    $self->_quarantine_legacy_xml($path);

    return 1;
}

sub _config_from_legacy_xml {
    my ( $self, $xml ) = @_;

    my $settings = ref $xml->{settings} eq 'HASH' ? $xml->{settings} : {};
    my $notifications = ref $xml->{notifications} eq 'HASH' ? $xml->{notifications} : {};

    my %procurement_settings;
    for my $key (qw(
        import_tmp_path
        import_load_path
        import_archive_path
        import_failed_path
        import_failed_archived_path
        authoriser
        allowed_locations
        productform_alternative_triggers
        automatch_biblios
        use_finna_materialtype
    )) {
        $procurement_settings{$key} = $self->_scalar( $settings->{$key} );
    }

    $procurement_settings{notification_mailto} = $self->_scalar( $notifications->{mailto} );
    $procurement_settings{notification_mailfrom} = $self->_scalar( $notifications->{mailfrom} );

    my $legacy_source_dir = $procurement_settings{import_tmp_path};
    my @folder_sources;
    if ($legacy_source_dir) {
        $procurement_settings{import_tmp_path} = $self->_legacy_staging_path($legacy_source_dir);
        push @folder_sources, {
            enabled             => 'yes',
            id                  => 'kohasuomi_legacy',
            local_dir           => $legacy_source_dir,
            pattern             => '*.xml',
            success_action      => 'delete',
            local_archive_dir   => '',
            minimum_age_seconds => 60,
        };
    }

    return Koha::Plugin::Fi::KohaSuomi::Editx::Config->from_flat(
        {
            procurement_settings => \%procurement_settings,
            sftp_sources         => [],
            folder_sources       => \@folder_sources,
        }
    );
}

sub _legacy_staging_path {
    my ( $self, $legacy_source_dir ) = @_;

    my $path = $legacy_source_dir || '';
    $path =~ s{/+\z}{};
    return '' if !$path;

    return File::Spec->catdir( dirname($path), 'staging' )
        if basename($path) eq 'tmp';

    return $path . '_staging';
}

sub _quarantine_legacy_xml {
    my ( $self, $path ) = @_;

    return 1 if !$path || !-e $path;

    my $target = $path . '.migrated-' . strftime( '%Y%m%d%H%M%S', localtime );
    $target .= ".$$" if -e $target;

    if ( rename $path, $target ) {
        $self->_log_and_warn(
            warn => 'Legacy procurement-config.xml was moved aside so this plugin version cannot keep reading stale XML configuration',
            {
                operation       => 'legacy_config_migration',
                path            => $path,
                quarantine_path => $target,
            }
        );
        return 1;
    }

    $self->_log_and_warn(
        warn => 'Legacy procurement-config.xml could not be moved aside; remove it from deployment/config management because this plugin version ignores it',
        {
            operation => 'legacy_config_migration',
            path      => $path,
            error     => "$!",
        }
    );

    return 1;
}

sub _legacy_xml_path {
    my ($self) = @_;

    return Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config->new->getConfigXmlPath;
}

sub _scalar {
    my ( $self, $value ) = @_;

    return '' unless defined $value;
    return "$value" unless ref $value;
    return '';
}

sub _log_and_warn {
    my ( $self, $level, $message, $context ) = @_;

    $self->{plugin}->_log_runtime( $level => $message, $context || {} );
    warn "$message\n";

    return 1;
}

1;
