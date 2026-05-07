#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;

use XML::Simple;
use File::Basename;
use Data::Dumper;
use C4::Context;

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
    my $kohaConfigPath = $ENV{'KOHA_CONF'};
    my $kohaPath = $ENV{'KOHA_PATH'};
    my($file, $path, $ext) = fileparse($kohaConfigPath);
    my $procurementConfigPath = $path . $configFile; # use the same path as koha_config.xml file
    return $procurementConfigPath;
}

sub getLogDir {
    my $self = shift;
    my $config = C4::Context->config('logdir') . "/editx";
    return $config;
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

    $confs->{'settings'}->{'log_directory'} = $self->getLogDir();

    return $confs;
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
