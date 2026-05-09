#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
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
use_ok($plugin_class);

my $plugin = bless {}, $plugin_class;

sub _message_text {
    my ($messages) = @_;

    return join "\n", map { $_->{text} } @$messages;
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

subtest 'SFTP YAML parser normalizes optional source fields' => sub {
    my ( $sources, $messages, $has_blocking_errors ) = $plugin->_parse_sftp_sources_yaml(<<'YAML');
sources:
  - id: alexandria
    host: sftp.example.org
    user: editx-user
    remote_dir: /out/alexandria
    strict_host_key_checking: false
YAML

    ok( !$has_blocking_errors, 'Valid SFTP YAML has no blocking errors' );
    is_deeply( $messages, [], 'Valid SFTP YAML has no messages' );
    is( scalar @$sources, 1, 'Parser returns one source' );
    is( $sources->[0]->{port}, 22, 'Parser defaults port to 22' );
    is( $sources->[0]->{pattern}, '*.xml', 'Parser defaults pattern to *.xml' );
    is( $sources->[0]->{after_download}, 'keep', 'Parser defaults after_download to keep' );
    is( $sources->[0]->{strict_host_key_checking}, 'no', 'Parser normalizes false strict_host_key_checking to no' );
};

subtest 'SFTP YAML parser reports blocking source errors' => sub {
    my ( $sources, $messages, $has_blocking_errors ) = $plugin->_parse_sftp_sources_yaml(<<'YAML');
sources:
  - id: invalid-id
    port: abc
    after_download: archive
  - id: invalid-id
    host: sftp.example.org
    user: editx-user
    remote_dir: /out
YAML

    my $message_text = _message_text($messages);

    ok( $has_blocking_errors, 'Invalid SFTP YAML has blocking errors' );
    is( scalar @$sources, 2, 'Parser still returns normalized source entries for reporting' );
    like( $message_text, qr{SFTP source 1 has no host\.}, 'Parser reports missing host' );
    like( $message_text, qr{SFTP source 1 has no user\.}, 'Parser reports missing user' );
    like( $message_text, qr{SFTP source 1 has no remote_dir\.}, 'Parser reports missing remote_dir' );
    like( $message_text, qr{SFTP source 1 port 'abc' is not numeric\.}, 'Parser reports a nonnumeric port' );
    like( $message_text, qr{SFTP source 1 uses archive but has no remote_archive_dir\.}, 'Parser reports archive without remote_archive_dir' );
    like( $message_text, qr{SFTP source 2 repeats id 'invalid-id'\.}, 'Parser reports duplicate source ids' );
};

subtest 'SFTP YAML parser allows simple globs and rejects unsafe patterns' => sub {
    my ( $sources, $messages, $has_blocking_errors ) = $plugin->_parse_sftp_sources_yaml(<<'YAML');
sources:
  - id: valid_glob
    host: sftp.example.org
    user: editx-user
    remote_dir: /out
    pattern: LibraryShipNotice_*.xml
  - id: unsafe_glob
    host: sftp.example.org
    user: editx-user
    remote_dir: /out
    pattern: ../*.xml
YAML

    my $message_text = _message_text($messages);

    ok( $has_blocking_errors, 'Unsafe SFTP pattern has blocking errors' );
    is( $sources->[0]->{pattern}, 'LibraryShipNotice_*.xml', 'Parser keeps a simple SFTP glob pattern' );
    like( $message_text, qr{SFTP source 2 pattern '\.\./\*\.xml' is invalid}, 'Parser rejects path-like SFTP patterns' );
    is( $plugin->_manual_stage_sftp_glob('LibraryShipNotice_*.xml'), 'LibraryShipNotice_*.xml', 'Manual staged list accepts a simple filename pattern' );
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
        return bless { entries => $entries, downloads => [] }, $class;
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
    is( $listing->{sftp_output}, '4 remote entries returned.', 'Manual staged listing reports structured SFTP result count' );
    is( $listing->{sftp_operation}, 'Net::SFTP::Foreign ls(/out)', 'Manual staged listing reports the SFTP list operation for diagnostics' );
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
    is( $listing->{sftp_output}, 'Net::SFTP::Foreign returned an empty remote directory listing.', 'Manual staged listing keeps empty output explicit for warning messages' );
    is( $listing->{sftp_operation}, 'Net::SFTP::Foreign ls(/out)', 'Manual staged listing reports the SFTP list operation' );
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
    like( _message_text($messages), qr{downloaded for preview}, 'Downloaded redirect shows the staff success message' );

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
    like( _message_text($messages), qr{Selected EDItX import finished: processed 1, failed 0, skipped 0}, 'Imported redirect shows the staff success message' );
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

subtest 'SFTP YAML default does not preload example sources' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::retrieve_data' } = sub { return; };

    my $yaml = $plugin->_sftp_sources_yaml();
    my ( $sources, $messages, $has_blocking_errors ) = $plugin->_parse_sftp_sources_yaml($yaml);

    is( $yaml, "sources: []\n", 'Missing saved SFTP config defaults to an empty source list' );
    unlike( $yaml, qr{alexandria_library|sftp\.example\.org}, 'Default SFTP YAML contains no example source values' );
    ok( !$has_blocking_errors, 'Empty default SFTP YAML has no parser errors' );
    is_deeply( $messages, [], 'Empty default SFTP YAML has no parser messages' );
    is( scalar @$sources, 0, 'Empty default SFTP YAML has no sources' );
};

subtest 'Tool SFTP status rejects an empty saved source list' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::retrieve_data' } = sub { return "sources: []\n"; };

    my $status = $plugin->_tool_sftp_status( { import_tmp_path => '/tmp/editx' } );
    my $message_text = _message_text( $status->{messages} );

    is( $status->{count}, 0, 'Tool status counts no saved SFTP sources' );
    ok( $status->{has_errors}, 'Tool status marks an empty source list as not runnable' );
    like( $message_text, qr{No SFTP sources are saved in the EDItX plugin configuration\.}, 'Tool status reports missing SFTP sources' );
};

subtest 'Recommended import paths are scoped to the Koha instance' => sub {
    no strict 'refs';
    no warnings qw(once redefine);
    local *{ $plugin_class . '::_koha_instance' } = sub { return 'kohadev'; };

    my $paths = $plugin->_recommended_import_paths();

    is( $paths->{base}, '/var/lib/koha/kohadev/editx', 'Recommended base path uses the detected Koha instance' );
    is( $paths->{tmp}, '/var/lib/koha/kohadev/editx/tmp', 'Recommended tmp path is below the base path' );
    is( $paths->{load}, '/var/lib/koha/kohadev/editx/load', 'Recommended load path is below the base path' );
    is( $paths->{archive}, '/var/lib/koha/kohadev/editx/archive', 'Recommended archive path is below the base path' );
    is( $paths->{fail}, '/var/lib/koha/kohadev/editx/fail', 'Recommended fail path is below the base path' );
    is( $paths->{failed_archived}, '/var/lib/koha/kohadev/editx/failed_archived', 'Recommended failed archive path is below the base path' );
    unlike( $paths->{base}, qr{/spool/}, 'Recommended base path avoids the root-owned Koha spool area' );
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

    local $ENV{KOHA_INSTANCE} = 'kohadev';
    local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config::loadConfigXml = sub {
        return { settings => {}, notifications => {} };
    };
    local *Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config::loadPluginData = sub {
        return {};
    };

    my $settings = Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config->new->getSettings;

    is( $settings->{settings}->{import_tmp_path}, '/var/lib/koha/kohadev/editx/tmp', 'Console config defaults tmp folder from KOHA_INSTANCE' );
    is( $settings->{settings}->{import_load_path}, '/var/lib/koha/kohadev/editx/load', 'Console config defaults load folder from KOHA_INSTANCE' );
    is( $settings->{settings}->{import_archive_path}, '/var/lib/koha/kohadev/editx/archive', 'Console config defaults archive folder from KOHA_INSTANCE' );
    is( $settings->{settings}->{import_failed_path}, '/var/lib/koha/kohadev/editx/fail', 'Console config defaults failed folder from KOHA_INSTANCE' );
    is( $settings->{settings}->{import_failed_archived_path}, '/var/lib/koha/kohadev/editx/failed_archived', 'Console config defaults failed archive folder from KOHA_INSTANCE' );
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

subtest 'ProductForm CSV parser nulls unknown itemtypes without blocking save' => sub {
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

    ok( !$has_blocking_errors, 'Unknown itemtypes are warnings, not blocking errors' );
    is_deeply(
        $rows,
        [
            { onix_code => 'AA', productform => 'BK', productform_alternative => undef },
            { onix_code => 'AB', productform => undef, productform_alternative => 'ALT' },
            { onix_code => 'AA', productform => 'BK', productform_alternative => 'ALT' },
        ],
        'Parser keeps rows and nulls unknown itemtype values'
    );
    like( $message_text, qr{Line 2: item type 'MISSING' does not exist; productform_alternative was stored as NULL\.}, 'Parser warns about unknown alternative itemtype' );
    like( $message_text, qr{Line 3: item type 'NOPE' does not exist; productform was stored as NULL\.}, 'Parser warns about unknown primary itemtype' );
    like( $message_text, qr{Line 4 repeats ONIX code 'AA'; the later value will win\.}, 'Parser warns about duplicate ONIX codes' );
};

done_testing();
