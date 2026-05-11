package Koha::Plugin::Fi::KohaSuomi::Editx::Config;

use Modern::Perl;

use C4::Context;
use Mojo::JSON qw(decode_json encode_json);

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

my @SFTP_SOURCE_KEYS = qw(
    enabled
    id
    host
    port
    user
    identity_file
    remote_dir
    local_dir
    pattern
    success_action
    remote_archive_dir
    known_hosts_file
    strict_host_key_checking
    ssh_config
);

my @FOLDER_SOURCE_KEYS = qw(
    enabled
    id
    local_dir
    pattern
    success_action
    local_archive_dir
    minimum_age_seconds
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
    return (CONFIG_KEY);
}

sub from_plugin_data {
    my ( $class, $plugin_data ) = @_;

    $plugin_data ||= {};

    if ( defined $plugin_data->{ CONFIG_KEY() } && $plugin_data->{ CONFIG_KEY() } =~ /\S/ ) {
        my $decoded = eval { decode_json( $plugin_data->{ CONFIG_KEY() } ) };
        return $class->normalize($decoded) if !$@ && ref $decoded eq 'HASH';
    }

    return $class->empty;
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
    $config->{sftp_sources}   = $params->{sftp_sources}   || [];
    $config->{folder_sources} = $params->{folder_sources} || [];

    return $class->normalize($config);
}

sub empty {
    return {
        version    => CONFIG_VERSION,
        import     => {},
        processing => {
            automatch_biblios     => 'yes',
            use_finna_materialtype => 'no',
        },
        notifications  => {},
        sftp_sources   => [],
        folder_sources => [],
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
        map { $class->_normalize_sftp_source($_) }
            grep { ref $_ eq 'HASH' } @{$sources}
    ];

    my $folder_sources = ref $config->{folder_sources} eq 'ARRAY' ? $config->{folder_sources} : [];
    $normalized->{folder_sources} = [
        map { $class->_normalize_folder_source($_) }
            grep { ref $_ eq 'HASH' } @{$folder_sources}
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

sub folder_sources {
    my ( $class, $config ) = @_;

    $config = $class->normalize($config);
    return $config->{folder_sources};
}

sub _normalize_sftp_source {
    my ( $class, $source ) = @_;

    my %normalized;
    for my $key (@SFTP_SOURCE_KEYS) {
        $normalized{$key} = _scalar( $source->{$key} );
    }

    $normalized{enabled} = _yes_no( $normalized{enabled}, 'yes' );
    $normalized{port} ||= 22;
    $normalized{pattern} ||= '*.xml';
    $normalized{success_action} = _source_success_action( $normalized{success_action} );
    $normalized{strict_host_key_checking} ||= 'yes';

    return \%normalized;
}

sub _normalize_folder_source {
    my ( $class, $source ) = @_;

    my %normalized;
    for my $key (@FOLDER_SOURCE_KEYS) {
        $normalized{$key} = _scalar( $source->{$key} );
    }

    $normalized{enabled} = _yes_no( $normalized{enabled}, 'yes' );
    $normalized{pattern} ||= '*.xml';
    $normalized{success_action} = _source_success_action( $normalized{success_action} );
    $normalized{minimum_age_seconds} = 60
        if !defined $normalized{minimum_age_seconds} || $normalized{minimum_age_seconds} eq '';

    return \%normalized;
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

sub _source_success_action {
    my ($value) = @_;

    $value = _scalar($value);
    return $value =~ /\A(?:keep|delete|archive)\z/ ? $value : 'keep';
}

1;
