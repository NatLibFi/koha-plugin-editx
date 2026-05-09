package Koha::Plugin::Fi::KohaSuomi::Editx::Config;

use Modern::Perl;

use C4::Context;
use Mojo::JSON qw(decode_json encode_json);
use YAML::XS qw(Load);

use constant CONFIG_KEY   => 'config_json';
use constant CONFIG_VERSION => 1;
use constant PLUGIN_CLASS => 'Koha::Plugin::Fi::KohaSuomi::Editx';

my @IMPORT_KEYS = qw(
    import_tmp_path
    import_load_path
    import_archive_path
    import_failed_path
    import_failed_archived_path
);

my @PROCESSING_KEYS = qw(
    authoriser
    allowed_locations
    productform_alternative_triggers
    automatch_biblios
    use_finna_materialtype
);

my @NOTIFICATION_KEYS = qw(
    notification_mailto
    notification_mailfrom
);

sub load {
    my ( $class, $plugin ) = @_;

    my %plugin_data;
    for my $key ( $class->plugin_data_keys ) {
        my $value = eval { $plugin->retrieve_data($key) };
        $plugin_data{$key} = $value if defined $value;
    }

    return $class->from_plugin_data( \%plugin_data );
}

sub load_for_plugin_class {
    my ( $class, $plugin_class ) = @_;

    $plugin_class ||= PLUGIN_CLASS;
    my @keys = $class->plugin_data_keys;
    my $placeholders = join ',', ('?') x @keys;
    my $rows = C4::Context->dbh->selectall_arrayref(
        "SELECT plugin_key, plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key IN ($placeholders)",
        { Slice => {} },
        $plugin_class,
        @keys
    );

    return $class->from_plugin_data( { map { $_->{plugin_key} => $_->{plugin_value} } @{$rows} } );
}

sub plugin_data_keys {
    return (
        CONFIG_KEY,
        'sftp_sources_yaml',
        ( map { "procurement_$_" } ( @IMPORT_KEYS, @PROCESSING_KEYS ) ),
        map { "procurement_$_" } @NOTIFICATION_KEYS,
    );
}

sub from_plugin_data {
    my ( $class, $plugin_data ) = @_;

    $plugin_data ||= {};

    if ( defined $plugin_data->{ CONFIG_KEY() } && $plugin_data->{ CONFIG_KEY() } =~ /\S/ ) {
        my $decoded = eval { decode_json( $plugin_data->{ CONFIG_KEY() } ) };
        return $class->normalize($decoded) if !$@ && ref $decoded eq 'HASH';
    }

    return $class->from_legacy_plugin_data($plugin_data);
}

sub from_legacy_plugin_data {
    my ( $class, $plugin_data ) = @_;

    $plugin_data ||= {};

    my $config = $class->empty;

    for my $key (@IMPORT_KEYS) {
        my $value = $plugin_data->{"procurement_$key"};
        $config->{import}->{$key} = $value if defined $value;
    }

    for my $key (@PROCESSING_KEYS) {
        my $value = $plugin_data->{"procurement_$key"};
        $config->{processing}->{$key} = $value if defined $value;
    }

    $config->{notifications}->{mailto} = $plugin_data->{procurement_notification_mailto}
        if defined $plugin_data->{procurement_notification_mailto};
    $config->{notifications}->{mailfrom} = $plugin_data->{procurement_notification_mailfrom}
        if defined $plugin_data->{procurement_notification_mailfrom};

    $config->{sftp_sources} = $class->_legacy_sftp_sources( $plugin_data->{sftp_sources_yaml} );

    return $class->normalize($config);
}

sub from_flat {
    my ( $class, $params ) = @_;

    $params ||= {};
    my $settings = $params->{procurement_settings} || {};

    my $config = $class->empty;
    for my $key (@IMPORT_KEYS) {
        $config->{import}->{$key} = $settings->{$key} // '';
    }
    for my $key (@PROCESSING_KEYS) {
        $config->{processing}->{$key} = $settings->{$key} // '';
    }
    $config->{notifications}->{mailto}   = $settings->{notification_mailto} // '';
    $config->{notifications}->{mailfrom} = $settings->{notification_mailfrom} // '';
    $config->{sftp_sources} = $params->{sftp_sources} || [];

    return $class->normalize($config);
}

sub empty {
    return {
        version       => CONFIG_VERSION,
        import        => {},
        processing    => {
            automatch_biblios     => 'yes',
            use_finna_materialtype => 'no',
        },
        notifications => {},
        sftp_sources  => [],
    };
}

sub normalize {
    my ( $class, $config ) = @_;

    $config = {} unless ref $config eq 'HASH';
    my $normalized = $class->empty;

    $normalized->{version} = CONFIG_VERSION;

    my $import = ref $config->{import} eq 'HASH' ? $config->{import} : {};
    for my $key (@IMPORT_KEYS) {
        $normalized->{import}->{$key} = _scalar( $import->{$key} );
    }

    my $processing = ref $config->{processing} eq 'HASH' ? $config->{processing} : {};
    for my $key (@PROCESSING_KEYS) {
        $normalized->{processing}->{$key} = _scalar( $processing->{$key} );
    }
    $normalized->{processing}->{automatch_biblios} =
        _yes_no( $normalized->{processing}->{automatch_biblios}, 'yes' );
    $normalized->{processing}->{use_finna_materialtype} =
        _yes_no( $normalized->{processing}->{use_finna_materialtype}, 'no' );

    my $notifications = ref $config->{notifications} eq 'HASH' ? $config->{notifications} : {};
    $normalized->{notifications}->{mailto}   = _scalar( $notifications->{mailto} );
    $normalized->{notifications}->{mailfrom} = _scalar( $notifications->{mailfrom} );

    my $sources = ref $config->{sftp_sources} eq 'ARRAY' ? $config->{sftp_sources} : [];
    $normalized->{sftp_sources} = [
        map { $class->_normalize_source($_) }
            grep { ref $_ eq 'HASH' } @{$sources}
    ];

    return $normalized;
}

sub to_json {
    my ( $class, $config ) = @_;

    return encode_json( $class->normalize($config) );
}

sub store_data {
    my ( $class, $config ) = @_;

    return {
        CONFIG_KEY() => $class->to_json($config),
    };
}

sub procurement_settings {
    my ( $class, $config ) = @_;

    $config = $class->normalize($config);

    return {
        %{ $config->{import} },
        %{ $config->{processing} },
        notification_mailto   => $config->{notifications}->{mailto},
        notification_mailfrom => $config->{notifications}->{mailfrom},
    };
}

sub procurement_plugin_data {
    my ( $class, $config ) = @_;

    my $settings = $class->procurement_settings($config);
    my %data;

    for my $key ( @IMPORT_KEYS, @PROCESSING_KEYS ) {
        $data{"procurement_$key"} = $settings->{$key} // '';
    }
    $data{procurement_notification_mailto}   = $settings->{notification_mailto} // '';
    $data{procurement_notification_mailfrom} = $settings->{notification_mailfrom} // '';

    return \%data;
}

sub sftp_sources {
    my ( $class, $config ) = @_;

    $config = $class->normalize($config);
    return $config->{sftp_sources};
}

sub _normalize_source {
    my ( $class, $source ) = @_;

    my %normalized;
    for my $key (qw(
        id host port user identity_file remote_dir local_dir pattern after_download remote_archive_dir
        known_hosts_file strict_host_key_checking ssh_config
    )) {
        $normalized{$key} = _scalar( $source->{$key} );
    }

    $normalized{port} ||= 22;
    $normalized{pattern} ||= '*.xml';
    $normalized{after_download} ||= 'keep';
    $normalized{strict_host_key_checking} ||= 'yes';

    return \%normalized;
}

sub _legacy_sftp_sources {
    my ( $class, $yaml ) = @_;

    return [] unless defined $yaml && $yaml =~ /\S/;

    my $config = eval { Load($yaml) };
    return [] if $@ || ref $config ne 'HASH' || ref $config->{sources} ne 'ARRAY';

    return $config->{sources};
}

sub _scalar {
    my ($value) = @_;

    return '' unless defined $value;
    return "$value" unless ref $value;
    return '';
}

sub _yes_no {
    my ( $value, $default ) = @_;

    $value = _scalar($value);
    return $default unless length $value;
    return $value =~ /\A(?:1|yes|true|on)\z/i ? 'yes' : 'no';
}

1;
