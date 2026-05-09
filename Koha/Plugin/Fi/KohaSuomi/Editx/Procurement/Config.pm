#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;

use XML::Simple;
use File::Basename;
use Data::Dumper;
use C4::Context;
use Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog;

use constant PLUGIN_CLASS => 'Koha::Plugin::Fi::KohaSuomi::Editx';

my $singleton;
my $configFile = "procurement-config.xml";

my @PLUGIN_SETTING_KEYS = qw(
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
);

my @PLUGIN_NOTIFICATION_KEYS = qw(
    mailto
    mailfrom
);

sub new {
    my $class = shift;
    $singleton ||= bless {}, $class;
}

sub loadConfigXml{
    my $self = shift;
    my $configs = {};
    my $xmlPath = $self->getConfigXmlPath();

    if( -e $xmlPath ){
        my $simple = XML::Simple->new;
        $configs = $simple->XMLin($xmlPath);
    }
    return $configs;
}

sub getConfigXmlPath{
    my $self = shift;
    my $kohaConfigPath = $ENV{'KOHA_CONF'} // '';
    return $configFile unless $kohaConfigPath;

    my $kohaPath = $ENV{'KOHA_PATH'};
    my($file, $path, $ext) = fileparse($kohaConfigPath);
    my $procurementConfigPath = $path . $configFile; # use the same path as koha_config.xml file
    return $procurementConfigPath;
}

sub getLogDir {
    my $self = shift;
    return Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog->runtime_log_dir;
}

sub getSettings{
    my $self = shift;
    my $confs = $self->loadConfigXml();
    $confs->{'settings'} ||= {};
    $confs->{'notifications'} ||= {};

    my $pluginData = $self->loadPluginData();
    foreach my $key (@PLUGIN_SETTING_KEYS) {
        my $pluginKey = "procurement_$key";
        if ( exists $pluginData->{$pluginKey} ) {
            $confs->{'settings'}->{$key} = $pluginData->{$pluginKey};
        }
    }
    foreach my $key (@PLUGIN_NOTIFICATION_KEYS) {
        my $pluginKey = "procurement_notification_$key";
        if ( exists $pluginData->{$pluginKey} ) {
            $confs->{'notifications'}->{$key} = $pluginData->{$pluginKey};
        }
    }

    $self->applyDefaultImportPaths( $confs->{'settings'} );
    $confs->{'settings'}->{'log_directory'} = $self->getLogDir();

    return $confs;
}

sub applyDefaultImportPaths {
    my ( $self, $settings ) = @_;

    my $paths = $self->recommendedImportPaths();
    return unless $paths;

    my %defaults = (
        import_tmp_path             => $paths->{tmp},
        import_load_path            => $paths->{load},
        import_archive_path         => $paths->{archive},
        import_failed_path          => $paths->{fail},
        import_failed_archived_path => $paths->{failed_archived},
    );

    for my $key ( keys %defaults ) {
        next if defined $settings->{$key} && $settings->{$key} ne '';
        $settings->{$key} = $defaults{$key};
    }

    return 1;
}

sub recommendedImportPaths {
    my $self = shift;

    my $instance = $self->kohaInstance();
    return unless defined $instance && $instance ne '';

    $instance =~ s/[^A-Za-z0-9_.-]/_/g;
    my $base = "/var/lib/koha/$instance/editx";

    return {
        tmp             => "$base/tmp",
        load            => "$base/load",
        archive         => "$base/archive",
        fail            => "$base/fail",
        failed_archived => "$base/failed_archived",
    };
}

sub kohaInstance {
    my $self = shift;

    return $ENV{'KOHA_INSTANCE'} if defined $ENV{'KOHA_INSTANCE'} && $ENV{'KOHA_INSTANCE'} ne '';

    my $kohaConfigPath = $ENV{'KOHA_CONF'} // '';
    if ( $kohaConfigPath =~ m{/etc/koha/sites/([^/]+)/} ) {
        return $1;
    }

    my ( undef, $path ) = fileparse($kohaConfigPath);
    $path =~ s{/$}{};
    if ( $path =~ m{/([^/]+)$} ) {
        return $1;
    }

    return;
}

sub loadPluginData {
    my $self = shift;

    my @pluginKeys = (
        map { "procurement_$_" } @PLUGIN_SETTING_KEYS,
        map { "procurement_notification_$_" } @PLUGIN_NOTIFICATION_KEYS,
    );
    my $placeholders = join ',', ('?') x @pluginKeys;
    my $rows = C4::Context->dbh->selectall_arrayref(
        "SELECT plugin_key, plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key IN ($placeholders)",
        { Slice => {} },
        PLUGIN_CLASS,
        @pluginKeys
    );

    return { map { $_->{plugin_key} => $_->{plugin_value} } @$rows };
}

sub getUseAutomatchBiblios {
    my $self = shift;
    my $settings = $self->getSettings();
    my $result = 'yes';
    if(defined $settings->{'settings'}->{'automatch_biblios'}){
        $result = $settings->{'settings'}->{'automatch_biblios'};
    }
    return $result;
}

sub getUseFinnaMaterials {
    my $self = shift;
    my $settings = $self->getSettings();
    my $result = 'no';
    if(defined $settings->{'settings'}->{'use_finna_materialtype'}){
        $result = $settings->{'settings'}->{'use_finna_materialtype'};
    }
    return $result;
}

1;
