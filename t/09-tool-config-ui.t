#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $plugin_root = File::Spec->catdir( $Bin, '..' );

sub read_file {
    my ($relative_path) = @_;

    my $path = File::Spec->catfile( $plugin_root, split m{/}, $relative_path );
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    return $content;
}

my $plugin_pm = read_file('Koha/Plugin/Fi/KohaSuomi/Editx.pm');
my $configure = read_file('Koha/Plugin/Fi/KohaSuomi/Editx/configure.tt');
my $tool = read_file('Koha/Plugin/Fi/KohaSuomi/Editx/tool.tt');
my $breadcrumbs = read_file('Koha/Plugin/Fi/KohaSuomi/Editx/includes/editx_breadcrumbs.inc');
my $css = read_file('Koha/Plugin/Fi/KohaSuomi/Editx/static_files/editx.css');
my $install_sql = read_file('installation/create_tables.sql');

like( $plugin_pm, qr{sub\s+tool\s*\{}, 'Plugin exposes a Koha tool page' );
like( $plugin_pm, qr{\$method\s*\|\|=\s*'tool'}, 'Plugin method URL defaults to the tool page' );
like( $plugin_pm, qr{tool_href\s*=>\s*\$self->plugin_method_url\('tool'\)}, 'Configure template receives tool_href' );
like( $plugin_pm, qr{manual_run_available}, 'Tool template receives manual action availability context' );
like( $plugin_pm, qr{get_qualified_table_name\('procurement_file'\)}, 'Plugin install uses a qualified procurement_file table' );
like( $plugin_pm, qr{_migrate_legacy_procurement_file_table}, 'Plugin install migrates legacy procurement_file data' );
like( $install_sql, qr{CREATE TABLE IF NOT EXISTS `koha_plugin_fi_kohasuomi_editx_map_productform`}, 'Install SQL still creates the ProductForm mapping table' );
unlike( $install_sql, qr{INSERT INTO\s+koha_plugin_fi_kohasuomi_editx_map_productform}i, 'Install SQL does not seed ProductForm mappings' );
unlike( $install_sql, qr{28VRK|28VRKLN|14VRK|EILAINATA}, 'Install SQL does not contain KohaSuomi-local itemtype seeds' );

like( $breadcrumbs, qr{href="\[%\s*tool_href\s*\|\s*html\s*%\]">EDItX plugin</a>}, 'Breadcrumb plugin root points to the tool page' );
like( $breadcrumbs, qr{active_method\s*!=\s*'configure'}, 'Breadcrumb configure shortcut is hidden on the configure page' );
like( $breadcrumbs, qr{href="\[%\s*configure_href\s*\|\s*html\s*%\]">Configure</a>}, 'Breadcrumb includes a configure shortcut on operational pages' );

unlike( $configure, qr{run_sync_now}, 'Configure page has no manual sync action input' );
unlike( $configure, qr{Download and import now}, 'Configure page has no manual download/import button' );
unlike( $configure, qr{Manual run result}, 'Configure page has no manual run result block' );
like( $configure, qr{href="\[%\s*tool_href\s*\|\s*html\s*%\]">Cancel</a>}, 'Configure cancel returns to the tool page' );
like( $configure, qr{id="mapping_csv"[\s\S]+?rows="8"}, 'Configure page keeps the mapping CSV editor compact' );
like( $configure, qr{data-editx-collapsible-storage="editx\.configure\.runtimeLogging\.v1"}, 'Runtime logging section has persisted collapse state' );
like( $configure, qr{data-editx-collapsible-default="collapsed"}, 'Runtime logging section is collapsed by default' );
like( $configure, qr{window\.localStorage}, 'Configure page persists the runtime logging collapse state in localStorage' );
like( $css, qr{\.editx-collapsible\.is-collapsed\s+\.editx-collapsible-body}, 'CSS hides collapsed runtime logging content' );

like( $tool, qr{active_text='Operations'\s+active_method='tool'}, 'Tool page marks the Operations breadcrumb active' );
like( $tool, qr{\[%\s+USE\s+raw\s+%\]}, 'Tool page loads Koha raw plugin before using template filters' );
like( $tool, qr{name="run_sync_now"\s+value="1"}, 'Tool page exposes the manual sync POST action' );
like( $tool, qr{Download and import now}, 'Tool page has the manual download/import button' );
like( $tool, qr{Manual run result}, 'Tool page renders manual run results' );
like( $tool, qr{nightly_sync_enabled}, 'Tool page shows read-only nightly automation status' );
like( $tool, qr{href="\[%\s*configure_href\s*\|\s*html\s*%\]">Configure</a>}, 'Tool page links to configuration' );
like( $tool, qr{sftp_config_messages[\s\S]+editx-manual-sync-form}, 'Tool page renders SFTP prerequisite warnings before the manual action form' );
like( $tool, qr{editx-action-note}, 'Tool page explains disabled manual runs inside the manual action form' );
unlike( $tool, qr{Manual download and import needs valid SFTP sources}, 'Tool page does not duplicate SFTP warnings below the manual action form' );
like( $css, qr{\.editx-manual-sync-form\s+\.editx-action-note}, 'CSS styles the manual action disabled note' );

done_testing();
