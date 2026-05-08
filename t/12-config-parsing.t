#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
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

    is( $paths->{base}, '/var/lib/koha/kohadev/spool/editx', 'Recommended base path uses the detected Koha instance' );
    is( $paths->{tmp}, '/var/lib/koha/kohadev/spool/editx/tmp', 'Recommended tmp path is below the base path' );
    is( $paths->{load}, '/var/lib/koha/kohadev/spool/editx/load', 'Recommended load path is below the base path' );
    is( $paths->{archive}, '/var/lib/koha/kohadev/spool/editx/archive', 'Recommended archive path is below the base path' );
    is( $paths->{fail}, '/var/lib/koha/kohadev/spool/editx/fail', 'Recommended fail path is below the base path' );
    is( $paths->{failed_archived}, '/var/lib/koha/kohadev/spool/editx/failed_archived', 'Recommended failed archive path is below the base path' );
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
